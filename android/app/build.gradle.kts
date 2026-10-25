import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val releaseRequested = gradle.startParameter.taskNames.any { it.contains("release", ignoreCase = true) }
val forceSkia = providers.gradleProperty("siteLensForceSkia").orNull == "true"
val signerPath = System.getenv("SITE_LENS_SIGNING_PROPERTIES")
    ?.takeIf { it.isNotBlank() }
    ?: "${System.getProperty("user.home")}/.config/site-lens/signing.properties"
val signerFile = file(signerPath)
val signer = Properties().apply { if (signerFile.isFile) signerFile.inputStream().use { load(it) } }
val localSdkProperties = Properties().apply {
    rootProject.file("local.properties").inputStream().use { load(it) }
}
val flutterVersionFile = file("${localSdkProperties.getProperty("flutter.sdk")}/bin/cache/flutter.version.json")
val builtFlutterVersion = if (flutterVersionFile.isFile) {
    Regex("\"frameworkVersion\"\\s*:\\s*\"([A-Za-z0-9.+-]+)\"")
        .find(flutterVersionFile.readText())?.groupValues?.get(1) ?: "unknown"
} else "unknown"
check(!releaseRequested || signerFile.isFile) {
    "Formal signer missing. Configure SITE_LENS_SIGNING_PROPERTIES outside the repository."
}
val repoRoot = rootProject.projectDir.parentFile.canonicalFile
check(!releaseRequested || !signerFile.canonicalFile.toPath().startsWith(repoRoot.toPath())) {
    "Formal signer must be stored outside the repository."
}

android {
    namespace = "dev.vikiea.site_lens"
    compileSdk = 36
    ndkVersion = "28.2.13676358"

    buildFeatures {
        buildConfig = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        manifestPlaceholders["appLabel"] = "择站 · Site Lens"
        manifestPlaceholders["flutterVersion"] = builtFlutterVersion
        applicationId = "dev.vikiea.site_lens"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 26
        targetSdk = 36
        // Keep Impeller enabled by default so Flutter-owned glass can use the
        // full premium shader path. A bounded compatibility build remains
        // available for device diagnosis without making WebView limitations a
        // global renderer downgrade.
        buildConfigField("boolean", "SITE_LENS_FORCE_SKIA", forceSkia.toString())
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.22.1"
        }
    }

    signingConfigs {
        create("formal") {
            if (signerFile.isFile) {
                storeFile = file(signer.getProperty("storeFile"))
                storePassword = signer.getProperty("storePassword")
                keyAlias = signer.getProperty("keyAlias")
                keyPassword = signer.getProperty("keyPassword")
            }
        }
    }
    buildTypes {
        configureEach {
            if (name == "profile") {
                applicationIdSuffix = ".debug"
                manifestPlaceholders["appLabel"] = "择站 · 分析"
            }
        }
        debug {
            applicationIdSuffix = ".debug"
            manifestPlaceholders["appLabel"] = "择站 · 调试"
        }
        release {
            manifestPlaceholders["appLabel"] = "择站 · Site Lens"
            signingConfig = signingConfigs.getByName("formal")
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
    implementation("androidx.core:core-ktx:1.18.0")
    implementation("androidx.work:work-runtime:2.12.0")
    testImplementation("junit:junit:4.13.2")
    implementation("androidx.webkit:webkit:1.17.1")
    implementation("androidx.swiperefreshlayout:swiperefreshlayout:1.2.0")
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    implementation("com.squareup.okhttp3:okhttp-dnsoverhttps:4.12.0")
    // MediaPlayer cannot reliably decode HLS playlists emitted by modern
    // WebView pages. Media3 supplies a maintained HLS renderer and buffering
    // stack for the native texture player.
    implementation("androidx.media3:media3-exoplayer:1.11.1")
    implementation("androidx.media3:media3-exoplayer-hls:1.11.1")
    implementation("androidx.media3:media3-session:1.11.1")
    implementation("androidx.media3:media3-muxer:1.11.1")
    implementation("androidx.media3:media3-inspector:1.11.1")
    implementation("androidx.media3:media3-inspector-frame:1.11.1")
    implementation("androidx.media3:media3-transformer:1.11.1")
}

// Formal release builds must never silently fall back to a debug certificate.
tasks.configureEach {
    if (name == "validateSigningRelease") doFirst {
        check(signerFile.isFile && listOf("storeFile", "storePassword", "keyAlias", "keyPassword")
            .all { !signer.getProperty(it).isNullOrBlank() }) {
            "Formal signer missing. Configure SITE_LENS_SIGNING_PROPERTIES outside the repository."
        }
    }
}
