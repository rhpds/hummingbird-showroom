#!/bin/bash
set -e

# Module 01-02: Security Scanning & SBOMs
# Auto-generated script from executable bash blocks
#
# Note: Registry startup timing and cosign operations require automation for reliable execution

# Container registries
UBI_REGISTRY="registry.access.redhat.com"
DOCKER_REGISTRY="docker.io"



echo "=== Enabling podman socket ==="
systemctl --user enable --now podman.socket

echo "=== Creating scanning directory ==="
mkdir -p ~/scanning
cd ~/scanning

echo "=== Verifying grype and syft installation ==="
grype version
syft version

echo "=== Creating UBI comparison image ==="
# Create Containerfile.ubi for comparison
cat > ~/sample-app/Containerfile.ubi << EOF
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
podman build -f ~/sample-app/Containerfile.ubi -t demo-ubi:v1 ~/sample-app
echo "✅ UBI comparison image built successfully"

echo "=== Step 1: Scan Hummingbird image for CVEs ==="
grype hummingbird-demo:v1
echo "✅ CVE scan completed"

echo "=== Step 2: Compare with Full UBI Image ==="
grype demo-ubi:v1 --only-fixed

echo "=== Step 3: Generate SBOM (human-readable table) ==="
syft hummingbird-demo:v1 -o table

echo "=== Step 3: Generate SBOM in SPDX-JSON format ==="
syft hummingbird-demo:v1 -o spdx-json=hummingbird-demo.spdx
echo "✅ SBOM generation completed"

# View package count
if [ -f hummingbird-demo.spdx ]; then
    jq '.packages | length' hummingbird-demo.spdx
else
    echo "ERROR: SBOM file hummingbird-demo.spdx was not created"
    exit 1
fi

echo "=== Step 5: Start a Local Registry and Push the Image ==="
# Start a local OCI registry
podman run -d --name registry -p 5000:5000 ${DOCKER_REGISTRY}/library/registry:2

# Wait for registry to be ready
echo "Waiting for registry to be ready..."
for i in {1..30}; do
    if curl -f -s http://localhost:5000/v2/ > /dev/null 2>&1; then
        echo "✅ Registry is ready!"
        break
    fi
    if [ $i -eq 30 ]; then
        echo "ERROR: Registry failed to start after 30 seconds"
        exit 1
    fi
    echo "Attempt $i/30: Registry not ready yet, waiting..."
    sleep 1
done

# Tag and push our image to the local registry
podman tag hummingbird-demo:v1 localhost:5000/hummingbird-demo:v1
podman push --tls-verify=false localhost:5000/hummingbird-demo:v1

# Capture the image digest for use with cosign
IMAGE_DIGEST=$(podman inspect --format='{{.Digest}}' localhost:5000/hummingbird-demo:v1)
if [ -z "$IMAGE_DIGEST" ]; then
    echo "ERROR: Failed to capture image digest"
    exit 1
fi
echo "✅ Image digest: ${IMAGE_DIGEST}"

echo "=== Step 6: Generate Signing Keys ==="
# Generate a key pair with empty password for automation
# Using expect-style input or environment variable
export COSIGN_PASSWORD=""
cosign generate-key-pair

echo "=== Step 7: Sign the Image ==="
cosign sign --yes --key cosign.key \
  --tlog-upload=false \
  --allow-insecure-registry \
  localhost:5000/hummingbird-demo@${IMAGE_DIGEST}
echo "✅ Image signing completed"

echo "=== Step 8: Verify the Signature ==="
cosign verify --key cosign.pub \
  --insecure-ignore-tlog=true \
  --allow-insecure-registry \
  localhost:5000/hummingbird-demo@${IMAGE_DIGEST}

echo "=== Step 9: Attach SBOM Attestation ==="
cosign attest --yes --key cosign.key \
  --predicate hummingbird-demo.spdx --type spdxjson \
  --tlog-upload=false \
  --allow-insecure-registry \
  localhost:5000/hummingbird-demo@${IMAGE_DIGEST}

echo "=== Step 10: Verify SBOM Attestation ==="
cosign verify-attestation --key cosign.pub \
  --type spdxjson \
  --insecure-ignore-tlog=true \
  --allow-insecure-registry \
  localhost:5000/hummingbird-demo@${IMAGE_DIGEST} \
  | jq -r '.payload' | base64 -d | jq '.predicate.packages | length'

echo "=== Step 11: Compare Image Sizes ==="
# Compare sizes (filter out the registry copy)
podman images | grep -E "hummingbird-demo|demo-ubi" | grep -v "5000"

echo "=== Calculating size reduction percentage ==="
# Calculate percentage based on actual image sizes
HUMMINGBIRD_SIZE=$(podman images hummingbird-demo --format "{{.Size}}" | head -1 | sed 's/MB//')
UBI_SIZE=$(podman images demo-ubi --format "{{.Size}}" | head -1 | sed 's/MB//')

if [ -n "$HUMMINGBIRD_SIZE" ] && [ -n "$UBI_SIZE" ]; then
    awk -v h="$HUMMINGBIRD_SIZE" -v u="$UBI_SIZE" 'BEGIN { 
        if (u > 0) printf "Size reduction: %.1f%% (%s MB vs %s MB)\n", (1 - h/u) * 100, h, u
        else print "Could not calculate size reduction"
    }'
else
    echo "Could not determine image sizes for calculation"
fi

echo "=== Cleanup ==="

echo "Stopping and removing local registry..."
podman stop registry 2>/dev/null || echo "Registry may already be stopped"
podman rm registry 2>/dev/null || echo "Registry may already be removed"

echo "=== Summary ==="
echo "✅ CVE scanning and SBOM generation completed"
echo "✅ Image signing and attestation completed" 
echo "✅ Security validation and verification completed"
echo ""
echo "=== Module 01-02 completed successfully! ==="
