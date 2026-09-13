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

// Some plugins pin an old `compileSdk`, and a newer transitive AndroidX
// dependency then refuses to build against it. Raising it only affects which
// APIs those libraries compile against — `minSdk` and `targetSdk` are
// untouched, so no device or runtime behaviour changes.
//
// This is done reflectively because the Android Gradle Plugin's types are not
// on the root build script's classpath in a Flutter project.
val minimumCompileSdk = 36

subprojects {
    afterEvaluate {
        val androidExtension = extensions.findByName("android") ?: return@afterEvaluate
        runCatching {
            val current = androidExtension.javaClass
                .getMethod("getCompileSdk")
                .invoke(androidExtension) as? Int
            if (current == null || current < minimumCompileSdk) {
                androidExtension.javaClass
                    .getMethod("setCompileSdk", Integer::class.java)
                    .invoke(androidExtension, minimumCompileSdk)
            }
        }
    }
}


tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}

subprojects {
    project.evaluationDependsOn(":app")
}
