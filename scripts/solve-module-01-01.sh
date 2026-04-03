#!/bin/bash
set -e

# Module 01-01: Introduction & Basic Images
# Solve script - completes module steps on behalf of user
#
# Creates: my-website, my-flasksite:ubi, my-flasksite:hi, hummingbird-demo:v1

# Container registries
HUMMINGBIRD_REGISTRY="quay.io/hummingbird"
UBI_REGISTRY="registry.access.redhat.com"

echo "=== Module 01-01 Solve Script ==="

# Check for setup files
if [ ! -f ~/webserver/index.html ]; then
    echo "ERROR: Missing required file ~/webserver/index.html"
    echo "This should have been created by setup-rhel.sh"
    echo "Please contact your instructor for assistance"
    exit 1
fi

if [ ! -d ~/flask ]; then
    echo "ERROR: Missing required directory ~/flask/"
    echo "This should have been created by setup-rhel.sh"
    echo "Please contact your instructor for assistance"
    exit 1
fi

if [ ! -d ~/sample-app ]; then
    echo "ERROR: Missing required directory ~/sample-app/"
    echo "This should have been created by setup-rhel.sh"
    echo "Please contact your instructor for assistance"
    exit 1
fi

# Cleanup function
cleanup() {
    podman stop caddy-server 2>/dev/null || true
    podman rm caddy-server 2>/dev/null || true
    podman stop webserver 2>/dev/null || true
    podman rm webserver 2>/dev/null || true
    podman stop flask-demo 2>/dev/null || true
    podman rm flask-demo 2>/dev/null || true
    podman stop demo 2>/dev/null || true
    podman rm demo 2>/dev/null || true
}
trap cleanup EXIT

echo "=== Running caddy server ==="
podman run -d --rm --name caddy-server \
  -p 8080:8080 \
  -v ~/webserver:/usr/share/caddy:ro,Z \
  ${HUMMINGBIRD_REGISTRY}/caddy:latest

sleep 2
podman stop caddy-server

echo "=== Creating Containerfile for caddy ==="
cat > ~/webserver/Containerfile << EOF
FROM ${HUMMINGBIRD_REGISTRY}/caddy:latest

COPY index.html /usr/share/caddy/
EOF

echo "=== Building caddy image ==="
podman build -t my-website -f ~/webserver/Containerfile ~/webserver

echo "=== Running webserver ==="
podman run -d --rm --name webserver -p 8080:8080 my-website

sleep 2
podman stop webserver

echo "=== Copying Flask files ==="
cp ~/webserver/index.html ~/flask/

echo "=== Building UBI Flask version ==="
podman build --net=host -t my-flasksite:ubi -f ~/flask/Containerfile.ubi ~/flask

echo "=== Running UBI Flask application ==="
podman run -d --rm --name flask-demo -p 8080:8080 my-flasksite:ubi

sleep 2
podman stop flask-demo

echo "=== Creating Hummingbird Flask Containerfile ==="
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

echo "=== Building Hummingbird Flask application ==="
podman build --net=host -t my-flasksite:hi -f ~/flask/Containerfile.hi ~/flask

echo "=== Running Hummingbird Flask application ==="
podman run -d --rm --name flask-demo -p 8080:8080 my-flasksite:hi

sleep 2
podman stop flask-demo

echo "=== Building multi-stage Quarkus application ==="
podman build -t hummingbird-demo:v1 -f ~/sample-app/Containerfile ~/sample-app

echo "=== Running Quarkus application ==="
podman run -d --rm --name demo -p 8080:8080 hummingbird-demo:v1

sleep 5
podman stop demo

echo "=== Module 01-01 completed ==="
echo "Created images: my-website, my-flasksite:ubi, my-flasksite:hi, hummingbird-demo:v1"
