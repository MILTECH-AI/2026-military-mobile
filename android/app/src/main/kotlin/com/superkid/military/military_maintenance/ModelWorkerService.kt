package com.superkid.military.military_maintenance

import android.app.Service
import android.content.Intent
import android.os.*

/** App-private, separate process. No Flutter engine, database or network work here. */
class ModelWorkerService : Service() {
    private val main = Handler(Looper.getMainLooper())
    private val inferenceThread = HandlerThread("model-inference")
    private lateinit var inference: Handler
    private var slot: NativeModelSession? = null
    @Volatile private var activeId: String? = null
    @Volatile private var activeThreads = 0
    @Volatile private var operation = "idle"
    // A load+infer pair is one busy cycle; a warning between them must not drop the model.
    @Volatile private var cycleBusy = false
    @Volatile private var requestedModelId: String? = null
    @Volatile private var releaseRequested = false
    @Volatile private var releaseTrimLevel = -1
    private val debuggable get() = applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE != 0

    // Debug-only diagnostics. Never log requests, model outputs, paths or identifiers.
    private fun trace(event: String, reason: String = "none", trimLevel: Int = -1, extra: Map<String, Any?> = emptyMap()) {
        if (!debuggable && event !in listOf("warning_decision", "warning_final_action", "exit_requested")) return
        try {
            val memory = android.app.ActivityManager.MemoryInfo()
            (getSystemService(ACTIVITY_SERVICE) as android.app.ActivityManager).getMemoryInfo(memory)
            val heap = Runtime.getRuntime()
            val record = org.json.JSONObject()
                .put("event", event).put("reason", reason).put("operation", operation)
                .put("trimLevel", trimLevel).put("loaded", slot != null)
                .put("availableBytes", memory.availMem).put("lowMemory", memory.lowMemory)
                .put("javaMaxBytes", heap.maxMemory()).put("javaUsedBytes", heap.totalMemory()-heap.freeMemory())
                .put("oomScoreAdj", java.io.File("/proc/self/oom_score_adj").readText().trim().toInt())
            for ((key,value) in extra) record.put(key,value ?: org.json.JSONObject.NULL)
            android.util.Log.i("MaintenanceRuntime", record.toString())
        } catch (_: Throwable) { /* Logging must not alter the existing failure policy. */ }
    }

    private fun killSelf(reason: String, trimLevel: Int = -1) {
        try { trace("exit_requested", reason, trimLevel) }
        finally { Process.killProcess(Process.myPid()) }
    }

    private fun releaseSlot(reason: String, level: Int = -1) {
        slot?.close()
        slot = null; activeId = null; activeThreads = 0; requestedModelId = null
        releaseRequested = false; releaseTrimLevel = -1
        if (level >= 0) trace("warning_final_action", reason, level, mapOf("finalAction" to "model_released"))
    }

    private fun handleWarning(level: Int, injected: Bundle? = null) {
        val memory = android.app.ActivityManager.MemoryInfo()
        val known = try {
            (getSystemService(ACTIVITY_SERVICE) as android.app.ActivityManager).getMemoryInfo(memory); true
        } catch (_: Throwable) { false }
        val available = injected?.getLong("availableBytes") ?: memory.availMem
        val low = injected?.getBoolean("lowMemory") ?: memory.lowMemory
        val threshold = injected?.getLong("androidThresholdBytes") ?: memory.threshold
        val decision = MemoryWarningPolicy.decide(level,available,threshold,low,known || injected != null,
            cycleBusy,requestedModelId == LlmFiles.ID || activeId == LlmFiles.ID)
        trace("warning_decision", trimLevel=level, extra=mapOf("decision" to decision.action,
            "decisionAvailableBytes" to available,"decisionLowMemory" to low,"androidThresholdBytes" to threshold,
            "reserveBytes" to decision.reserveBytes,"effectiveThresholdBytes" to decision.thresholdBytes,
            "memorySource" to if(injected==null) "observed" else "debug_injected",
            "warningSource" to if(injected!=null) "debug_injected" else if(level==-1) "flutter_callback_level_unknown" else "android_trim_callback",
            "cycleBusy" to cycleBusy,"snapshotKnown" to (known || injected!=null)))
        when(decision.action) {
            MemoryWarningPolicy.FALLBACK -> {
                trace("warning_final_action","pressure_guard",level,mapOf("finalAction" to "exit_worker_for_fallback"))
                killSelf("pressure_guard",level)
            }
            MemoryWarningPolicy.DEFER -> {
                releaseRequested=true; releaseTrimLevel=level
                trace("warning_final_action","pending_completion",level,mapOf("finalAction" to "release_after_inference"))
            }
            MemoryWarningPolicy.RELEASE -> {
                releaseRequested=true; releaseTrimLevel=level
                inference.post {
                    if(!cycleBusy) try { releaseSlot("idle_warning",level) }
                    catch(_:Throwable) { killSelf("release_failed",level) }
                }
            }
            else -> trace("warning_final_action","not_pressure",level,mapOf("finalAction" to "none"))
        }
    }

