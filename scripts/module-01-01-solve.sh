#!/bin/bash
set -e

# Module 01-01: Building with Hummingbird
# Auto-generated script from executable bash blocks

# Retry curl with exponential backoff to handle container startup time
retry_curl() {
    local url="$1"
    local max_attempts=10
    local attempt=1
    local wait_time=1

    while [ $attempt -le $max_attempts ]; do
        echo "Attempting to connect (attempt $attempt/$max_attempts)..."
        if curl -f -s --max-time 5 "$url" > /dev/null 2>&1; then
            curl "$url"
            return 0
        fi

        if [ $attempt -lt $max_attempts ]; then
            echo "Connection failed, waiting ${wait_time}s before retry..."
            sleep $wait_time
            wait_time=$((wait_time * 2))
            if [ $wait_time -gt 8 ]; then
                wait_time=8
            fi
        fi
        attempt=$((attempt + 1))
    done

    echo "Failed to connect after $max_attempts attempts"
    return 1
}

echo "=== Step 1: Create a simple index.html ==="
mkdir -p ~/webserver
cat  > ~/webserver/index.html << 'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Project Hummingbird</title>
    <!-- Load Tailwind CSS from CDN for instant styling -->
    <script src="https://cdn.tailwindcss.com"></script>
    <link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;700;800&display=swap" rel="stylesheet">
    <style>
        body {
            font-family: 'Inter', sans-serif;
        }
    </style>
</head>
<body class="bg-gray-50 flex items-center justify-center min-h-screen p-4">
    <div class="text-center">
        <h1 class="text-6xl md:text-8xl font-extrabold text-indigo-700
                   hover:scale-105 transition duration-300 ease-in-out">
            Welcome to Red Hat Hardened Images
        </h1>
        <p class="mt-4 text-xl text-gray-500">
            Your simple Caddy server is running!
        </p>
        <p class="mt-5 text-xl text-gray-400">
	    ....everybody loves hummingbirds
        </p>
    </div>
</body>

EOF

echo "=== Running caddy server and testing ==="
podman run -d --rm --name caddy-server \
  -p 8080:8080 \
  -v ~/webserver:/usr/share/caddy:ro,Z \
  quay.io/hummingbird-hatchling/caddy:latest
retry_curl http://localhost:8080
podman stop caddy-server

echo "=== Creating Containerfile for caddy ==="
cat  > ~/webserver/Containerfile << 'EOF'
FROM quay.io/hummingbird-hatchling/caddy:latest

COPY index.html /usr/share/caddy/
EOF

echo "=== Building and running caddy containerfile ==="
podman build -t my-website -f ~/webserver/Containerfile ~/webserver
podman run -d --rm --name webserver -p 8080:8080 my-website
retry_curl http://localhost:8080

echo "=== Testing with containerized curl ==="
podman run --rm --net=host quay.io/hummingbird-hatchling/curl:latest http://localhost:8080
podman stop webserver

echo "=== Step 2: Creating Flask application ==="
mkdir -p ~/flask
cat  > ~/flask/app.py << 'EOF'
from flask import Flask

app = Flask(__name__)

@app.route("/")
def home():
    return """
    <!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Project Hummingbird</title>
    <!-- Load Tailwind CSS from CDN for instant styling -->
    <script src="https://cdn.tailwindcss.com"></script>
    <link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;700;800&display=swap" rel="stylesheet">
    <style>
        body {
            font-family: 'Inter', sans-serif;
        }
    </style>
</head>
<body class="bg-gray-50 flex items-center justify-center min-h-screen p-4">
    <div class="text-center">
        <h1 class="text-6xl md:text-8xl font-extrabold text-indigo-700
                   hover:scale-105 transition duration-300 ease-in-out">
            Welcome to Project Hummingbird
        </h1>
        <p class="mt-4 text-xl text-gray-500">
            Your simple Flask application is running!
        </p>
        <p class="mt-5 text-xl text-gray-400">
	    ....everybody loves hummingbirds
        </p>
    </div>
</body>
</html>
    """

