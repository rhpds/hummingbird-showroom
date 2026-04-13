#!/bin/bash
set -e

# Module 01-03: Vulnerability Scanning & SBOMs
# Validation script - fails fast if prerequisites missing or steps fail
# Status to stdout, errors to stderr, internal commands suppressed

# Container registries
HUMMINGBIRD_REGISTRY="quay.io/hummingbird"

echo "=== Validating Module 01-03: Vulnerability Scanning & SBOMs ==="

#
# 1. PREREQUISITE CHECKS (fail fast if environment is broken)
#
echo "Checking prerequisites..."

# Check that prerequisite image exists
if ! podman images --format "{{.Repository}}:{{.Tag}}" | grep -q "^localhost/hummingbird-demo:v1$"; then
    echo "❌ ERROR: hummingbird-demo:v1 not found" >&2
    echo "   Module 01-03 requires the output from Module 01-02" >&2
    echo "   Run: validate-module-01-02.sh or solve-module-01-02.sh" >&2
    exit 1
fi

# Check that required tools are installed
if ! command -v grype &> /dev/null; then
    echo "❌ ERROR: grype not found in PATH" >&2
    echo "   Expected to be installed by setup-rhel.sh" >&2
    exit 1
fi

if ! command -v syft &> /dev/null; then
    echo "❌ ERROR: syft not found in PATH" >&2
    echo "   Expected to be installed by setup-rhel.sh" >&2
    exit 1
fi

if ! command -v cosign &> /dev/null; then
    echo "❌ ERROR: cosign not found in PATH" >&2
    echo "   Expected to be installed by setup-rhel.sh" >&2
    exit 1
fi

if ! command -v jq &> /dev/null; then
    echo "❌ ERROR: jq not found in PATH" >&2
    echo "   Expected to be installed during system setup" >&2
    exit 1
fi

# Check that scanning directory can be created
if [ ! -d ~/scanning ]; then
    mkdir -p ~/scanning || {
        echo "❌ ERROR: Cannot create ~/scanning directory" >&2
        exit 1
    }
fi

echo "✅ Prerequisites verified"

#
# 2. EXECUTE MODULE STEPS (exactly as student would)
#
echo "Executing module steps..."

# Change to scanning directory
cd ~/scanning

# Enable podman socket
echo "Enabling podman socket..."
systemctl --user enable --now podman.socket >/dev/null 2>&1 || {
    echo "❌ ERROR: Failed to enable podman socket" >&2
    echo "   This is required for grype and syft to access podman" >&2
    exit 2
}

echo "✅ Podman socket enabled"

# Download Red Hat SBOM (verify registry access and cosign works)
echo "Downloading Red Hat SBOM for openjdk:21-runtime..."
cosign download sbom ${HUMMINGBIRD_REGISTRY}/openjdk:21-runtime > rh-openjdk-sbom.json 2>&1 || {
    echo "❌ ERROR: Failed to download Red Hat SBOM" >&2
    echo "   This may indicate:" >&2
    echo "   - Registry connectivity issues" >&2
    echo "   - cosign not working properly" >&2
    echo "   - SBOM not available for this image" >&2
    exit 2
}

echo "✅ Red Hat SBOM downloaded"

# Scan with grype
echo "Running CVE scan with grype..."
grype hummingbird-demo:v1 2>&1 | tee grype-scan-raw.log | sed 's/\x1b\[[0-9;]*m//g' > grype-scan.log || {
    GRYPE_EXIT=$?
    # Grype returns non-zero if vulnerabilities are found, which is okay
    # Only fail if it's a real error (exit code > 1)
    if [ $GRYPE_EXIT -gt 1 ]; then
        echo "❌ ERROR: Grype scan failed with exit code $GRYPE_EXIT" >&2
        cat grype-scan.log
        exit 2
    fi
}

echo "✅ Grype scan completed"

# Check scan output is valid (either summary format or table format)
# Using cleaned log without ANSI codes for reliable parsing
if ! grep -qE "(Scanned for vulnerabilities|VULNERABILITY.*SEVERITY)" grype-scan.log; then
    echo "❌ ERROR: Grype scan output is incomplete or malformed" >&2
    echo "Expected either summary line or CVE table" >&2
    cat grype-scan.log
    exit 2
fi

# Display scan results
echo "Scan results:"

# Check if we have summary format (no CVEs found)
if grep -q "Scanned for vulnerabilities" grype-scan.log; then
    grep -A 2 "Scanned for vulnerabilities" grype-scan.log || true
    VULN_COUNT=$(grep -oP 'Scanned for vulnerabilities\s+\[\K[0-9]+' grype-scan.log || echo "0")
    echo "✅ No vulnerabilities found in scan (0 CVEs)"

# Or table format (CVEs found)
elif grep -q "VULNERABILITY.*SEVERITY" grype-scan.log; then
    # Count vulnerabilities from table (each line after header is a CVE)
    VULN_COUNT=$(grep -c "CVE-" grype-scan.log || echo "0")
    echo ""
    echo "⚠️  WARNING: Found $VULN_COUNT vulnerability entries in hummingbird-demo:v1"
    echo "   Module notes: Hardened images typically have 0 or near-zero CVEs at ship time"
    echo "   This may indicate dependencies with known issues (e.g., glibc, systemd-libs)"
    echo "   This is NOT a validation failure - just documenting current state"
    echo ""
    echo "Sample of findings:"
    head -20 grype-scan.log

    # Show unique CVEs
    UNIQUE_CVES=$(grep -oP 'CVE-[0-9-]+' grype-scan.log | sort -u | wc -l)
    echo ""
    echo "Unique CVEs: $UNIQUE_CVES"
    echo "Total entries: $VULN_COUNT (some CVEs affect multiple packages)"
