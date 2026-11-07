package com.camanime.app

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.ActivityCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val keepAliveChannel = "camanime/keepalive"
    private val advertsChannel = "camanime/adverts"
    private val navigationChannel = "camanime/navigation"
    private val notificationsChannel = "camanime/notifications"

    private var navigation: MethodChannel? = null
    private var pendingAdvert: Map<String, String>? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

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
                        requestNotificationPermission()
                        result.success(true)
                    }
                    "disable" -> result.success(true)
                    "downloadComplete" -> {
                        Notifications.downloadComplete(
                            this,
                            call.argument<String>("title") ?: "CamAnime",
                            call.argument<Int>("episode") ?: 0,
                            call.argument<String>("id") ?: "camanime-episode"
                        )
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }

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
        deliverAdvert(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
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