if __name__ == "__main__":
    # Listen on all interfaces (0.0.0.0) on port 8080
    app.run(host="0.0.0.0", port=8080)
EOF

echo "=== Step 3: Creating UBI Flask Containerfile for comparison ==="
cat > ~/flask/Containerfile.ubi << 'EOF'
# Stage 1: Base Image from Red Hat UBI
FROM registry.access.redhat.com/ubi9/ubi

# Install pip to manage application dependencies
RUN dnf -y install python3-pip && dnf clean all

# Create a non-root user and group for the application
# Using a different UID/GID to avoid conflict with existing users in the base image.
RUN groupadd -r -g 1005 appgroup && \
    useradd -r -u 1005 -g 1005 -d /app -s /sbin/nologin -c "Application User" appuser

# Set the working directory in the container
WORKDIR /app

# Ensure ownership is set to the new non-root user
# COPY always executes as root
COPY --chown=appuser:appgroup app.py .

# Set environment variables for Python
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

# Install application dependencies
USER root
RUN python3 -m pip install --extra-index-url http://localhost:8000 flask 

# Switch to the non-root user for runtime 
USER appuser

# Expose the port Flask will listen on
EXPOSE 8080

# Appropriately set the stop signal for the python interpreter executed as PID 1
STOPSIGNAL SIGINT
ENTRYPOINT ["python3", "./app.py"]

EOF

echo "=== Building UBI Flask version ==="
podman build --net=host -t my-flasksite:ubi -f ~/flask/Containerfile.ubi ~/flask

echo "=== Step 4: Creating Hummingbird Flask Containerfile ==="
cat > ~/flask/Containerfile.hi << 'EOF'
# Stage 1: Base Image from Project Hummingbird
FROM quay.io/hummingbird-hatchling/python:3.14

# Set the working directory in the container
WORKDIR /app

# Copy the application files to the target directory
# COPY always executes as root
COPY --chown=65532 app.py .

# Set environment variables for Python
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

# Switch to root from the non-root user to install dependencies
# By default, these install in /tmp/.local for the non-root user 
USER root
RUN python3 -m pip install --index-url http://localhost:8000/simple flask 

# Switch to the default non-root user for runtime 
USER ${CONTAINER_DEFAULT_USER}

# Expose the port Flask will listen on
EXPOSE 8080

# Appropriately set the stop signal for the python interpreter executed as PID 1
STOPSIGNAL SIGINT
ENTRYPOINT ["python", "./app.py"]

EOF

echo "=== Building and testing Hummingbird Flask application ==="
podman build --net=host -t my-flasksite:hi -f ~/flask/Containerfile.hi ~/flask
podman run -d --rm --name flask-demo -p 8080:8080 my-flasksite:hi
retry_curl http://localhost:8080
podman stop flask-demo

echo "=== Comparing Flask image sizes ==="
podman images my-flasksite

echo "=== Step 5: Scaffolding Quarkus project ==="
quarkus create app com.example:sample-app \
    --extension='rest,rest-jackson' \
    --no-code
cd sample-app

echo "=== Updating .dockerignore ==="
cat > .dockerignore << 'EOF'
target/
.git/
.gitignore
README.md
*.cmd
EOF

echo "=== Fixing file permissions ==="
chmod -R a+rX .mvn/ src/
chmod a+r pom.xml
chmod a+x mvnw

echo "=== Creating GreetingResource.java ==="
mkdir -p src/main/java/com/example
cat > src/main/java/com/example/GreetingResource.java << 'EOF'
package com.example;

import jakarta.ws.rs.GET;
import jakarta.ws.rs.Path;
import jakarta.ws.rs.Produces;
import jakarta.ws.rs.core.MediaType;
import java.time.Instant;
import java.util.LinkedHashMap;
import java.util.Map;

@Path("/")
public class GreetingResource {

    @GET
    @Produces(MediaType.APPLICATION_JSON)
    public Map<String, String> hello() {
        Map<String, String> response = new LinkedHashMap<>();
        response.put("message", "Hello from Hummingbird!");
        response.put("runtime", "Java " + System.getProperty("java.version"));
        response.put("platform", System.getProperty("os.name").toLowerCase());
        response.put("timestamp", Instant.now().toString());
        return response;
    }

