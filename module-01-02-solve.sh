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
syft hummingbird-demo:v1 -o spdx-json=hi.spdx

# View package count
jq '.packages | length' hi.spdx

echo "=== Step 5: Start a Local Registry and Push the Image ==="
# Start a local OCI registry
podman run -d --name registry -p 5000:5000 docker.io/library/registry:2

# Tag and push our image to the local registry
podman tag hummingbird-demo:v1 localhost:5000/hummingbird-demo:v1
podman push --tls-verify=false localhost:5000/hummingbird-demo:v1

# Capture the image digest for use with cosign
IMAGE_DIGEST=$(podman inspect --format='{{.Digest}}' localhost:5000/hummingbird-demo:v1)
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
  --predicate hi.spdx --type spdxjson \
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
# Calculate exact percentage
awk 'BEGIN { printf "Size reduction: %.1f%%\n", (1 - 273.0/624.0) * 100 }'

echo "=== Step 12: Clean Up Local Registry ==="
podman stop registry && podman rm registry

echo "=== All security scanning and signing steps completed successfully! ==="
