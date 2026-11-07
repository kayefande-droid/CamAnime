package com.camanime.app

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.work.BackoffPolicy
import androidx.work.Constraints
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.NetworkType
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.Worker
import androidx.work.WorkerParameters
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.TimeUnit
import kotlin.random.Random

/**
 * Posts one anime advert notification per run. It runs every 30 minutes via
 * WorkManager, which gives the two-per-hour cadence the feature promises.
 *
 * The advert is always a real catalogue entry fetched from the website; when
 * the fetch fails the slot is skipped rather than inventing a title.
 */
class AdvertWorker(context: Context, params: WorkerParameters) :
    Worker(context, params) {

    override fun doWork(): Result {
        val advert = fetchAnimeAdvert() ?: return Result.success()
        post(advert)
        return Result.success()
    }

    private data class Advert(val id: String, val title: String)

    private fun fetchAnimeAdvert(): Advert? {
        var connection: HttpURLConnection? = null
        return try {
            connection = URL("$API_BASE/api/v1/catalog/home")
                .openConnection() as HttpURLConnection
            connection.connectTimeout = 20000
            connection.readTimeout = 20000
            connection.setRequestProperty("User-Agent", "CamAnime-Android")
            connection.setRequestProperty("Accept", "application/json")
            if (connection.responseCode !in 200..299) return null
            val body = connection.inputStream.bufferedReader().use { it.readText() }
            val catalog = JSONObject(body).optJSONObject("catalog") ?: return null
            val pool = mutableListOf<Advert>()
            val sections = catalog.keys()
            while (sections.hasNext()) {
                val section = catalog.optJSONArray(sections.next()) ?: continue
                for (index in 0 until section.length()) {
                    val item = section.optJSONObject(index) ?: continue
                    val id = item.optString("id")
                    val title = item.optString("title")
                    if (id.isNotEmpty() && title.isNotEmpty()) {
                        pool.add(Advert(id, title))
                    }
                }
            }
            if (pool.isEmpty()) null else pool[Random.nextInt(pool.size)]
        } catch (_: Exception) {
            null
        } finally {
            connection?.disconnect()
        }
    }

    private fun post(advert: Advert) {
        val manager =
            applicationContext.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Anime adverts",
                NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = "Two anime suggestions every hour"
                enableVibration(true)
                lockscreenVisibility = android.app.Notification.VISIBILITY_PUBLIC
            }
            manager.createNotificationChannel(channel)
        }

        val intent = Intent(applicationContext, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
            putExtra("advert_anime_id", advert.id)
            putExtra("advert_anime_title", advert.title)
        }
        val pendingIntent = PendingIntent.getActivity(
            applicationContext,
            advert.id.hashCode(),
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val notification = NotificationCompat.Builder(applicationContext, CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle("Anime pick · CamAnime")
            .setContentText("${advert.title} is ready to watch — tap to open.")
            .setStyle(
                NotificationCompat.BigTextStyle().bigText(
                    "${advert.title} is ready to watch on CamAnime. " +
                        "Two suggestions per hour — turn them off any time in Settings."
                )
            )
            .setAutoCancel(true)
            .setContentIntent(pendingIntent)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setDefaults(NotificationCompat.DEFAULT_ALL)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .build()

        try {
            manager.notify(advert.id.hashCode() and 0x7fffffff, notification)
        } catch (_: SecurityException) {
            // Notification permission revoked: the next slot is skipped.
        }
    }

    companion object {
        private const val API_BASE = "https://camanime.onrender.com"
        // A new id so phones that already created the old quiet channel get
        // the heads-up behaviour instead of keeping its original importance.
        const val CHANNEL_ID = "camanime_adverts_v2"
        const val UNIQUE_WORK = "camanime-anime-adverts"
        private const val INTERVAL_MINUTES = 30L

        fun schedule(context: Context) {
            val request = PeriodicWorkRequestBuilder<AdvertWorker>(
                INTERVAL_MINUTES,
                TimeUnit.MINUTES
            )
                .setConstraints(
                    Constraints.Builder()
                        .setRequiredNetworkType(NetworkType.CONNECTED)
                        .build()
                )
                .setBackoffCriteria(
                    BackoffPolicy.LINEAR,
                    15,
                    TimeUnit.MINUTES
                )
                .build()
            WorkManager.getInstance(context).enqueueUniquePeriodicWork(
                UNIQUE_WORK,
                ExistingPeriodicWorkPolicy.KEEP,
                request
            )
        }

        fun cancel(context: Context) {
            WorkManager.getInstance(context).cancelUniqueWork(UNIQUE_WORK)
        }
    }
}
