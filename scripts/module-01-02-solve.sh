#!/bin/bash
set -e

# Module 01-02: Security Scanning & SBOMs
# Auto-generated script from executable bash blocks

echo "=== Checking prerequisites ==="
# Verify that hummingbird-demo:v1 exists (created in module 01-01)
if ! podman images --format "{{.Repository}}:{{.Tag}}" | grep -q "^localhost/hummingbird-demo:v1$"; then
    echo "ERROR: hummingbird-demo:v1 image not found"
    echo "Please run module-01-01-solve.sh first to build the required image"
    exit 1
fi

# Verify that demo-ubi:v1 exists (created in module 01-01)
if ! podman images --format "{{.Repository}}:{{.Tag}}" | grep -q "^localhost/demo-ubi:v1$"; then
    echo "ERROR: demo-ubi:v1 image not found"
    echo "Please run module-01-01-solve.sh first to build the required image"
    exit 1
fi

echo "Prerequisites met: hummingbird-demo:v1 and demo-ubi:v1 found"

echo "=== Enabling podman socket ==="
systemctl --user enable --now podman.socket

echo "=== Creating scanning directory ==="
mkdir -p ~/scanning
cd ~/scanning

echo "=== Verifying grype and syft installation ==="
grype version
syft version

echo "=== Step 1: Scan Hummingbird image for CVEs ==="
grype hummingbird-demo:v1

echo "=== Step 2: Compare with Full UBI Image ==="
grype demo-ubi:v1 --only-fixed

echo "=== Step 3: Generate SBOM (human-readable table) ==="
syft hummingbird-demo:v1 -o table

echo "=== Step 3: Generate SBOM in SPDX-JSON format ==="
syft hummingbird-demo:v1 -o spdx-json=hummingbird-demo.spdx

# View package count
if [ -f hummingbird-demo.spdx ]; then
    jq '.packages | length' hummingbird-demo.spdx
else
    echo "ERROR: SBOM file hummingbird-demo.spdx was not created"
    exit 1
fi

echo "=== Step 5: Start a Local Registry and Push the Image ==="
# Start a local OCI registry
podman run -d --name registry -p 5000:5000 docker.io/library/registry:2

# Wait for registry to be ready
echo "Waiting for registry to be ready..."
for i in {1..30}; do
    if curl -f -s http://localhost:5000/v2/ > /dev/null 2>&1; then
        echo "Registry is ready!"
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
echo "Image digest: ${IMAGE_DIGEST}"

echo "=== Step 6: Generate Signing Keys ==="
# Generate a key pair with empty password for automation
# Using expect-style input or environment variable
export COSIGN_PASSWORD=""
printf '\n\n' | cosign generate-key-pair

echo "=== Step 7: Sign the Image ==="
printf '\n' | cosign sign --yes --key cosign.key \
  --tlog-upload=false \
  --allow-insecure-registry \
  localhost:5000/hummingbird-demo@${IMAGE_DIGEST}

echo "=== Step 8: Verify the Signature ==="
cosign verify --key cosign.pub \
  --insecure-ignore-tlog=true \
  --allow-insecure-registry \
  localhost:5000/hummingbird-demo@${IMAGE_DIGEST}

echo "=== Step 9: Attach SBOM Attestation ==="
printf '\n' | cosign attest --yes --key cosign.key \
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

echo "=== Step 12: Clean Up Local Registry ==="
podman stop registry || echo "Registry may already be stopped"
podman rm registry || echo "Registry may already be removed"

echo "=== All security scanning and signing steps completed successfully! ==="
