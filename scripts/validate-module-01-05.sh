#!/bin/bash
set -e

# Module 01-05: Custom Security Configurations
# Validation script - fails fast if prerequisites missing or steps fail
#
# Note: FIPS testing section expects different exit codes:
# - Non-FIPS image: test-fips.py returns exit code 2 (expected failure)
# - FIPS image: test-fips.py returns exit code 0 (expected success)

# Container registries
# HUMMINGBIRD_REGISTRY="quay.io/hummingbird-hatchling"
HUMMINGBIRD_REGISTRY="quay.io/hummingbird"



echo "=== Checking prerequisites ==="

# Check that setup files exist
if [ ! -f ~/webserver/Caddyfile ]; then
    echo "❌ ERROR: ~/webserver/Caddyfile not found"
    echo "   Expected to be created by setup-rhel.sh"
    exit 1
fi

if [ ! -f ~/fips/test-fips.py ]; then
    echo "❌ ERROR: ~/fips/test-fips.py not found"
    echo "   Expected to be created by setup-rhel.sh"
    exit 1
fi

echo "✅ Prerequisites verified"

echo "=== Step 1: Certificate Authority Bundle Management ==="

# Ensure webserver directory exists
mkdir -p ~/webserver

echo "Using pre-created Caddyfile..."
echo "Caddyfile and webserver files already created by setup script"

echo "Creating SSL Containerfile..."
cat > ~/webserver/Containerfile << EOF
FROM ${HUMMINGBIRD_REGISTRY}/caddy:latest
COPY Caddyfile /etc/caddy/Caddyfile

COPY index.html /usr/share/caddy/
EOF

echo "Building and running SSL-enabled Caddy server..."
podman build -t caddy:ssl -f ~/webserver/Containerfile ~/webserver
podman run --replace -d --name caddy-ssl -p 8443:8443 -v ~/webserver:/usr/share/caddy:ro,Z caddy:ssl
echo "✅ SSL-enabled Caddy server started"

# Give container time to start and generate certificates
sleep 5

echo "Testing SSL connection (this will fail due to self-signed cert)..."
podman run --net=host --rm -it ${HUMMINGBIRD_REGISTRY}/curl:latest https://localhost:8443 || echo "Expected failure due to self-signed certificate"

echo "Extracting certificate authority files..."
podman cp caddy-ssl:/data/caddy/pki/authorities/local/root.key .
podman cp caddy-ssl:/data/caddy/pki/authorities/local/root.crt .
cat root.key root.crt > ca.pem
echo "✅ Certificate authority files extracted"

echo "Creating Containerfile for curl with custom CA..."
cat > ~/Containerfile.pem << EOF
FROM ${HUMMINGBIRD_REGISTRY}/curl:latest-builder as builder

# Copy the certificate to the image
COPY ca.pem /tmp/

# Temporarily switch to root to add the CA certificate to the trust store
USER root
RUN trust anchor /tmp/ca.pem
USER \${CONTAINER_DEFAULT_USER}

# Runtime stage:
# Copy the trust store from the builder image to the runtime image
FROM ${HUMMINGBIRD_REGISTRY}/curl:latest
COPY --from=builder /etc/pki/ca-trust/extracted /etc/pki/ca-trust/extracted
EOF

echo "Building curl image with custom CA trust store..."
podman build -t curl:local-ca -f ~/Containerfile.pem ~ || {
    echo "❌ ERROR: Failed to build curl image with custom CA"
    podman stop caddy-ssl 2>/dev/null || true
    exit 2
}

echo "✅ curl:local-ca image built successfully"

