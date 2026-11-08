package com.camanime.app

import android.Manifest
import android.app.Activity
import android.content.ContentValues
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Exports finished episodes into public device storage.
 *
 * Android 10+ uses MediaStore, so no permission is needed and the copy is
 * indexed for every file manager and gallery. Android 9 and older fall back to
 * the legacy Download/CamAnime directory behind WRITE_EXTERNAL_STORAGE.
 *
 * The copy is deliberately independent of the app-private download: deleting
 * the in-app episode or uninstalling CamAnime never removes the exported file.
 */
class StorageBridge(private val activity: Activity) {

    companion object {
        private const val CHANNEL = "camanime/storage"
        private const val PERMISSION_REQUEST = 9002
        private var pending: MethodChannel.Result? = null
        private var pendingArgs: Map<String, Any?>? = null

        fun register(activity: Activity, messenger: io.flutter.plugin.common.BinaryMessenger) {
            MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
                when (call.method) {
                    "save" -> save(activity, call, result)
                    "openDownloads" -> {
                        openDownloads(activity)
                        result.success(true)
                    }
                    "delete" -> {
                        val location = call.argument<String>("location") ?: ""
                        delete(activity, location)
                        result.success(true)
                    }
                    "setProfilePic" -> {
                        val bytes = call.argument<ByteArray>("bytes")
                        if (bytes == null) {
                            result.error(
                                "INVALID_ARGUMENTS",
                                "bytes",
                                "A PNG/JPG byte array is required."
                            )
                        } else {
                            result.success(setProfilePic(activity, bytes))
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        }

        private fun save(activity: Activity, call: MethodCall, result: MethodChannel.Result) {
            val args = mapOf(
                "path" to call.argument<String>("path"),
                "folder" to call.argument<String>("folder"),
                "subfolder" to call.argument<String>("subfolder"),
                "name" to call.argument<String>("name")
            )
            val source = args["path"] as? String
            if (source.isNullOrEmpty() || !File(source).exists()) {
                result.success(null)
                return
            }
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q &&
                ContextCompat.checkSelfPermission(
                    activity, Manifest.permission.WRITE_EXTERNAL_STORAGE
                ) != PackageManager.PERMISSION_GRANTED
            ) {
                pending = result
                pendingArgs = args
                ActivityCompat.requestPermissions(
                    activity,
                    arrayOf(Manifest.permission.WRITE_EXTERNAL_STORAGE),
                    PERMISSION_REQUEST
                )
                return
            }
            result.success(writeCopy(activity, args))
        }

        /** Called by MainActivity when the legacy permission dialog closes. */
        fun onPermissionResult(requestCode: Int, granted: Boolean) {
            if (requestCode != PERMISSION_REQUEST) return
            val result = pending ?: return
            val args = pendingArgs
            pending = null
            pendingArgs = null
            val activity = resultActivity ?: run {
                result.success(null)
                return
            }
            result.success(if (granted && args != null) writeCopy(activity, args) else null)
        }

        private var resultActivity: Activity? = null

        fun attach(activity: Activity) {
            resultActivity = activity
        }

        private fun writeCopy(activity: Activity, args: Map<String, Any?>): String? {
            val source = args["path"] as? String ?: return null
            val folder = safeSegment(args["folder"] as? String, "CamAnime")
            val subfolder = safeSegment(args["subfolder"] as? String, "")
            val name = safeName(args["name"] as? String) ?: return null
            return try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    writeMediaStore(activity, source, folder, subfolder, name)
                } else {
                    writeLegacy(activity, source, folder, subfolder, name)
                }
            } catch (_: Exception) {
                null
            }
        }

        private fun writeMediaStore(
            activity: Activity,
            source: String,
            folder: String,
            subfolder: String,
            name: String
        ): String? {
            val relative = buildString {
                append(Environment.DIRECTORY_DOWNLOADS)
                append("/CamAnime/")
                append(folder)
                if (subfolder.isNotEmpty()) {
                    append("/")
                    append(subfolder)
                }
            }
            val values = ContentValues().apply {
                put(MediaStore.Downloads.DISPLAY_NAME, name)
                put(MediaStore.Downloads.MIME_TYPE, mimeFor(name))
                put(MediaStore.Downloads.RELATIVE_PATH, relative)
                put(MediaStore.Downloads.IS_PENDING, 1)
            }
            val resolver = activity.contentResolver
            val uri: Uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                ?: return null
            try {
                resolver.openOutputStream(uri)?.use { out ->
                    File(source).inputStream().use { input ->
                        input.copyTo(out, 256 * 1024)
                    }
                } ?: return null
                val done = ContentValues().apply {
                    put(MediaStore.Downloads.IS_PENDING, 0)
                }
                resolver.update(uri, done, null, null)
                return "Downloads/CamAnime/$folder/${if (subfolder.isEmpty()) "" else "$subfolder/"}$name"
            } catch (e: Exception) {
                resolver.delete(uri, null, null)
                throw e
            }
        }

        @Suppress("DEPRECATION")
        private fun writeLegacy(
            activity: Activity,
            source: String,
            folder: String,
            subfolder: String,
            name: String
        ): String? {
            val base = File(
                Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS),
                "CamAnime/$folder" + if (subfolder.isEmpty()) "" else "/$subfolder"
            )
            if (!base.exists() && !base.mkdirs()) return null
            val target = File(base, name)
            File(source).inputStream().use { input ->
                target.outputStream().use { out -> input.copyTo(out, 256 * 1024) }
            }
            return target.absolutePath
        }