    private fun openModel(id: String, threads: Int): NativeModelSession {
        if (id == "distiluse-int8-v1" && android.os.Build.VERSION.SDK_INT >= 24) return OnnxEmbeddingSession(this, threads)
        if (id == LlmFiles.ID && LlmFiles.supported()) return LlamaSession(this, threads)
        if (id == VisionFiles.ID) return OnnxVisionSession(this, threads)
        if (id == SystemPilotFiles.ID) return SystemPilotSession(this, threads)
        throw UnsupportedOperationException("runtime_not_installed")
    }

    private val messenger = Messenger(Handler(Looper.getMainLooper()) { msg ->
        val reply = msg.replyTo
        val requestId = msg.arg1
        val data = Bundle(msg.data)
        if (data.getString("operation") == "shutdown") {
            // Inference runs on another thread; this also aborts a stuck native call.
            killSelf("shutdown_request")
        } else if (data.getString("operation") == "flutter_memory_pressure") {
            handleWarning(-1)
        } else if (data.getString("operation") == "diagnostic_trim" && debuggable) {
            handleWarning(data.getInt("level"),data)
        } else if (data.getString("operation") == "sample_memory") {
            val begin = SystemClock.elapsedRealtimeNanos()
            val pss = Debug.getPss()
            try { reply?.send(Message.obtain().apply { this.data = Bundle().apply {
                putInt("pid", Process.myPid()); putLong("pssKb", pss)
                putLong("startNanos", begin); putLong("endNanos", SystemClock.elapsedRealtimeNanos())
                putString("modelId", activeId); putInt("threads", activeThreads)
            } }) } catch (_: RemoteException) { }
        } else {
            if(data.getString("operation")=="load") {
                cycleBusy=true; requestedModelId=data.getString("modelId")
            }
            inference.post {
                val result = Bundle()
                operation = data.getString("operation") ?: "unknown"
                trace("operation_start")
                try {
                    when (data.getString("operation")) {
                        "probe" -> {
                            result.putInt("pid", Process.myPid())
                            result.putInt("pssKb", Debug.getPss().toInt())
                            result.putString("status", if (slot != null) "model_loaded" else "idle")
                            result.putBoolean("loaded", slot != null)
                        }
                        "load" -> {
                            check(slot == null) { "slot_busy" }
                            val threads = data.getInt("threads")
                            require(threads > 0)
                            slot = openModel(requireNotNull(data.getString("modelId")),
                                threads.coerceAtMost(Runtime.getRuntime().availableProcessors()))
                            activeId = data.getString("modelId")
                            activeThreads = threads.coerceAtMost(Runtime.getRuntime().availableProcessors())
                        }
                        "infer" -> {
                            val current = checkNotNull(slot) { "no_loaded_model" }
                            // Deterministic Android integration test only; absent from normal requests.
                            if(debuggable) {
                                val hold=org.json.JSONObject(data.getString("inputJson") ?: "{}").optInt("diagnosticHoldMs",0)
                                if(hold in 1..1000) { trace("diagnostic_hold"); Thread.sleep(hold.toLong()) }
                            }
                            result.putString("outputJson", current.infer(data.getString("inputJson") ?: "{}"))
                        }
                        "unload" -> {
                            releaseSlot("explicit_unload")
                        }
                        else -> throw IllegalArgumentException("unknown_operation")
                    }
                } catch (_: OutOfMemoryError) {
                    // Reclaim the entire native address space, not just Java heap.
                    killSelf("caught_out_of_memory")
                } catch (_: UnsupportedOperationException) {
                    result.putString("error", "runtime_not_installed")
                } catch (failure: Throwable) {
                    trace("operation_failure", failure.javaClass.simpleName)
                    // Debug diagnostics contain fixed operation/class codes only, never messages or inputs.
                    val debuggable = applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE != 0
                    val detail = if (debuggable) "_${data.getString("operation")}_${failure.javaClass.simpleName}" else ""
                    result.putString("error", "model_operation_failed$detail")
                }
                if(operation=="infer" || operation=="unload" || result.containsKey("error")) {
                    cycleBusy=false
                    if(releaseRequested) try { releaseSlot("completed_inference",releaseTrimLevel) }
                    catch(_:Throwable) { killSelf("release_failed",releaseTrimLevel) }
                }
                trace("operation_reply")
                try { reply?.send(Message.obtain().apply { arg1 = requestId; this.data = result }) }
                catch (_: RemoteException) { main.post { killSelf("reply_remote_exception") } }
                operation = "idle"
            }
        }
        true
    })

    override fun onCreate() { super.onCreate(); inferenceThread.start(); inference = Handler(inferenceThread.looper) }
    override fun onBind(intent: Intent): IBinder = messenger.binder
    override fun onTrimMemory(level: Int) {
        super.onTrimMemory(level)
        handleWarning(level)
    }
    override fun onDestroy() { inferenceThread.quitSafely(); super.onDestroy() }
}

/** Implementations own native handles and must close all tensors/sessions. */
interface NativeModelSession : AutoCloseable {
    fun infer(inputJson: String): String
}