    @GET
    @Path("/health")
    @Produces(MediaType.APPLICATION_JSON)
    public Map<String, String> health() {
        Map<String, String> response = new LinkedHashMap<>();
        response.put("status", "healthy");
        return response;
    }
}
EOF

echo "=== Configuring application.properties ==="
cat > src/main/resources/application.properties << 'EOF'
quarkus.http.host=0.0.0.0
quarkus.http.port=8080
EOF

echo "=== Creating multi-stage Containerfile ==="
cat > Containerfile << 'EOF'
# Multi-stage build: builder -> runtime

# Build arguments for registry flexibility
ARG BUILDER_REGISTRY=quay.io/hummingbird-hatchling
ARG RUNTIME_REGISTRY=quay.io/hummingbird-hatchling

# ============================================
# Stage 1: Build stage using builder variant
# ============================================
FROM ${BUILDER_REGISTRY}/openjdk:21-builder AS builder

# Install unzip needed by the Maven wrapper to extract the Maven distribution
USER root
RUN dnf install -y unzip && dnf clean all

WORKDIR /build

# Copy Maven wrapper and dependency manifest first (layer cache)
COPY mvnw pom.xml ./
COPY .mvn ./.mvn

# Download dependencies (cached unless pom.xml changes)
RUN ./mvnw dependency:go-offline -B

# Copy source and build
COPY src ./src
RUN ./mvnw package -DskipTests -B

# ============================================
# Stage 2: Runtime stage using Hummingbird
# ============================================
FROM ${RUNTIME_REGISTRY}/openjdk:21-runtime

WORKDIR /app

# Copy the Quarkus fast-jar layout
COPY --from=builder --chown=65532:65532 /build/target/quarkus-app/lib/ ./lib/
COPY --from=builder --chown=65532:65532 /build/target/quarkus-app/*.jar ./
COPY --from=builder --chown=65532:65532 /build/target/quarkus-app/app/ ./app/
COPY --from=builder --chown=65532:65532 /build/target/quarkus-app/quarkus/ ./quarkus/

# Run as non-root user
USER 65532

# Expose port
EXPOSE 8080

# JVM configuration
ENV JAVA_OPTS_APPEND="-Dquarkus.http.host=0.0.0.0"

# Start application
ENTRYPOINT ["java", "-jar", "quarkus-run.jar"]
EOF

echo "=== Building with Podman ==="
cd ~/sample-app
podman build -t hummingbird-demo:v1 .

echo "=== Building UBI version ==="
cd ~/sample-app

# Create a UBI-only Containerfile (single-stage, no Hummingbird)
cat > Containerfile.ubi << 'EOF'
FROM registry.access.redhat.com/ubi9/openjdk-21:latest
USER root
RUN microdnf install -y unzip && microdnf clean all
WORKDIR /build
COPY mvnw pom.xml ./
COPY .mvn ./.mvn
RUN ./mvnw dependency:go-offline -B
COPY src ./src
RUN ./mvnw package -DskipTests -B
WORKDIR /app
RUN cp -r /build/target/quarkus-app/* /app/
EXPOSE 8080
USER 1001
ENTRYPOINT ["java", "-jar", "quarkus-run.jar"]
EOF

# Build UBI-only version
podman build -f Containerfile.ubi -t demo-ubi:v1 .

echo "=== Verifying image sizes ==="
podman images hummingbird-demo
podman images demo-ubi

echo "=== Running and testing the container ==="
# Run in background
podman run -d --rm --name demo -p 8080:8080 hummingbird-demo:v1

# Test the endpoint (retry_curl will wait for service to be ready)
retry_curl http://localhost:8080/

echo "=== Testing health endpoint ==="
curl http://localhost:8080/health

echo "=== Viewing container logs ==="
podman logs demo

echo "=== Stopping and removing container ==="
podman stop demo

echo "=== All steps completed successfully! ==="
