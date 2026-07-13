import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val releaseKeyFile = rootProject.file("key.properties")
val releaseKeys = Properties()
if (releaseKeyFile.exists()) {
    releaseKeyFile.inputStream().use(releaseKeys::load)
}
val releaseRequested = gradle.startParameter.taskNames.any {
    it.contains("release", ignoreCase = true)
}
val requiredReleaseKeys = listOf("storeFile", "storePassword", "keyAlias", "keyPassword")
if (releaseRequested) {
    val missing = requiredReleaseKeys.filter { releaseKeys.getProperty(it).isNullOrBlank() }
    if (!releaseKeyFile.exists() || missing.isNotEmpty()) {
        throw GradleException(
            "QuickDrop release signing is not configured. Copy android/key.properties.example " +
                "to android/key.properties and set storeFile, storePassword, keyAlias, and keyPassword."
        )
    }
    val configuredStore = rootProject.file(releaseKeys.getProperty("storeFile"))
    if (!configuredStore.isFile) {
        throw GradleException("QuickDrop release keystore was not found: $configuredStore")
    }
}

android {
    namespace = "com.karnyadavdev.quickdrop"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.karnyadavdev.quickdrop"
        minSdk = 29
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            if (releaseKeyFile.exists() && requiredReleaseKeys.all {
                    !releaseKeys.getProperty(it).isNullOrBlank()
                }) {
                storeFile = rootProject.file(releaseKeys.getProperty("storeFile"))
                storePassword = releaseKeys.getProperty("storePassword")
                keyAlias = releaseKeys.getProperty("keyAlias")
                keyPassword = releaseKeys.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("release")
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
