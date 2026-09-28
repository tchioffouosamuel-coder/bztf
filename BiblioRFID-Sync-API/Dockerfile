FROM eclipse-temurin:17-jdk AS builder

WORKDIR /workspace

COPY gradlew gradlew
COPY gradle gradle
COPY settings.gradle.kts build.gradle.kts gradle.properties ./
RUN chmod +x gradlew

COPY src src
RUN ./gradlew --no-daemon test deliver

FROM eclipse-temurin:17-jre

WORKDIR /app
COPY --from=builder /workspace/dist/bibliorfid-sync-api.jar /app/bibliorfid-sync-api.jar

RUN mkdir -p /app/data

VOLUME ["/app/data"]
EXPOSE 8080
ENTRYPOINT ["java", "-jar", "/app/bibliorfid-sync-api.jar"]
