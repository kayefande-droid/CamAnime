package com.camanime.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.core.app.NotificationCompat

/**
 * Heads-up notifications that land above whatever app is on screen.
 *
 * The channel is created at IMPORTANCE_HIGH so Android shows it as a banner and
 * keeps it at the top of the shade; the notification itself uses PRIORITY_MAX
 * plus the default sound/vibration for pre-Oreo devices. A separate channel is
 * used from the quiet foreground download channel, which must stay silent.
 */
object Notifications {
    const val COMPLETE_CHANNEL_ID = "camanime_downloads_complete"

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

    /** "Episode N is ready offline" — tapping it opens My Library. */
    fun downloadComplete(
        context: Context,
        animeTitle: String,
        episode: Int,
        taskId: String
    ) {
        ensureCompleteChannel(context)
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
        val title = animeTitle.ifBlank { "CamAnime" }
        val notification = NotificationCompat.Builder(context, COMPLETE_CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_sys_download_done)
            .setContentTitle("Episode $episode is ready offline")
            .setContentText("$title — tap to watch it from My Library.")
            .setStyle(
                NotificationCompat.BigTextStyle().bigText(
                    "$title Episode $episode finished downloading. " +
                        "Tap to watch it from My Library with no internet needed."
                )
            )
            .setAutoCancel(true)
            .setContentIntent(pending)
            .setPriority(NotificationCompat.PRIORITY_MAX)
            .setDefaults(NotificationCompat.DEFAULT_ALL)
            .setCategory(NotificationCompat.CATEGORY_STATUS)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .build()
        try {
            manager.notify(taskId.hashCode() and 0x7fffffff, notification)
        } catch (_: SecurityException) {
            // Notification permission revoked: the episode is still saved.
        }
    }
}
