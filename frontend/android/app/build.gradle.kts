import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
    id("com.google.gms.google-services")
}

// Load key.properties if it exists (release signing)
val keyPropertiesFile = rootProject.file("key.properties")
val keyProperties = Properties()
if (keyPropertiesFile.exists()) {
    keyProperties.load(FileInputStream(keyPropertiesFile))
}

// OPT-IN, off by default: `-PumbraUnsignedRelease=true` (CI passes
// `--android-project-arg=umbraUnsignedRelease=true`) packages the release APK with NO
// signature at all, even when key.properties exists. `.github/workflows/
// release-apk.yml` builds that file from a tag; the owner signs it offline
// (`scripts/apk/sign-ci-apk.ps1`), so the keystore never reaches CI. An unsigned
// APK cannot be installed, so it cannot be mistaken for a shippable one. The
// App Bundle keeps the keystore gate: Play gets a signed bundle from the PC.
val unsignedRelease =
    project.findProperty("umbraUnsignedRelease")?.toString() == "true"

// HARD GATE (execution-time): a release build without a real keystore must FAIL
// LOUDLY, never silently fall back to debug signing (a debug-signed "release"
// looks shippable but is not: Play rejects it and its signature can't ever be
// upgraded in place). Guarding the EXACT packaging tasks — not
// startParameter.taskNames — catches task-name-free invocations too (`gradlew
// build` / `assemble` build the release variant without naming it). Exact
// names, NOT a package*Release* prefix match: packageReleaseResources/-Assets
// are dependencies of lintRelease/testReleaseUnitTest, and gating those would
// make release unit tests demand a keystore. packageRelease = APK,
// packageReleaseBundle = AAB.
tasks.matching { it.name == "packageRelease" || it.name == "packageReleaseBundle" }
    .configureEach {
        val isApk = name == "packageRelease"
        doFirst {
            if (!keyPropertiesFile.exists() && !(unsignedRelease && isApk)) {
                throw GradleException(
                    "Release packaging requested but android/key.properties is missing. " +
                    "Create the release keystore first — see docs/runbooks/android-release.md " +
                    "(copy android/key.properties.example to android/key.properties and fill it in)."
                )
            }
        }
    }

android {
    namespace = "com.fireplace.app"
    // Pinned explicitly (= Flutter 3.44.6 defaults) so an SDK upgrade cannot
    // silently change backup semantics, Keystore behavior, or 16KB compliance.
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    lint {
        // lintVitalAnalyzeRelease runs third-party plugin modules' lint during
        // every release build and is a known Windows flake source (lint-cache
        // jar locks, e.g. :file_picker:lintVitalAnalyzeRelease FileSystemException
        // 2026-07-29). We don't gate releases on lint; the release gates are the
        // signing/16KB checks in build-android.ps1.
        checkReleaseBuilds = false
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        isCoreLibraryDesugaringEnabled = true
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    signingConfigs {
        if (keyPropertiesFile.exists()) {
            create("release") {
                keyAlias = keyProperties["keyAlias"] as String
                keyPassword = keyProperties["keyPassword"] as String
                storeFile = file(keyProperties["storeFile"] as String)
                storePassword = keyProperties["storePassword"] as String
            }
        }
    }

    defaultConfig {
        applicationId = "com.fireplace.app"
        minSdk = 24
        targetSdk = 36
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        // Patrol (integration_test runner, workflow-2.0 Batch 8.2). androidTest only:
        // no effect on debug/release app builds.
        testInstrumentationRunner = "pl.leancode.patrol.PatrolJUnitRunner"
        testInstrumentationRunnerArguments["clearPackageData"] = "true"
    }

    testOptions {
        execution = "ANDROIDX_TEST_ORCHESTRATOR"
    }

    buildTypes {
        release {
            // The execution-time gate above throws whenever a release artifact
            // is PACKAGED without a keystore. Defense in depth: with no
            // keystore the signingConfig is NULL, so even a path the task-name
            // filter missed yields an inert UNSIGNED apk (also rejected by the
            // apksigner gate in build-android.ps1) — NEVER a debug-signed one
            // that looks shippable.
            signingConfig = if (keyPropertiesFile.exists() && !unsignedRelease) {
                signingConfigs.getByName("release")
            } else {
                null
            }
        }
    }

    // Native libs are STORED uncompressed by default (AGP does this whenever
    // minSdk >= 23 so the loader can mmap straight out of the APK). For a
    // SIDELOADED apk that friends download over mobile data, that is the wrong
    // trade: the 24 `.so` entries deflate 100.29 MiB -> 44.19 MiB (44.1%),
    // taking the universal APK from 105.2 MiB to 48.9 MiB (MEASURED, 0.2.46).
    // Nothing is removed — every ABI still ships, so the file installs on any
    // friend's phone and on the x86_64 emulator.
    //
    // It also costs NOTHING on the device, because only the ONE matching ABI is
    // extracted. Measured on real hardware, same app version:
    //   phone  f849cc68 (stored):         base.apk 105.3 MiB + lib/ 7 KB  = 105.3
    //   emulator-5554 (legacy packaging): base.apk  48.9 MiB + lib/ 37.2  =  86.2
    // So the on-device footprint DROPS ~19 MiB as well. (It would only grow for
    // a SINGLE-ABI apk: 38.8 stored vs 19.7 + 33.9 extracted.)
    //
    // 16KB compliance is unaffected: the loader mmaps the EXTRACTED copy, so
    // ELF p_align >= 16384 still governs and scripts/verify-apk-16k.mjs still
    // reads it (it inflates method-8 entries — see its `entryData`). Verified
    // 16/16 green on the packed APK, which then installed and cold-started on
    // the emulator in 3.94 s with no dlopen/UnsatisfiedLink errors.
    //
    // TWO consequences, both recorded in docs/runbooks/android-release.md:
    //   - a --dart-define can no longer be byte-searched in the RAW apk;
    //     extract lib/<abi>/libapp.so first, then search it.
    //   - revisit this if we ever ship an AAB: Play does its own delivery
    //     compression and prefers uncompressed libs.
    packaging {
        jniLibs {
            useLegacyPackaging = true
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
    androidTestUtil("androidx.test:orchestrator:1.5.1")
}
