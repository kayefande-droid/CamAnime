package com.camanime.app

import android.Manifest
import android.content.Intent
import android.app.PictureInPictureParams
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.os.Build
import android.os.Bundle
import android.util.Rational
import androidx.core.app.ActivityCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val keepAliveChannel = "camanime/keepalive"
    private val advertsChannel = "camanime/adverts"
    private val navigationChannel = "camanime/navigation"
    private val notificationsChannel = "camanime/notifications"
    private val pipChannel = "camanime/pip"
    private val playerChannel = "camanime/player"
    private val updateChannel = "camanime/update"

    private var navigation: MethodChannel? = null
    private var pip: MethodChannel? = null
    private var update: MethodChannel? = null
    private var pendingAdvert: Map<String, String>? = null
    /** True while the miniplayer is playing, i.e. worth floating. */
    private var pipArmed = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // FCM posts on this channel. Create it at launch so a release or
        // episode push that arrives while the app is closed still shows:
        // Android 8+ drops a notification whose channel does not exist.
        try {
            Notifications.ensureUpdatesChannel(this)
        } catch (_: Exception) {
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // In-app self-update: download the release APK, then hand it to the
        // system installer (Android always requires that final confirmation).
        UpdaterBridge.register(this, flutterEngine.dartExecutor.binaryMessenger)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, keepAliveChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        try {
                            val intent =
                                Intent(this, DownloadKeepAliveService::class.java)
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                                startForegroundService(intent)
                            } else {
                                startService(intent)
                            }
                            result.success(true)
                        } catch (e: Exception) {
                            // Background start may be refused by the OS; the
                            // Dart downloader still runs and resumes later.
                            result.success(false)
                        }
                    }
                    "stop" -> {
                        try {
                            stopService(
                                Intent(this, DownloadKeepAliveService::class.java)
                            )
                        } catch (_: Exception) {
                        }
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, advertsChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        AdvertWorker.schedule(this)
                        requestNotificationPermission()
                        result.success(true)
                    }
                    "stop" -> {
                        AdvertWorker.cancel(this)
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, notificationsChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "init", "enable" -> {
                        Notifications.ensureCompleteChannel(this)
                        // FCM posts on this channel; create it before any token is
                        // registered so the first push is not dropped.
                        Notifications.ensureUpdatesChannel(this)
                        requestNotificationPermission()
                        result.success(true)
                    }
                    "disable" -> result.success(true)
                    "announcement" -> {
                        Notifications.announcement(
                            this,
                            call.argument<String>("title") ?: "CamAnime",
                            call.argument<String>("body") ?: "",
                            call.argument<String>("id") ?: "camanime-announcement",
                            call.argument<String>("version"),
                            call.argument<String>("action")
                        )
                        result.success(true)
                    }
                    "downloadComplete" -> {
                        val notificationsEnabled =
                            call.argument<Boolean>("notificationsEnabled") ?: true
                        Notifications.downloadComplete(
                            this,
                            call.argument<String>("title") ?: "CamAnime",
                            call.argument<Int>("episode") ?: 0,
                            call.argument<String>("id") ?: "camanime-episode",
                            notificationsEnabled,
                            call.argument<String>("image")
                                ?: call.argument<String>("imageUrl")
                        )
                        result.success(true)
                    }
                    "updateInProgress" -> {
                        Notifications.updateInProgress(
                            this,
                            call.argument<String>("version") ?: "2.9.0",
                            call.argument<String>("id") ?: "camanime-update"
                        )
                        result.success(true)
                    }
                    "dismissUpdateInProgress" -> {
                        Notifications.dismissUpdateInProgress(this)
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }

        // Miniplayer, small floating window: leaving the app with playback
        // running shrinks it above other apps; Android's own X closes it and
        // Dart ends playback in that case.
        pip = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            pipChannel
        ).also { channel ->
            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "supported" -> result.success(pipSupported())
                    "arm" -> {
                        pipArmed = call.argument<Boolean>("armed") ?: false
                        result.success(true)
                    }
                    "enter" -> result.success(enterPip())
                    else -> result.notImplemented()
                }
            }
        }

        // In-app auto-update triggered from a notification tap / scheduled alarm.
        // The Android side invokes "startNow"; Dart runs the download, install and
        // restart, then the freshly installed app shows the whats-new dialog.
        update = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            updateChannel
        ).also { channel ->
            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "startNow" -> {
                        deliverUpdateIntent(intent)
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
        }

        // Player brightness: Android cannot set system brightness from an app,
        // but it can dim its own window, which is exactly what a video player
        // needs. -1 restores the system setting on exit.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, playerChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "brightness" -> {
                        val value = call.argument<Double>("value") ?: 1.0
                        val attrs = window.attributes
                        attrs.screenBrightness = value.coerceIn(0.02, 1.0).toFloat()
                        window.attributes = attrs
                        result.success(true)
                    }
                    "resetBrightness" -> {
                        val attrs = window.attributes
                        attrs.screenBrightness = -1f
                        window.attributes = attrs
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }

        StorageBridge.attach(this)
        StorageBridge.register(this, flutterEngine.dartExecutor.binaryMessenger)

        navigation = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            navigationChannel
        ).also { channel ->
            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "getInitialAdvert" -> {
                        result.success(pendingAdvert)
                        pendingAdvert = null
                    }
                    else -> result.notImplemented()
                }
            }
        }
        // Honor a pending update launch before showing any advert.
        deliverUpdateIntent(intent)
        deliverAdvert(intent)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        val granted = grantResults.isNotEmpty() &&
            grantResults[0] == PackageManager.PERMISSION_GRANTED
        StorageBridge.onPermissionResult(requestCode, granted)
    }

    private fun pipSupported(): Boolean =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            packageManager.hasSystemFeature(
                PackageManager.FEATURE_PICTURE_IN_PICTURE
            )

    private fun enterPip(): Boolean {
        if (!pipSupported() || isInPictureInPictureMode) return false
        return try {
            val params = PictureInPictureParams.Builder()
                .setAspectRatio(Rational(16, 9))
                .build()
            enterPictureInPictureMode(params)
        } catch (e: Exception) {
            false
        }
    }

    /** Home button / app switch: float the episode instead of stopping it. */
    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        if (pipArmed) enterPip()
    }

    override fun onPictureInPictureModeChanged(
        isInPictureInPictureMode: Boolean,
        newConfig: Configuration
    ) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        pip?.invokeMethod(
            if (isInPictureInPictureMode) "pipEntered" else "pipClosed",
            null
        )
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        deliverUpdateIntent(intent)
        deliverAdvert(intent)
    }

    /** Routes an advert notification tap into the Flutter detail screen. */
    private fun deliverAdvert(intent: Intent?) {
        val animeId = intent?.getStringExtra("advert_anime_id") ?: return
        val title = intent.getStringExtra("advert_anime_title") ?: "Anime"
        val advert = mapOf("anime_id" to animeId, "title" to title)
        pendingAdvert = advert
        navigation?.invokeMethod("openAdvert", advert)
        intent.removeExtra("advert_anime_id")
        intent.removeExtra("advert_anime_title")
    }

    /**
     * When a live-update notification or the scheduled alarm launches the app with
     * `start_update = true`, hand off to Dart so it can download, install and restart.
     */
    private fun deliverUpdateIntent(intent: Intent?) {
        if (intent?.getBooleanExtra("start_update", false) != true) return
        update?.invokeMethod("startNow", null)
    }

    private fun requestNotificationPermission() {
        if (Build.VERSION.SDK_INT < 33) return
        if (checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
        ) {
            return
        }
        ActivityCompat.requestPermissions(
            this,
            arrayOf(Manifest.permission.POST_NOTIFICATIONS),
            9001
        )
    }
}
