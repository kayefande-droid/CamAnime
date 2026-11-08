package com.camanime.app

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * In-app updater, native half.
 *
 * The Dart side downloads the new APK and hands the path here. Android never
 * lets an app install a package silently unless it is a device owner, so the
 * last step is the system package installer: this bridge opens it with the
 * downloaded file, and the user confirms once. After the install Android
 * replaces the app and restarts it, which is the "update itself" behaviour.
 *
 * If "install unknown apps" is not granted for CamAnime, the bridge opens that
 * exact settings screen instead of failing silently.
 */
class UpdaterBridge(private val activity: Activity) {

    companion object {
        private const val CHANNEL = "camanime/updater"

        fun register(activity: Activity, messenger: io.flutter.plugin.common.BinaryMessenger) {
            val bridge = UpdaterBridge(activity)
            MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
                when (call.method) {
                    "canInstall" -> result.success(bridge.canInstall())
                    "install" -> {
                        val path = call.argument<String>("path") ?: ""
                        result.success(bridge.install(path))
                    }
                    "permissionSettings" -> result.success(bridge.openPermissionSettings())
                    "versionName" -> result.success(bridge.versionName())
                    "restart" -> result.success(bridge.restart())
                    else -> result.notImplemented()
                }
            }
        }
    }

    private fun canInstall(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return true
        return activity.packageManager.canRequestPackageInstalls()
    }

    private fun versionName(): String = try {
        val info = activity.packageManager.getPackageInfo(activity.packageName, 0)
        info.versionName ?: ""
    } catch (_: Exception) {
        ""
    }

    private fun openPermissionSettings(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return true
        return try {
            val intent = Intent(
                Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                Uri.parse("package:" + activity.packageName)
            )
            activity.startActivity(intent)
            false
        } catch (_: Exception) {
            false
        }
    }

    private fun install(path: String): Boolean {
        if (path.isEmpty()) return false
        val file = File(path)
        if (!file.exists() || file.length() < 1024) return false
        if (!canInstall()) {
            openPermissionSettings()
            return false
        }
        return try {
            val uri: Uri = FileProvider.getUriForFile(
                activity,
                activity.packageName + ".fileprovider",
                file
            )
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, "application/vnd.android.package-archive")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            activity.startActivity(intent)
            true
        } catch (_: Exception) {
            false
        }
    }

    /** Brings CamAnime back to the front after an update check. */
    private fun restart(): Boolean = try {
        val intent = activity.packageManager.getLaunchIntentForPackage(activity.packageName)
        if (intent == null) {
            false
        } else {
            intent.addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_NEW_TASK)
            activity.startActivity(intent)
            activity.finishAffinity()
            true
        }
    } catch (_: Exception) {
        false
    }
}
