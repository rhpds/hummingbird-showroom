#!/bin/bash
set -e

# Module 01-02: Multi-Stage Builds
# Solve script - completes module steps on behalf of user
#
# Creates: hummingbird-demo:v1

# Container registries
HUMMINGBIRD_REGISTRY="quay.io/hummingbird"

echo "=== Module 01-02 Solve Script ==="

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
    podman stop demo 2>/dev/null || true
    podman rm demo 2>/dev/null || true
}
trap cleanup EXIT

echo "=== Building multi-stage Quarkus application ==="
podman build -t hummingbird-demo:v1 -f ~/sample-app/Containerfile ~/sample-app

echo "=== Running Quarkus application ==="
podman run -d --rm --name demo -p 8080:8080 hummingbird-demo:v1

sleep 5
podman stop demo

echo "=== Module 01-02 completed ==="
echo "Created image: hummingbird-demo:v1"
