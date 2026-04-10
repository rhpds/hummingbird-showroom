#!/bin/bash
set -e

# Module 01-04: Image Signing & Attestation
# Validation script - fails fast if prerequisites missing or steps fail
# Status to stdout, errors to stderr, internal commands suppressed

# Container registries
HUMMINGBIRD_REGISTRY="quay.io/hummingbird"

echo "=== Validating Module 01-04: Image Signing & Attestation ==="

#
# 1. PREREQUISITE CHECKS (fail fast if environment is broken)
#
echo "Checking prerequisites..."

# Check that prerequisite image exists
if ! podman images --format "{{.Repository}}:{{.Tag}}" | grep -q "^localhost/hummingbird-demo:v1$"; then
    echo "❌ ERROR: hummingbird-demo:v1 not found" >&2
    echo "   Module 01-04 requires the output from Module 01-02" >&2
    echo "   Run: validate-module-01-02.sh or solve-module-01-02.sh" >&2
    exit 1
fi

# Check that SBOM exists (from Module 01-03)
SBOM_PATH="${HOME}/scanning/hummingbird-demo.spdx"
if [ ! -f "$SBOM_PATH" ]; then
    echo "❌ ERROR: $SBOM_PATH not found" >&2
    echo "   Module 01-04 requires the SBOM from Module 01-03" >&2
    echo "   Run: validate-module-01-03.sh or solve-module-01-03.sh" >&2
    echo "" >&2
    echo "Debug info:" >&2
    echo "  Current user: $(whoami)" >&2
    echo "  HOME: $HOME" >&2
    echo "  Looking for: $SBOM_PATH" >&2
    echo "  Current directory: $(pwd)" >&2
    echo "  Directory exists: $([ -d "${HOME}/scanning" ] && echo "yes" || echo "no")" >&2
    if [ -d "${HOME}/scanning" ]; then
        echo "  Files in ~/scanning:" >&2
        ls -la "${HOME}/scanning/" 2>&1 | head -10
    else
        echo "  ~/scanning directory does not exist!" >&2
        echo "  This means validate-module-01-03.sh did not complete successfully" >&2
    fi
    exit 1
fi

echo "✅ SBOM file found: $SBOM_PATH"

# Check that cosign is installed
if ! command -v cosign &> /dev/null; then
    echo "❌ ERROR: cosign not found in PATH" >&2
    echo "   Expected to be installed by setup-rhel.sh" >&2
    exit 1
fi

# Check that jq is installed
if ! command -v jq &> /dev/null; then
    echo "❌ ERROR: jq not found in PATH" >&2
    echo "   Expected to be installed during system setup" >&2
    exit 1
fi

# Check for Quay credentials
if [ -z "${QUAY_HOSTNAME:-}" ] || [ -z "${QUAY_USER:-}" ] || [ -z "${QUAY_PASSWORD:-}" ]; then
    echo "❌ ERROR: Quay credentials not available" >&2
    echo "   Required environment variables: QUAY_HOSTNAME, QUAY_USER, QUAY_PASSWORD" >&2
    echo "   These should be injected by the showroom platform" >&2
    exit 1
fi

export QUAY_ORG="${QUAY_HOSTNAME}/${QUAY_USER}"

echo "✅ Prerequisites verified"
echo "   - hummingbird-demo:v1 exists"
echo "   - SBOM file exists"
echo "   - Quay credentials available: ${QUAY_ORG}"

#
# 2. EXECUTE MODULE STEPS (exactly as student would)
#
echo "Executing module steps..."

# Change to scanning directory (where SBOM is located)
cd ~/scanning

# Login to Quay
echo "Logging into Quay registry..."
echo "${QUAY_PASSWORD}" | podman login "${QUAY_HOSTNAME}" --username "${QUAY_USER}" --password-stdin >/dev/null 2>&1 || {
    echo "❌ ERROR: Failed to login to Quay" >&2
    echo "   Check credentials: QUAY_HOSTNAME=${QUAY_HOSTNAME}, QUAY_USER=${QUAY_USER}" >&2
    exit 2
}

