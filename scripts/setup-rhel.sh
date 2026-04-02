#! /bin/bash
# dnf install -y container-tools java-21-openjdk-devel python3-pip vim-enhanced cloud-init git-all

# Container registries
HUMMINGBIRD_REGISTRY="${HUMMINGBIRD_REGISTRY:-quay.io/hummingbird}"
UBI_REGISTRY="${UBI_REGISTRY:-registry.access.redhat.com}"
DOCKER_REGISTRY="${DOCKER_REGISTRY:-docker.io}"

# GitHub repository references
GITHUB_ORG="${GITHUB_ORG:-rhpds}"
GITHUB_REPO="${GITHUB_REPO:-hummingbird-showroom}"
GITHUB_BRANCH="${GITHUB_BRANCH:-main}"
GITHUB_BASE_URL="https://raw.githubusercontent.com/${GITHUB_ORG}/${GITHUB_REPO}/refs/heads/${GITHUB_BRANCH}"

# Download Flask packages locally
mkdir -p /var/pypi-cache
pip download  --python-version=3.14 --only-binary=:all: flask -d /var/pypi-cache/
pip download  --python-version=3.12 --only-binary=:all: flask -d /var/pypi-cache/

cat > /etc/containers/systemd/pypiserver.container << 'EOF'
[Unit]
Description=PyPi Local service

[Container]
Image=${DOCKER_REGISTRY}/pypiserver/pypiserver:latest
ContainerName=pypiserver
PublishPort=8000:8080
Volume=/var/pypi-cache:/data/packages:z

[Service]
Restart=on-failure

[Install]
WantedBy=default.target
EOF
systemctl daemon-reload
systemctl start pypiserver

# Install cosign from GitHub releases
COSIGN_VERSION=v2.4.1
curl -LO https://github.com/sigstore/cosign/releases/download/${COSIGN_VERSION}/cosign-linux-amd64
sudo install -m 755 cosign-linux-amd64 /usr/local/bin/cosign
rm cosign-linux-amd64

# Verify installation
cosign version

# Install syft
SYFT_VERSION=v1.42.2
curl -sSfL https://raw.githubusercontent.com/anchore/syft/main/install.sh | sudo sh -s -- -b /usr/local/bin ${SYFT_VERSION}

# Verify installation
syft version

# Install grype
GRYPE_VERSION=v0.109.1
curl -sSfL https://raw.githubusercontent.com/anchore/grype/main/install.sh | sudo sh -s -- -b /usr/local/bin ${GRYPE_VERSION}

# Verify installation
grype version
grype db update

echo "=== Pre-pulling container images for modules 01-03 ==="

# Hummingbird images needed across modules
echo "Pulling Hummingbird runtime images..."
su -l rhel -c "podman pull ${HUMMINGBIRD_REGISTRY}/caddy:latest"
su -l rhel -c "podman pull ${HUMMINGBIRD_REGISTRY}/curl:latest"
su -l rhel -c "podman pull ${HUMMINGBIRD_REGISTRY}/curl:latest-builder"

echo "Pulling Hummingbird Python images..."
su -l rhel -c "podman pull ${HUMMINGBIRD_REGISTRY}/python:3.14"
su -l rhel -c "podman pull ${HUMMINGBIRD_REGISTRY}/python:3.14-builder"
su -l rhel -c "podman pull ${HUMMINGBIRD_REGISTRY}/python:3.14-fips"

echo "Pulling Hummingbird OpenJDK images..."
su -l rhel -c "podman pull ${HUMMINGBIRD_REGISTRY}/openjdk:21-builder"
su -l rhel -c "podman pull ${HUMMINGBIRD_REGISTRY}/openjdk:21-runtime"

# Docker.io images
echo "Pulling Docker registry image..."
su -l rhel -c "podman pull ${DOCKER_REGISTRY}/library/registry:2"

echo "✅ Container images pre-pulled successfully"

cat > /tmp/quarkus.sh <<'EOF'
curl -Ls https://sh.jbang.dev | bash -s - trust add https://repo1.maven.org/maven2/io/quarkus/quarkus-cli/
curl -Ls https://sh.jbang.dev | bash -s - app install --fresh --force quarkus@quarkusio
export PATH="$HOME/.jbang/bin:$PATH"
if ! grep -q '.jbang/bin' ~/.bashrc 2>/dev/null; then
    echo 'export PATH="$HOME/.jbang/bin:$PATH"' >> ~/.bashrc
