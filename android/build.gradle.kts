/**
 * build.gradle.kts (project-level) -- Root Build Configuration
 *
 * # What this file does
 *
 * The project-level build.gradle.kts configures settings that apply to
 * ALL modules in the project. In our case, we only have one module (:app),
 * but this separation is a Gradle convention that scales to multi-module
 * projects.
 *
 * # Why `apply false`?
 *
 * The `plugins` block here declares plugins with `apply false`, which means:
 *   "Download this plugin and make it available, but don't apply it to
 *    the root project."
 *
 * Each module then applies only the plugins it needs. This prevents the
 * Android plugin from running on the root project (which has no source code)
 * and avoids plugin version conflicts between modules.
 *
 * # Version alignment
 *
 * All plugin versions are declared here in one place. When you upgrade
 * Kotlin or AGP, you only change ONE line instead of hunting through
 * multiple build files.
 */

plugins {
    /**
     * Android Gradle Plugin (AGP) -- builds Android APKs/AABs.
     *
     * Version 8.3.2 targets:
     *   - Android API 34 (Android 14)
     *   - Gradle 8.4+
     *   - JDK 17
     *
     * The "com.android.application" variant builds an APK (runnable app).
     * The "com.android.library" variant (not used here) builds an AAR.
     */
    id("com.android.application") version "8.3.2" apply false

    /**
     * Kotlin Android plugin -- compiles .kt files for Android targets.
     *
     * This must match the Kotlin stdlib version used in app dependencies.
     * Version 1.9.23 is a stable release compatible with AGP 8.3.x.
     */
    id("org.jetbrains.kotlin.android") version "1.9.23" apply false
}