echo "✅ Quay login successful"

# Tag image for Quay
echo "Tagging image for Quay..."
podman tag hummingbird-demo:v1 ${QUAY_ORG}/hummingbird-demo:v1 >/dev/null 2>&1 || {
    echo "❌ ERROR: Failed to tag image" >&2
    exit 2
}

echo "✅ Image tagged: ${QUAY_ORG}/hummingbird-demo:v1"

# Push image to Quay
echo "Pushing image to Quay..."
podman push ${QUAY_ORG}/hummingbird-demo:v1 >/dev/null 2>&1 || {
    echo "❌ ERROR: Failed to push image to Quay" >&2
    echo "   Check registry permissions and network connectivity" >&2
    exit 2
}

echo "✅ Image pushed to Quay"

# Capture image digest
echo "Capturing image digest..."
IMAGE_DIGEST=$(podman inspect --format='{{.Digest}}' ${QUAY_ORG}/hummingbird-demo:v1)

if [ -z "$IMAGE_DIGEST" ]; then
    echo "❌ ERROR: Failed to capture image digest" >&2
    echo "   The image may not have been pushed successfully" >&2
    exit 2
fi

echo "✅ Image digest: ${IMAGE_DIGEST}"

# Generate cosign key pair
echo "Generating cosign key pair..."
export COSIGN_PASSWORD=""
cosign generate-key-pair --output-key-prefix cosign >/dev/null 2>&1 || {
    echo "❌ ERROR: Failed to generate cosign key pair" >&2
    exit 2
}

if [ ! -f cosign.key ] || [ ! -f cosign.pub ]; then
    echo "❌ ERROR: Cosign keys not created" >&2
    exit 2
fi

echo "✅ Cosign key pair generated"

# Sign the image
echo "Signing image with cosign..."
cosign sign --yes --key cosign.key \
  --tlog-upload=false \
  ${QUAY_ORG}/hummingbird-demo@${IMAGE_DIGEST} >/dev/null 2>&1 || {
    echo "❌ ERROR: Failed to sign image" >&2
    exit 2
}

echo "✅ Image signed successfully"

# Attach SBOM attestation
echo "Attaching SBOM attestation..."
cosign attest --yes --key cosign.key \
  --predicate "$SBOM_PATH" --type spdxjson \
  --tlog-upload=false \
  ${QUAY_ORG}/hummingbird-demo@${IMAGE_DIGEST} >/dev/null 2>&1 || {
    echo "❌ ERROR: Failed to attach SBOM attestation" >&2
    exit 2
}

echo "✅ SBOM attestation attached"

#
# 3. ASSERT OUTCOMES (verify expected results)
#
echo "Verifying outcomes..."

# Verify the signature
echo "Verifying image signature..."
VERIFY_OUTPUT=$(cosign verify --key cosign.pub \
  --insecure-ignore-tlog=true \
  ${QUAY_ORG}/hummingbird-demo@${IMAGE_DIGEST} 2>&1) || {
    echo "❌ ERROR: Signature verification failed" >&2
    echo "Output:" >&2
    echo "$VERIFY_OUTPUT" >&2
    exit 3
}

echo "✅ Signature verification passed"

# Verify the SBOM attestation
echo "Verifying SBOM attestation..."
ATTEST_OUTPUT=$(cosign verify-attestation --key cosign.pub \
  --type spdxjson \
  --insecure-ignore-tlog=true \
  ${QUAY_ORG}/hummingbird-demo@${IMAGE_DIGEST} 2>&1) || {
    echo "❌ ERROR: SBOM attestation verification failed" >&2
    echo "Output:" >&2
    echo "$ATTEST_OUTPUT" >&2
    exit 3
}

echo "✅ SBOM attestation verification passed"

# Verify package count in attestation
echo "Verifying package count in attestation..."

