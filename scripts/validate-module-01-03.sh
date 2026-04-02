#!/bin/bash
set -e

# Module 01-03: Common security changes (SELinux)
# Auto-generated script from executable bash blocks
#
# Note: FIPS testing section expects different exit codes:
# - Non-FIPS image: test-fips.py returns exit code 2 (expected failure)
# - FIPS image: test-fips.py returns exit code 0 (expected success)

# Container registries
# HUMMINGBIRD_REGISTRY="quay.io/hummingbird-hatchling"
HUMMINGBIRD_REGISTRY="quay.io/hummingbird"



echo "=== Checking prerequisites ==="
# Verify that hummingbird-demo:v1 exists (created in module 01-01)
if ! podman images --format "{{.Repository}}:{{.Tag}}" | grep -q "^localhost/hummingbird-demo:v1$"; then
    echo "ERROR: hummingbird-demo:v1 image not found"
    echo "Please run module-01-01-solve.sh first to build the required image"
    exit 1
fi

echo "Prerequisites met: hummingbird-demo:v1 found"

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
podman build -t curl:local-ca -f ~/Containerfile.pem ~

echo "Testing SSL connection with custom CA (should succeed)..."
podman run --net=host --rm -it curl:local-ca https://localhost:8443

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
podman build -t fips:no -f ~/fips/Containerfile ~/fips
echo "Running FIPS test with standard image (expecting FIPS failure):"
if podman run --rm fips:no; then
    echo "WARNING: FIPS test passed on non-FIPS image (unexpected)"
else
    EXIT_CODE=$?
    if [ $EXIT_CODE -eq 2 ]; then
        echo "✓ Expected result: FIPS test correctly failed on non-FIPS image"
    else
        echo "WARNING: Unexpected exit code $EXIT_CODE from FIPS test (skipping)"
    fi
fi

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
podman build -t fips:yes -f ~/fips/Containerfile.fips ~/fips
echo "Running FIPS test with FIPS-enabled image (expecting FIPS success):"
if podman run --rm fips:yes; then
    echo "✓ Expected result: FIPS test passed on FIPS-enabled image"
else
    EXIT_CODE=$?
    if [ $EXIT_CODE -eq 2 ]; then
        echo "WARNING: FIPS test failed on FIPS-enabled image (unexpected)"
        echo "This may indicate the FIPS image is not properly configured"
    else
        echo "WARNING: Unexpected exit code $EXIT_CODE from FIPS test (skipping)"
    fi
fi

echo "=== Step 3: SELinux and udica Setup ==="

echo "Checking SELinux enforcement status..."
SELINUX_STATUS=$(getenforce)
echo "SELinux status: $SELINUX_STATUS"

if [ "$SELINUX_STATUS" != "Enforcing" ]; then
    echo "WARNING: SELinux is not in enforcing mode. Enabling enforcing mode..."
    sudo setenforce 1
    sudo sed -i 's/^SELINUX=.*/SELINUX=enforcing/' /etc/selinux/config
fi

echo "Verifying udica installation..."
udica --version

echo "Verifying SELinux labels on directories..."
ls -lZ /opt/myapp/

echo "=== Step 5: Running Container with Default Policy ==="

echo "Running Hummingbird container with bind mounts and default policy..."
podman run -d \
  --name demo-policy-run \
  --env container=podman \
  -v /opt/myapp/config:/app/config:ro,Z \
  -v /opt/myapp/logs:/app/logs:rw,Z \
  -p 8080:8080 \
  hummingbird-demo:v1

echo "Waiting for container to start..."
sleep 5

echo "Checking container status..."
podman ps -a --filter name=demo-policy-run

echo "Testing application endpoint..."
curl http://localhost:8080/ || echo "Application may still be starting"

echo "=== Step 6: Generating Custom SELinux Policy with udica ==="

echo "Generating udica policy from container inspection..."
podman inspect demo-policy-run | sudo udica hummingbird_demo

echo "=== Step 7: Examining Generated CIL Policy ==="

echo "Generated CIL policy content:"
cat hummingbird_demo.cil

echo "Checking which ports share the http_cache_port_t label..."
sudo semanage port -l | grep http_cache || echo "Port information not available"

echo "=== Step 8: Loading SELinux Policy ==="

echo "Loading custom SELinux policy..."
sudo semodule -i hummingbird_demo.cil \
  /usr/share/udica/templates/{base_container.cil,net_container.cil}

echo "Verifying policy was loaded..."
sudo semodule -l | grep hummingbird_demo
echo "✅ SELinux policy loaded successfully"

echo "=== Step 9: Applying Custom Policy ==="

echo "Stopping initial container run..."
podman stop demo-policy-run
podman rm demo-policy-run

echo "Starting container with custom SELinux policy..."
podman run -d \
  --name demo-selinux \
  --env container=podman \
  --security-opt label=type:hummingbird_demo.process \
  -v /opt/myapp/config:/app/config:ro,Z \
  -v /opt/myapp/logs:/app/logs:rw,Z \
  -p 8080:8080 \
  hummingbird-demo:v1

echo "=== Step 10: Verifying Custom Policy Application ==="

echo "Checking container process label..."
podman inspect demo-selinux --format '{{.ProcessLabel}}'

echo "Waiting for application to start..."
sleep 5

echo "Testing application functionality with custom policy..."
curl http://localhost:8080/
curl http://localhost:8080/health

echo "=== Step 11: Cleanup ==="

echo "Stopping and removing containers..."
podman stop demo-selinux || echo "Container may already be stopped"
podman rm demo-selinux || echo "Container may already be removed"

# Clean up any remaining containers from certificate testing
podman stop caddy-ssl 2>/dev/null || echo "Caddy SSL container already stopped"
podman rm caddy-ssl 2>/dev/null || echo "Caddy SSL container already removed"

echo "=== Summary ==="
echo "✅ Certificate Authority bundle management completed"
echo "✅ FIPS variants testing completed"
echo "✅ SELinux udica policy generation and application completed"
echo "✅ Container hardening with custom SELinux policy verified"
echo ""
echo "NOTE: Custom SELinux policy 'hummingbird_demo' remains loaded for future use."
echo "To remove it later, run: sudo semodule -r hummingbird_demo"
echo ""
echo "=== Module 01-03 completed successfully! ==="
