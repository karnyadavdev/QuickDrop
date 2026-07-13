package com.karnyadavdev.quickdrop

import android.Manifest
import android.app.Activity
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.database.Cursor
import android.net.ConnectivityManager
import android.net.Uri
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Environment
import android.provider.DocumentsContract
import android.provider.MediaStore
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.BufferedOutputStream
import java.io.File
import java.io.FileOutputStream
import java.io.InputStream
import java.io.OutputStream
import java.net.Inet4Address
import java.util.concurrent.CancellationException
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicLong

class MainActivity : FlutterActivity() {
    private val channelName = "com.karnyadavdev.quickdrop/native"
    private val filesRequestCode = 7209
    private val folderRequestCode = 7210
    private val notificationRequestCode = 7211
    private lateinit var channel: MethodChannel
    private var multicastLock: WifiManager.MulticastLock? = null
    private var filePickerResult: MethodChannel.Result? = null
    private var folderPickerResult: MethodChannel.Result? = null
    private val fileWorker = Executors.newSingleThreadExecutor()
    private val openFiles = ConcurrentHashMap<Long, InputStream>()
    private val nextFileId = AtomicLong(1)
    private val saveWorker = Executors.newSingleThreadExecutor()
    private val packWorker = Executors.newSingleThreadExecutor()
    @Volatile private var cancelFolderPack = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            channelName
        )
        TransferService.cancelTransfer = {
            channel.invokeMethod("cancelTransfer", null)
        }
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "acquireMulticastLock" -> acquireMulticastLock(result)
                "releaseMulticastLock" -> {
                    releaseMulticastLock()
                    result.success(null)
                }
                "getNetworkPrefixes" -> result.success(getNetworkPrefixes())
                "pickFiles" -> pickFiles(result)
                "pickFolder" -> pickFolder(result)
                "openFile" -> openFile(call, result)
                "readFileChunk" -> readFileChunk(call, result)
                "closeFile" -> closeFile(call, result)
                "packFolder" -> packFolder(call, result)
                "packFiles" -> packFiles(call, result)
                "cancelFolderPack" -> {
                    cancelFolderPack = true
                    result.success(null)
                }
                "startTransferService" -> startTransferService(call, result)
                "updateTransferService" -> updateTransferService(call, result)
                "stopTransferService" -> {
                    stopService(Intent(this, TransferService::class.java))
                    result.success(null)
                }
                "exportToDownloads" -> exportToDownloads(call, result)
                else -> result.notImplemented()
            }
        }
    }

    override fun onDestroy() {
        TransferService.cancelTransfer = null
        releaseMulticastLock()
        cancelFolderPack = true
        openFiles.values.forEach { runCatching { it.close() } }
        openFiles.clear()
        fileWorker.shutdownNow()
        saveWorker.shutdownNow()
        packWorker.shutdownNow()
        super.onDestroy()
    }

    private fun startTransferService(
        call: MethodCall,
        result: MethodChannel.Result
    ) {
        askForNotificationPermission()
        val intent = transferServiceIntent(call, TransferService.START)
        try {
            startForegroundService(intent)
            result.success(null)
        } catch (error: Exception) {
            result.error("TRANSFER_SERVICE_FAILED", error.message, null)
        }
    }

    private fun updateTransferService(
        call: MethodCall,
        result: MethodChannel.Result
    ) {
        try {
            startService(transferServiceIntent(call, TransferService.UPDATE))
            result.success(null)
        } catch (error: Exception) {
            result.error("TRANSFER_SERVICE_FAILED", error.message, null)
        }
    }

    private fun transferServiceIntent(
        call: MethodCall,
        action: String
    ): Intent {
        return Intent(this, TransferService::class.java).apply {
            this.action = action
            putExtra(
                TransferService.TITLE,
                call.argument<String>("title") ?: "QuickDrop transfer"
            )
            putExtra(
                TransferService.FILE_NAME,
                call.argument<String>("fileName") ?: "File"
            )
            putExtra(
                TransferService.PROGRESS,
                call.argument<Number>("progress")?.toInt() ?: -1
            )
        }
    }

    private fun askForNotificationPermission() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
        ) {
            return
        }
        val settings = getSharedPreferences("quickdrop", Context.MODE_PRIVATE)
        if (settings.getBoolean("askedForNotifications", false)) return
        settings.edit().putBoolean("askedForNotifications", true).apply()
        requestPermissions(
            arrayOf(Manifest.permission.POST_NOTIFICATIONS),
            notificationRequestCode
        )
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == filesRequestCode) {
            handleFilesResult(resultCode, data)
            return
        }
        if (requestCode != folderRequestCode) {
            super.onActivityResult(requestCode, resultCode, data)
            return
        }

        val result = folderPickerResult
        folderPickerResult = null
        if (result == null) return

        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            result.success(null)
            return
        }

        try {
            runCatching {
                contentResolver.takePersistableUriPermission(
                    uri,
                    Intent.FLAG_GRANT_READ_URI_PERMISSION
                )
            }
            val rootId = DocumentsContract.getTreeDocumentId(uri)
            val rootUri = DocumentsContract.buildDocumentUriUsingTree(uri, rootId)
            val folder = readTreeItem(rootUri)
            if (!folder.isDirectory) throw IllegalStateException("The selection is not a folder")
            result.success(mapOf("uri" to uri.toString(), "name" to folder.name))
        } catch (error: Exception) {
            result.error("FOLDER_PICK_FAILED", error.message, null)
        }
    }

    private fun pickFiles(result: MethodChannel.Result) {
        if (filePickerResult != null) {
            result.error("FILE_PICK_BUSY", "The file picker is already open", null)
            return
        }
        filePickerResult = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "*/*"
            putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
        }
        try {
            startActivityForResult(intent, filesRequestCode)
        } catch (error: Exception) {
            filePickerResult = null
            result.error("FILE_PICK_FAILED", error.message, null)
        }
    }

    private fun handleFilesResult(resultCode: Int, data: Intent?) {
        val result = filePickerResult
        filePickerResult = null
        if (result == null) return
        if (resultCode != Activity.RESULT_OK || data == null) {
            result.success(null)
            return
        }
        try {
            val uris = mutableListOf<Uri>()
            data.clipData?.let { clip ->
                for (index in 0 until clip.itemCount) uris.add(clip.getItemAt(index).uri)
            }
            if (uris.isEmpty()) data.data?.let { uris.add(it) }
            if (uris.isEmpty()) {
                result.success(null)
                return
            }
            val files = uris.distinct().map { uri ->
                runCatching {
                    contentResolver.takePersistableUriPermission(
                        uri,
                        Intent.FLAG_GRANT_READ_URI_PERMISSION
                    )
                }
                val info = readFileInfo(uri)
                mapOf("uri" to uri.toString(), "name" to info.name, "size" to info.size)
            }
            result.success(files)
        } catch (error: Exception) {
            result.error("FILE_PICK_FAILED", error.message ?: "Could not inspect the selected file", null)
        }
    }

    private fun openFile(call: MethodCall, result: MethodChannel.Result) {
        val uriText = call.argument<String>("uri")
        if (uriText.isNullOrBlank()) {
            result.error("INVALID_ARGUMENT", "A document URI is required", null)
            return
        }
        fileWorker.execute {
            try {
                val input = contentResolver.openInputStream(Uri.parse(uriText))
                    ?: throw IllegalStateException("Could not open the selected document")
                val id = nextFileId.getAndIncrement()
                openFiles[id] = input
                runOnUiThread { result.success(id) }
            } catch (error: Exception) {
                runOnUiThread { result.error("DOCUMENT_OPEN_FAILED", error.message, null) }
            }
        }
    }

    private fun readFileChunk(call: MethodCall, result: MethodChannel.Result) {
        val fileId = call.argument<Number>("fileId")?.toLong()
        val requested = call.argument<Number>("maxBytes")?.toInt()
        if (fileId == null || requested == null || requested <= 0) {
            result.error("INVALID_ARGUMENT", "A reader and positive chunk size are required", null)
            return
        }
        val maxBytes = minOf(requested, 4 * 1024 * 1024)
        fileWorker.execute {
            try {
                val input = openFiles[fileId]
                    ?: throw IllegalStateException("The document reader is closed")
                val buffer = ByteArray(maxBytes)
                val count = input.read(buffer)
                val bytes = if (count <= 0) ByteArray(0) else buffer.copyOf(count)
                runOnUiThread { result.success(bytes) }
            } catch (error: Exception) {
                runOnUiThread { result.error("DOCUMENT_READ_FAILED", error.message, null) }
            }
        }
    }

    private fun closeFile(call: MethodCall, result: MethodChannel.Result) {
        val fileId = call.argument<Number>("fileId")?.toLong()
        if (fileId == null) {
            result.error("INVALID_ARGUMENT", "A reader is required", null)
            return
        }
        fileWorker.execute {
            runCatching { openFiles.remove(fileId)?.close() }
            runOnUiThread { result.success(null) }
        }
    }

    private fun pickFolder(result: MethodChannel.Result) {
        if (folderPickerResult != null) {
            result.error("FOLDER_PICK_BUSY", "The folder picker is already open", null)
            return
        }
        folderPickerResult = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
            addFlags(Intent.FLAG_GRANT_PREFIX_URI_PERMISSION)
        }
        try {
            startActivityForResult(intent, folderRequestCode)
        } catch (error: Exception) {
            folderPickerResult = null
            result.error("FOLDER_PICK_FAILED", error.message, null)
        }
    }

    private fun packFolder(call: MethodCall, result: MethodChannel.Result) {
        val uriText = call.argument<String>("uri")
        val outputPath = call.argument<String>("outputPath")
        if (uriText.isNullOrBlank() || outputPath.isNullOrBlank()) {
            result.error("INVALID_ARGUMENT", "Folder URI and output path are required", null)
            return
        }

        cancelFolderPack = false
        packWorker.execute {
            val outputFile = File(outputPath)
            try {
                val treeUri = Uri.parse(uriText)
                val rootId = DocumentsContract.getTreeDocumentId(treeUri)
                val rootUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, rootId)
                val root = readTreeItem(rootUri)
                if (!root.isDirectory) throw IllegalStateException("The selection is not a folder")

                outputFile.parentFile?.mkdirs()
                val stats = PackResult()
                BufferedOutputStream(FileOutputStream(outputFile), 256 * 1024).use { output ->
                    val tar = TarWriter(output)
                    addFolderChildren(tar, treeUri, root.documentId, "", stats)
                    tar.finish()
                }
                if (cancelFolderPack) throw CancellationException("Folder packaging cancelled")
                runOnUiThread {
                    result.success(stats.toMap())
                }
            } catch (error: Exception) {
                outputFile.delete()
                runOnUiThread {
                    result.error("FOLDER_PACK_FAILED", error.message ?: "Could not prepare the folder", null)
                }
            }
        }
    }

    private fun packFiles(call: MethodCall, result: MethodChannel.Result) {
        val rawFiles = call.argument<List<Map<String, Any?>>>("files")
        val outputPath = call.argument<String>("outputPath")
        if (rawFiles.isNullOrEmpty() || outputPath.isNullOrBlank()) {
            result.error("INVALID_ARGUMENT", "Files and output path are required", null)
            return
        }
        cancelFolderPack = false
        packWorker.execute {
            val outputFile = File(outputPath)
            try {
                outputFile.parentFile?.mkdirs()
                val stats = PackResult()
                val usedNames = mutableSetOf<String>()
                BufferedOutputStream(FileOutputStream(outputFile), 256 * 1024).use { output ->
                    val tar = TarWriter(output)
                    for (raw in rawFiles) {
                        if (cancelFolderPack) throw CancellationException("File packaging cancelled")
                        val uriText = raw["uri"] as? String
                            ?: throw IllegalArgumentException("A selected file URI is missing")
                        val declaredName = raw["name"] as? String
                            ?: throw IllegalArgumentException("A selected file name is missing")
                        val declaredSize = (raw["size"] as? Number)?.toLong()
                            ?: throw IllegalArgumentException("A selected file size is missing")
                        if (declaredSize < 0) throw IllegalArgumentException("Unknown file size")
                        val name = unusedName(safeTarName(declaredName), usedNames)
                        addUriFile(tar, Uri.parse(uriText), name, declaredSize, 0, stats)
                    }
                    tar.finish()
                }
                if (cancelFolderPack) throw CancellationException("File packaging cancelled")
                runOnUiThread { result.success(stats.toMap()) }
            } catch (error: Exception) {
                outputFile.delete()
                runOnUiThread {
                    result.error("FILE_PACK_FAILED", error.message ?: "Could not prepare the files", null)
                }
            }
        }
    }

    private fun addFolderChildren(
        tar: TarWriter,
        treeUri: Uri,
        parentDocumentId: String,
        parent: String,
        stats: PackResult
    ) {
        if (cancelFolderPack) throw CancellationException("Folder packaging cancelled")
        val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(
            treeUri,
            parentDocumentId
        )
        val cursor = contentResolver.query(childrenUri, TREE_COLUMNS, null, null, null)
            ?: throw IllegalStateException("The document provider returned no folder contents")
        cursor.use {
            while (it.moveToNext()) {
                if (cancelFolderPack) throw CancellationException("Folder packaging cancelled")
                val item = treeItemFrom(treeUri, it)
                val itemName = safeTarName(item.name)
                val path = if (parent.isBlank()) itemName else "$parent/$itemName"
                if (item.isDirectory) {
                    tar.addDirectory(path, item.modified)
                    stats.directories++
                    addFolderChildren(tar, treeUri, item.documentId, path, stats)
                } else {
                    if (item.size < 0) {
                        throw IllegalStateException("The provider did not report the size of $itemName")
                    }
                    addUriFile(tar, item.uri, path, item.size, item.modified, stats)
                }
            }
        }
    }

    private fun addUriFile(
        tar: TarWriter,
        uri: Uri,
        path: String,
        size: Long,
        modified: Long,
        stats: PackResult
    ) {
        val input = contentResolver.openInputStream(uri)
            ?: throw IllegalStateException("Could not open $path")
        input.use {
            tar.addFile(path, size, modified, it) {
                if (cancelFolderPack) throw CancellationException("Folder packaging cancelled")
            }
            if (it.read() != -1) {
                throw IllegalStateException("$path changed size while it was being packaged")
            }
        }
        stats.files++
        stats.bytes += size
    }

    private fun readFileInfo(uri: Uri): PickedFile {
        val columns = arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE)
        val cursor = contentResolver.query(uri, columns, null, null, null)
            ?: throw IllegalStateException("The document provider returned no metadata")
        return cursor.use {
            if (!it.moveToFirst()) throw IllegalStateException("The selected document no longer exists")
            val name = it.getString(it.getColumnIndexOrThrow(OpenableColumns.DISPLAY_NAME))
                ?.takeIf(String::isNotBlank)
                ?: throw IllegalStateException("The document provider returned no file name")
            val sizeIndex = it.getColumnIndexOrThrow(OpenableColumns.SIZE)
            if (it.isNull(sizeIndex)) {
                throw IllegalStateException(
                    "The provider did not report the size of $name. Download it locally and try again."
                )
            }
            val size = it.getLong(sizeIndex)
            if (size < 0) throw IllegalStateException("The provider returned an invalid size for $name")
            PickedFile(name, size)
        }
    }

    private fun readTreeItem(uri: Uri): TreeItem {
        val cursor = contentResolver.query(uri, TREE_COLUMNS, null, null, null)
            ?: throw IllegalStateException("The document provider returned no metadata")
        return cursor.use {
            if (!it.moveToFirst()) throw IllegalStateException("The selected folder no longer exists")
            treeItemFrom(uri, it, uri)
        }
    }

    private fun treeItemFrom(treeUri: Uri, cursor: Cursor, knownUri: Uri? = null): TreeItem {
        val documentId = cursor.getString(
            cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_DOCUMENT_ID)
        ) ?: throw IllegalStateException("A document identifier is missing")
        val name = cursor.getString(
            cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_DISPLAY_NAME)
        )?.takeIf(String::isNotBlank)
            ?: throw IllegalStateException("A document name is missing")
        val mime = cursor.getString(
            cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_MIME_TYPE)
        ) ?: throw IllegalStateException("The provider did not classify $name")
        val sizeIndex = cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_SIZE)
        val size = if (cursor.isNull(sizeIndex)) -1 else cursor.getLong(sizeIndex)
        val modifiedIndex = cursor.getColumnIndexOrThrow(
            DocumentsContract.Document.COLUMN_LAST_MODIFIED
        )
        val modified = if (cursor.isNull(modifiedIndex)) 0 else cursor.getLong(modifiedIndex)
        return TreeItem(
            documentId = documentId,
            uri = knownUri ?: DocumentsContract.buildDocumentUriUsingTree(treeUri, documentId),
            name = name,
            isDirectory = mime == DocumentsContract.Document.MIME_TYPE_DIR,
            size = size,
            modified = modified
        )
    }

    private fun safeTarName(raw: String): String {
        val clean = raw.replace('/', '_').replace('\\', '_').trim()
        if (clean.isBlank() || clean == "." || clean == "..") {
            throw IllegalStateException("A selected item has an invalid name")
        }
        return clean
    }

    private fun unusedName(name: String, used: MutableSet<String>): String {
        for (number in 0..9999) {
            val candidate = copyName(name, number)
            if (used.add(candidate.lowercase())) return candidate
        }
        throw IllegalStateException("Too many files have the same name")
    }

    private data class PickedFile(val name: String, val size: Long)
    private data class TreeItem(
        val documentId: String,
        val uri: Uri,
        val name: String,
        val isDirectory: Boolean,
        val size: Long,
        val modified: Long
    )
    private data class PackResult(
        var files: Int = 0,
        var directories: Int = 0,
        var bytes: Long = 0
    ) {
        fun toMap(): Map<String, Any> = mapOf(
            "files" to files,
            "directories" to directories,
            "bytes" to bytes
        )
    }

    companion object {
        private val TREE_COLUMNS = arrayOf(
            DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            DocumentsContract.Document.COLUMN_MIME_TYPE,
            DocumentsContract.Document.COLUMN_SIZE,
            DocumentsContract.Document.COLUMN_LAST_MODIFIED
        )
    }

    private fun acquireMulticastLock(result: MethodChannel.Result) {
        try {
            val wifiManager = applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
            if (wifiManager == null) {
                result.error("UNAVAILABLE", "Wi-Fi service is unavailable", null)
                return
            }
            val lock = multicastLock ?: wifiManager.createMulticastLock("QuickDropDiscovery")
            lock.setReferenceCounted(false)
            if (!lock.isHeld) lock.acquire()
            multicastLock = lock
            result.success(null)
        } catch (error: Exception) {
            result.error("MULTICAST_LOCK_FAILED", error.message, null)
        }
    }

    private fun releaseMulticastLock() {
        multicastLock?.let { lock ->
            if (lock.isHeld) lock.release()
        }
        multicastLock = null
    }

    @Suppress("DEPRECATION")
    private fun getNetworkPrefixes(): Map<String, Int> {
        val connectivity = getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
            ?: return emptyMap()
        val result = linkedMapOf<String, Int>()
        for (network in connectivity.allNetworks) {
            val capabilities = connectivity.getNetworkCapabilities(network) ?: continue
            if (!capabilities.hasTransport(android.net.NetworkCapabilities.TRANSPORT_WIFI) &&
                !capabilities.hasTransport(android.net.NetworkCapabilities.TRANSPORT_ETHERNET)) {
                continue
            }
            val properties = connectivity.getLinkProperties(network) ?: continue
            for (linkAddress in properties.linkAddresses) {
                val address = linkAddress.address
                if (address is Inet4Address && !address.isLoopbackAddress && !address.isLinkLocalAddress) {
                    val host = address.hostAddress ?: continue
                    result[host] = linkAddress.prefixLength
                }
            }
        }
        return result
    }

    private fun exportToDownloads(call: MethodCall, result: MethodChannel.Result) {
        val sourcePath = call.argument<String>("path")
        val isFolder = call.argument<Boolean>("isFolder") == true
        if (sourcePath.isNullOrBlank()) {
            result.error("INVALID_ARGUMENT", "A source path is required", null)
            return
        }
        saveWorker.execute {
            try {
                val source = File(sourcePath)
                if (!source.exists()) throw IllegalArgumentException("Received content no longer exists")
                if (isFolder) {
                    exportDirectory(source)
                } else {
                    exportFile(source, Environment.DIRECTORY_DOWNLOADS + "/QuickDrop")
                }
                runOnUiThread { result.success(null) }
            } catch (error: Exception) {
                runOnUiThread {
                    result.error("EXPORT_FAILED", error.message ?: "Could not export received content", null)
                }
            }
        }
    }

    private fun exportDirectory(directory: File) {
        val root = Environment.DIRECTORY_DOWNLOADS + "/QuickDrop/" + directory.name
        directory.walkTopDown().filter { it.isFile }.forEach { file ->
            val relativeParent = file.parentFile?.relativeTo(directory)?.path.orEmpty()
                .replace(File.separatorChar, '/')
            val destination = if (relativeParent.isBlank()) root else "$root/$relativeParent"
            exportFile(file, destination)
        }
    }

    private fun exportFile(source: File, relativePath: String) {
        val folder = relativePath.trimEnd('/') + "/"
        val saved = createDownloadFile(source.name, folder)
        try {
            source.inputStream().use { input ->
                contentResolver.openOutputStream(saved.uri)?.use { output ->
                    input.copyTo(output)
                } ?: throw IllegalStateException("Could not open the Downloads entry")
            }
            saved.values.clear()
            saved.values.put(MediaStore.Downloads.IS_PENDING, 0)
            contentResolver.update(saved.uri, saved.values, null, null)
        } catch (error: Exception) {
            contentResolver.delete(saved.uri, null, null)
            throw error
        }
    }

    private data class DownloadFile(val uri: android.net.Uri, val values: ContentValues)

    private fun createDownloadFile(name: String, folder: String): DownloadFile {
        for (number in 0..999) {
            val fileName = copyName(name, number)
            if (nameExists(fileName, folder)) continue
            val values = ContentValues().apply {
                put(MediaStore.Downloads.DISPLAY_NAME, fileName)
                put(MediaStore.Downloads.MIME_TYPE, "application/octet-stream")
                put(MediaStore.Downloads.RELATIVE_PATH, folder)
                put(MediaStore.Downloads.IS_PENDING, 1)
            }
            val uri = contentResolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                ?: throw IllegalStateException("Could not create a Downloads entry")
            if (savedName(uri) == fileName) {
                return DownloadFile(uri, values)
            }
            contentResolver.delete(uri, null, null)
        }
        throw IllegalStateException("Could not find a free file name")
    }

    private fun nameExists(name: String, folder: String): Boolean {
        val where = "${MediaStore.Downloads.DISPLAY_NAME}=? AND ${MediaStore.Downloads.RELATIVE_PATH}=?"
        return contentResolver.query(
            MediaStore.Downloads.EXTERNAL_CONTENT_URI,
            arrayOf(MediaStore.Downloads._ID),
            where,
            arrayOf(name, folder),
            null
        )?.use { files -> files.moveToFirst() } ?: false
    }

    private fun copyName(name: String, number: Int): String {
        val cleanName = moveCopyNumber(name)
        if (number == 0) return cleanName
        val dot = cleanName.lastIndexOf('.')
        val base = if (dot > 0) cleanName.substring(0, dot) else cleanName
        val extension = if (dot > 0) cleanName.substring(dot) else ""
        return "$base ($number)$extension"
    }

    private fun moveCopyNumber(name: String): String {
        val match = Regex("^(.*)(\\.[^. ]+) \\((\\d+)\\)$").matchEntire(name)
            ?: return name
        return match.groupValues[1] + " (" + match.groupValues[3] + ")" + match.groupValues[2]
    }

    private fun savedName(uri: android.net.Uri): String? {
        val columns = arrayOf(MediaStore.Downloads.DISPLAY_NAME)
        return contentResolver.query(
            uri,
            columns,
            null,
            null,
            null
        )?.use { files ->
            if (!files.moveToFirst()) return@use null
            files.getString(files.getColumnIndexOrThrow(MediaStore.Downloads.DISPLAY_NAME))
        }
    }

    private class TarWriter(private val output: OutputStream) {
        private val zeroBlock = ByteArray(512)

        fun addDirectory(name: String, modified: Long) {
            val path = if (name.endsWith('/')) name else "$name/"
            writeHeader(path, 0, modified, '5')
        }

        fun addFile(
            name: String,
            size: Long,
            modified: Long,
            input: InputStream,
            checkCancelled: () -> Unit
        ) {
            writeHeader(name, size, modified, '0')
            val buffer = ByteArray(256 * 1024)
            var remaining = size
            while (remaining > 0) {
                checkCancelled()
                val read = input.read(buffer, 0, minOf(buffer.size.toLong(), remaining).toInt())
                if (read <= 0) throw IllegalStateException("A file ended before all bytes were read")
                output.write(buffer, 0, read)
                remaining -= read
            }
            val padding = ((512 - size % 512) % 512).toInt()
            if (padding > 0) output.write(zeroBlock, 0, padding)
        }

        fun finish() {
            output.write(zeroBlock)
            output.write(zeroBlock)
            output.flush()
        }

        private fun writeHeader(name: String, size: Long, modified: Long, type: Char) {
            val header = ByteArray(512)
            val parts = splitName(name)
            putText(header, 0, 100, parts.second)
            putOctal(header, 100, 8, if (type == '5') 493 else 420)
            putOctal(header, 108, 8, 0)
            putOctal(header, 116, 8, 0)
            putOctal(header, 124, 12, size)
            putOctal(header, 136, 12, maxOf(0, modified / 1000))
            for (index in 148 until 156) header[index] = 32
            header[156] = type.code.toByte()
            putText(header, 257, 6, "ustar")
            putText(header, 263, 2, "00")
            putText(header, 345, 155, parts.first)

            var checksum = 0
            for (byte in header) checksum += byte.toInt() and 0xFF
            val text = checksum.toString(8).padStart(6, '0')
            putText(header, 148, 6, text)
            header[154] = 0
            header[155] = 32
            output.write(header)
        }

        private fun splitName(name: String): Pair<String, String> {
            if (name.toByteArray(Charsets.UTF_8).size <= 100) return "" to name
            val isDirectory = name.endsWith('/')
            val path = if (isDirectory) name.dropLast(1) else name
            var slash = path.lastIndexOf('/')
            while (slash > 0) {
                val prefix = path.substring(0, slash)
                val shortName = path.substring(slash + 1) + if (isDirectory) "/" else ""
                if (prefix.toByteArray(Charsets.UTF_8).size <= 155 &&
                    shortName.toByteArray(Charsets.UTF_8).size <= 100) {
                    return prefix to shortName
                }
                slash = path.lastIndexOf('/', slash - 1)
            }
            throw IllegalStateException("A folder path is too long to send: $name")
        }

        private fun putText(block: ByteArray, start: Int, length: Int, text: String) {
            val bytes = text.toByteArray(Charsets.UTF_8)
            if (bytes.size > length) throw IllegalStateException("A folder path is too long to send")
            System.arraycopy(bytes, 0, block, start, bytes.size)
        }

        private fun putOctal(block: ByteArray, start: Int, length: Int, value: Long) {
            val text = value.toString(8).padStart(length - 1, '0')
            if (text.length >= length) throw IllegalStateException("A file is too large to package")
            putText(block, start, length - 1, text)
        }
    }

}
