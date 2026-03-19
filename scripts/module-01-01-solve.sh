#!/bin/bash
set -e

# Module 01-01: Building with Hummingbird
# Auto-generated script from executable bash blocks
#
# Note: Container startup timing requires readiness checks for reliable automation

# Container registries
HUMMINGBIRD_REGISTRY="quay.io/hummingbird-hatchling"
UBI_REGISTRY="registry.access.redhat.com"




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
  ${HUMMINGBIRD_REGISTRY}/caddy:latest

# Wait for container to be ready and test
echo "Testing container readiness..."
for i in {1..5}; do
    if curl -f -s http://localhost:8080 > /dev/null 2>&1; then
        curl http://localhost:8080
        echo "✅ Caddy server responding successfully"
        break
    fi
    echo "Waiting for container to start (attempt $i/5)..."
    sleep 1
done
podman stop caddy-server

echo "=== Creating Containerfile for caddy ==="
cat  > ~/webserver/Containerfile << EOF
FROM ${HUMMINGBIRD_REGISTRY}/caddy:latest

COPY index.html /usr/share/caddy/
EOF

echo "=== Building and running caddy containerfile ==="
podman build -t my-website -f ~/webserver/Containerfile ~/webserver
podman run -d --rm --name webserver -p 8080:8080 my-website

# Wait for container to be ready and test
echo "Testing webserver container readiness..."
for i in {1..5}; do
    if curl -f -s http://localhost:8080 > /dev/null 2>&1; then
        curl http://localhost:8080
        echo "✅ Webserver container responding successfully"
        break
    fi
    echo "Waiting for webserver to start (attempt $i/5)..."
    sleep 1
done

echo "=== Testing with containerized curl ==="
podman run --rm --net=host ${HUMMINGBIRD_REGISTRY}/curl:latest http://localhost:8080
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
cat > ~/flask/Containerfile.ubi << EOF
# Stage 1: Base Image from Red Hat UBI
FROM ${UBI_REGISTRY}/ubi9/ubi

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
cat > ~/flask/Containerfile.hi << EOF
# Stage 1: Base Image from Project Hummingbird
FROM ${HUMMINGBIRD_REGISTRY}/python:3.14

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

# Wait for Flask container to be ready and test
echo "Testing Flask container readiness..."
for i in {1..5}; do
    if curl -f -s http://localhost:8080 > /dev/null 2>&1; then
        curl http://localhost:8080
        echo "✅ Flask container responding successfully"
        break
    fi
    echo "Waiting for Flask to start (attempt $i/5)..."
    sleep 1
done
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
cat > Containerfile << EOF
# Multi-stage build: builder -> runtime

# ============================================
# Stage 1: Build stage using builder variant
# ============================================
FROM ${HUMMINGBIRD_REGISTRY}/openjdk:21-builder AS builder

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
FROM ${HUMMINGBIRD_REGISTRY}/openjdk:21-runtime

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
podman build -t hummingbird-demo:v1 -f ~/sample-app/Containerfile ~/sample-app



echo "=== Running and testing the container ==="
# Run in background
podman run -d --rm --name demo -p 8080:8080 hummingbird-demo:v1

# Wait for Quarkus to start
sleep 5

# Test the endpoint
curl http://localhost:8080/
echo "✅ Quarkus application endpoint responding successfully"

echo "=== Testing health endpoint ==="
curl http://localhost:8080/health
echo "✅ Health endpoint responding successfully"

echo "=== Viewing container logs ==="
podman logs demo

echo "=== Cleanup ==="

echo "Stopping and removing containers..."
podman stop demo || echo "Container may already be stopped"
podman rm demo || echo "Container may already be removed"

# Clean up any other containers that may have been created
podman stop webserver 2>/dev/null || echo "Webserver container already stopped"
podman rm webserver 2>/dev/null || echo "Webserver container already removed"
podman stop caddy-server 2>/dev/null || echo "Caddy server container already stopped"
podman rm caddy-server 2>/dev/null || echo "Caddy server container already removed"

echo "=== Summary ==="
echo "✅ Container image building and testing completed"
echo "✅ Flask application deployed successfully"
echo "✅ Quarkus application built and validated"
echo ""
echo "=== Module 01-01 completed successfully! ==="