        private fun openDownloads(activity: Activity) {
            try {
                val intent = Intent(Intent.ACTION_VIEW).apply {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                        setDataAndType(
                            MediaStore.Downloads.EXTERNAL_CONTENT_URI,
                            "vnd.android.document/directory"
                        )
                    } else {
                        @Suppress("DEPRECATION")
                        setDataAndType(
                            Uri.fromFile(
                                Environment.getExternalStoragePublicDirectory(
                                    Environment.DIRECTORY_DOWNLOADS
                                )
                            ),
                            "resource/folder"
                        )
                    }
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_GRANT_READ_URI_PERMISSION)
                }
                activity.startActivity(intent)
            } catch (_: Exception) {
            }
        }

        private fun delete(activity: Activity, location: String) {
            try {
                if (location.startsWith("content://")) {
                    activity.contentResolver.delete(Uri.parse(location), null, null)
                } else if (location.isNotEmpty()) {
                    File(location).delete()
                }
            } catch (_: Exception) {
            }
        }

        private fun mimeFor(name: String): String = when (name.substringAfterLast('.', "").lowercase()) {
            "ts" -> "video/mp2t"
            "mkv" -> "video/x-matroska"
            "webm" -> "video/webm"
            "jpg", "jpeg" -> "image/jpeg"
            "png" -> "image/png"
            else -> "video/mp4"
        }

        private fun setProfilePic(activity: Activity, bytes: ByteArray): Boolean {
            return try {
                val values = ContentValues().apply {
                    put(MediaStore.Images.Media.DISPLAY_NAME, "profile_avatar.png")
                    put(MediaStore.Images.Media.MIME_TYPE, "image/png")
                    put(MediaStore.Images.Media.RELATIVE_PATH, "Pictures/CamAnime")
                    put(MediaStore.Images.Media.IS_PENDING, 1)
                }
                val uri = activity.contentResolver.insert(
                    MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values
                ) ?: return false
                activity.contentResolver.openOutputStream(uri)?.use { out ->
                    out.write(bytes)
                } ?: return false
                activity.contentResolver.update(
                    uri,
                    ContentValues().apply { put(MediaStore.Images.Media.IS_PENDING, 0) },
                    null,
                    null
                )
                true
            } catch (_: Exception) {
                false
            }
        }

        private fun safeSegment(raw: String?, fallback: String): String {
            val cleaned = (raw ?: "").replace(Regex("[\\\\/:*?\"<>|]"), "").trim()
            return if (cleaned.isEmpty()) fallback else cleaned.take(80)
        }

        private fun safeName(raw: String?): String? {
            val cleaned = (raw ?: "").replace(Regex("[\\\\/:*?\"<>|]"), "").trim()
            if (cleaned.isEmpty()) return null
            val dot = cleaned.lastIndexOf('.')
            val base = if (dot > 0) cleaned.substring(0, dot) else cleaned
            val ext = if (dot > 0) cleaned.substring(dot) else ".mp4"
            return base.take(80) + ext
        }
    }
}
