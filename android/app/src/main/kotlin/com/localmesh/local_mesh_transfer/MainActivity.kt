package com.localmesh.local_mesh_transfer

import android.Manifest
import android.app.DownloadManager
import android.content.ClipData
import android.provider.DocumentsContract
import android.widget.Toast
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.provider.Settings
import android.webkit.MimeTypeMap
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.Locale

class MainActivity : FlutterActivity() {
    private companion object {
        private const val PERMISSION_CHANNEL = "com.localmesh/permissions"
        private const val NETWORK_CHANNEL = "com.localmesh/network"
        private const val FILEPICKER_CHANNEL = "com.localmesh/filepicker"
        private const val REQUEST_NEARBY_DEVICES = 1001
        private const val REQUEST_PICK_FILE = 1002
        private const val REQUEST_NOTIFICATIONS = 1003
    }

    private var pendingNearbyResult: MethodChannel.Result? = null
    private var pendingFilePickerResult: MethodChannel.Result? = null
    private var pendingPickerMultiple = false
    private var pendingNotificationResult: MethodChannel.Result? = null
    private var multicastLock: WifiManager.MulticastLock? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Permission request channel
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            PERMISSION_CHANNEL
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "requestNearbyDevices" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        if (ContextCompat.checkSelfPermission(
                                this,
                                Manifest.permission.NEARBY_WIFI_DEVICES
                            ) == PackageManager.PERMISSION_GRANTED
                        ) {
                            result.success(true)
                        } else {
                            pendingNearbyResult = result
                            ActivityCompat.requestPermissions(
                                this,
                                arrayOf(Manifest.permission.NEARBY_WIFI_DEVICES),
                                REQUEST_NEARBY_DEVICES
                            )
                        }
                    } else {
                        result.success(true)
                    }
                }
                "checkNearbyDevices" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        result.success(
                            ContextCompat.checkSelfPermission(
                                this,
                                Manifest.permission.NEARBY_WIFI_DEVICES
                            ) == PackageManager.PERMISSION_GRANTED
                        )
                    } else {
                        result.success(true)
                    }
                }
                "requestNotifications" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
                        ContextCompat.checkSelfPermission(
                            this,
                            Manifest.permission.POST_NOTIFICATIONS
                        ) != PackageManager.PERMISSION_GRANTED
                    ) {
                        pendingNotificationResult = result
                        ActivityCompat.requestPermissions(
                            this,
                            arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                            REQUEST_NOTIFICATIONS
                        )
                    } else {
                        result.success(true)
                    }
                }
                else -> result.notImplemented()
            }
        }

        // Network helper channel
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            NETWORK_CHANNEL
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "acquireMulticastLock" -> {
                    try {
                        if (multicastLock == null) {
                            val wifi = applicationContext
                                .getSystemService(Context.WIFI_SERVICE) as WifiManager
                            multicastLock = wifi.createMulticastLock("local_mesh_discovery")
                            multicastLock?.setReferenceCounted(true)
                            multicastLock?.acquire()
                        }
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("MULTICAST_LOCK_ERROR", e.message, null)
                    }
                }
                "releaseMulticastLock" -> {
                    try {
                        multicastLock?.release()
                        multicastLock = null
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("MULTICAST_LOCK_RELEASE_ERROR", e.message, null)
                    }
                }
                "getDeviceName" -> {
                    val androidName = Settings.Global.getString(
                        applicationContext.contentResolver,
                        Settings.Global.DEVICE_NAME
                    )
                    result.success(androidName ?: Build.MODEL ?: "Android 设备")
                }
                "startConnectionService" -> {
                    try {
                        ConnectionForegroundService.start(this)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("FOREGROUND_SERVICE_ERROR", e.message, null)
                    }
                }
                "stopConnectionService" -> {
                    ConnectionForegroundService.stop(this)
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }

        // File picker channel
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            FILEPICKER_CHANNEL
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "pickFile", "pickFiles" -> {
                    if (pendingFilePickerResult != null) {
                        result.error("FILE_PICKER_BUSY", "A file selection is already pending", null)
                        return@setMethodCallHandler
                    }
                    try {
                        pendingPickerMultiple = call.method == "pickFiles"
                        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                            addCategory(Intent.CATEGORY_OPENABLE)
                            type = "*/*"
                            putExtra(Intent.EXTRA_ALLOW_MULTIPLE, pendingPickerMultiple)
                        }
                        pendingFilePickerResult = result
                        startActivityForResult(intent, REQUEST_PICK_FILE)
                    } catch (e: Exception) {
                        pendingFilePickerResult = null
                        result.error("FILE_PICKER_ERROR", e.message, null)
                    }
                }
                "getStateDir" -> result.success(filesDir.absolutePath)
                "getDownloadDir" -> {
                    // Use app's private filesDir for temporary storage
                    val received = File(filesDir, "received")
                    if (!received.exists()) received.mkdirs()
                    result.success(received.absolutePath)
                }
                "moveToDownloads" -> {
                    val tempPath = call.argument<String>("tempPath")
                    val fileName = call.argument<String>("fileName")
                    if (tempPath == null || fileName == null) {
                        result.error("INVALID_ARGS", "tempPath and fileName required", null)
                        return@setMethodCallHandler
                    }
                    try {
                        val tempFile = File(tempPath)
                        if (!tempFile.exists()) {
                            result.error("FILE_NOT_FOUND", "Temp file not found: $tempPath", null)
                            return@setMethodCallHandler
                        }

                        // Create MediaStore entry under Download/驿传/
                        val contentValues = ContentValues().apply {
                            put(MediaStore.Downloads.DISPLAY_NAME, fileName)
                            put(MediaStore.Downloads.MIME_TYPE, getMimeType(fileName))
                            put(MediaStore.Downloads.RELATIVE_PATH, "${Environment.DIRECTORY_DOWNLOADS}/驿传")
                            put(MediaStore.Downloads.IS_PENDING, 1)
                        }

                        val uri = contentResolver.insert(
                            MediaStore.Downloads.EXTERNAL_CONTENT_URI,
                            contentValues
                        )

                        if (uri == null) {
                            result.error("MEDIASTORE_FAILED", "Failed to create MediaStore entry", null)
                            return@setMethodCallHandler
                        }

                        try {
                            val output = contentResolver.openOutputStream(uri)
                                ?: throw IllegalStateException("Failed to open MediaStore output")
                            output.use {
                                tempFile.inputStream().use { input -> input.copyTo(it) }
                            }

                            // Mark as not pending only after the full copy succeeds.
                            val updateValues = ContentValues().apply {
                                put(MediaStore.Downloads.IS_PENDING, 0)
                            }
                            if (contentResolver.update(uri, updateValues, null, null) != 1) {
                                throw IllegalStateException("Failed to publish MediaStore entry")
                            }

                            if (!tempFile.delete()) {
                                throw IllegalStateException("Failed to remove temporary file")
                            }

                            result.success(uri.toString())
                        } catch (e: Exception) {
                            contentResolver.delete(uri, null, null)
                            throw e
                        }
                    } catch (e: Exception) {
                        result.error("MOVE_ERROR", "Failed to move file: ${e.message}", null)
                    }
                }
                "openFile" -> {
                    val uriStr = call.argument<String>("uri")
                    if (uriStr == null) {
                        result.error("INVALID_ARGS", "uri required", null)
                        return@setMethodCallHandler
                    }
                    try {
                        val uri = Uri.parse(uriStr)
                        openSharedFile(uri, call.argument<String>("fileName"))
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("OPEN_ERROR", "Failed to open file: ${e.message}", null)
                    }
                }
                "deleteFile" -> {
                    val uriStr = call.argument<String>("uri")
                    if (uriStr == null) {
                        result.error("INVALID_ARGS", "uri required", null)
                        return@setMethodCallHandler
                    }
                    try {
                        val deleted = contentResolver.delete(Uri.parse(uriStr), null, null)
                        result.success(deleted > 0)
                    } catch (e: Exception) {
                        result.error("DELETE_ERROR", "Failed to delete file: ${e.message}", null)
                    }
                }
                "openLocalFile" -> {
                    val filePath = call.argument<String>("path")
                    if (filePath == null) {
                        result.error("INVALID_ARGS", "path required", null)
                        return@setMethodCallHandler
                    }
                    try {
                        val file = java.io.File(filePath)
                        val uri = androidx.core.content.FileProvider.getUriForFile(
                            this,
                            "$packageName.fileprovider",
                            file
                        )
                        if (!file.isFile) throw IllegalStateException("File no longer exists")
                        openSharedFile(uri, call.argument<String>("fileName") ?: file.name)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("OPEN_ERROR", "Failed to open local file: ${e.message}", null)
                    }
                }
                "revealFile" -> {
                    val uri = call.argument<String>("uri")?.let(Uri::parse)
                    // External file managers cannot browse private app/cache directories.
                    if (uri?.authority != MediaStore.AUTHORITY) {
                        result.success(false)
                        return@setMethodCallHandler
                    }
                    try {
                        val directory = DocumentsContract.buildDocumentUri(
                            "com.android.externalstorage.documents",
                            "primary:${Environment.DIRECTORY_DOWNLOADS}/驿传"
                        )
                        try {
                            startActivity(Intent(Intent.ACTION_VIEW).apply {
                                setDataAndType(directory, DocumentsContract.Document.MIME_TYPE_DIR)
                                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            })
                        } catch (_: Exception) {
                            startActivity(Intent(DownloadManager.ACTION_VIEW_DOWNLOADS).apply {
                                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            })
                            Toast.makeText(this, "已打开下载列表，请查找 Download/驿传 中的文件", Toast.LENGTH_LONG).show()
                        }
                        result.success(true)
                    } catch (error: Exception) {
                        result.error("REVEAL_ERROR", "Unable to open Downloads: ${error.message}", null)
                    }
                }
                "openExternalUrl" -> {
                    val url = call.argument<String>("url")
                    val uri = url?.let(Uri::parse)
                    if (uri == null || uri.scheme != "https" || uri.host.isNullOrEmpty()) {
                        result.error("INVALID_URL", "A valid HTTPS URL is required", null)
                        return@setMethodCallHandler
                    }
                    try {
                        startActivity(Intent(Intent.ACTION_VIEW, uri))
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("OPEN_URL_ERROR", e.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)

        if (requestCode == REQUEST_NEARBY_DEVICES) {
            pendingNearbyResult?.success(
                grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED
            )
            pendingNearbyResult = null
        } else if (requestCode == REQUEST_NOTIFICATIONS) {
            pendingNotificationResult?.success(
                grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED
            )
            pendingNotificationResult = null
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == REQUEST_PICK_FILE) {
            val result = pendingFilePickerResult ?: return
            val multiple = pendingPickerMultiple
            if (resultCode != RESULT_OK || data == null) {
                pendingFilePickerResult = null
                result.success(if (multiple) emptyList<Any>() else null)
                return
            }
            val uris = mutableListOf<Uri>()
            val clips = data.clipData
            if (clips != null) {
                for (index in 0 until clips.itemCount) uris.add(clips.getItemAt(index).uri)
            } else {
                data.data?.let { uris.add(it) }
            }
            // Copy content URIs off the UI thread. Each file needs a unique path,
            // including identically named files selected from different providers.
            Thread {
                val copies = mutableListOf<File>()
                try {
                    val files = uris.distinct().map { uri ->
                        val cacheFile = File.createTempFile("picked_", ".tmp", cacheDir)
                        copies.add(cacheFile)
                        val input = contentResolver.openInputStream(uri)
                            ?: throw IllegalStateException("Unable to open selected file")
                        input.use { source ->
                            cacheFile.outputStream().use { output -> source.copyTo(output) }
                        }
                        mapOf("path" to cacheFile.absolutePath,
                              "name" to (getDisplayName(uri) ?: "unknown"),
                              "size" to cacheFile.length())
                    }
                    runOnUiThread {
                        pendingFilePickerResult = null
                        result.success(if (multiple) files else files.firstOrNull())
                    }
                } catch (error: Exception) {
                    copies.forEach { it.delete() }
                    runOnUiThread {
                        pendingFilePickerResult = null
                        result.error("FILE_PICKER_ERROR", error.message, null)
                    }
                }
            }.start()
        }
    }

    override fun onDestroy() {
        try {
            multicastLock?.release()
        } catch (_: Exception) {}
        multicastLock = null
        super.onDestroy()
    }

    private fun getDisplayName(uri: android.net.Uri): String? {
        var name: String? = null
        val cursor = contentResolver.query(uri, null, null, null, null)
        cursor?.use { c ->
            if (c.moveToFirst()) {
                val nameIndex = c.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (nameIndex >= 0) {
                    name = c.getString(nameIndex)
                }
            }
        }
        return name
    }

    private fun openSharedFile(uri: Uri, fileName: String?) {
        val name = fileName ?: getDisplayName(uri) ?: ""
        val fromName = getMimeType(name)
        val mime = if (fromName != "application/octet-stream") fromName
                   else contentResolver.getType(uri) ?: fromName
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, mime)
            clipData = ClipData.newRawUri("file", uri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        // For APKs Android displays its installer and, if necessary, its own
        // unknown-source permission prompt. Installation still requires consent.
        startActivity(intent)
    }

    private fun getMimeType(fileName: String): String {
        val extension = fileName.substringAfterLast('.', "").lowercase(Locale.ROOT)
        if (extension == "apk") return "application/vnd.android.package-archive"
        return MimeTypeMap.getSingleton().getMimeTypeFromExtension(extension)
            ?: "application/octet-stream"
    }
}
