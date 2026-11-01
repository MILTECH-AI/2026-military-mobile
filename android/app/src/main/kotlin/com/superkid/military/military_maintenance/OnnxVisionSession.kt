package com.superkid.military.military_maintenance

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.media.ExifInterface
import android.os.Debug
import android.os.Process
import android.system.Os
import ai.onnxruntime.OnnxJavaType
import ai.onnxruntime.OnnxTensor
import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtSession
import java.io.File
import java.nio.ByteBuffer
import java.security.MessageDigest
import org.json.JSONArray
import org.json.JSONObject

object VisionFiles {
    const val ID = "ssd-mobilenet-int8-public-v1"
    const val SHA = "2b79e6a7fb1ec6a33f332b9b10d82d9de4b7b49dcd26b5946921bb356895c954"
    const val BYTES = 9540809L
    fun active(context: Context) = File(context.filesDir, "optional-models/$ID.onnx")
    fun info(context: Context): Map<String, Any> = mapOf("modelId" to ID, "task" to "vision", "tier" to "basic",
        "minAndroidApi" to 24, "supportedAbi" to true, "installed" to (active(context).isFile && active(context).length() == BYTES),
        "bytes" to BYTES, "sha256" to SHA, "classes" to "COCO; no verified Rexton part mapping")
    fun validate(file: File) {
        require(file.isFile && file.length() == BYTES)
        val hash = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input -> val buffer = ByteArray(65536)
            while (true) { val n = input.read(buffer); if (n < 0) break; hash.update(buffer, 0, n) } }
        require(hash.digest().joinToString("") { "%02x".format(it) } == SHA)
    }
    fun install(context: Context, source: File) {
        require(source.canonicalPath.startsWith(context.cacheDir.canonicalPath + File.separator))
        require(source.length() == BYTES && context.filesDir.usableSpace > BYTES + 32L * 1024 * 1024)
        val target = active(context); target.parentFile!!.mkdirs()
        val staging = File.createTempFile("vision-import-", ".onnx", target.parentFile)
        try { source.inputStream().use { input -> staging.outputStream().use { input.copyTo(it) } }; validate(staging); Os.rename(staging.path, target.path) }
        finally { staging.delete() }
    }
}

/** Public COCO model execution test. No military images or part-performance claim. */
class OnnxVisionSession(private val context: Context, threads: Int) : NativeModelSession {
    private val environment = OrtEnvironment.getEnvironment()
    private val session: OrtSession
    init {
        VisionFiles.validate(VisionFiles.active(context))
        session = OrtSession.SessionOptions().use { options ->
            options.setIntraOpNumThreads(threads); options.setInterOpNumThreads(1)
            options.setOptimizationLevel(OrtSession.SessionOptions.OptLevel.ALL_OPT)
            environment.createSession(VisionFiles.active(context).path, options)
        }
    }
    private fun pixels(file: File): ByteArray {
        require(file.canonicalPath.startsWith(File(context.applicationInfo.dataDir).canonicalPath + File.separator))
        require(file.isFile && file.length() in 1..(32L * 1024 * 1024))
        val options = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(file.path, options)
        require(options.outWidth in 1..20000 && options.outHeight in 1..20000)
        options.inSampleSize = 1
        while (maxOf(options.outWidth, options.outHeight) / options.inSampleSize > 600) options.inSampleSize *= 2
        options.inJustDecodeBounds = false
        options.inPreferredConfig = Bitmap.Config.ARGB_8888
        val decoded = requireNotNull(BitmapFactory.decodeFile(file.path, options))
        var oriented = decoded
        try {
            val orientation = try { ExifInterface(file.path).getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL) } catch (_: Exception) { 1 }
            val matrix = Matrix()
            when (orientation) {
                2 -> matrix.setScale(-1f, 1f)
                3 -> matrix.setRotate(180f)
                4 -> matrix.setScale(1f, -1f)
                5 -> { matrix.setRotate(90f); matrix.postScale(-1f, 1f) }
                6 -> matrix.setRotate(90f)
                7 -> { matrix.setRotate(270f); matrix.postScale(-1f, 1f) }
                8 -> matrix.setRotate(270f)
            }
            if (!matrix.isIdentity) oriented = Bitmap.createBitmap(decoded, 0, 0, decoded.width, decoded.height, matrix, false)
            val scaled = Bitmap.createScaledBitmap(oriented, 300, 300, false)
            try {
                val argb = IntArray(300 * 300); scaled.getPixels(argb, 0, 300, 0, 0, 300, 300)
                return ByteArray(argb.size * 3).also { rgb -> for (i in argb.indices) {
                    rgb[i*3] = (argb[i] shr 16).toByte(); rgb[i*3+1] = (argb[i] shr 8).toByte(); rgb[i*3+2] = argb[i].toByte()
                } }
            } finally { if (scaled !== oriented) scaled.recycle() }
        } finally { if (oriented !== decoded) oriented.recycle(); decoded.recycle() }
    }
    override fun infer(inputJson: String): String {
        val image = File(JSONObject(inputJson).getString("imagePath"))
        val rgb = pixels(image)
        OnnxTensor.createTensor(environment, ByteBuffer.wrap(rgb), longArrayOf(1,300,300,3), OnnxJavaType.UINT8).use { tensor ->
            session.run(mapOf("inputs" to tensor)).use { output ->
                @Suppress("UNCHECKED_CAST")
                val boxes = (output.get("detection_boxes").get().value as Array<Array<FloatArray>>)[0]
                @Suppress("UNCHECKED_CAST")
                val classes = (output.get("detection_classes").get().value as Array<FloatArray>)[0]
                @Suppress("UNCHECKED_CAST")
                val scores = (output.get("detection_scores").get().value as Array<FloatArray>)[0]
                val count = (output.get("num_detections").get().value as FloatArray)[0].toInt().coerceIn(0,minOf(boxes.size,classes.size,scores.size,100))
                val detections = JSONArray()
                for (i in 0 until count) {
                    val box = boxes[i]
                    if (scores[i].isFinite() && scores[i] in .5f..1f && classes[i].isFinite() && classes[i].toInt() in 1..90 && box.size == 4 && box.all { it.isFinite() } && box[0]<=box[2] && box[1]<=box[3]) {
                        detections.put(JSONObject().put("classId", classes[i].toInt()).put("score",scores[i]).put("box",JSONArray(box.map { it.coerceIn(0f,1f) })))
                    }
                }
                return JSONObject().put("modelId",VisionFiles.ID).put("modelSha256",VisionFiles.SHA).put("detections",detections)
                    .put("workerPid",Process.myPid()).put("pssKb",Debug.getPss()).put("inputShape",JSONArray(listOf(1,300,300,3)))
                    .put("threshold",.5).put("purpose","public_runtime_probe_not_rexton_part_detection").toString()
            }
        }
    }
    override fun close() { session.close() }
}
