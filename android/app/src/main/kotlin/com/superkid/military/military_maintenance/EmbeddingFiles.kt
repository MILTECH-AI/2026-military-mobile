package com.superkid.military.military_maintenance

import android.content.Context
import org.json.JSONObject
import java.io.File
import java.security.MessageDigest
import java.util.zip.ZipInputStream

object EmbeddingFiles {
    const val EXECUTION_CONFIG = "ort1.23.2-all-cpu-u8s8-cased128-dense512-v1"
    private val names = setOf("model.onnx", "vocab.txt", "index.json", "knowledge.json", "LICENSE.txt", "manifest.json")
    fun active(context: Context) = File(context.filesDir, "rag/active")
    fun sha(file: File): String {
        val hash = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buffer = ByteArray(65536)
            while (true) { val n = input.read(buffer); if (n < 0) break; hash.update(buffer, 0, n) }
        }
        return hash.digest().joinToString("") { "%02x".format(it.toInt() and 255) }
    }
    fun validate(directory: File): JSONObject {
        val manifestFile = File(directory, "manifest.json")
        require(manifestFile.length() in 1..32768)
        val m = JSONObject(manifestFile.readText())
        require(m.getInt("version") == 1 && m.getString("modelId") == "distiluse-int8-v1")
        require(m.getInt("dimension") == 512 && m.getInt("maxTokens") == 128 && m.getInt("minAndroidApi") == 24)
        require(m.getString("license") == "Apache-2.0" && m.getString("runtime") == "onnxruntime-1.23.2-cpu")
        require(m.getString("executionConfig") == EXECUTION_CONFIG)
        val files = m.getJSONObject("files")
        require(files.keys().asSequence().toSet() == names - "manifest.json")
        for (name in names - "manifest.json") {
            val file = File(directory, name)
            val spec = files.getJSONObject(name)
            require(file.isFile && file.length() == spec.getLong("bytes") && sha(file) == spec.getString("sha256"))
        }
        require(File(directory, "index.json").length() <= 4 * 1024 * 1024)
        require(File(directory, "knowledge.json").length() <= 4 * 1024 * 1024)
        require(File(directory, "vocab.txt").length() <= 4 * 1024 * 1024)
        return m
    }
    fun install(context: Context, source: File): Map<String, Any> {
        require(source.canonicalPath.startsWith(context.cacheDir.canonicalPath + File.separator) && source.isFile)
        require(source.length() in 1..(256L * 1024 * 1024))
        require(context.filesDir.usableSpace > 512L * 1024 * 1024)
        val parent = File(context.filesDir, "rag").apply { mkdirs() }
        val stage = File(parent, "staging-${System.nanoTime()}").apply { mkdir() }
        var total = 0L
        try {
            val seen = mutableSetOf<String>()
            ZipInputStream(source.inputStream().buffered()).use { zip ->
                while (true) {
                    val entry = zip.nextEntry ?: break
                    require(!entry.isDirectory && entry.name in names && seen.add(entry.name))
                    File(stage, entry.name).outputStream().use { output ->
                        val buffer = ByteArray(65536)
                        while (true) {
                            val n = zip.read(buffer); if (n < 0) break
                            total += n; require(total <= 256L * 1024 * 1024)
                            output.write(buffer, 0, n)
                        }
                    }
                }
            }
            require(seen == names)
            validate(stage)
            val active = active(context)
            val backup = File(parent, "previous-${System.nanoTime()}")
            if (active.exists()) check(active.renameTo(backup))
            if (!stage.renameTo(active)) { backup.renameTo(active); error("install_failed") }
            backup.deleteRecursively() // Fixed app-private sibling generated above.
            return info(context)
        } finally { stage.deleteRecursively() }
    }
    fun info(context: Context): Map<String, Any> {
        val dir = active(context)
        val file = File(dir, "manifest.json")
        if (!file.isFile) return mapOf("installed" to false)
        val m = JSONObject(file.readText())
        return mapOf("installed" to true, "modelId" to m.getString("modelId"),
            "minAndroidApi" to m.getInt("minAndroidApi"), "indexPath" to File(dir, "index.json").path,
            "knowledgePath" to File(dir, "knowledge.json").path,
            "modelSha256" to m.getJSONObject("files").getJSONObject("model.onnx").getString("sha256"),
            "executionConfig" to m.getString("executionConfig"))
    }
}
