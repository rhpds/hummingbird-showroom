#!/bin/bash
set -e

# Module 01-08: Content-Based Layer Splitting with chunkah (Optional)
# Solve script - completes module steps on behalf of user
#
# Creates: hummingbird-demo:v1 (if missing), chunkah-demo images, shell helpers

# Container registries
HUMMINGBIRD_REGISTRY="quay.io/hummingbird-hatchling"
BUILDER_REGISTRY="registry.access.redhat.com/ubi9"

echo "=== Module 01-08 Solve Script ==="

# Check for setup directory
if [ ! -d ~/sample-app ]; then
    echo "ERROR: Missing required directory ~/sample-app/"
    echo "This should have been created by setup-rhel.sh"
    echo "Please contact your instructor for assistance"
    exit 1
fi

# Cleanup function
cleanup() {
    podman stop chunkah-demo 2>/dev/null || true
    podman rm chunkah-demo 2>/dev/null || true
}
trap cleanup EXIT

# Build hummingbird-demo:v1 if missing
if ! podman images --format "{{.Repository}}:{{.Tag}}" | grep -q "^localhost/hummingbird-demo:v1$"; then
    echo "=== Building prerequisite: hummingbird-demo:v1 ==="
    podman build -t hummingbird-demo:v1 -f ~/sample-app/Containerfile ~/sample-app
fi

echo "=== Running chunkah on existing image ==="
export CHUNKAH_CONFIG_STR="$(podman inspect hummingbird-demo:v1)"

podman run --rm \
  --mount=type=image,src=hummingbird-demo:v1,dst=/chunkah \
  -e CHUNKAH_CONFIG_STR \
  quay.io/jlebon/chunkah build \
  | podman load

echo "=== Creating chunkah demo application ==="
mkdir -p ~/hummingbird-lab/chunkah-demo/src/main/java/com/example
mkdir -p ~/hummingbird-lab/chunkah-demo/src/main/resources

# Copy pom.xml and Maven wrapper from sample-app
cp ~/sample-app/pom.xml ~/hummingbird-lab/chunkah-demo/
cp ~/sample-app/mvnw ~/hummingbird-lab/chunkah-demo/
cp -r ~/sample-app/.mvn ~/hummingbird-lab/chunkah-demo/

# Create minimal Quarkus application
cat > ~/hummingbird-lab/chunkah-demo/src/main/java/com/example/GreetingResource.java << 'SRV'
package com.example;
import jakarta.ws.rs.GET;
import jakarta.ws.rs.Path;
import jakarta.ws.rs.Produces;
import jakarta.ws.rs.core.MediaType;
import java.util.Map;

@Path("/")
public class GreetingResource {
    @GET
    @Produces(MediaType.APPLICATION_JSON)
    public Map<String, String> hello() {
        return Map.of("message", "Hello from chunkah-split Hummingbird!");
    }
}
SRV

cat > ~/hummingbird-lab/chunkah-demo/src/main/resources/application.properties << 'PROPS'
quarkus.http.host=0.0.0.0
quarkus.http.port=8080
PROPS

echo "=== Creating Containerfile for chunkah demo ==="
cat > ~/hummingbird-lab/chunkah-demo/Containerfile << EOF
# Stage 1: Build the Quarkus application
FROM ${BUILDER_REGISTRY}/openjdk-21:latest AS builder

USER root
RUN microdnf install -y unzip && microdnf clean all

WORKDIR /build
COPY mvnw pom.xml ./
COPY .mvn ./.mvn
RUN ./mvnw dependency:go-offline -B
COPY src ./src
RUN ./mvnw package -DskipTests -B

# Stage 2: Runtime stage using Hummingbird
FROM ${HUMMINGBIRD_REGISTRY}/openjdk:21-runtime

WORKDIR /app
COPY --from=builder --chown=1001:1001 /build/target/quarkus-app/lib/ ./lib/
COPY --from=builder --chown=1001:1001 /build/target/quarkus-app/*.jar ./
COPY --from=builder --chown=1001:1001 /build/target/quarkus-app/app/ ./app/
COPY --from=builder --chown=1001:1001 /build/target/quarkus-app/quarkus/ ./quarkus/

LABEL org.opencontainers.image.title="chunkah-demo"
USER 1001
EXPOSE 8080
ENV JAVA_OPTS_APPEND="-Dquarkus.http.host=0.0.0.0"
ENTRYPOINT ["java", "-jar", "quarkus-run.jar"]
EOF

echo "=== Building chunkah demo application ==="
buildah build \
  --format oci \
  --tag chunkah-demo:pre-split \
  ~/hummingbird-lab/chunkah-demo/

echo "=== Applying chunkah splitting to demo app ==="
export CHUNKAH_CONFIG_STR="$(podman inspect chunkah-demo:pre-split)"

podman run --rm \
  --mount=type=image,src=chunkah-demo:pre-split,dst=/chunkah \
  -e CHUNKAH_CONFIG_STR \
  quay.io/jlebon/chunkah build \
    --max-layers 32 \
  | podman load

# Tag the loaded image
LOADED_ID=$(podman images --format '{{.ID}}' --filter dangling=true | head -1)
if [ -n "$LOADED_ID" ]; then
    podman tag "$LOADED_ID" chunkah-demo:v1
fi

echo "=== Adding shell helper functions ==="
# Check if hb-chunk already exists in bashrc
if ! grep -q "function hb-chunk" ~/.bashrc 2>/dev/null; then
    cat >> ~/.bashrc << 'HELPERS'

# Hummingbird chunkah helpers
function hb-chunk() {
    local image="${1:?Usage: hb-chunk <image:tag>}"
    export CHUNKAH_CONFIG_STR="$(podman inspect "$image")"
    podman run --rm \
      --mount=type=image,src="$image",dst=/chunkah \
      -e CHUNKAH_CONFIG_STR \
      quay.io/jlebon/chunkah build \
        --max-layers 32 \
      | podman load
}

function hb-chunk-push() {
    local image="${1:?Usage: hb-chunk-push <image:tag> <registry-url>}"
    local registry="${2:?}"
    podman push --compression-format=zstd:chunked "$image" "$registry"
}
HELPERS
fi

echo "=== Module 01-08 completed ==="
echo "Created: chunkah-split images, shell helpers (hb-chunk, hb-chunk-push)"
echo "Note: Source ~/.bashrc to use shell helpers in current session"
