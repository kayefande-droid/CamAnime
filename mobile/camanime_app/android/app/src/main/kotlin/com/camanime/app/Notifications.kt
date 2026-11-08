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
