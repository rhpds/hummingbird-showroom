#!/bin/bash
set -e

# Module 01-03: Vulnerability Scanning & SBOMs
# Solve script - completes module steps on behalf of user
#
# Creates: hummingbird-demo:v1 (if missing), SBOM file

# Container registries
HUMMINGBIRD_REGISTRY="quay.io/hummingbird"

echo "=== Module 01-03 Solve Script ==="

# Check for setup directory
if [ ! -d ~/sample-app ]; then
    echo "ERROR: Missing required directory ~/sample-app/"
    echo "This should have been created by setup-rhel.sh"
    echo "Please contact your instructor for assistance"
    exit 1
fi

# Cleanup function
cleanup() {
    cd ~
}
trap cleanup EXIT

# Build hummingbird-demo:v1 if missing
if ! podman images --format "{{.Repository}}:{{.Tag}}" | grep -q "^localhost/hummingbird-demo:v1$"; then
    echo "=== Building prerequisite: hummingbird-demo:v1 ==="
    podman build -t hummingbird-demo:v1 -f ~/sample-app/Containerfile ~/sample-app
fi

echo "=== Enabling podman socket ==="
systemctl --user enable --now podman.socket

echo "=== Creating scanning directory ==="
mkdir -p ~/scanning
cd ~/scanning

echo "=== Scanning Hummingbird image for CVEs ==="
grype hummingbird-demo:v1

echo "=== Generating SBOM (SPDX-JSON format) ==="
syft hummingbird-demo:v1 -o spdx-json=hummingbird-demo.spdx

cd ~

echo "=== Module 01-03 completed ==="
echo "Created: ~/scanning/hummingbird-demo.spdx SBOM file"
