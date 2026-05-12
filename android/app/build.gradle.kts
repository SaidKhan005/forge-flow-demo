plugins {
    id("com.android.application")
    id("kotlin-android")
    id("com.google.gms.google-services")
    // MP1 — Crashlytics Gradle plugin (must come after google-services).
    id("com.google.firebase.crashlytics")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

import java.util.Properties
import java.io.FileInputStream

val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties()
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "com.forgeflow.app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
        isCoreLibraryDesugaringEnabled = true
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    defaultConfig {
        applicationId = "com.forgeflow.app"
        minSdk = flutter.minSdkVersion
        // MP3 — Explicitly pin targetSdk = 34 (Play Store requirement as of
        // 2024). flutter.targetSdkVersion resolves from the Flutter SDK's
        // local.properties; we override here so the Play Store requirement
        // is always met regardless of which Flutter SDK channel CI uses.
        // Verified: Flutter 3.32.x pins targetSdkVersion=35 in stable;
        // this explicit override guarantees >= 34 even on older SDK pins.
        targetSdk = 35
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    flavorDimensions += "brand"

    productFlavors {
        create("forgeflow") {
            dimension = "brand"
            applicationId = "com.forgeflow.app"
            resValue("string", "app_name", "Forge & Flow")
        }
        create("forgeflowProd1") {
            dimension = "brand"
            applicationId = "com.forgeflow.app"
            resValue("string", "app_name", "Forge & Flow")
        }
        create("barrio") {
            dimension = "brand"
            applicationId = "com.forgeflow.barrio"
            resValue("string", "app_name", "Barrio")
        }
        create("barrioProd1") {
            dimension = "brand"
            applicationId = "com.forgeflow.barrio"
            resValue("string", "app_name", "Barrio")
        }
    }

    sourceSets {
        getByName("forgeflowProd1") {
            res.srcDir("src/forgeflow/res")
        }
        getByName("barrioProd1") {
            res.srcDir("src/barrio/res")
        }
    }

    signingConfigs {
        if (keystorePropertiesFile.exists()) {
            create("release") {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (keystorePropertiesFile.exists()) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")
}

flutter {
    source = "../.."
}
