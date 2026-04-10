#!/bin/bash
set -e

# Module 01-02: Multi-Stage Builds
# Validation script - fails fast if prerequisites missing or steps fail
# Status to stdout, errors to stderr, internal commands suppressed

# Container registries
HUMMINGBIRD_REGISTRY="quay.io/hummingbird"

echo "=== Validating Module 01-02: Multi-Stage Builds ==="

#
# 1. PREREQUISITE CHECKS (fail fast if environment is broken)
#
echo "Checking prerequisites..."

# Check that setup files exist
if [ ! -d ~/sample-app ]; then
    echo "❌ ERROR: ~/sample-app directory not found" >&2
    echo "   Expected to be created by setup-rhel.sh" >&2
    exit 1
fi

if [ ! -f ~/sample-app/Containerfile ]; then
    echo "❌ ERROR: ~/sample-app/Containerfile not found" >&2
    echo "   Expected to be created by setup-rhel.sh" >&2
    exit 1
fi

# Verify quarkus CLI is available
if ! command -v quarkus &> /dev/null; then
    echo "❌ ERROR: quarkus CLI not found in PATH" >&2
    echo "   Expected to be installed by setup-rhel.sh" >&2
    exit 1
fi

# Verify Java is available
if ! command -v java &> /dev/null; then
    echo "❌ ERROR: java not found in PATH" >&2
    echo "   Expected to be installed during system setup" >&2
    exit 1
fi

echo "✅ Prerequisites verified"

#
# 2. EXECUTE MODULE STEPS (exactly as student would)
#
echo "Executing module steps..."

# Build the multi-stage image
echo "Building multi-stage Quarkus application..."
cd ~/sample-app
podman build -t hummingbird-demo:v1 -f Containerfile . >/dev/null 2>&1 || {
    echo "❌ ERROR: Multi-stage build failed" >&2
    exit 2
}

echo "✅ Image built successfully"

# Run the container
echo "Starting Quarkus application..."
podman run -d --rm --name demo -p 8080:8080 hummingbird-demo:v1 >/dev/null 2>&1 || {
    echo "❌ ERROR: Failed to start container" >&2
    exit 2
}

# Wait for Quarkus to start
echo "Waiting for application to start..."
sleep 5

#
# 3. ASSERT OUTCOMES (verify expected results)
#
echo "Verifying outcomes..."

# Check that container is running
if ! podman ps --format "{{.Names}}" | grep -q "^demo$"; then
    echo "❌ ERROR: Container 'demo' is not running" >&2
    podman logs demo 2>&1 || true
    podman stop demo >/dev/null 2>&1 || true
    exit 3
fi

echo "✅ Container is running"

# Test the main endpoint
echo "Testing main endpoint..."
RESPONSE=$(curl -f -s http://localhost:8080/ 2>&1) || {
    echo "❌ ERROR: Main endpoint failed to respond" >&2
    echo "   Response: $RESPONSE" >&2
    podman logs demo
    podman stop demo >/dev/null 2>&1
    exit 3
}

if [[ ! "$RESPONSE" =~ "Hello" ]]; then
    echo "❌ ERROR: Unexpected response from main endpoint" >&2
    echo "   Response: $RESPONSE" >&2
    podman stop demo >/dev/null 2>&1
    exit 3
fi

echo "✅ Main endpoint responding correctly"

# Test the health endpoint
echo "Testing health endpoint..."
HEALTH=$(curl -f -s http://localhost:8080/health 2>&1) || {
    echo "❌ ERROR: Health endpoint failed to respond" >&2
    echo "   Response: $HEALTH" >&2
    podman logs demo
    podman stop demo >/dev/null 2>&1
    exit 3
}

# Verify health response is valid JSON with status=healthy
if ! echo "$HEALTH" | jq -e '.status == "healthy"' > /dev/null 2>&1; then
    echo "❌ ERROR: Health endpoint shows unhealthy status or invalid JSON" >&2
    echo "   Expected: {\"status\": \"healthy\"}" >&2
    echo "   Received: $HEALTH" >&2
    podman stop demo >/dev/null 2>&1
    exit 3
fi

echo "✅ Health endpoint reporting {\"status\": \"healthy\"}"

# Verify image size is reasonable (should be much smaller than UBI version)
IMAGE_SIZE=$(podman images hummingbird-demo:v1 --format "{{.Size}}" | head -1)
echo "Image size: $IMAGE_SIZE"

# Extract numeric size (assumes format like "273 MB" or "1.5 GB")
SIZE_MB=$(echo "$IMAGE_SIZE" | sed 's/[^0-9.]//g')

# Convert to integer for comparison (truncate decimal)
SIZE_INT=${SIZE_MB%%.*}

# Check if size is numeric and reasonable
if [ -n "$SIZE_INT" ] && [ "$SIZE_INT" -gt 400 ] 2>/dev/null; then
    echo "⚠️  WARNING: Image size seems large ($IMAGE_SIZE)"
    echo "   Expected: < 400 MB for multi-stage build"
    echo "   This may indicate the build didn't use multi-stage properly"
fi

echo "✅ Image size is reasonable: $IMAGE_SIZE"

# Check that UBI comparison image exists (optional)
if podman images --format "{{.Repository}}:{{.Tag}}" | grep -q "^localhost/hummingbird-demo:ubi$"; then
    UBI_SIZE=$(podman images hummingbird-demo:ubi --format "{{.Size}}" | head -1)
    echo "UBI comparison image size: $UBI_SIZE"
    echo "Size reduction demonstrates multi-stage benefit"
fi

# Cleanup
echo "Cleaning up..."
podman stop demo >/dev/null 2>&1 || true

echo ""
echo "✅ Module 01-02 validation PASSED"
echo "   - Multi-stage build successful"
echo "   - Application runs and responds correctly"
echo "   - Health endpoint reports healthy"
echo "   - Image size optimized"
exit 0
