buildscript {
    repositories {
        google()
        mavenCentral()
    }
    dependencies {
        // MP1 — Firebase Crashlytics Gradle plugin.
        // google-services is already applied via the Flutter Firebase plugin;
        // we declare Crashlytics here so the app-level build.gradle.kts can
        // apply it with id("com.google.firebase.crashlytics").
        classpath("com.google.firebase:firebase-crashlytics-gradle:3.0.4")
    }
}

allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
