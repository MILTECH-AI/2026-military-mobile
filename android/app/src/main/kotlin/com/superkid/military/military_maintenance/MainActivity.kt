package com.superkid.military.military_maintenance

import android.app.Activity
import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private var modelRuntime: ModelRuntimeBridge? = null
    private var pending: MethodChannel.Result? = null
    private var exportFile: File? = null
    private val io = Executors.newSingleThreadExecutor()
    private val maxBytes = 64L * 1024 * 1024
    private var importLimit = maxBytes

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        modelRuntime = ModelRuntimeBridge(this)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "maintenance/model_runtime")
            .setMethodCallHandler { call, result -> modelRuntime!!.handle(call, result) }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "maintenance/local_files")
            .setMethodCallHandler { call, result ->
                if (pending != null) {
                    result.error("busy", "파일 선택이 이미 진행 중입니다.", null)
                    return@setMethodCallHandler
                }
                try {
                    when (call.method) {
                        "releaseBackup" -> {
                            val file = File(call.argument<String>("path") ?: "").canonicalFile
                            val root = cacheDir.canonicalPath + File.separator
                            val safe = file.path.startsWith(root) && file.name.startsWith("maintenance-import-")
                            result.success(safe && (!file.exists() || file.delete()))
                        }
                        "saveBackup" -> {
                            val file = File(call.argument<String>("path") ?: "").canonicalFile
                            val root = File(applicationInfo.dataDir).canonicalPath + File.separator
                            require(file.path.startsWith(root) && file.isFile && file.length() <= maxBytes)
                            exportFile = file
                            pending = result
                            startActivityForResult(Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                                addCategory(Intent.CATEGORY_OPENABLE)
                                type = "application/octet-stream"
                                putExtra(Intent.EXTRA_LOCAL_ONLY, true)
                                putExtra(Intent.EXTRA_TITLE, call.argument<String>("name") ?: "maintenance.mbackup")
                            }, 701)
                        }
                        "pickBackup", "pickEmbedding", "pickLlm" -> {
                            importLimit = when (call.method) { "pickLlm" -> 512L * 1024 * 1024; "pickEmbedding" -> 256L * 1024 * 1024; else -> maxBytes }
                            pending = result
                            startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                                addCategory(Intent.CATEGORY_OPENABLE)
                                type = "*/*"
                                putExtra(Intent.EXTRA_LOCAL_ONLY, true)
                            }, 702)
                        }
                        else -> result.notImplemented()
                    }
                } catch (_: Exception) {
                    pending = null
                    exportFile = null
                    result.error("file", "기기에서 파일 선택을 열지 못했습니다.", null)
                }
            }
    }

    override fun onDestroy() {
        modelRuntime?.dispose()
        modelRuntime = null
        super.onDestroy()
    }

    @Deprecated("Uses system document picker")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != 701 && requestCode != 702) return
        val result = pending ?: return
        val source = exportFile
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            pending = null
            exportFile = null
            result.success(if (requestCode == 701) false else null)
            return
        }
        io.execute {
            var imported: File? = null
            try {
                val value: Any = if (requestCode == 701) {
                    requireNotNull(source)
                    requireNotNull(contentResolver.openOutputStream(uri, "wt")).use { out ->
                        source.inputStream().use { it.copyTo(out) }
                    }
                    true
                } else {
                    val file = File.createTempFile("maintenance-import-", ".mbackup", cacheDir)
                    imported = file
                    requireNotNull(contentResolver.openInputStream(uri)).use { input ->
                        file.outputStream().use { out ->
                            val buffer = ByteArray(8192)
                            var total = 0L
                            while (true) {
                                val n = input.read(buffer)
                                if (n < 0) break
                                total += n
                                require(total <= importLimit)
                                out.write(buffer, 0, n)
                            }
                        }
                    }
                    file.absolutePath
                }
                runOnUiThread {
                    pending = null
                    exportFile = null
                    result.success(value)
                }
            } catch (_: Exception) {
                imported?.delete()
                runOnUiThread {
                    pending = null
                    exportFile = null
                    result.error("file", "파일을 처리하지 못했습니다. 파일 크기와 저장 공간을 확인해 주세요.", null)
                }
            }
        }
    }
}
