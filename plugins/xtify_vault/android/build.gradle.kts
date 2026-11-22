group = "com.xmokecursed.xtify.vault"
version = "1.0.0"

plugins {
    id("com.android.library")
}

android {
    namespace = "com.xmokecursed.xtify.vault"
    compileSdk = flutter.compileSdkVersion

    defaultConfig {
        minSdk = 24
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}
