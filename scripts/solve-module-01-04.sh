#!/bin/bash
set -e

# Module 01-04: Image Signing & Attestation
# Solve script - completes module steps on behalf of user
#
# Creates: hummingbird-demo:v1 (if missing), SBOM, cosign keys, signed image

# Container registries
HUMMINGBIRD_REGISTRY="quay.io/hummingbird"
DOCKER_REGISTRY="docker.io"

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

# Cleanup function
cleanup() {
    podman stop registry 2>/dev/null || true
    podman rm registry 2>/dev/null || true
}
trap cleanup EXIT

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

echo "=== Starting local registry ==="
podman run -d --name registry -p 5000:5000 ${DOCKER_REGISTRY}/library/registry:2

# Give registry a moment to start
sleep 2

echo "=== Tagging and pushing image to local registry ==="
podman tag hummingbird-demo:v1 localhost:5000/hummingbird-demo:v1
podman push --tls-verify=false localhost:5000/hummingbird-demo:v1

echo "=== Capturing image digest ==="
IMAGE_DIGEST=$(podman inspect --format='{{.Digest}}' localhost:5000/hummingbird-demo:v1)

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
  --allow-http-registry \
  localhost:5000/hummingbird-demo@${IMAGE_DIGEST}

echo "=== Attaching SBOM attestation ==="
cosign attest --yes --key cosign.key \
  --predicate ~/scanning/hummingbird-demo.spdx --type spdxjson \
  --tlog-upload=false \
  --allow-http-registry \
  localhost:5000/hummingbird-demo@${IMAGE_DIGEST}

echo "=== Stopping local registry ==="
podman stop registry
podman rm registry

cd ~

echo "=== Module 01-04 completed ==="
echo "Created: cosign keys (cosign.key, cosign.pub), signed image with SBOM attestation"
