package com.camanime.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.LinearGradient
import android.graphics.Paint
import android.graphics.Shader
import android.graphics.Typeface
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.core.app.NotificationCompat
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.Executors

/** Companion stable id so update notices can be posted and dismissed together. */
private const val UPDATE_NOTIFICATION_ID = 71001

/**
 * Heads-up notifications that land above whatever app is on screen.
 *
 * The download-complete banner shows part of the anime poster: the Dart side
 * forwards the artwork URL, this side fetches a downscaled copy on a worker
 * thread and paints it through BigPictureStyle. When the fetch fails (offline,
 * hotlink rejection) the banner falls back to a local drawable instead of a
 * blank box, so the alert never looks broken.
 */
private const val POSTER_FALLBACK = android.R.drawable.ic_menu_gallery
private const val POSTER_MAX_PX = 512

object Notifications {
    const val COMPLETE_CHANNEL_ID = "camanime_downloads_complete"
    const val ANNOUNCE_CHANNEL_ID = "camanime_announcements"

    /**
     * Channel the Cloudflare worker targets for Firebase messages
     * (`android.notification.channel_id`). It must exist on the device before a
     * push arrives, otherwise Android drops the notification silently on O+.
     */
    const val UPDATES_CHANNEL_ID = "camanime_updates"