fi

EOF
chmod +x /tmp/quarkus.sh
su -l rhel -c /tmp/quarkus.sh
rm /tmp/quarkus.sh

mkdir -p /home/rhel/webserver /home/rhel/flask /home/rhel/scanning /home/rhel/fips
curl -o /home/rhel/fips/test-fips.py -L ${GITHUB_BASE_URL}/scripts/test-fips.py

echo "=== Step 5: Scaffolding Quarkus project ==="
su -l rhel -c "quarkus create app com.example:sample-app \
    --extension='rest,rest-jackson' \
    --no-code"

echo "=== Updating .dockerignore ==="
cat > /home/rhel/sample-app/.dockerignore << 'EOF'
target/
.git/
.gitignore
README.md
*.cmd
EOF

echo "=== Fixing file permissions ==="
chmod -R a+rX /home/rhel/sample-app/.mvn/ /home/rhel/sample-app/src/
chmod a+r /home/rhel/sample-app/pom.xml
chmod a+x /home/rhel/sample-app/mvnw

echo "=== Creating GreetingResource.java ==="
mkdir -p /home/rhel/sample-app/src/main/java/com/example
cat > /home/rhel/sample-app/src/main/java/com/example/GreetingResource.java << 'EOF'
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
cat > /home/rhel/sample-app/src/main/resources/application.properties << 'EOF'
quarkus.http.host=0.0.0.0
quarkus.http.port=8080
EOF

echo "=== Creating UBI comparison image ==="
# Create Containerfile.ubi for comparison
cat > /home/rhel/sample-app/Containerfile.ubi << EOF
FROM ${UBI_REGISTRY}/ubi9/openjdk-21:latest
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

# Build UBI-only version for comparison
su -l rhel -c "podman build -f /home/rhel/sample-app/Containerfile.ubi -t hummingbird-demo:ubi /home/rhel/sample-app"
echo "✅ UBI comparison image built successfully"

echo "=== Step 4: Preparing Host Directories for Bind Mounts ==="

echo "Creating host directories for bind mounts..."
mkdir -p /opt/myapp/config /opt/myapp/logs
chown -R rhel:rhel /opt/myapp

echo "Setting SELinux context for container file access..."
semanage fcontext -a -t container_file_t "/opt/myapp/config(/.*)?" || echo "Context may already exist"
semanage fcontext -a -t container_file_t "/opt/myapp/logs(/.*)?" || echo "Context may already exist"
restorecon -Rv /opt/myapp

echo "=== Creating exercise files for improved reliability ==="

echo "Creating HTML landing page..."
cat > /home/rhel/webserver/index.html << 'EOF'
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

echo "Creating Flask application..."
cat > /home/rhel/flask/app.py << 'EOF'
from flask import Flask

app = Flask(__name__,)

@app.route("/")
def index():
    return app.send_static_file("index.html")

if __name__ == "__main__":
    # Listen on all interfaces (0.0.0.0) on port 8080
    app.run(host="0.0.0.0", port=8080)

EOF

echo "Creating Caddy SSL configuration..."
cat > /home/rhel/webserver/Caddyfile << 'EOF'
{
    http_port 8080
    https_port 8443
}

localhost {
    tls internal
    root * /usr/share/caddy
    file_server
}
EOF

echo "Creating multi-stage Quarkus Containerfile..."
cat > /home/rhel/sample-app/Containerfile << 'EOF'
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
# Stage 2: Runtime stage
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

echo "Creating Flask UBI Containerfile..."
cat > /home/rhel/flask/Containerfile.ubi << 'EOF'
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
COPY --chown=appuser:appgroup index.html static/

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

echo "✅ Exercise files created successfully"

curl -o /home/rhel/validate-mod-01-01.sh -L ${GITHUB_BASE_URL}/scripts/validate-module-01-01.sh
curl -o /home/rhel/validate-mod-01-02.sh -L ${GITHUB_BASE_URL}/scripts/validate-module-01-02.sh
curl -o /home/rhel/validate-mod-01-03.sh -L ${GITHUB_BASE_URL}/scripts/validate-module-01-03.sh
chmod +x /home/rhel/validate-mod-01-*.sh

chown -R rhel:rhel /home/rhel/
