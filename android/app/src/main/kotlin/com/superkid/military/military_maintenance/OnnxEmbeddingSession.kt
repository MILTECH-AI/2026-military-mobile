package com.superkid.military.military_maintenance

import android.content.Context
import android.os.Debug
import android.os.Process
import ai.onnxruntime.OnnxTensor
import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtSession
import java.nio.LongBuffer
import org.json.JSONArray
import org.json.JSONObject

class OnnxEmbeddingSession(context: Context, threads: Int) : NativeModelSession {
    private val directory = EmbeddingFiles.active(context)
    private val manifest = EmbeddingFiles.validate(directory)
    private val tokenizer = WordPiece(java.io.File(directory, "vocab.txt"))
    private val environment = OrtEnvironment.getEnvironment()
    private val session = OrtSession.SessionOptions().use { options ->
        options.setIntraOpNumThreads(threads)
        options.setInterOpNumThreads(1)
        options.setOptimizationLevel(OrtSession.SessionOptions.OptLevel.ALL_OPT)
        environment.createSession(java.io.File(directory, "model.onnx").path, options)
    }
    override fun infer(inputJson: String): String {
        val input = JSONObject(inputJson)
        val ids = tokenizer.encode(input.getString("text"))
        val shape = longArrayOf(1, ids.size.toLong())
        OnnxTensor.createTensor(environment, LongBuffer.wrap(ids), shape).use { tokens ->
            OnnxTensor.createTensor(environment, LongBuffer.wrap(LongArray(ids.size) { 1L }), shape).use { mask ->
                session.run(mapOf("input_ids" to tokens, "attention_mask" to mask)).use { outputs ->
                    @Suppress("UNCHECKED_CAST")
                    val vector = (outputs[0].value as Array<FloatArray>)[0]
                    require(vector.size == 512 && vector.all { it.isFinite() })
                    val result = JSONObject().put("embedding", JSONArray(vector.toList()))
                        .put("workerPid", Process.myPid()).put("pssKb", Debug.getPss())
                        .put("modelId", manifest.getString("modelId"))
                        .put("modelSha256", manifest.getJSONObject("files").getJSONObject("model.onnx").getString("sha256"))
                        .put("executionConfig", EmbeddingFiles.EXECUTION_CONFIG)
                    if (input.optBoolean("diagnostic", false)) result.put("tokenIds", JSONArray(ids.toList()))
                    return result.toString()
                }
            }
        }
    }
    override fun close() { session.close() }
}
