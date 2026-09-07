import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
    // Lot 4 : lit android/app/google-services.json (fichier à fournir par
    // Victor, absent de ce dépôt — voir ACTIVATION-FCM.md §4).
    id("com.google.gms.google-services")
}

val backgroundGeolocation = project(":flutter_background_geolocation")
apply { from("${backgroundGeolocation.projectDir}/background_geolocation.gradle") }

val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("../../environment/key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "cm.wetrackam.driver"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
        // Lot 4/8 : requis par flutter_local_notifications (message
        // d'erreur explicite) et par plusieurs dépendances AndroidX
        // modernes utilisées par flutter_webrtc — sans ceci, l'AAR de ces
        // paquets échoue dès la vérification des métadonnées, avant même
        // la compilation du code.
        isCoreLibraryDesugaringEnabled = true
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    defaultConfig {
        applicationId = "cm.wetrackam.driver"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (keystorePropertiesFile.exists()) {
            create("release") {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = keystoreProperties["storeFile"]?.let { file(it) }
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }
    buildTypes {
        release {
            if (!keystorePropertiesFile.exists()) {
                throw GradleException(
                    "Signature Android absente : fournir environment/key.properties et le keystore officiel"
                )
            }
            signingConfig = signingConfigs.getByName("release")
            isShrinkResources = false
        }
    }

    lint {
        disable.add("NullSafeMutableLiveData")
    }
}

dependencies {
    implementation("org.slf4j:slf4j-api:2.0.17")
    implementation("com.github.tony19:logback-android:3.0.0")
    // Requis pour que isCoreLibraryDesugaringEnabled ci-dessus fonctionne
    // réellement — l'activer seul ne suffit pas, cette bibliothèque fournit
    // le nécessaire au compilateur pour désucrer les API Java 8+ utilisées
    // par flutter_local_notifications/flutter_webrtc sur des minSdk anciens.
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}

flutter {
    source = "../.."
}

// Un APK de production sans le fichier Firebase officiel compile parfois
// mais ne reçoit aucun appel/message en arrière-plan. On échoue donc avant
// la compilation plutôt que de livrer une fonctionnalité fantôme.
val verifyProductionFirebase by tasks.registering {
    doLast {
        val config = file("google-services.json")
        if (!config.exists()) {
            throw GradleException(
                "FCM non configuré : fournir android/app/google-services.json officiel"
            )
        }
        val content = config.readText()
        if (content.contains("DUMMY", ignoreCase = true) ||
            content.contains("placeholder", ignoreCase = true) ||
            !content.contains("\"package_name\": \"cm.wetrackam.driver\"")) {
            throw GradleException(
                "google-services.json invalide ou destiné à une autre application"
            )
        }
    }
}

tasks.matching { it.name == "preReleaseBuild" || it.name == "preProfileBuild" }
    .configureEach { dependsOn(verifyProductionFirebase) }
