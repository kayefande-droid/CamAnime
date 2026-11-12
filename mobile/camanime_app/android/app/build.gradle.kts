plugins {
    id("com.android.application")
    // Firebase: generates the values FCM reads from android/app/google-services.json.
    id("com.google.gms.google-services")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.camanime.app"
    compileSdk = 36
    // No C/C++ sources or NDK-built plugins in this app. Pinning the NDK made
    // every build wait on (and fail over) a ~700 MB SDK download, so it is left
    // to AGP's default: nothing here compiles native code.
    // ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // flutter_local_notifications 22.x uses java.time and other JDK APIs
        // through AAR metadata that requires desugaring on minSdk 24.
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.camanime.app"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // Firebase Messaging requires API 23 (Android 6.0). The previous
        // flutter.minSdkVersion (21) cannot satisfy it.
        minSdk = flutter.minSdkVersion
        targetSdk = 36
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        // Keep the debug keystore (stable across builds, so sideloaded updates
        // are signature-compatible) but sign with every scheme. v1 (JAR) is
        // required for Android 6/7 devices; v2/v3 cover modern Android.
        getByName("debug") {
            enableV1Signing = true
            enableV2Signing = true
            enableV3Signing = true
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("debug")
            // WorkManager + Room are reached reflectively; without these rules R8
            // strips them and the app crashes inside androidx.startup.
            isMinifyEnabled = true
            // Drop unused resources too; minify + shrink make the release APK
            // harder to inspect and smaller to download.
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")

    // Periodic anime-advert notifications (every 30 minutes = 2 per hour).
    implementation("androidx.work:work-runtime-ktx:2.9.1")

    // Firebase platform: pins every Firebase Android artifact to one BoM so
    // Messaging, Analytics, Auth and Firestore cannot drift apart.
    implementation(platform("com.google.firebase:firebase-bom:35.1.0"))
    implementation("com.google.firebase:firebase-messaging")
    implementation("com.google.firebase:firebase-analytics")
}
