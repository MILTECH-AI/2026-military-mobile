package com.superkid.military.military_maintenance

import android.app.Instrumentation
import android.app.Activity
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.json.JSONObject

/** Test APK only. Runs the app's real Dart RAG and native ONNX in an API 24 AVD. */
class RagInstrumentation : Instrumentation() {
    private var entry = "ragDeviceProbe"
    private var threads = 2
    private var userWaitMs = 1000
    private var reuseInstalled = false
    private var auxiliaryPhone = false
    private fun writeReport(data: Map<*, *>) {
        val safe = if (auxiliaryPhone) AuxReportPrivacy.report(data) else data
        File(targetContext.filesDir, "rag-probe-result.json").writeText(JSONObject(safe).toString(2))
    }
    override fun onCreate(arguments: Bundle?) {
        super.onCreate(arguments)
        entry = arguments?.getString("entry") ?: "ragDeviceProbe"
        require(entry in listOf("ragDeviceProbe", "memoryWarningDeviceProbe", "optionalModelDeviceProbe", "visionDeviceProbe", "flowDeviceProbe", "systemPilotDeviceProbe", "ragUtilityDeviceProbe"))
        threads = arguments?.getString("threads")?.toInt() ?: 2
        userWaitMs = arguments?.getString("userWaitMs")?.toInt() ?: 1000
        reuseInstalled = arguments?.getString("reuseInstalled") == "true"
        auxiliaryPhone = arguments?.getString("auxiliaryPhone") == "true" || android.os.Build.MODEL == "SM-N981N"
        require(!reuseInstalled || entry == "flowDeviceProbe")
        require(threads in 1..4 && userWaitMs in 0..5000)
        start()
    }
    override fun onStart() {
        Thread {
            try {
              if (!reuseInstalled) {
                EmbeddingFiles.install(targetContext, File(targetContext.cacheDir, "maintenance-import-probe.mrag"))
                if (entry in listOf("optionalModelDeviceProbe", "flowDeviceProbe", "ragUtilityDeviceProbe")) LlmFiles.install(targetContext, File(targetContext.cacheDir, "maintenance-import-llm.gguf"))
                if (entry in listOf("visionDeviceProbe", "flowDeviceProbe")) VisionFiles.install(targetContext, File(targetContext.cacheDir, "maintenance-import-vision.onnx"))
                if (entry == "systemPilotDeviceProbe" || File(targetContext.cacheDir,"maintenance-import-system.msystem").isFile) SystemPilotFiles.install(targetContext,File(targetContext.cacheDir,"maintenance-import-system.msystem"))
              }
            } catch (e: Throwable) {
                writeReport(mapOf(
                    "status" to "failed", "error" to "bundle_install_${e.javaClass.simpleName}"
                ))
                finish(Activity.RESULT_CANCELED, Bundle().apply { putString("status", "bundle_install_failed") })
                return@Thread
            }
            val completed = CountDownLatch(1)
            var payload: Map<*, *>? = null
            var engine: FlutterEngine? = null
            var bridge: ModelRuntimeBridge? = null
            val main = Handler(Looper.getMainLooper())
            main.post {
                try {
                    val loader = FlutterInjector.instance().flutterLoader()
                    loader.startInitialization(targetContext)
                    loader.ensureInitializationComplete(targetContext, emptyArray())
                    val e = FlutterEngine(targetContext)
                    engine = e
                    val b = ModelRuntimeBridge(targetContext)
                    bridge = b
                    MethodChannel(e.dartExecutor.binaryMessenger, "maintenance/model_runtime")
                        .setMethodCallHandler { call, result -> b.handle(call, result) }
                    MethodChannel(e.dartExecutor.binaryMessenger, "maintenance/device_probe")
                        .setMethodCallHandler { call, result ->
                            if (call.method == "config") { result.success(mapOf("threads" to threads,"userWaitMs" to userWaitMs)); return@setMethodCallHandler }
                            if (call.method == "triggerTrim") {
                                val descriptor = uiAutomation.executeShellCommand("am send-trim-memory ${targetContext.packageName}:model_worker RUNNING_CRITICAL")
                                val commandOutput = android.os.ParcelFileDescriptor.AutoCloseInputStream(descriptor).bufferedReader().use { it.readText() }
                                result.success(commandOutput)
                                return@setMethodCallHandler
                            }
                            payload = call.arguments as? Map<*, *>
                            result.success(null); completed.countDown()
                        }
                    e.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint(loader.findAppBundlePath(), entry))
                } catch (e: Throwable) { payload = mapOf("status" to "failed", "error" to e.javaClass.name); completed.countDown() }
            }
            if (!completed.await(if (entry == "ragUtilityDeviceProbe") 3600 else if (entry in listOf("optionalModelDeviceProbe", "flowDeviceProbe")) 600 else 180, TimeUnit.SECONDS)) payload = mapOf("status" to "failed", "error" to "instrumentation_timeout")
            val data = mutableMapOf<Any?, Any?>()
            data.putAll(payload ?: mapOf("status" to "failed", "error" to "empty_result"))
            data["bundleInstallVerified"] = !reuseInstalled
            data["reusedPreviouslyVerifiedInstallation"] = reuseInstalled
            if (entry == "optionalModelDeviceProbe") data["llmInstallVerified"] = true
            if (entry == "visionDeviceProbe") data["visionInstallVerified"] = true
            writeReport(data)
            main.post { bridge?.dispose(); engine?.destroy() }
            finish(if (data["status"] == "passed") Activity.RESULT_OK else Activity.RESULT_CANCELED,
                Bundle().apply { putString("status", data["status"].toString()); putString("resultFile", "app-private/rag-probe-result.json") })
        }.start()
    }
}
