#!/bin/bash
set -e

# Module 01-04: Image Signing & Attestation
# Validation script - fails fast if prerequisites missing or steps fail

# Container registries
HUMMINGBIRD_REGISTRY="quay.io/hummingbird"

echo "=== Validating Module 01-04: Image Signing & Attestation ==="

#
# 1. PREREQUISITE CHECKS (fail fast if environment is broken)
#
echo "Checking prerequisites..."

# Check that prerequisite image exists
if ! podman images --format "{{.Repository}}:{{.Tag}}" | grep -q "^localhost/hummingbird-demo:v1$"; then
    echo "❌ ERROR: hummingbird-demo:v1 not found"
    echo "   Module 01-04 requires the output from Module 01-02"
    echo "   Run: validate-module-01-02.sh or solve-module-01-02.sh"
    exit 1
fi

# Check that SBOM exists (from Module 01-03)
if [ ! -f ~/scanning/hummingbird-demo.spdx ]; then
    echo "❌ ERROR: ~/scanning/hummingbird-demo.spdx not found"
    echo "   Module 01-04 requires the SBOM from Module 01-03"
    echo "   Run: validate-module-01-03.sh or solve-module-01-03.sh"
    exit 1
fi

# Check that cosign is installed
if ! command -v cosign &> /dev/null; then
    echo "❌ ERROR: cosign not found in PATH"
    echo "   Expected to be installed by setup-rhel.sh"
    exit 1
fi

# Check that jq is installed
if ! command -v jq &> /dev/null; then
    echo "❌ ERROR: jq not found in PATH"
    echo "   Expected to be installed during system setup"
    exit 1
fi

# Check for Quay credentials
if [ -z "${QUAY_HOSTNAME:-}" ] || [ -z "${QUAY_USER:-}" ] || [ -z "${QUAY_PASSWORD:-}" ]; then
    echo "❌ ERROR: Quay credentials not available"
    echo "   Required environment variables: QUAY_HOSTNAME, QUAY_USER, QUAY_PASSWORD"
    echo "   These should be injected by the showroom platform"
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
echo "${QUAY_PASSWORD}" | podman login "${QUAY_HOSTNAME}" --username "${QUAY_USER}" --password-stdin || {
    echo "❌ ERROR: Failed to login to Quay"
    echo "   Check credentials: QUAY_HOSTNAME=${QUAY_HOSTNAME}, QUAY_USER=${QUAY_USER}"
    exit 2
}

echo "✅ Quay login successful"

# Tag image for Quay
echo "Tagging image for Quay..."
podman tag hummingbird-demo:v1 ${QUAY_ORG}/hummingbird-demo:v1 || {
    echo "❌ ERROR: Failed to tag image"
    exit 2
}

echo "✅ Image tagged: ${QUAY_ORG}/hummingbird-demo:v1"

# Push image to Quay
echo "Pushing image to Quay..."
podman push ${QUAY_ORG}/hummingbird-demo:v1 || {
    echo "❌ ERROR: Failed to push image to Quay"
    echo "   Check registry permissions and network connectivity"
    exit 2
}

echo "✅ Image pushed to Quay"

# Capture image digest
echo "Capturing image digest..."
IMAGE_DIGEST=$(podman inspect --format='{{.Digest}}' ${QUAY_ORG}/hummingbird-demo:v1)

if [ -z "$IMAGE_DIGEST" ]; then
    echo "❌ ERROR: Failed to capture image digest"
    echo "   The image may not have been pushed successfully"
    exit 2
fi

echo "✅ Image digest: ${IMAGE_DIGEST}"

# Generate cosign key pair
echo "Generating cosign key pair..."
export COSIGN_PASSWORD=""
cosign generate-key-pair --output-key-prefix cosign 2>&1 || {
    echo "❌ ERROR: Failed to generate cosign key pair"
    exit 2
}

if [ ! -f cosign.key ] || [ ! -f cosign.pub ]; then
    echo "❌ ERROR: Cosign keys not created"
    exit 2
fi

echo "✅ Cosign key pair generated"

# Sign the image
echo "Signing image with cosign..."
cosign sign --yes --key cosign.key \
  --tlog-upload=false \
  ${QUAY_ORG}/hummingbird-demo@${IMAGE_DIGEST} 2>&1 || {
    echo "❌ ERROR: Failed to sign image"
    exit 2
}

echo "✅ Image signed successfully"

# Attach SBOM attestation
echo "Attaching SBOM attestation..."
cosign attest --yes --key cosign.key \
  --predicate hummingbird-demo.spdx --type spdxjson \
  --tlog-upload=false \
  ${QUAY_ORG}/hummingbird-demo@${IMAGE_DIGEST} 2>&1 || {
    echo "❌ ERROR: Failed to attach SBOM attestation"
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
    echo "❌ ERROR: Signature verification failed"
    echo "$VERIFY_OUTPUT"
    exit 3
}

if ! echo "$VERIFY_OUTPUT" | grep -q "Verification for"; then
    echo "❌ ERROR: Unexpected signature verification output"
    echo "$VERIFY_OUTPUT"
    exit 3
fi

echo "✅ Signature verification passed"

# Verify the SBOM attestation
echo "Verifying SBOM attestation..."
ATTEST_OUTPUT=$(cosign verify-attestation --key cosign.pub \
  --type spdxjson \
  --insecure-ignore-tlog=true \
  ${QUAY_ORG}/hummingbird-demo@${IMAGE_DIGEST} 2>&1) || {
    echo "❌ ERROR: SBOM attestation verification failed"
    echo "$ATTEST_OUTPUT"
    exit 3
}

if ! echo "$ATTEST_OUTPUT" | grep -q "Verification for"; then
    echo "❌ ERROR: Unexpected attestation verification output"
    echo "$ATTEST_OUTPUT"
    exit 3
fi

echo "✅ SBOM attestation verification passed"

# Verify package count in attestation
echo "Verifying package count in attestation..."
ATTEST_PKG_COUNT=$(echo "$ATTEST_OUTPUT" | jq -r '.payload' | base64 -d | jq '.predicate.packages | length' 2>/dev/null) || {
    echo "❌ ERROR: Failed to extract package count from attestation"
    exit 3
}

# Compare with original SBOM
SBOM_PKG_COUNT=$(jq '.packages | length' hummingbird-demo.spdx 2>/dev/null)

if [ "$ATTEST_PKG_COUNT" != "$SBOM_PKG_COUNT" ]; then
    echo "❌ ERROR: Package count mismatch"
    echo "   Original SBOM: $SBOM_PKG_COUNT packages"
    echo "   Attestation: $ATTEST_PKG_COUNT packages"
    exit 3
fi

echo "✅ Package count matches: $ATTEST_PKG_COUNT packages"

# Download attestation and verify it's complete
echo "Downloading attestation..."
cosign download attestation \
  --output-file downloaded-attestation.json \
  ${QUAY_ORG}/hummingbird-demo@${IMAGE_DIGEST} 2>&1 || {
    echo "❌ ERROR: Failed to download attestation"
    exit 3
}

if [ ! -f downloaded-attestation.json ] || [ ! -s downloaded-attestation.json ]; then
    echo "❌ ERROR: Downloaded attestation is missing or empty"
    exit 3
fi

echo "✅ Attestation downloaded successfully"

# Verify downloaded attestation is valid JSON
if ! jq empty downloaded-attestation.json 2>/dev/null; then
    echo "❌ ERROR: Downloaded attestation is not valid JSON"
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
