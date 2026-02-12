# ==========================================
# STAGE 1: BUILD (Maven)
# ==========================================
FROM maven:3.9.6-eclipse-temurin-17 AS build
WORKDIR /app

# Copy dependency definition first (Caching layer)
COPY pom.xml .
# Download dependencies (this layer will be cached if pom.xml doesn't change)
RUN mvn dependency:go-offline -B

# Copy source code and build
COPY src ./src
RUN mvn clean package -DskipTests

# ==========================================
# STAGE 2: RUNTIME (JRE)
# ==========================================
FROM eclipse-temurin:17-jre-jammy
WORKDIR /app

# Copy only the compiled JAR from the build stage
COPY --from=build /app/target/*.jar app.jar

# Expose the port we configured in application.properties
EXPOSE 8082

# Run the application
ENTRYPOINT ["java", "-jar", "app.jar"]