package com.superkid.military.military_maintenance

import android.content.Context
import android.os.Debug
import android.os.Process
import ai.onnxruntime.*
import java.io.File
import java.nio.FloatBuffer
import java.util.zip.ZipInputStream
import org.json.JSONArray
import org.json.JSONObject

object SystemPilotFiles {
    const val ID="maintenance-system-pilot-v1"
    const val CONFIG="hash-char-binary-fnv1a32-v1"
    private val names=setOf("model.onnx","model.json","manifest.json")
    private val labels=setOf("엔진/연료","흡기/배기","냉각","제동","조향/현가","동력전달","공조","차체","전장")
    fun active(context:Context)=File(context.filesDir,"system-pilot/active")
    fun validate(dir:File):JSONObject {
        require(File(dir,"manifest.json").length() in 1..32768)
        val manifest=JSONObject(File(dir,"manifest.json").readText())
        require(manifest.getInt("version")==1&&manifest.getString("modelId")==ID&&manifest.getInt("minAndroidApi")==24)
        val files=manifest.getJSONObject("files");require(files.keys().asSequence().toSet()==names-"manifest.json")
        for(name in names-"manifest.json"){
            val f=File(dir,name);val spec=files.getJSONObject(name)
            require(f.isFile&&f.length() in 1..(2L*1024*1024)&&f.length()==spec.getLong("bytes")&&EmbeddingFiles.sha(f)==spec.getString("sha256"))
        }
        val meta=JSONObject(File(dir,"model.json").readText())
        require(meta.getInt("version")==1&&meta.getString("modelId")==ID&&meta.getInt("dimension")==4096&&meta.getInt("maxChars")==2000&&meta.getString("featureConfig")==CONFIG)
        require(meta.getString("sourceStatus")=="authorship_unconfirmed"&&meta.getString("labelStatus")=="single_ai_draft_not_human_reviewed"&&meta.getString("use")=="suggestion_only")
        val classes=meta.getJSONArray("labels");require(classes.length()==9&&(0 until classes.length()).map{classes.getString(it)}.toSet()==labels)
        val seen=meta.getJSONArray("seenFeatureIds");require(seen.length() in 1..4096)
        require((0 until seen.length()).all{seen.getInt(it) in 0..4095})
        return meta
    }
    fun info(context:Context):Map<String,Any>{
        val dir=active(context);if(!File(dir,"manifest.json").isFile)return mapOf("installed" to false,"modelId" to ID)
        return try { val m=validate(dir);val manifest=JSONObject(File(dir,"manifest.json").readText())
        mapOf("installed" to true,"modelId" to ID,"minAndroidApi" to 24,"task" to "prediction","tier" to "basic",
            "metadataPath" to File(dir,"model.json").path,"modelSha256" to manifest.getJSONObject("files").getJSONObject("model.onnx").getString("sha256"),
            "sourceStatus" to m.getString("sourceStatus"),"labelStatus" to m.getString("labelStatus"),"use" to "suggestion_only")
        }catch(_:Exception){mapOf("installed" to false,"modelId" to ID,"error" to "integrity_unconfirmed")}
    }
    fun install(context:Context,source:File):Map<String,Any>{
        require(source.canonicalPath.startsWith(context.cacheDir.canonicalPath+File.separator)&&source.length() in 1..(5L*1024*1024))
        require(context.filesDir.usableSpace>32L*1024*1024)
        val parent=File(context.filesDir,"system-pilot").apply{mkdirs()};val stage=File(parent,"stage-${System.nanoTime()}").apply{mkdir()}
        try{
            val seen=mutableSetOf<String>();var total=0L
            ZipInputStream(source.inputStream().buffered()).use{zip->while(true){
                val entry=zip.nextEntry?:break;require(!entry.isDirectory&&entry.name in names&&seen.add(entry.name))
                File(stage,entry.name).outputStream().use{out->val buffer=ByteArray(65536);while(true){val n=zip.read(buffer);if(n<0)break;total+=n;require(total<=5L*1024*1024);out.write(buffer,0,n)}}
            }}
            require(seen==names);validate(stage)
            val current=active(context);val previous=File(parent,"previous-${System.nanoTime()}")
            if(current.exists())check(current.renameTo(previous))
            if(!stage.renameTo(current)){previous.renameTo(current);error("install_failed")}
            previous.deleteRecursively()
            return info(context)
        }finally{stage.deleteRecursively()}
    }
}

class SystemPilotSession(context:Context,threads:Int):NativeModelSession{
    private val dir=SystemPilotFiles.active(context)
    private val meta=SystemPilotFiles.validate(dir)
    private val hash=JSONObject(File(dir,"manifest.json").readText()).getJSONObject("files").getJSONObject("model.onnx").getString("sha256")
    private val env=OrtEnvironment.getEnvironment()
    private val session=OrtSession.SessionOptions().use{options->options.setIntraOpNumThreads(threads);options.setInterOpNumThreads(1);env.createSession(File(dir,"model.onnx").path,options)}
    init{require(session.inputNames==setOf("features")&&session.outputNames==setOf("scores"))}
    override fun infer(inputJson:String):String{
        val input=JSONObject(inputJson);require(input.getString("featureConfig")==SystemPilotFiles.CONFIG)
        val v=input.getJSONArray("features");require(v.length()==4096)
        val features=FloatArray(4096){v.getDouble(it).toFloat()};require(features.all{it.isFinite()&&(it==0f||it==1f)})
        OnnxTensor.createTensor(env,FloatBuffer.wrap(features),longArrayOf(1,4096)).use{tensor->session.run(mapOf("features" to tensor)).use{output->
            @Suppress("UNCHECKED_CAST")val scores=(output[0].value as Array<FloatArray>)[0]
            require(scores.size==9&&scores.all{it.isFinite()&&it in 0f..1f})
            return JSONObject().put("modelId",SystemPilotFiles.ID).put("modelSha256",hash).put("scores",JSONArray(scores.toList())).put("labels",meta.getJSONArray("labels"))
                .put("sourceStatus","authorship_unconfirmed").put("labelStatus","single_ai_draft_not_human_reviewed").put("use","suggestion_only")
                .put("workerPid",Process.myPid()).put("pssKb",Debug.getPss()).toString()
        }}
    }
    override fun close(){session.close()}
}