    private val posterExecutor = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())

    fun ensureCompleteChannel(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager =
            context.getSystemService(NotificationManager::class.java) ?: return
        val channel = NotificationChannel(
            COMPLETE_CHANNEL_ID,
            "Downloads finished",
            NotificationManager.IMPORTANCE_HIGH
        ).apply {
            description =
                "Tells you when an episode is saved and ready to watch offline."
            enableVibration(true)
            enableLights(true)
            setShowBadge(true)
            lockscreenVisibility = Notification.VISIBILITY_PUBLIC
        }
        manager.createNotificationChannel(channel)
    }

    fun ensureUpdatesChannel(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager =
            context.getSystemService(NotificationManager::class.java) ?: return
        val channel = NotificationChannel(
            UPDATES_CHANNEL_ID,
            "CamAnime updates",
            NotificationManager.IMPORTANCE_HIGH
        ).apply {
            description =
                "New episodes, new anime, app updates and service notices."
            enableVibration(true)
            enableLights(true)
            setShowBadge(true)
            lockscreenVisibility = Notification.VISIBILITY_PUBLIC
        }
        manager.createNotificationChannel(channel)
    }

    fun ensureAnnouncementChannel(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager =
            context.getSystemService(NotificationManager::class.java) ?: return
        val channel = NotificationChannel(
            ANNOUNCE_CHANNEL_ID,
            "CamAnime announcements",
            NotificationManager.IMPORTANCE_HIGH
        ).apply {
            description = "News and notices published by the CamAnime team."
            enableVibration(true)
            enableLights(true)
            setShowBadge(true)
            lockscreenVisibility = Notification.VISIBILITY_PUBLIC
        }
        manager.createNotificationChannel(channel)
    }

    /**
     * Admin announcement pushed through the app feed (no Firebase needed).
     *
     * When [action] is "update" the notification carries the app logo as both the
     * small icon and the large icon, taps start the in-app update immediately, and a
     * second notification is scheduled two minutes later so the user has a short
     * window to read the message before the app begins updating.
     */
    fun announcement(
        context: Context,
        title: String,
        body: String,
        notificationKey: String,
        version: String?,
        action: String?
    ) {
        if (body.isBlank()) return
        ensureAnnouncementChannel(context)
        val manager =
            context.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
                ?: return
        val startUpdate = action == "update"
        val appIcon = android.graphics.drawable.Icon.createWithResource(
            context, com.camanime.app.R.mipmap.ic_launcher)
        val launch = context.packageManager.getLaunchIntentForPackage(context.packageName)
            ?: Intent(context, MainActivity::class.java)
        launch.apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
            putExtra("open_announcements", true)
            if (startUpdate) putExtra("start_update", true)
        }
        val pending = PendingIntent.getActivity(
            context,
            notificationKey.hashCode(),
            launch,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val notification = NotificationCompat.Builder(context, ANNOUNCE_CHANNEL_ID)
            .setSmallIcon(com.camanime.app.R.mipmap.ic_launcher)
            .setLargeIcon(appIcon)
            .setContentTitle(title.ifBlank { "CamAnime" })
            .setContentText(body)
            .setStyle(
                NotificationCompat.BigTextStyle().bigText(
                    _updateBody(title, body, version, startUpdate)))
            .setAutoCancel(true)
            .setContentIntent(pending)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setDefaults(NotificationCompat.DEFAULT_ALL)
            .setCategory(
                if (startUpdate) NotificationCompat.CATEGORY_STATUS
                else NotificationCompat.CATEGORY_MESSAGE)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .build()
        try {
            manager.notify(notificationKey.hashCode() and 0x7fffffff, notification)
        } catch (_: SecurityException) {
            // Permission revoked: the announcement is still in the app feed.
        }
        if (startUpdate && version != null) {
            UpdateAlarmWorker.schedule(context, version, notificationKey)
        }
    }

    private fun _updateBody(
        title: String,
        body: String,
        version: String?,
        startUpdate: Boolean
    ): String {
        val head = if (title.isBlank()) "CamAnime" else title
        val vline = version?.let { "CamAnime $it" } ?: "CamAnime"
        val base = if (startUpdate) {
            "$head\n$vline is ready to install.\n\n$body"
        } else {
            "$head\n\n$body"
        }
        return base.trim()
    }

    /**
     * Notification that fires two minutes after a live-update announcement, with the
     * app logo and a tap that starts the in-app update.
     */
    fun updateAlarm(
        context: Context,
        version: String,
        notificationKey: String
    ) {
        ensureAnnouncementChannel(context)
        val manager =
            context.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
                ?: return
        val launch = context.packageManager.getLaunchIntentForPackage(context.packageName)
            ?: Intent(context, MainActivity::class.java)
        launch.apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
            putExtra("start_update", true)
        }
        val pending = PendingIntent.getActivity(
            context,
            notificationKey.hashCode(),
            launch,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val appIcon = android.graphics.drawable.Icon.createWithResource(
            context, com.camanime.app.R.mipmap.ic_launcher)
        val notification = NotificationCompat.Builder(context, ANNOUNCE_CHANNEL_ID)
            .setSmallIcon(com.camanime.app.R.mipmap.ic_launcher)
            .setLargeIcon(appIcon)
            .setContentTitle("Live update going on")
            .setContentText("CamAnime $version is ready to install.")
            .setStyle(
                NotificationCompat.BigTextStyle().bigText(
                    "CamAnime $version is ready to install. " +
                        "Tap to update now and restart."))
            .setAutoCancel(true)
            .setContentIntent(pending)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setDefaults(NotificationCompat.DEFAULT_ALL)
            .setCategory(NotificationCompat.CATEGORY_STATUS)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setTicker("CamAnime $version is ready to install")
            .build()
        try {
            manager.notify(
                notificationKey.hashCode() and 0x7fffffff, notification)
        } catch (_: SecurityException) {
            // Permission revoked: the in-app update dialog still appears.
        }
    }

    /**
     * "Episode N is ready offline" — tapping it opens My Library.
     *
     * Posted the moment the episode finishes (the Dart downloader calls this as
     * soon as the file is renamed), so the banner pops with the episode rather
     * than arriving late. The remote poster is fetched in the background and the
     * notification is re-posted with the artwork when it lands; the alert itself
     * never waits on the network.
     */
    fun downloadComplete(
        context: Context,
        animeTitle: String,
        episode: Int,
        taskId: String,
        notificationsEnabled: Boolean,
        imageUrl: String?
    ) {
        if (!notificationsEnabled) return
        ensureCompleteChannel(context)

        val appContext = context.applicationContext
        val title = animeTitle.ifBlank { "CamAnime" }
        val notificationId = taskId.hashCode() and 0x7fffffff

        post(
            appContext,
            notificationId,
            title,
            episode,
            taskId,
            localFallbackPoster(title, episode)
        )

        if (imageUrl.isNullOrBlank()) return
        posterExecutor.execute {
            val remote = fetchRemotePoster(imageUrl)
            if (remote == null) return@execute
            mainHandler.post {
                post(appContext, notificationId, title, episode, taskId, remote)
            }
        }
    }

    private fun post(
        context: Context,
        notificationId: Int,
        title: String,
        episode: Int,
        taskId: String,
        poster: Bitmap
    ) {
        val manager =
            context.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
                ?: return

        val launch = context.packageManager.getLaunchIntentForPackage(context.packageName)
            ?: Intent(context, MainActivity::class.java)
        launch.apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
            putExtra("open_library", true)
        }
        val pending = PendingIntent.getActivity(
            context,
            taskId.hashCode(),
            launch,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val notification = NotificationCompat.Builder(context, COMPLETE_CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_sys_download_done)
            .setContentTitle("Episode $episode is ready offline")
            .setContentText("$title — tap to watch it from My Library.")
            .setStyle(
                NotificationCompat.BigPictureStyle()
                    .bigPicture(poster)
                    .bigLargeIcon(poster as Bitmap?)
                    .setSummaryText("$title · Episode $episode")
            )
            .setLargeIcon(poster)
            .setAutoCancel(true)
            .setContentIntent(pending)
            .setPriority(NotificationCompat.PRIORITY_MAX)
            .setDefaults(NotificationCompat.DEFAULT_ALL)
            .setCategory(NotificationCompat.CATEGORY_STATUS)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .build()

        try {
            manager.notify(notificationId, notification)
        } catch (_: SecurityException) {
            // Notification permission revoked: the episode is still saved.
        }
    }

    /**
     * Local poster card used until (or instead of) the remote artwork.
     *
     * Drawn on the device so the banner always reads as a card — title, episode
     * and brand colour — rather than a bare icon when the CDN is unreachable,
     * the artwork is behind a hotlink rule, or the download ran offline.
     */
    private fun localFallbackPoster(title: String, episode: Int): Bitmap {
        val w = 640
        val h = 360
        val card = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(card)
        canvas.drawColor(Color.parseColor("#0A0D14"))
        val wash = Paint().apply {
            shader = LinearGradient(
                0f, 0f, w.toFloat(), h.toFloat(),
                Color.parseColor("#16305A"), Color.parseColor("#0A0D14"),
                Shader.TileMode.CLAMP
            )
        }
        canvas.drawRect(0f, 0f, w.toFloat(), h.toFloat(), wash)
        canvas.drawRect(
            0f, h - 10f, w.toFloat(), h.toFloat(),
            Paint().apply { color = Color.parseColor("#087BFF") }
        )
        val titlePaint = Paint().apply {
            color = Color.WHITE
            textSize = 38f
            isAntiAlias = true
            typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
        }
        val subPaint = Paint().apply {
            color = Color.parseColor("#B7C3D9")
            textSize = 24f
            isAntiAlias = true
        }
        val label = title.trim().ifBlank { "CamAnime" }
        canvas.drawText(
            if (label.length > 24) label.substring(0, 24) else label,
            30f, h / 2f, titlePaint
        )
        canvas.drawText("Episode $episode · CamAnime", 30f, h / 2f + 46f, subPaint)
        return card
    }

    /** Placeholder kept for callers that only need a valid bitmap. */
    /**
     * "Live update going on" heads-up: the app found a newer build and is
     * downloading it. Posted once per check so the user sees the update even when
     * the download dialog is behind another app.
     */
    fun updateInProgress(
        context: Context,
        version: String,
        notificationKey: String
    ) {
        ensureAnnouncementChannel(context)
        val manager =
            context.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
                ?: return
        val launch = context.packageManager.getLaunchIntentForPackage(context.packageName)
            ?: Intent(context, MainActivity::class.java)
        launch.apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val pending = PendingIntent.getActivity(
            context,
            notificationKey.hashCode(),
            launch,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val appIcon = android.graphics.drawable.Icon.createWithResource(
            context, com.camanime.app.R.mipmap.ic_launcher)
        val notification = NotificationCompat.Builder(context, ANNOUNCE_CHANNEL_ID)
            .setSmallIcon(com.camanime.app.R.mipmap.ic_launcher)
            .setLargeIcon(appIcon)
            .setContentTitle("Live update going on")
            .setContentText("CamAnime $version is being downloaded in the background.")
            .setStyle(
                NotificationCompat.BigTextStyle()
                    .bigText(
                        "CamAnime $version is being downloaded in the background. "
                            + "Tap to open the app."))
            .setAutoCancel(true)
            .setContentIntent(pending)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setDefaults(NotificationCompat.DEFAULT_ALL)
            .setCategory(NotificationCompat.CATEGORY_STATUS)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setTicker("CamAnime $version is being downloaded")
            .build()
        try {
            manager.notify(UPDATE_NOTIFICATION_ID, notification)
        } catch (_: SecurityException) {
            // Permission revoked: the in-app update dialog still appears.
        }
    }

    /**
     * Clears the "Live update going on" heads-up notification posted by
     * [updateInProgress]. Safe to call more than once; a missing notification is
     * a no-op rather than an error.
     */
    fun dismissUpdateInProgress(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager =
            context.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
                ?: return
        try {
            manager.cancel(UPDATE_NOTIFICATION_ID)
        } catch (_: SecurityException) {
            // Permission revoked: the notice is moot anyway.
        }
    }

    private fun blankPoster(): Bitmap =
        Bitmap.createBitmap(1, 1, Bitmap.Config.ARGB_8888)

    /**
     * Downloads and downscales the poster. Runs on [posterExecutor], never on
     * the UI thread, and gives up quickly so a slow CDN cannot leak a socket.
     */
    private fun fetchRemotePoster(url: String): Bitmap? {
        var connection: HttpURLConnection? = null
        return try {
            connection = (URL(url).openConnection() as HttpURLConnection).apply {
                connectTimeout = 4000
                readTimeout = 4000
                instanceFollowRedirects = true
                setRequestProperty("User-Agent", "CamAnime/Android")
                setRequestProperty(
                    "Accept",
                    "image/avif,image/webp,image/apng,image/*,*/*;q=0.8"
                )
                setRequestProperty("Referer", "https://camanime.onrender.com/")
                setInstanceFollowRedirects(true)
                connect()
            }
            if (connection.responseCode !in 200..299) return null
            connection.inputStream.use { stream ->
                val raw = BitmapFactory.decodeStream(stream) ?: return null
                val largest = maxOf(raw.width, raw.height)
                if (largest <= POSTER_MAX_PX) {
                    raw
                } else {
                    val scale = POSTER_MAX_PX.toFloat() / largest
                    Bitmap.createScaledBitmap(
                        raw,
                        (raw.width * scale).toInt().coerceAtLeast(1),
                        (raw.height * scale).toInt().coerceAtLeast(1),
                        true
                    )
                }
            }
        } catch (_: Exception) {
            null
        } finally {
            try {
                connection?.disconnect()
            } catch (_: Exception) {
            }
        }
    }
}
