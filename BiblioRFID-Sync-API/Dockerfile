FROM eclipse-temurin:17-jre
WORKDIR /app
COPY dist/bibliorfid-sync-api.jar /app/bibliorfid-sync-api.jar
VOLUME ["/app/data"]
EXPOSE 8080
ENTRYPOINT ["java", "-jar", "/app/bibliorfid-sync-api.jar"]
