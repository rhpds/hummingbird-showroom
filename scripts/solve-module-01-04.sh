#!/bin/bash
set -e

# Module 01-04: Image Signing & Attestation
# Solve script - completes module steps on behalf of user
#
# Creates: hummingbird-demo:v1 (if missing), SBOM, cosign keys, signed image

# Container registries
HUMMINGBIRD_REGISTRY="quay.io/hummingbird"
DOCKER_REGISTRY="docker.io"

# Quay registry (injected by showroom platform)
if [ -z "${QUAY_HOSTNAME:-}" ] || [ -z "${QUAY_USER:-}" ] || [ -z "${QUAY_PASSWORD:-}" ]; then
    echo "ERROR: Quay credentials not available"
    echo "Required environment variables: QUAY_HOSTNAME, QUAY_USER, QUAY_PASSWORD"
    echo "These should be injected by the showroom platform"
    exit 1
fi

export QUAY_ORG="${QUAY_HOSTNAME}/${QUAY_USER}"

echo "=== Module 01-04 Solve Script ==="

# Check for setup files
if [ ! -d ~/sample-app ]; then
    echo "ERROR: Missing required directory ~/sample-app/"
    echo "This should have been created by setup-rhel.sh"
    echo "Please contact your instructor for assistance"
    exit 1
fi

if [ ! -f ~/sample-app/Containerfile ]; then
    echo "ERROR: Missing required file ~/sample-app/Containerfile"
    echo "This should have been created by setup-rhel.sh"
    echo "Please contact your instructor for assistance"
    exit 1
fi

# Build hummingbird-demo:v1 if missing
if ! podman images --format "{{.Repository}}:{{.Tag}}" | grep -q "^localhost/hummingbird-demo:v1$"; then
    echo "=== Building prerequisite: hummingbird-demo:v1 ==="
    podman build -t hummingbird-demo:v1 -f ~/sample-app/Containerfile ~/sample-app
fi

# Generate SBOM if missing
mkdir -p ~/scanning
cd ~/scanning

if [ ! -f ~/scanning/hummingbird-demo.spdx ]; then
    echo "=== Generating prerequisite: SBOM ==="
    syft hummingbird-demo:v1 -o spdx-json=hummingbird-demo.spdx
fi

echo "=== Logging into Quay ==="
podman login ${QUAY_HOSTNAME} --username ${QUAY_USER} --password ${QUAY_PASSWORD}

echo "=== Tagging and pushing image to Quay ==="
podman tag hummingbird-demo:v1 ${QUAY_ORG}/hummingbird-demo:v1
podman push ${QUAY_ORG}/hummingbird-demo:v1

echo "=== Capturing image digest ==="
IMAGE_DIGEST=$(podman inspect --format='{{.Digest}}' ${QUAY_ORG}/hummingbird-demo:v1)

if [ -z "$IMAGE_DIGEST" ]; then
    echo "ERROR: Failed to capture image digest"
    exit 1
fi

echo "Image digest: ${IMAGE_DIGEST}"

echo "=== Generating cosign key pair ==="
export COSIGN_PASSWORD=""
cosign generate-key-pair

echo "=== Signing image with cosign ==="
cosign sign --yes --key cosign.key \
  --tlog-upload=false \
  ${QUAY_ORG}/hummingbird-demo@${IMAGE_DIGEST}

echo "=== Attaching SBOM attestation ==="
cosign attest --yes --key cosign.key \
  --predicate ~/scanning/hummingbird-demo.spdx --type spdxjson \
  --tlog-upload=false \
  ${QUAY_ORG}/hummingbird-demo@${IMAGE_DIGEST}

cd ~

echo "=== Module 01-04 completed ==="
echo "Created: cosign keys (cosign.key, cosign.pub)"
echo "Image pushed and signed in Quay: ${QUAY_ORG}/hummingbird-demo:v1"
echo "SBOM attestation attached"
