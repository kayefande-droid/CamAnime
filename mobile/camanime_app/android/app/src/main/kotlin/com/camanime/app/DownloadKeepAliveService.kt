package com.camanime.app

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat

/**
 * Keeps the CamAnime process alive (and visible in the notification shade)
 * while episodes are downloading, so a download continues when the app is
 * backgrounded or the screen is off. All transfer state lives in the Dart
 * queue, which resumes by byte offset even if the process is killed.
 */
class DownloadKeepAliveService : Service() {

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopSelf()
            return START_NOT_STICKY
        }
        createChannel()
        val launch = packageManager.getLaunchIntentForPackage(packageName)
        val pending = PendingIntent.getActivity(
            this,
            0,
            launch,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        val notification = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("CamAnime downloads")
            .setContentText("Saving episodes for offline — resumes automatically.")
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setContentIntent(pending)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()
        startForeground(NOTIFICATION_ID, notification)
        return START_STICKY
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = getSystemService(NotificationManager::class.java)
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Episode downloads",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Shows while CamAnime saves episodes for offline viewing."
                setShowBadge(false)
            }
            manager.createNotificationChannel(channel)
        }
    }

    companion object {
        const val CHANNEL_ID = "camanime_downloads"
        const val NOTIFICATION_ID = 4102
        const val ACTION_STOP = "com.camanime.app.STOP_DOWNLOADS"
    }
}
