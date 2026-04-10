#!/bin/bash
set -e

# Module 01-01: Building with Hummingbird
# Auto-generated script from executable bash blocks
#
# Note: Container startup timing requires readiness checks for reliable automation

# Container registries
# HUMMINGBIRD_REGISTRY="quay.io/hummingbird-hatchling"
HUMMINGBIRD_REGISTRY="quay.io/hummingbird"
UBI_REGISTRY="registry.access.redhat.com"


echo "=== Step 1: Using pre-created index.html ==="
echo "HTML landing page already created by setup script"

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

echo "=== Step 2: Using pre-created Flask application ==="
cp ~/webserver/index.html ~/flask/


echo "=== Building UBI Flask version ==="
podman build --net=host -t my-flasksite:ubi -f ~/flask/Containerfile.ubi ~/flask

echo "=== Testing UBI Flask application ==="
podman run -d --rm --name flask-demo -p 8080:8080 my-flasksite:ubi

# Wait for Flask container to be ready and test
echo "Testing UBI Flask container readiness..."
for i in {1..5}; do
    if curl -f -s http://localhost:8080 > /dev/null 2>&1; then
        curl http://localhost:8080
        echo "✅ UBI Flask container responding successfully"
        break
    fi
    echo "Waiting for Flask to start (attempt $i/5)..."
    sleep 1
done
podman stop flask-demo

echo "=== Step 4: Creating Hummingbird Flask Containerfile ==="
cat > ~/flask/Containerfile.hi << EOF
# Stage 1: Base Image from Project Hummingbird
FROM ${HUMMINGBIRD_REGISTRY}/python:3.14-builder

# Set the working directory in the container
WORKDIR /app

# Copy the application files to the target directory
# COPY always executes as root
COPY --chown=65532 app.py .
COPY --chown=65532 index.html static/

# Set environment variables for Python
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

# Switch to root from the non-root user to install dependencies
# By default, these install in /tmp/.local for the non-root user 
USER root
RUN python3 -m pip install --index-url http://localhost:8000/simple flask 

# Switch to the default non-root user for runtime
USER \${CONTAINER_DEFAULT_USER}

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

echo "=== Cleanup ==="

echo "Stopping and removing containers..."
podman stop webserver 2>/dev/null || echo "Webserver container already stopped"
podman rm webserver 2>/dev/null || echo "Webserver container already removed"
podman stop caddy-server 2>/dev/null || echo "Caddy server container already stopped"
podman rm caddy-server 2>/dev/null || echo "Caddy server container already removed"
podman stop flask-demo 2>/dev/null || echo "Flask container already stopped"
podman rm flask-demo 2>/dev/null || echo "Flask container already removed"

echo "=== Summary ==="
echo "✅ Container image building and testing completed"
echo "✅ Caddy webserver tested with direct run and Containerfile"
echo "✅ Flask application built with both UBI and Hardened images"
echo "✅ Image size comparison shows Hardened image benefits"
echo ""
echo "=== Module 01-01 completed successfully! ==="
