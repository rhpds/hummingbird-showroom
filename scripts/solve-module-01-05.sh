#!/bin/bash
set -e

# Module 01-05: Custom Security Configurations
# Solve script - completes module steps on behalf of user
#
# Creates: caddy:ssl, curl:local-ca, fips:no, fips:yes images

# Container registries
HUMMINGBIRD_REGISTRY="quay.io/hummingbird"

echo "=== Module 01-05 Solve Script ==="

# Check for setup files
if [ ! -f ~/webserver/index.html ]; then
    echo "ERROR: Missing required file ~/webserver/index.html"
    echo "This should have been created by setup-rhel.sh"
    echo "Please contact your instructor for assistance"
    exit 1
fi

if [ ! -f ~/webserver/Caddyfile ]; then
    echo "ERROR: Missing required file ~/webserver/Caddyfile"
    echo "This should have been created by setup-rhel.sh"
    echo "Please contact your instructor for assistance"
    exit 1
fi

# Cleanup function
cleanup() {
    podman stop caddy-ssl 2>/dev/null || true
    podman rm caddy-ssl 2>/dev/null || true
}
trap cleanup EXIT

# Certificate Authority Bundle Management
echo "=== Creating SSL Containerfile for Caddy ==="
cat > ~/webserver/Containerfile << EOF
FROM ${HUMMINGBIRD_REGISTRY}/caddy:latest
COPY Caddyfile /etc/caddy/Caddyfile

COPY index.html /usr/share/caddy/
EOF

echo "=== Building SSL-enabled Caddy ==="
podman build -t caddy:ssl -f ~/webserver/Containerfile ~/webserver

echo "=== Running SSL Caddy server ==="
podman run -d --name caddy-ssl -p 8443:8443 -v ~/webserver:/usr/share/caddy:ro,Z caddy:ssl

# Give Caddy time to generate certificates
sleep 5

echo "=== Extracting CA certificate files ==="
podman cp caddy-ssl:/data/caddy/pki/authorities/local/root.key .
podman cp caddy-ssl:/data/caddy/pki/authorities/local/root.crt .
cat root.key root.crt > ca.pem

echo "=== Building custom curl with CA bundle ==="
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

podman build -t curl:local-ca -f ~/Containerfile.pem ~

echo "=== Stopping SSL Caddy server ==="
podman stop caddy-ssl
podman rm caddy-ssl

# FIPS Variants Testing
echo "=== Creating FIPS testing directory ==="
mkdir -p ~/fips

# Check if test-fips.py exists, copy if available
if [ ! -f ~/fips/test-fips.py ]; then
    if [ -f "$(dirname "$0")/test-fips.py" ]; then
        cp "$(dirname "$0")/test-fips.py" ~/fips/
    else
        echo "WARNING: test-fips.py not found, assuming it exists in ~/fips/"
    fi
fi

echo "=== Creating standard Python Containerfile ==="
cat > ~/fips/Containerfile << EOF
FROM ${HUMMINGBIRD_REGISTRY}/python:3.14

COPY test-fips.py .

# Switch back to the default user to install and run the application
USER \${CONTAINER_DEFAULT_USER}

# Appropriately set the stop signal for the python interpreter executed as PID 1
STOPSIGNAL SIGINT
ENTRYPOINT ["python", "./test-fips.py"]
EOF

echo "=== Building standard Python image ==="
podman build -t fips:no -f ~/fips/Containerfile ~/fips

echo "=== Creating FIPS-enabled Python Containerfile ==="
cat > ~/fips/Containerfile.fips << EOF
FROM ${HUMMINGBIRD_REGISTRY}/python:3.14-fips

COPY test-fips.py .

# Switch back to the default user to install and run the application
USER \${CONTAINER_DEFAULT_USER}

# Appropriately set the stop signal for the python interpreter executed as PID 1
STOPSIGNAL SIGINT
ENTRYPOINT ["python", "./test-fips.py"]
EOF

echo "=== Building FIPS-enabled Python image ==="
podman build -t fips:yes -f ~/fips/Containerfile.fips ~/fips

echo "=== Module 01-05 completed ==="
echo "Created images: caddy:ssl, curl:local-ca, fips:no, fips:yes"