# Test SSL connection with custom CA (should succeed)
echo "Testing SSL connection with custom CA (should succeed)..."
SSL_RESPONSE=$(podman run --net=host --rm curl:local-ca https://localhost:8443 2>&1)
SSL_EXIT=$?

if [ $SSL_EXIT -ne 0 ]; then
    echo "❌ ERROR: curl with custom CA failed (exit code $SSL_EXIT)"
    echo "   This should have succeeded with the custom CA trust store"
    echo "   Response:"
    echo "$SSL_RESPONSE"
    echo "Caddy logs:"
    podman logs caddy-ssl 2>&1 | tail -20
    podman stop caddy-ssl
    exit 3
fi

# Verify we got HTML content back (index.html)
if [[ ! "$SSL_RESPONSE" =~ "html" ]] && [[ ! "$SSL_RESPONSE" =~ "HTML" ]]; then
    echo "❌ ERROR: Unexpected response from HTTPS endpoint"
    echo "   Expected HTML content, got:"
    echo "$SSL_RESPONSE"
    podman stop caddy-ssl
    exit 3
fi

echo "✅ SSL connection successful with custom CA - received HTML content"

echo "Stopping SSL Caddy server..."
podman stop caddy-ssl

echo "=== Step 2: FIPS Variants Testing ==="

echo "=== Step 7: Check FIPS mode on host ==="
echo "Checking if host is in FIPS mode..."
cat /proc/sys/crypto/fips_enabled
echo "A value of 0 means the host is NOT in FIPS mode"
echo "Note: Container FIPS enforcement operates independently of host FIPS mode"
echo ""

# Create FIPS testing directory and copy test file
mkdir -p ~/fips
if [ ! -f ~/fips/test-fips.py ]; then
    if [ -f "$(dirname "$0")/test-fips.py" ]; then
        echo "Copying test-fips.py to ~/fips/ directory..."
        cp "$(dirname "$0")/test-fips.py" ~/fips/ || echo "WARNING: Could not copy test-fips.py, assuming it exists"
    else
        echo "WARNING: test-fips.py not found, assuming it exists in ~/fips/"
    fi
fi

echo "Creating standard Python Containerfile..."
cat > ~/fips/Containerfile << EOF
FROM ${HUMMINGBIRD_REGISTRY}/python:3.14

COPY test-fips.py .

# Switch back to the default user to install and run the application
USER \${CONTAINER_DEFAULT_USER}

# Appropriately set the stop signal for the python interpreter executed as PID 1
STOPSIGNAL SIGINT
ENTRYPOINT ["python", "./test-fips.py"]
EOF

echo "Building and testing standard Python image..."
podman build -t fips:no -f ~/fips/Containerfile ~/fips || {
    echo "❌ ERROR: Failed to build non-FIPS Python image"
    exit 2
}

echo "✅ Non-FIPS image built successfully"

echo "Running FIPS test with standard image (expecting NOT FIPS CAPABLE):"
# Capture output and strip ANSI color codes for reliable parsing
FIPS_NO_OUTPUT=$(podman run --rm fips:no 2>&1 | sed 's/\x1b\[[0-9;]*m//g')

# Check for expected text markers (without Unicode symbols, ANSI codes stripped)
if ! echo "$FIPS_NO_OUTPUT" | grep -q "FIPS provider: not active"; then
    echo "❌ ERROR: Expected 'FIPS provider: not active' in output"
    echo "   Got:"
    echo "$FIPS_NO_OUTPUT"
    exit 3
fi

if ! echo "$FIPS_NO_OUTPUT" | grep -q "NOT FIPS CAPABLE"; then
    echo "❌ ERROR: Expected 'NOT FIPS CAPABLE' in output"
    echo "   Got:"
    echo "$FIPS_NO_OUTPUT"
    exit 3
fi

# Non-FIPS should show FAIL for algorithm blocking (algorithms are NOT blocked)
if ! echo "$FIPS_NO_OUTPUT" | grep -q "FAIL - Disallowed Algorithms Blocked"; then
    echo "❌ ERROR: Expected 'FAIL - Disallowed Algorithms Blocked' in output"
    echo "   Got:"
    echo "$FIPS_NO_OUTPUT"
    exit 3
fi

echo "✅ Non-FIPS image shows expected output: NOT FIPS CAPABLE"

echo "Creating FIPS-enabled Python Containerfile..."
cat > ~/fips/Containerfile.fips << EOF
FROM ${HUMMINGBIRD_REGISTRY}/python:3.14-fips

COPY test-fips.py .

# Switch back to the default user to install and run the application
USER \${CONTAINER_DEFAULT_USER}

# Appropriately set the stop signal for the python interpreter executed as PID 1
STOPSIGNAL SIGINT
ENTRYPOINT ["python", "./test-fips.py"]
EOF

echo "Building and testing FIPS-enabled Python image..."
podman build -t fips:yes -f ~/fips/Containerfile.fips ~/fips || {
    echo "❌ ERROR: Failed to build FIPS Python image"
    exit 2
}

echo "✅ FIPS image built successfully"

echo "Running FIPS test with FIPS-enabled image (expecting FIPS CAPABLE):"
# Capture output and strip ANSI color codes for reliable parsing
FIPS_YES_OUTPUT=$(podman run --rm fips:yes 2>&1 | sed 's/\x1b\[[0-9;]*m//g')

# Check for expected text markers (without Unicode symbols, ANSI codes stripped)
if ! echo "$FIPS_YES_OUTPUT" | grep -q "FIPS provider: active"; then
    echo "❌ ERROR: Expected 'FIPS provider: active' in output"
    echo "   Got:"
    echo "$FIPS_YES_OUTPUT"
    exit 3
fi

if ! echo "$FIPS_YES_OUTPUT" | grep -q "FIPS CAPABLE"; then
    echo "❌ ERROR: Expected 'FIPS CAPABLE' in output"
    echo "   Got:"
    echo "$FIPS_YES_OUTPUT"
    exit 3
fi

# FIPS should show PASS for algorithm blocking (algorithms ARE blocked)
if ! echo "$FIPS_YES_OUTPUT" | grep -q "PASS - Disallowed Algorithms Blocked"; then
    echo "❌ ERROR: Expected 'PASS - Disallowed Algorithms Blocked' in output"
    echo "   This indicates FIPS enforcement is not working"
    echo "   Got:"
    echo "$FIPS_YES_OUTPUT"
    exit 3
fi

echo "✅ FIPS image shows expected output: FIPS CAPABLE"

echo "=== Cleanup ==="

echo "Stopping and removing containers..."
podman stop caddy-ssl 2>/dev/null || echo "Caddy SSL container already stopped"
podman rm caddy-ssl 2>/dev/null || echo "Caddy SSL container already removed"

echo "=== Summary ==="
echo "✅ Certificate Authority bundle management completed"
echo "✅ FIPS variants testing completed"
echo ""
echo "=== Module 01-05 validation completed successfully! ==="
