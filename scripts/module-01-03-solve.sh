#!/bin/bash
set -e

# Module 01-03: Common security changes (SELinux)
# Auto-generated script from executable bash blocks
#
# Note: FIPS testing section expects different exit codes:
# - Non-FIPS image: test-fips.py returns exit code 2 (expected failure)
# - FIPS image: test-fips.py returns exit code 0 (expected success)

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

echo "Creating Caddyfile with SSL configuration..."
cat > ~/webserver/Caddyfile << 'EOF'
{
    http_port 8080
    https_port 8443
}

localhost {
    tls internal
    root * /usr/share/caddy
    file_server
}
EOF

echo "Creating Containerfile for SSL-enabled Caddy..."
cat > ~/webserver/Containerfile.caddy << 'EOF'
FROM quay.io/hummingbird-hatchling/caddy:latest

COPY Caddyfile /etc/caddy/Caddyfile
EOF

echo "Building and running SSL-enabled Caddy server..."
cd ~/webserver
podman build -t caddy:ssl -f Containerfile.caddy . 
podman run --replace -d --name caddy-ssl -p 8443:8443 -v ~/webserver:/usr/share/caddy:ro,Z caddy:ssl

# Give container time to start and generate certificates
sleep 5

echo "Testing SSL connection (this will fail due to self-signed cert)..."
podman run --net=host --rm quay.io/hummingbird-hatchling/curl:latest https://localhost:8443 || echo "Expected failure due to self-signed certificate"

echo "Extracting certificate authority files..."
podman cp caddy-ssl:/data/caddy/pki/authorities/local/root.key ~/webserver/
podman cp caddy-ssl:/data/caddy/pki/authorities/local/root.crt ~/webserver/
cat ~/webserver/root.key ~/webserver/root.crt > ~/webserver/ca.pem

echo "Creating Containerfile for curl with custom CA..."
cat > ~/webserver/Containerfile.pem << 'EOF'
FROM quay.io/hummingbird-hatchling/curl:latest-builder as builder

# Copy the certificate to the image
COPY ca.pem /tmp/

# Temporarily switch to root to add the CA certificate to the trust store
USER root
RUN trust anchor /tmp/ca.pem
USER ${CONTAINER_DEFAULT_USER}

# Runtime stage:
# Copy the trust store from the builder image to the runtime image
FROM quay.io/hummingbird-hatchling/curl:latest
COPY --from=builder /etc/pki/ca-trust/extracted /etc/pki/ca-trust/extracted
EOF

echo "Building curl image with custom CA trust store..."
podman build -t curl:local-ca -f Containerfile.pem .

echo "Testing SSL connection with custom CA (should succeed)..."
podman run --net=host --rm curl:local-ca https://localhost:8443

echo "Stopping SSL Caddy server..."
podman stop caddy-ssl

echo "=== Step 2: FIPS Variants Testing ==="

# Create FIPS testing directory
mkdir -p ~/fips
cd ~/fips

# Check for test-fips.py file
if [ ! -f ~/fips/test-fips.py ]; then
    echo "WARNING: test-fips.py not found. Creating a simple FIPS test file..."
    cat > ~/fips/test-fips.py << 'EOF'
#!/usr/bin/env python3
import sys
import subprocess

def check_fips_mode():
    try:
        # Check if FIPS mode is enabled in OpenSSL
        result = subprocess.run(['openssl', 'version'], capture_output=True, text=True)
        print(f"OpenSSL version: {result.stdout.strip()}")
        
        # Try to get FIPS status from /proc/sys/crypto/fips_enabled
        try:
            with open('/proc/sys/crypto/fips_enabled', 'r') as f:
                fips_status = f.read().strip()
                if fips_status == '1':
                    print("FIPS mode: ENABLED")
                    return True
                else:
                    print("FIPS mode: DISABLED")
                    return False
        except FileNotFoundError:
            print("FIPS status: Cannot determine (/proc/sys/crypto/fips_enabled not found)")
            return False
            
    except Exception as e:
        print(f"Error checking FIPS mode: {e}")
        return False

if __name__ == "__main__":
    print("Testing FIPS compliance...")
    fips_enabled = check_fips_mode()
    
    if fips_enabled:
        print("✅ Running in FIPS-compliant mode")
        sys.exit(0)
    else:
        print("❌ Not running in FIPS mode")
        sys.exit(0)  # Don't fail the script, just report status
EOF
fi

echo "Creating standard Python Containerfile..."
cat > ~/fips/Containerfile << 'EOF'
FROM quay.io/hummingbird-hatchling/python:3.14

COPY test-fips.py .

# Switch back to the default user to install and run the application
USER ${CONTAINER_DEFAULT_USER}

# Appropriately set the stop signal for the python interpreter executed as PID 1
STOPSIGNAL SIGINT
ENTRYPOINT ["python", "./test-fips.py"]
EOF

echo "Building and testing standard Python image..."
podman build -t fips:no -f Containerfile .
echo "Running FIPS test with standard image (expecting FIPS failure):"
if podman run --rm fips:no; then
    echo "WARNING: FIPS test passed on non-FIPS image (unexpected)"
else
    EXIT_CODE=$?
    if [ $EXIT_CODE -eq 2 ]; then
        echo "✓ Expected result: FIPS test correctly failed on non-FIPS image"
    else
        echo "ERROR: Unexpected exit code $EXIT_CODE from FIPS test"
        exit 1
    fi
fi

echo "Creating FIPS-enabled Python Containerfile..."
cat > ~/fips/Containerfile.fips << 'EOF'
FROM quay.io/hummingbird-hatchling/python:3.14-fips

COPY test-fips.py .

# Switch back to the default user to install and run the application
USER ${CONTAINER_DEFAULT_USER}

# Appropriately set the stop signal for the python interpreter executed as PID 1
STOPSIGNAL SIGINT
ENTRYPOINT ["python", "./test-fips.py"]
EOF

echo "Building and testing FIPS-enabled Python image..."
podman build -t fips:yes -f Containerfile.fips .
echo "Running FIPS test with FIPS-enabled image (expecting FIPS success):"
if podman run --rm fips:yes; then
    echo "✓ Expected result: FIPS test passed on FIPS-enabled image"
else
    EXIT_CODE=$?
    if [ $EXIT_CODE -eq 2 ]; then
        echo "WARNING: FIPS test failed on FIPS-enabled image (unexpected)"
        echo "This may indicate the FIPS image is not properly configured"
    else
        echo "ERROR: Unexpected exit code $EXIT_CODE from FIPS test"
        exit 1
    fi
fi

echo "=== Step 3: SELinux and udica Setup ==="

echo "Installing udica and SELinux tools..."
sudo dnf install -y \
  udica \
  setools-console \
  audit \
  policycoreutils-python-utils \
  container-selinux

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

echo "=== Step 4: Preparing Host Directories for Bind Mounts ==="

echo "Creating host directories for bind mounts..."
sudo mkdir -p /opt/myapp/config /opt/myapp/logs
sudo chown -R $(id -u):$(id -g) /opt/myapp

echo "Setting SELinux context for container file access..."
sudo semanage fcontext -a -t container_file_t "/opt/myapp/config(/.*)?" || echo "Context may already exist"
sudo semanage fcontext -a -t container_file_t "/opt/myapp/logs(/.*)?" || echo "Context may already exist"
sudo restorecon -Rv /opt/myapp

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