# Extract payload, decode base64, parse JSON - with proper error handling
PAYLOAD=$(echo "$ATTEST_OUTPUT" | jq -r '.payload' 2>&1)
if [ $? -ne 0 ] || [ -z "$PAYLOAD" ]; then
    echo "❌ ERROR: Failed to extract payload from attestation" >&2
    echo "   jq error: $PAYLOAD" >&2
    echo "   Attestation output may not be valid JSON" >&2
    exit 3
fi

DECODED=$(echo "$PAYLOAD" | base64 -d 2>&1)
if [ $? -ne 0 ]; then
    echo "❌ ERROR: Failed to decode base64 payload" >&2
    echo "   Error: $DECODED" >&2
    exit 3
fi

ATTEST_PKG_COUNT=$(echo "$DECODED" | jq '.predicate.packages | length' 2>&1)
if [ $? -ne 0 ] || [ -z "$ATTEST_PKG_COUNT" ]; then
    echo "❌ ERROR: Failed to parse SBOM from attestation" >&2
    echo "   jq error: $ATTEST_PKG_COUNT" >&2
    echo "   Decoded payload:" >&2
    echo "$DECODED" | head -20 >&2
    exit 3
fi

# Compare with original SBOM
SBOM_PKG_COUNT=$(jq '.packages | length' "$SBOM_PATH" 2>&1)
if [ $? -ne 0 ] || [ -z "$SBOM_PKG_COUNT" ]; then
    echo "❌ ERROR: Failed to parse original SBOM" >&2
    echo "   jq error: $SBOM_PKG_COUNT" >&2
    exit 3
fi

if [ "$ATTEST_PKG_COUNT" != "$SBOM_PKG_COUNT" ]; then
    echo "❌ ERROR: Package count mismatch" >&2
    echo "   Original SBOM: $SBOM_PKG_COUNT packages" >&2
    echo "   Attestation: $ATTEST_PKG_COUNT packages" >&2
    exit 3
fi

echo "✅ Package count matches: $ATTEST_PKG_COUNT packages"

# Download attestation and verify it's complete
echo "Downloading attestation..."
cosign download attestation \
  --output-file downloaded-attestation.json \
  ${QUAY_ORG}/hummingbird-demo@${IMAGE_DIGEST} >/dev/null 2>&1 || {
    echo "❌ ERROR: Failed to download attestation" >&2
    exit 3
}

if [ ! -f downloaded-attestation.json ] || [ ! -s downloaded-attestation.json ]; then
    echo "❌ ERROR: Downloaded attestation is missing or empty" >&2
    exit 3
fi

echo "✅ Attestation downloaded successfully"

# Verify downloaded attestation is valid JSON
if ! jq empty downloaded-attestation.json 2>/dev/null; then
    echo "❌ ERROR: Downloaded attestation is not valid JSON" >&2
    exit 3
fi

echo "✅ Downloaded attestation is valid JSON"

# Test verification of Red Hat signed images (read-only verification)
echo ""
echo "Verifying Red Hat signed image (openjdk:21-runtime)..."
RH_VERIFY=$(cosign verify --insecure-ignore-tlog \
  --key https://catalog.hummingbird-project.io/cosign.pub \
  ${HUMMINGBIRD_REGISTRY}/openjdk:21-runtime 2>&1) || {
    echo "⚠️  WARNING: Red Hat image verification failed"
    echo "   This may indicate registry connectivity issues"
}

if echo "$RH_VERIFY" | grep -q "Verification for"; then
    echo "✅ Red Hat image signature verified"
else
    echo "⚠️  WARNING: Could not verify Red Hat image signature"
fi

cd ~

echo ""
echo "✅ Module 01-04 validation PASSED"
echo "   - Image pushed to Quay: ${QUAY_ORG}/hummingbird-demo:v1"
echo "   - Image signed with cosign"
echo "   - Signature verified successfully"
echo "   - SBOM attestation attached and verified"
echo "   - Attestation contains $ATTEST_PKG_COUNT packages"
echo "   - Files created in ~/scanning/"
exit 0
