package com.superkid.military.military_maintenance

import android.app.ActivityManager
import android.app.admin.DevicePolicyManager
import android.content.pm.PackageManager
import android.hardware.camera2.CameraManager
import android.app.AppOpsManager
import android.content.*
import android.os.*
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.io.File
import java.util.concurrent.Executors

class ModelRuntimeBridge(private val context: Context) {
    private val files = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private var worker: Messenger? = null
    private var bound = false
    private var pending: MethodChannel.Result? = null
    private var resetting: MethodChannel.Result? = null
    private var queued: (() -> Unit)? = null
    private var requestId = 0
    private var flutterPressurePending = false
    private fun forwardFlutterPressure() {
        worker?.send(Message.obtain().apply { data=Bundle().apply { putString("operation","flutter_memory_pressure") } })
    }
    private val preferences = context.getSharedPreferences("model-runtime", Context.MODE_PRIVATE)
    private val memoryTrace = FlowMemoryTrace(main) { worker to bound }
    private fun cameraStatus(): String = try {
        val policy = context.getSystemService(Context.DEVICE_POLICY_SERVICE) as DevicePolicyManager
        val cameras = context.getSystemService(Context.CAMERA_SERVICE) as CameraManager
        when {
            policy.getCameraDisabled(null) -> "disabled_policy"
            !context.packageManager.hasSystemFeature(PackageManager.FEATURE_CAMERA_ANY) || cameras.cameraIdList.isEmpty() -> "no_hardware"
            context.checkSelfPermission(android.Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED -> "permission_required"
            (context.getSystemService(Context.APP_OPS_SERVICE) as AppOpsManager).checkOpNoThrow(
                AppOpsManager.OPSTR_CAMERA, android.os.Process.myUid(), context.packageName) in
                listOf(AppOpsManager.MODE_IGNORED, AppOpsManager.MODE_ERRORED) -> "disabled_appops"
            else -> "available"
        }
    } catch (_: Exception) { "unknown" }
    private val timeout = Runnable {
        pending?.error("worker_timeout", "추론 프로세스 응답 시간 초과", null)
        pending = null
        queued = null
        resetting?.error("reset_unconfirmed", "추론 프로세스 종료 확인 불가", null)
        resetting = null
    }
    private val replies = Messenger(Handler(Looper.getMainLooper()) { msg ->
        if (msg.arg1 == requestId && pending != null) {
            main.removeCallbacks(timeout)
            val result = pending
            pending = null
            val error = msg.data.getString("error")
            if (error != null) result?.error(error, "모델을 실행하지 못했습니다.", null)
            else {
                val output = msg.data.getString("outputJson")
                try {
                    if (output != null) result?.success(jsonValue(JSONObject(output)))
                    else result?.success(msg.data.keySet().associateWith { msg.data.get(it) })
                } catch (_: Exception) { result?.error("invalid_output", "모델 출력 형식 오류", null) }
            }
        }
        true
    })
    private fun jsonValue(value: Any?): Any? = when (value) {
        JSONObject.NULL -> null
        is JSONObject -> value.keys().asSequence().associateWith { key -> jsonValue(value.get(key)) }
        is org.json.JSONArray -> (0 until value.length()).map { i -> jsonValue(value.get(i)) }
        else -> value
    }
    private val connection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName, binder: IBinder) {
            worker = Messenger(binder)
            if (resetting != null) shutdown() else {
                queued?.also { queued = null; it() }
                if(flutterPressurePending) {
                    flutterPressurePending=false
                    try { forwardFlutterPressure() }
                    catch(_:DeadObjectException) { disconnected() }
                    catch(_:RemoteException) { /* A pending call's watchdog/reset still owns recovery. */ }
                }
            }
        }
        override fun onServiceDisconnected(name: ComponentName) { disconnected() }
        override fun onBindingDied(name: ComponentName) { disconnected() }
        override fun onNullBinding(name: ComponentName) { disconnected() }
    }
    private fun disconnected() {
        main.removeCallbacks(timeout)
        worker = null
        queued = null
        flutterPressurePending = false
        flutterPressurePending = false
        pending?.error("worker_died", "추론 프로세스가 종료되었습니다.", null)
        pending = null
        if (bound) { context.unbindService(connection); bound = false }
        resetting?.success(null)
        resetting = null
    }
    private fun shutdown() {
        try { worker?.send(Message.obtain().apply { data = Bundle().apply { putString("operation", "shutdown") } }) }
        catch (_: DeadObjectException) { disconnected() }
        catch (_: RemoteException) { /* Await binder death or quarantine on timeout. */ }
    }
    fun handle(call: io.flutter.plugin.common.MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "notifyMemoryPressure" -> {
                try {
                    val state=when {
                        resetting!=null -> "already_releasing"
                        worker!=null -> {forwardFlutterPressure();"forwarded"}
                        bound -> {flutterPressurePending=true;"queued_until_bound"}
                        else -> "no_worker_resources"
                    }
                    runCatching {
                        val m=ActivityManager.MemoryInfo()
                        (context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager).getMemoryInfo(m)
                        android.util.Log.i("MaintenanceUiPressure",JSONObject().put("event","flutter_pressure_forwarded")
                            .put("trimLevelKnown",false).put("availableBytes",m.availMem).put("lowMemory",m.lowMemory)
                            .put("action",state).toString())
                    }
                    result.success(mapOf("action" to state))
                } catch(_:Exception) {result.error("pressure_forward_failed","메모리 경고 전달 실패",null)}
            }
            "diagnosticTrim" -> {
                val debug = context.applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE != 0
                val level=call.argument<Int>("level")
                val available=call.argument<Number>("availableBytes")?.toLong()
                val threshold=call.argument<Number>("androidThresholdBytes")?.toLong()
                if(!debug || worker==null || level !in listOf(5,10,15,20,40,60,80) || available==null || available<0 || threshold==null || threshold<0) {
                    result.error("diagnostic_unavailable","시험 전용 조건 확인 실패",null)
                } else try {
                    worker!!.send(Message.obtain().apply { data=Bundle().apply {
                        putString("operation","diagnostic_trim");putInt("level",level!!)
                        putLong("availableBytes",available);putLong("androidThresholdBytes",threshold)
                        putBoolean("lowMemory",call.argument<Boolean>("lowMemory") ?: false)
                    } })
                    result.success(null)
                } catch(_:Exception) { result.error("diagnostic_send_failed","시험 신호 전송 실패",null) }
            }
            "startMemoryTrace" -> { memoryTrace.start((call.argument<Int>("intervalMs") ?: 500).toLong()); result.success(null) }
            "markMemoryTrace" -> { memoryTrace.mark(call.argument<String>("phase") ?: "unknown"); result.success(null) }
            "stopMemoryTrace" -> files.execute {
                try { val data = memoryTrace.stop(); main.post { result.success(data) } }
                catch (_: Exception) { main.post { result.error("trace", "메모리 표본 수집 종료 실패", null) } }
            }
            "modelInfo" -> try { result.success(EmbeddingFiles.info(context) + mapOf("optionalModels" to listOf(LlmFiles.info(context), VisionFiles.info(context)), "systemPilot" to SystemPilotFiles.info(context))) }
                catch (_: Exception) { result.error("bundle", "임베딩 묶음 확인 실패", null) }
            "installLlm" -> {
                files.execute {
                    try {
                        LlmFiles.install(context, File(call.argument<String>("path") ?: ""))
                        main.post { result.success(LlmFiles.info(context)) }
                    } catch (_: Exception) { main.post { result.error("llm_import", "공개 LLM 모델의 API·ABI·크기·해시·공간을 확인해 주세요.", null) } }
                }
            }
            "installVision" -> {
                files.execute {
                    try { VisionFiles.install(context, File(call.argument<String>("path") ?: "")); main.post { result.success(VisionFiles.info(context)) } }
                    catch (_: Exception) { main.post { result.error("vision_import", "공개 Vision 모델의 파일·해시·공간을 확인해 주세요.", null) } }
                }
            }
            "installSystemPilot" -> files.execute {
                try{val data=SystemPilotFiles.install(context,File(call.argument<String>("path")?:""));main.post{result.success(data)}}
                catch(_:Exception){main.post{result.error("system_pilot_import","파일럿 모델의 출처 표시·파일·해시·공간을 확인해 주세요.",null)}}
            }
            "installEmbedding" -> {
                files.execute {
                    try {
                        val info = EmbeddingFiles.install(context, File(call.argument<String>("path") ?: ""))
                        main.post { result.success(info) }
                    } catch (_: Exception) { main.post { result.error("bundle", "임베딩 묶음 검증·설치 실패. 공간과 파일을 확인해 주세요.", null) } }
                }
            }
            "capabilities" -> {
                val memory = ActivityManager.MemoryInfo()
                (context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager).getMemoryInfo(memory)
                result.success(mapOf("totalRamBytes" to memory.totalMem, "availableRamBytes" to memory.availMem,
                    "lowMemory" to memory.lowMemory, "cameraStatus" to cameraStatus(), "cores" to Runtime.getRuntime().availableProcessors(),
                    "abis" to Build.SUPPORTED_ABIS.toList(), "androidApi" to Build.VERSION.SDK_INT,
                    "isEmulator" to (Build.FINGERPRINT.startsWith("generic") || Build.HARDWARE.contains("ranchu") || Build.HARDWARE.contains("goldfish")),
                    "freeStorageBytes" to StatFs(context.filesDir.absolutePath).availableBytes))
            }
            "getCeiling" -> result.success(preferences.getString("ceiling", null))
            "setCeiling" -> {
                val value = call.argument<String>("tier")
                if (value != null && value !in listOf("basic", "enhanced", "generation")) {
                    result.error("invalid_tier", "지원하지 않는 모델 단계", null)
                } else if (preferences.edit().putString("ceiling", value).commit()) result.success(null)
                else result.error("settings", "설정 저장 실패", null)
            }
            "reset" -> {
                if (resetting != null) { result.error("busy", "종료 확인 중", null); return }
                if (!bound) { result.success(null); return }
                pending?.error("reset", "추론 프로세스 재설정", null)
                pending = null
                queued = null
                resetting = result
                main.removeCallbacks(timeout)
                main.postDelayed(timeout, 30000)
                shutdown()
            }
            "load", "infer", "unload", "probe" -> {
                memoryTrace.event("model_request", "${call.method}:${call.argument<String>("modelId") ?: "active"}")
                if (pending != null || resetting != null) { result.error("busy", "모델 작업 진행 중", null); return }
                val data = Bundle().apply {
                    putString("operation", call.method)
                    putString("modelId", call.argument<String>("modelId"))
                    putInt("threads", call.argument<Int>("threads") ?: 2)
                    if (call.method == "infer") putString("inputJson", JSONObject(call.arguments as? Map<*, *> ?: emptyMap<Any, Any>()).toString())
                }
                pending = result
                requestId += 1
                val currentId = requestId
                val send = {
                    try { worker!!.send(Message.obtain().apply { arg1 = currentId; replyTo = replies; this.data = data }) }
                    catch (_: Exception) {
                        main.removeCallbacks(timeout)
                        pending?.error("transport", "모델 요청 전송 실패", null)
                        pending = null
                        // Sending failed does not prove worker death. Keep binding
                        // until reset explicitly confirms process termination.
                    }
                }
                main.postDelayed(timeout, if (call.method == "infer" && call.argument<String>("task") == "generation") 120000 else 30000)
                if (worker != null) send() else {
                    queued = send
                    if (!bound) {
                        bound = context.bindService(Intent(context, ModelWorkerService::class.java), connection, Context.BIND_AUTO_CREATE)
                        if (!bound) disconnected()
                    }
                }
            }
            else -> result.notImplemented()
        }
    }
    fun dispose() {
        memoryTrace.dispose()
        files.shutdown()
        main.removeCallbacks(timeout)
        shutdown()
        if (bound) { context.unbindService(connection); bound = false }
        worker = null
        pending?.error("disposed", "화면 엔진 종료", null)
        resetting?.error("disposed", "화면 엔진 종료", null)
        pending = null; resetting = null; queued = null
    }
}
