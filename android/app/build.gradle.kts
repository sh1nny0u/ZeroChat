plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.zerochat.zerochat"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion
    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = JavaVersion.VERSION_17.toString() }
    defaultConfig {
        applicationId = "com.zerochat.zerochat"
        manifestPlaceholders["appLabel"] = "ZeroChat"
        manifestPlaceholders["allowLanHttp"] = if (System.getenv("ZEROCHAT_ALLOW_LAN_HTTP") == "1") "true" else "false"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        multiDexEnabled = true
    }
    val store = System.getenv("ZEROCHAT_KEYSTORE")
    if (!store.isNullOrBlank()) {
        signingConfigs.create("production") {
            storeFile = file(store)
            storePassword = System.getenv("ZEROCHAT_STORE_PASSWORD")
            keyAlias = System.getenv("ZEROCHAT_KEY_ALIAS")
            keyPassword = System.getenv("ZEROCHAT_KEY_PASSWORD")
        }
    }
    if (gradle.startParameter.taskNames.any { it.contains("Release", ignoreCase = true) } &&
        (store.isNullOrBlank() || listOf("ZEROCHAT_STORE_PASSWORD", "ZEROCHAT_KEY_ALIAS", "ZEROCHAT_KEY_PASSWORD").any { System.getenv(it).isNullOrBlank() })) {
        throw GradleException("正式构建必须配置独立发布密钥及签名环境变量")
    }
    buildTypes { release { signingConfig = signingConfigs.findByName("production") } }
}
flutter { source = "../.." }
dependencies { coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.0.4") }
