/**
 * settings.gradle.kts -- Gradle Settings for e-nable Android Renderer
 *
 * # What this file does
 *
 * Gradle's settings file defines the project structure. It runs BEFORE any
 * build.gradle.kts file, and its job is to tell Gradle:
 *   1. What the root project is called
 *   2. Which sub-projects (modules) exist
 *   3. Where to find plugins and dependencies
 *
 * # Why pluginManagement and dependencyResolutionManagement?
 *
 * These two blocks centralize repository configuration. Without them,
 * each build.gradle.kts would need its own `repositories {}` block,
 * leading to duplicated config and inconsistent dependency resolution.
 *
 * The `repositoriesMode.set(FAIL_ON_PROJECT_REPOS)` setting enforces
 * that NO module can declare its own repositories -- everything comes
 * from this central config. This prevents "works on my machine" issues
 * where different modules resolve the same dependency from different sources.
 */

pluginManagement {
    /**
     * Repositories for Gradle PLUGINS (not app dependencies).
     *
     * Gradle plugins are build tools (like the Android Gradle Plugin or
     * Kotlin compiler plugin). They come from:
     *   - gradlePluginPortal(): Gradle's official plugin registry
     *   - google(): Android Gradle Plugin lives here
     *   - mavenCentral(): Kotlin compiler plugin and other JVM plugins
     *
     * Order matters: Gradle searches repositories in order and uses
     * the first match. We put google() first because Android builds
     * use it most heavily.
     */
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    /**
     * FAIL_ON_PROJECT_REPOS: if any module's build.gradle.kts tries
     * to add its own repository, the build fails. This keeps all
     * repository config in one place (here).
     */
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)

    /**
     * Repositories for app DEPENDENCIES (libraries our code uses).
     *
     * google(): Android SDK, AndroidX, Material Design libraries
     * mavenCentral(): Kotlin stdlib, coroutines, and most open-source libraries
     */
    repositories {
        google()
        mavenCentral()
    }
}

/**
 * Root project name. This appears in Gradle's console output and
 * is used as the default artifact group if not overridden.
 */
rootProject.name = "e-nable-mirror"

/**
 * Include the :app module. Gradle looks for build.gradle.kts in
 * the `app/` subdirectory. Our project has a single module since
 * the Android side is a focused renderer app, not a multi-module
 * library project.
 */
include(":app")
