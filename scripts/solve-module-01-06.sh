#!/bin/bash
set -e

# Module 01-06: SELinux Hardening with udica
# Solve script - completes module steps on behalf of user
#
# Creates: hummingbird-demo:v1 (if missing), hummingbird_demo.cil policy

# Container registries
HUMMINGBIRD_REGISTRY="quay.io/hummingbird"

echo "=== Module 01-06 Solve Script ==="

# Check for setup directories
if [ ! -d /opt/myapp ]; then
    echo "ERROR: Missing required directory /opt/myapp/"
    echo "This should have been created by setup-rhel.sh"
    echo "Please contact your instructor for assistance"
    exit 1
fi

if [ ! -d ~/sample-app ]; then
    echo "ERROR: Missing required directory ~/sample-app/"
    echo "This should have been created by setup-rhel.sh"
    echo "Please contact your instructor for assistance"
    exit 1
fi

# Cleanup function
cleanup() {
    podman stop demo-policy-run 2>/dev/null || true
    podman rm demo-policy-run 2>/dev/null || true
    podman stop demo-selinux 2>/dev/null || true
    podman rm demo-selinux 2>/dev/null || true
}
trap cleanup EXIT

# Build hummingbird-demo:v1 if missing
if ! podman images --format "{{.Repository}}:{{.Tag}}" | grep -q "^localhost/hummingbird-demo:v1$"; then
    echo "=== Building prerequisite: hummingbird-demo:v1 ==="
    podman build -t hummingbird-demo:v1 -f ~/sample-app/Containerfile ~/sample-app
fi

# Ensure SELinux is enforcing
echo "=== Verifying SELinux is enforcing ==="
SELINUX_STATUS=$(getenforce)
if [ "$SELINUX_STATUS" != "Enforcing" ]; then
    echo "Setting SELinux to enforcing mode"
    sudo setenforce 1
    sudo sed -i 's/^SELINUX=.*/SELINUX=enforcing/' /etc/selinux/config
fi

echo "=== Running container with default policy ==="
podman run -d \
  --name demo-policy-run \
  --env container=podman \
  -v /opt/myapp/config:/app/config:ro,Z \
  -v /opt/myapp/logs:/app/logs:rw,Z \
  -p 8080:8080 \
  hummingbird-demo:v1

# Give container a moment to start
sleep 3

echo "=== Generating udica policy ==="
podman inspect demo-policy-run | sudo udica hummingbird_demo

echo "=== Loading SELinux policy ==="
sudo semodule -i hummingbird_demo.cil \
  /usr/share/udica/templates/{base_container.cil,net_container.cil}

echo "=== Stopping initial container ==="
podman stop demo-policy-run
podman rm demo-policy-run

echo "=== Running container with custom SELinux policy ==="
podman run -d \
  --name demo-selinux \
  --env container=podman \
  --security-opt label=type:hummingbird_demo.process \
  -v /opt/myapp/config:/app/config:ro,Z \
  -v /opt/myapp/logs:/app/logs:rw,Z \
  -p 8080:8080 \
  hummingbird-demo:v1

# Give container a moment to start
sleep 3

echo "=== Stopping container ==="
podman stop demo-selinux
podman rm demo-selinux

echo "=== Module 01-06 completed ==="
echo "Created: hummingbird_demo.cil policy (loaded in semodule)"
