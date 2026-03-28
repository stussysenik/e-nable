/**
 * build.gradle.kts (app module) -- Android App Build Configuration
 *
 * # What this file does
 *
 * Configures how the :app module compiles, packages, and runs on Android.
 * Key responsibilities:
 *   1. Set Android SDK versions (min, target, compile)
 *   2. Configure Kotlin compiler options
 *   3. Declare library dependencies
 *   4. Set up JNI for the Zig native library
 *
 * # Boox SDK Strategy
 *
 * The Boox SDK (EpdController, etc.) is accessed via REFLECTION, not as a
 * compile-time dependency. This means:
 *   - The app compiles and runs on ANY Android device (graceful fallback)
 *   - No proprietary SDK JAR needs to be checked into version control
 *   - On Boox devices, reflection finds EpdController and uses fast DW/GU refresh
 *   - On non-Boox devices, the app falls back to standard View.invalidate()
 *
 * This is the same pattern used by apps like KOReader that support multiple
 * e-ink vendors without hard dependencies on any vendor SDK.
 *
 * # Zig Native Library
 *
 * The Zig core library (libenable_core.so) is cross-compiled by zig-core/
 * and placed in app/src/main/jniLibs/arm64-v8a/. The Gradle build does NOT
 * compile native code itself -- that's handled by the top-level Makefile.
 */

plugins {
    /**
     * Apply the Android Application plugin. This was declared (but not applied)
     * in the root build.gradle.kts. Now we actually apply it to this module.
     */
    id("com.android.application")

    /**
     * Apply the Kotlin Android plugin for .kt compilation.
     */
    id("org.jetbrains.kotlin.android")
}

android {
    /**
     * Namespace replaces the package attribute in AndroidManifest.xml
     * (deprecated since AGP 7.3). It determines the R class package
     * and is used for resource resolution.
     */
    namespace = "com.enable.mirror"

    /**
     * compileSdk: The Android SDK version used to COMPILE the app.
     * This determines which Android APIs are visible to the compiler.
     * SDK 34 = Android 14, the latest stable as of this project.
     *
     * Important: compileSdk does NOT affect which devices can run the app.
     * That's controlled by minSdk below.
     */
    compileSdk = 34

    defaultConfig {
        /**
         * applicationId: The unique identifier for this app on a device
         * and on the Google Play Store. By convention, it's the reversed
         * domain name + app name. Once published, this CANNOT change.
         */
        applicationId = "com.enable.mirror"

        /**
         * minSdk: The OLDEST Android version that can run this app.
         * SDK 28 = Android 9 (Pie), which covers all Boox devices since
         * the Note Pro (2019). Going lower would exclude modern Kotlin
         * coroutines features and AndroidX APIs we depend on.
         */
        minSdk = 28

        /**
         * targetSdk: The Android version the app was TESTED against.
         * Setting this to 34 opts into Android 14 behavior changes.
         * Google Play requires targetSdk >= 33 for new apps.
         */
        targetSdk = 34

        /**
         * Version tracking. versionCode is an integer that must increase
         * with each release (used by Google Play and package manager).
         * versionName is the human-readable version string.
         */
        versionCode = 1
        versionName = "0.1.0"
    }

    buildTypes {
        /**
         * Release build type: optimized, minified, not debuggable.
         * ProGuard/R8 is disabled for now -- our app is small and
         * we use reflection for Boox SDK (which R8 would strip).
         */
        release {
            isMinifyEnabled = false
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }

    /**
     * Kotlin/Java compatibility. Both must target the same JVM version
     * to avoid bytecode incompatibilities. JVM 17 is the standard for
     * modern Android development with AGP 8.x.
     */
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    /**
     * JNI library path. Gradle automatically packages any .so files
     * found in jniLibs/{abi}/ into the APK. The Zig cross-compiler
     * outputs libenable_core.so to this path.
     *
     * We only target arm64-v8a because ALL Boox devices since 2019
     * use 64-bit ARM SoCs (Qualcomm Snapdragon or RockChip RK3566).
     * No need to waste APK size on x86 or 32-bit ARM.
     */
    sourceSets {
        getByName("main") {
            jniLibs.srcDirs("src/main/jniLibs")
        }
    }
}

dependencies {
    // ── AndroidX Core ────────────────────────────────────────────
    //
    // core-ktx: Kotlin extensions for Android framework APIs.
    // Provides concise, idiomatic Kotlin wrappers for things like
    // SharedPreferences, Bundle, Canvas, etc.
    implementation("androidx.core:core-ktx:1.12.0")

    // appcompat: Backward-compatible implementations of Android UI
    // components. Even on Android 9+ devices, this provides
    // consistent Material Design behavior and bug fixes.
    implementation("androidx.appcompat:appcompat:1.6.1")

    // ── Kotlin Coroutines ────────────────────────────────────────
    //
    // Coroutines are Kotlin's approach to asynchronous programming.
    // Unlike Java threads, coroutines are:
    //   - Lightweight: millions can run concurrently (they're not OS threads)
    //   - Structured: parent coroutines wait for children to complete
    //   - Cancellable: cancellation propagates through the coroutine tree
    //
    // We use coroutines for:
    //   - TCP socket I/O (non-blocking reads/writes)
    //   - Frame processing pipeline (producer-consumer with channels)
    //   - Input event batching (debounce with delay)
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.7.3")

    // ── Testing ──────────────────────────────────────────────────
    testImplementation("junit:junit:4.13.2")
    androidTestImplementation("androidx.test.ext:junit:1.1.5")
}
