import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
}

// Same selection order as plugins/setup/buildkit/gradle/plugin.gradle:
// ANDROID_ARCH wins, otherwise Flutter -Ptarget-platform, otherwise every
// supported ABI. x86 is not a shipped core ABI.
val coreAbiFilters = resolveCoreAbiFilters()

android {
    namespace = "com.follow.clash.core"
    compileSdk = libs.versions.compileSdk.get().toInt()
    ndkVersion = libs.versions.ndkVersion.get()

    defaultConfig {
        minSdk = libs.versions.minSdk.get().toInt()
        ndk {
            abiFilters += coreAbiFilters
        }
    }


    sourceSets {
        getByName("main") {
            jniLibs.srcDirs("src/main/jniLibs")
        }
    }

    externalNativeBuild {
        cmake {
            path("src/main/cpp/CMakeLists.txt")
            version = "3.22.1"
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildTypes {
        release {
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget.set(JvmTarget.JVM_17)
    }
}


dependencies {
    implementation(libs.annotation.jvm)
}

fun resolveCoreAbiFilters(): List<String> {
    val archToAbi = mapOf(
        "arm" to "armeabi-v7a",
        "arm64" to "arm64-v8a",
        "amd64" to "x86_64",
    )
    val platformToAbi = mapOf(
        "android-arm" to "armeabi-v7a",
        "android-arm64" to "arm64-v8a",
        "android-x64" to "x86_64",
    )
    val allAbis = listOf("armeabi-v7a", "arm64-v8a", "x86_64")

    val androidArch = System.getenv("ANDROID_ARCH")?.trim().orEmpty()
    if (androidArch.isNotEmpty()) {
        return listOf(archToAbi[androidArch] ?: error("Invalid arch: $androidArch"))
    }

    val targetPlatform = (
        findProperty("target-platform") ?: rootProject.findProperty("target-platform")
        )?.toString()?.trim().orEmpty()
    if (targetPlatform.isEmpty()) {
        return allAbis
    }

    val abis = linkedSetOf<String>()
    for (raw in targetPlatform.split(',')) {
        val name = raw.trim()
        if (name.isEmpty()) continue
        abis += platformToAbi[name] ?: error("Invalid target-platform: $name")
    }
    if (abis.isEmpty()) error("No Android target platforms provided")
    return abis.toList()
}
