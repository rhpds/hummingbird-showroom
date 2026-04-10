#!/bin/bash
set -e

# Module 01-02: Security Scanning & SBOMs
# Auto-generated script from executable bash blocks
#
# Note: Registry startup timing and cosign operations require automation for reliable execution

# Container registries
UBI_REGISTRY="registry.access.redhat.com"
DOCKER_REGISTRY="docker.io"

# Quay registry (injected by showroom platform)
if [ -z "${QUAY_HOSTNAME:-}" ] || [ -z "${QUAY_USER:-}" ] || [ -z "${QUAY_PASSWORD:-}" ]; then
    echo "ERROR: Quay credentials not available"
    echo "Required environment variables: QUAY_HOSTNAME, QUAY_USER, QUAY_PASSWORD"
    echo "These should be injected by the showroom platform"
    exit 1
fi

export QUAY_ORG="${QUAY_HOSTNAME}/${QUAY_USER}"



echo "=== Enabling podman socket ==="
systemctl --user enable --now podman.socket

echo "=== Creating scanning directory ==="
mkdir -p ~/scanning
cd ~/scanning

echo "=== Verifying grype and syft installation ==="
grype version
syft version

echo "=== Using pre-created UBI comparison image ==="
echo "UBI Containerfile already created by setup script"

echo "=== Viewing image comparison ==="
podman images hummingbird-demo

echo "=== Step 1: Scan Hummingbird image for CVEs ==="
grype hummingbird-demo:v1
echo "✅ CVE scan completed"

echo "=== Step 2: Compare with Full UBI Image ==="
grype hummingbird-demo:ubi --only-fixed

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

echo "=== Step 5: Log into Quay and Push the Image ==="
# Login to Quay registry
podman login ${QUAY_HOSTNAME} --username ${QUAY_USER} --password ${QUAY_PASSWORD}

# Tag and push our image to Quay
podman tag hummingbird-demo:v1 ${QUAY_ORG}/hummingbird-demo:v1
podman push ${QUAY_ORG}/hummingbird-demo:v1

# Capture the image digest for use with cosign
IMAGE_DIGEST=$(podman inspect --format='{{.Digest}}' ${QUAY_ORG}/hummingbird-demo:v1)
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
  ${QUAY_ORG}/hummingbird-demo@${IMAGE_DIGEST}
echo "✅ Image signing completed"

echo "=== Step 8: Verify the Signature ==="
cosign verify --key cosign.pub \
  --insecure-ignore-tlog=true \
  ${QUAY_ORG}/hummingbird-demo@${IMAGE_DIGEST}

echo "=== Step 9: Attach SBOM Attestation ==="
cosign attest --yes --key cosign.key \
  --predicate hummingbird-demo.spdx --type spdxjson \
  --tlog-upload=false \
  ${QUAY_ORG}/hummingbird-demo@${IMAGE_DIGEST}

echo "=== Step 10: Verify SBOM Attestation ==="
cosign verify-attestation --key cosign.pub \
  --type spdxjson \
  --insecure-ignore-tlog=true \
  ${QUAY_ORG}/hummingbird-demo@${IMAGE_DIGEST} \
  | jq -r '.payload' | base64 -d | jq '.predicate.packages | length'

echo "=== Step 11: Compare Image Sizes ==="
# Compare sizes
podman images | grep "hummingbird-demo"

echo "=== Calculating size reduction percentage ==="
# Calculate percentage based on actual image sizes
HUMMINGBIRD_SIZE=$(podman images hummingbird-demo:v1 --format "{{.Size}}" | head -1 | sed 's/MB//')
UBI_SIZE=$(podman images hummingbird-demo:ubi --format "{{.Size}}" | head -1 | sed 's/MB//')

if [ -n "$HUMMINGBIRD_SIZE" ] && [ -n "$UBI_SIZE" ]; then
    awk -v h="$HUMMINGBIRD_SIZE" -v u="$UBI_SIZE" 'BEGIN { 
        if (u > 0) printf "Size reduction: %.1f%% (%s MB vs %s MB)\n", (1 - h/u) * 100, h, u
        else print "Could not calculate size reduction"
    }'
else
    echo "Could not determine image sizes for calculation"
fi

echo "=== Cleanup ==="

cd ~

echo "=== Summary ==="
echo "✅ CVE scanning and SBOM generation completed"
echo "✅ Image pushed to Quay registry: ${QUAY_ORG}/hummingbird-demo:v1"
echo "✅ Image signing and attestation completed"
echo "✅ Security validation and verification completed"
echo ""
echo "=== Module 01-02 completed successfully! ==="
