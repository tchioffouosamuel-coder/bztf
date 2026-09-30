plugins {
    kotlin("jvm") version "2.2.20"
    kotlin("plugin.serialization") version "2.2.20"
    id("io.ktor.plugin") version "3.6.0"
}

group = "com.bibliorfid"
version = "1.2.0"

// Gradle's Windows test worker corrupts non-ASCII paths in its classpath file.
layout.buildDirectory.set(file("${System.getProperty("java.io.tmpdir")}/bibliorfid-sync-api-build"))

application {
    mainClass.set("com.bibliorfid.sync.ApplicationKt")
}

kotlin {
    jvmToolchain(17)
}

dependencies {
    implementation("io.ktor:ktor-server-core")
    implementation("io.ktor:ktor-server-netty")
    implementation("io.ktor:ktor-server-content-negotiation")
    implementation("io.ktor:ktor-serialization-kotlinx-json")
    implementation("io.ktor:ktor-server-websockets")
    implementation("io.ktor:ktor-server-status-pages")
    implementation("io.ktor:ktor-server-call-logging")
    implementation("io.ktor:ktor-server-cors")
    implementation("org.xerial:sqlite-jdbc:3.51.1.0")
    implementation("ch.qos.logback:logback-classic:1.5.18")

    testImplementation(kotlin("test"))
    testImplementation("io.ktor:ktor-server-test-host")
    testImplementation("io.ktor:ktor-client-content-negotiation")
    testImplementation("io.ktor:ktor-client-websockets")
}

tasks.test {
    useJUnitPlatform()
}

ktor {
    fatJar {
        archiveFileName.set("bibliorfid-sync-api.jar")
    }
}

tasks.register<Copy>("deliver") {
    dependsOn("buildFatJar")
    from(layout.buildDirectory.file("libs/bibliorfid-sync-api.jar"))
    into(layout.projectDirectory.dir("dist"))
}
