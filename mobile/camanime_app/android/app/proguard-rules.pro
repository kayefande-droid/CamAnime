# WorkManager builds its Room database by class name at process start, and both
# the generated WorkDatabase_Impl and AdvertWorker are created reflectively.
# Without these rules R8 renames/strips them and the app dies in
# androidx.startup.InitializationProvider before the first frame:
#   RuntimeException: Unable to get provider androidx.startup.InitializationProvider
#   caused by: Failed to create an instance of class ...WorkDatabase
-keep class * extends androidx.room.RoomDatabase { <init>(); }
-keep class androidx.work.impl.WorkDatabase_Impl { *; }
-keep class * extends androidx.work.ListenableWorker { <init>(...); }

# androidx.startup instantiates initializers by class *name* from manifest
# meta-data, and androidx.work's initializer only appears there as a string.
# R8 sees no code reference and strips it, so the process dies in
# InitializationProvider.onCreate before Flutter starts:
#   RuntimeException: Unable to get provider androidx.startup.InitializationProvider
#   caused by: ClassNotFoundException: androidx.work.WorkManagerInitializer
-keep class androidx.startup.** { *; }
-keep class * implements androidx.startup.Initializer { *; }
-keep class androidx.work.WorkManagerInitializer { *; }

# The worker the app schedules by class reference.
-keep class com.camanime.app.AdvertWorker { <init>(...); }

# Foreground download service is declared in the manifest.
-keep class com.camanime.app.DownloadKeepAliveService { *; }