else
    echo "⚠️  WARNING: Unexpected grype output format"
fi

# Generate SBOM with syft (table format for verification)
echo "Generating SBOM (table format for verification)..."
syft hummingbird-demo:v1 -o table > sbom-table.txt 2>&1 || {
    echo "❌ ERROR: SBOM table generation failed" >&2
    cat sbom-table.txt
    exit 2
}

echo "✅ SBOM table generated"

# Generate SBOM in SPDX-JSON format (for compliance)
echo "Generating SBOM (SPDX-JSON format)..."
echo "Running: syft hummingbird-demo:v1 -o spdx-json=hummingbird-demo.spdx"
echo "Working directory: $(pwd)"

syft hummingbird-demo:v1 -o spdx-json=hummingbird-demo.spdx 2>&1 | tee sbom-generation.log || {
    SYFT_EXIT=$?
    echo "❌ ERROR: SBOM generation failed with exit code $SYFT_EXIT" >&2
    echo "Command output:" >&2
    cat sbom-generation.log
    echo "" >&2
    echo "Debug info:" >&2
    echo "  Current directory: $(pwd)" >&2
    echo "  Image exists: $(podman images hummingbird-demo:v1 --format '{{.Repository}}:{{.Tag}}')" >&2
    echo "  syft version: $(syft version | head -3)" >&2
    exit 2
}

echo "✅ SBOM generated in SPDX-JSON format"
echo "DEBUG: Verifying file was created..."
ls -la hummingbird-demo.spdx || {
    echo "❌ ERROR: SBOM file not found after generation!" >&2
    echo "Files in current directory:" >&2
    ls -la
    exit 2
}

#
# 3. ASSERT OUTCOMES (verify expected results)
#
echo "Verifying outcomes..."

# Verify SBOM file exists
if [ ! -f hummingbird-demo.spdx ]; then
    echo "❌ ERROR: SBOM file not created" >&2
    exit 3
fi

echo "✅ SBOM file exists"

# Verify SBOM is valid JSON
if ! jq empty hummingbird-demo.spdx 2>/dev/null; then
    echo "❌ ERROR: SBOM is not valid JSON" >&2
    exit 3
fi

echo "✅ SBOM is valid JSON"

# Verify SBOM contains expected package count
PACKAGE_COUNT=$(jq '.packages | length' hummingbird-demo.spdx 2>/dev/null)

if [ -z "$PACKAGE_COUNT" ]; then
    echo "❌ ERROR: Cannot extract package count from SBOM" >&2
    exit 3
fi

# Expected range: 150-200 packages (Quarkus + OpenJDK + system libraries)
# Module 01-03 shows ~169-170 packages as typical output
if [ "$PACKAGE_COUNT" -lt 150 ] || [ "$PACKAGE_COUNT" -gt 200 ]; then
    echo "❌ ERROR: Unexpected package count: $PACKAGE_COUNT" >&2
    echo "   Expected: 150-200 packages" >&2
    echo "   Module shows ~169-170 as typical" >&2
    echo "   This may indicate SBOM generation is incomplete" >&2
    exit 3
fi

echo "✅ Package count: $PACKAGE_COUNT (within expected range 150-200)"

# Verify SBOM contains expected metadata
SBOM_NAME=$(jq -r '.name' hummingbird-demo.spdx 2>/dev/null)
if [ -z "$SBOM_NAME" ]; then
    echo "❌ ERROR: SBOM missing 'name' field" >&2
    exit 3
fi

echo "✅ SBOM metadata complete (name: $SBOM_NAME)"

# Verify Red Hat SBOM was downloaded
if [ ! -f rh-openjdk-sbom.json ] || [ ! -s rh-openjdk-sbom.json ]; then
    echo "❌ ERROR: Red Hat SBOM file is missing or empty" >&2
    exit 3
fi

echo "✅ Red Hat SBOM downloaded and non-empty"

# Compare with UBI image if it exists
if podman images --format "{{.Repository}}:{{.Tag}}" | grep -q "^localhost/hummingbird-demo:ubi$"; then
    echo ""
    echo "Comparing with UBI image..."

    # Scan UBI image
    grype hummingbird-demo:ubi --only-fixed > grype-ubi-scan.log 2>&1 || true

    echo "UBI image scan summary:"
    grep -A 2 "Scanned for vulnerabilities" grype-ubi-scan.log 2>/dev/null || echo "UBI scan completed"

    echo ""
    echo "Note: Hardened images typically show 0 or near-zero CVEs"
    echo "      UBI images may show 15-30+ CVEs even when recently built"
fi

cd ~

echo ""
echo "✅ Module 01-03 validation PASSED"
echo "   - Grype CVE scanning operational"
echo "   - Syft SBOM generation working"
echo "   - SBOM contains $PACKAGE_COUNT packages"
echo "   - Red Hat SBOM download successful"
echo "   - Files created in ~/scanning/"
exit 0
