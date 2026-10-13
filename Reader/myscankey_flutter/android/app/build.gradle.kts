plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val ilmsStandalone = providers.gradleProperty("ILMS_STANDALONE").orNull == "true"
val targetName = providers.gradleProperty("target").orNull?.replace('\\', '/')?.substringAfterLast('/')
// Flutter device tests wrap the target in a generated listener.dart.
val ilmsRecipe = providers.gradleProperty("ILMS_RECIPE").orNull == "true"
require(targetName != "listener.dart" || ilmsRecipe) {
    "Flutter device-test wrappers require explicit ILMS_RECIPE=true."
}
val ilmsTarget = targetName == "main_ilms.dart" ||
    (ilmsRecipe && (targetName == "ilms_device_test.dart" || targetName == "listener.dart"))
require(ilmsStandalone == ilmsTarget) {
    "ILMS targets require ORG_GRADLE_PROJECT_ILMS_STANDALONE=true; legacy targets must not use it."
}

android {
    namespace = "com.bibliorfid.myscankey_flutter"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = if (ilmsStandalone) "com.bibliorfid.myscankey_flutter.ilms" else "com.bibliorfid.myscankey_flutter"
        manifestPlaceholders["applicationLabel"] = if (ilmsStandalone) "BIBLIORFID ILMS" else "Bibliothèque ZTF"
        manifestPlaceholders["applicationActivity"] = if (ilmsStandalone) ".IlmsActivity" else ".MainActivity"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        minSdk = 24
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        ndk {
            abiFilters += listOf("arm64-v8a", "armeabi-v7a")
        }
    }

    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.22.1"
        }
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
            proguardFiles("proguard-rules.pro")
        }
    }
}

dependencies {
    implementation(files("libs/N01_1.3.1.6.jar"))
    implementation(files("libs/reader.jar"))
    compileOnly(files("libs/uhf.jar"))
    compileOnly(files("libs/scankey.jar"))
    implementation("com.google.code.gson:gson:2.8.7")
    testImplementation("junit:junit:4.13.2")
}

flutter {
    source = "../.."
}
