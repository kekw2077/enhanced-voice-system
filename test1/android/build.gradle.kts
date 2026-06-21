allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.buildDir = file("../build")
subprojects {
    project.buildDir = file("${rootProject.buildDir}/${project.name}")
}
subprojects {
    project.evaluationDependsOn(":app")
}

// file_picker 11.0.2 skips self-applying the Kotlin Android plugin on AGP 9+,
// assuming AGP's built-in Kotlin support will compile its Kotlin sources.
// We keep android.builtInKotlin=false (other plugins like
// flutter_plugin_android_lifecycle still self-apply the old way and conflict
// with built-in Kotlin), so apply the plugin for file_picker explicitly here.
subprojects {
    if (project.name == "file_picker") {
        apply(plugin = "org.jetbrains.kotlin.android")
    }
}