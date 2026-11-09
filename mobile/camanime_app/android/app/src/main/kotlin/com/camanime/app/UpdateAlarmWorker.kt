package com.camanime.app

import android.content.Context
import androidx.work.ExistingWorkPolicy
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.Worker
import androidx.work.WorkerParameters
import java.util.concurrent.TimeUnit

class UpdateAlarmWorker(
    context: Context,
    params: WorkerParameters
) : Worker(context, params) {
    override fun doWork(): Result {
        val version = inputData.getString("version") ?: return Result.failure()
        val key = inputData.getString("key") ?: "camanime-update"
        Notifications.updateAlarm(applicationContext, version, key)
        return Result.success()
    }

    companion object {
        fun schedule(context: Context, version: String, key: String) {
            val request = OneTimeWorkRequestBuilder<UpdateAlarmWorker>()
                .setInitialDelay(2, TimeUnit.MINUTES)
                .addTag(key)
                .setInputData(
                    androidx.work.Data.Builder()
                        .putString("version", version)
                        .putString("key", key)
                        .build()
                )
                .build()
            WorkManager.getInstance(context).enqueueUniqueWork(
                key,
                ExistingWorkPolicy.REPLACE,
                request
            )
        }
    }
}
