import java.io.ByteArrayOutputStream

val ktor_version: String by project
val logback_version: String by project

plugins {
    alias(libs.plugins.kotlin.jvm)
    alias(libs.plugins.kotlinx.serialization)
    alias(libs.plugins.ktor)
    alias(libs.plugins.shadow.jar)
}

group = "com.claire"
version = "0.1.0"

application {
    mainClass.set("com.claire.ApplicationKt")
}

dependencies {
    implementation(project(":submodules:atria-kotlin"))

    implementation(libs.kotlinx.serialization.json)
    implementation(libs.kotlinx.serialization.protobuf)

    // ktor server
    implementation("io.ktor:ktor-server-netty-jvm:$ktor_version")
    implementation("io.ktor:ktor-server-core-jvm:$ktor_version")
    implementation("io.ktor:ktor-server-auth:$ktor_version")
    implementation("io.ktor:ktor-server-websockets:$ktor_version")
    implementation("io.ktor:ktor-serialization-kotlinx-json-jvm:$ktor_version")
    implementation("io.ktor:ktor-server-content-negotiation-jvm:$ktor_version")

    // ktor client
    implementation("io.ktor:ktor-client-core:$ktor_version")
    implementation("io.ktor:ktor-client-logging:$ktor_version")
    implementation("io.ktor:ktor-client-auth:$ktor_version")
    implementation("io.ktor:ktor-client-content-negotiation:$ktor_version")
    implementation("io.ktor:ktor-client-okhttp-jvm:$ktor_version")
    implementation("io.ktor:ktor-client-websockets:$ktor_version")

    // koin
    implementation(libs.koin.core)

    // logback
    implementation("ch.qos.logback:logback-classic:$logback_version")
}

tasks.withType<com.github.jengelman.gradle.plugins.shadow.tasks.ShadowJar> {
    archiveClassifier.set("")
    manifest {
        attributes["Main-Class"] = "com.claire.ApplicationKt"
    }
}

// Git info
fun gitCommand(vararg args: String): String {
    return try {
        val stdout = ByteArrayOutputStream()
        exec {
            commandLine("git", *args)
            standardOutput = stdout
        }
        stdout.toString().trim()
    } catch (e: Exception) {
        "unknown"
    }
}

val gitCommitHash = gitCommand("rev-parse", "--short", "HEAD")
val gitBranch = gitCommand("rev-parse", "--abbrev-ref", "HEAD")

tasks.withType<Jar> {
    manifest {
        attributes(
            "Implementation-Version" to project.version,
            "Git-Commit" to gitCommitHash,
            "Git-Branch" to gitBranch
        )
    }
}
