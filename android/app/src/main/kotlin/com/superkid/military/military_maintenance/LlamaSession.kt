package com.superkid.military.military_maintenance

import android.app.ActivityManager
import android.content.Context
import android.os.Build
import android.os.Debug
import android.os.Process
import android.system.Os
import java.io.File
import java.security.MessageDigest
import org.json.JSONObject

/** Optional public model. Import on PC/USB; no downloader or network runtime. */
object LlmFiles {
    const val ID = "qwen3-0.6b-q4_0"
    const val SHA = "da2572f16c06133561ce56accaa822216f2391ef4d37fba427801cd6736417d4"
    const val BYTES = 428970080L
    const val REVISION = "0ec4027a2a0183de87c007069adddc06e665f7de"
    fun active(context: Context) = File(context.filesDir, "optional-models/$ID.gguf")
    fun supported() = Build.VERSION.SDK_INT >= 28 && Process.is64Bit()
    fun validate(file: File) {
        require(file.isFile && file.length() == BYTES)
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buffer = ByteArray(65536)
            while (true) { val n = input.read(buffer); if (n < 0) break; digest.update(buffer, 0, n) }
        }
        require(digest.digest().joinToString("") { "%02x".format(it) } == SHA)
    }
    fun info(context: Context): Map<String, Any> = mapOf(
        "modelId" to ID, "task" to "generation", "tier" to "generation", "minAndroidApi" to 28,
        "installed" to (active(context).isFile && active(context).length() == BYTES),
        "supportedAbi" to Process.is64Bit(), "bytes" to BYTES, "sha256" to SHA,
        "llamaRevision" to REVISION, "contextTokens" to 1536, "maxOutputTokens" to 128)
    fun install(context: Context, source: File) {
        require(supported())
        require(source.canonicalPath.startsWith(context.cacheDir.canonicalPath + File.separator))
        val target = active(context)
        target.parentFile!!.mkdirs()
        require(context.filesDir.usableSpace > BYTES + 64L * 1024 * 1024)
        val staging = File.createTempFile("llm-import-", ".gguf", target.parentFile)
        try {
            require(source.length() == BYTES)
            source.inputStream().use { input -> staging.outputStream().use { output -> input.copyTo(output) } }
            validate(staging)
            Os.rename(staging.path, target.path)
        } finally { staging.delete() }
    }
}

/** Referenced only after API/ABI checks. API 24 never loads the API 28 .so. */
object LlamaNative {
    init { System.loadLibrary("maintenance_llama") }
    external fun open(path: String, threads: Int): Long
    external fun generate(handle: Long, prompt: String, grammar: String, limit: Int): String
    external fun close(handle: Long)
}

class LlamaSession(context: Context, threads: Int) : NativeModelSession {
    private var handle = 0L
    init {
        require(LlmFiles.supported())
        val memory = ActivityManager.MemoryInfo()
        (context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager).getMemoryInfo(memory)
        check(!memory.lowMemory) { "low_memory" }
        LlmFiles.validate(LlmFiles.active(context))
        handle = LlamaNative.open(LlmFiles.active(context).path, threads)
        check(handle != 0L)
    }
    override fun infer(inputJson: String): String {
        val input = JSONObject(inputJson)
        val limit = input.optInt("maxTokens", 96)
        require(limit in 64..128)
        val output = LlamaNative.generate(handle, input.getString("prompt"), input.getString("grammar"), limit)
        val split = output.indexOf('\n')
        val counts = output.substring(0, split).split(',')
        return JSONObject().put("text", output.substring(split + 1)).put("inputTokens", counts[0].toInt())
            .put("outputTokens", counts[1].toInt()).put("ended", counts[2] == "1")
            .put("modelId", LlmFiles.ID).put("modelSha256", LlmFiles.SHA)
            .put("llamaRevision", LlmFiles.REVISION).put("workerPid", Process.myPid()).put("pssKb", Debug.getPss()).toString()
    }
    override fun close() { if (handle != 0L) { LlamaNative.close(handle); handle = 0L } }
}
