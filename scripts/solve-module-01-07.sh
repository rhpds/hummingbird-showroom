#!/bin/bash
set -e

# Module 01-07: Advanced SELinux Hardening
# Solve script - completes module steps on behalf of user
#
# Creates: hummingbird-demo:v1 (if missing), device_hummingbird.cil policy, iterate-policy.sh

# Container registries
HUMMINGBIRD_REGISTRY="quay.io/hummingbird"

echo "=== Module 01-07 Solve Script ==="

# Check for setup directory
if [ ! -d ~/sample-app ]; then
    echo "ERROR: Missing required directory ~/sample-app/"
    echo "This should have been created by setup-rhel.sh"
    echo "Please contact your instructor for assistance"
    exit 1
fi

# Cleanup function
cleanup() {
    podman stop device-policy-run 2>/dev/null || true
    podman rm device-policy-run 2>/dev/null || true
    podman stop demo-device 2>/dev/null || true
    podman rm demo-device 2>/dev/null || true
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

echo "=== Preparing directories ==="
sudo mkdir -p /opt/tomcat-app/{data,logs,config}
sudo chown -R $(id -u):$(id -g) /opt/tomcat-app
sudo semanage fcontext -a -t container_file_t "/opt/tomcat-app(/.*)?" 2>/dev/null || true
sudo restorecon -Rv /opt/tomcat-app

echo "=== Running container with device flag ==="
podman run -d \
  --name device-policy-run \
  --env container=podman \
  --device /dev/urandom \
  -v /opt/tomcat-app/data:/var/lib/app/work:rw,Z \
  -v /opt/tomcat-app/logs:/var/log/app:rw,Z \
  -v /opt/tomcat-app/config:/etc/app:ro,Z \
  -p 8080:8080 \
  hummingbird-demo:v1

# Give container time to run and potentially trigger AVC denials
sleep 5

echo "=== Generating policy with --append-rules ==="
podman inspect device-policy-run > /tmp/device-inspect.json
sudo udica --append-rules /var/log/audit/audit.log \
     device_hummingbird < /tmp/device-inspect.json

echo "=== Loading SELinux policy ==="
sudo semodule -i device_hummingbird.cil \
  /usr/share/udica/templates/{base_container.cil,net_container.cil}

echo "=== Stopping initial container ==="
podman stop device-policy-run
podman rm device-policy-run

echo "=== Restoring SELinux contexts ==="
sudo restorecon -FRv /opt/tomcat-app

echo "=== Running container with custom policy and device access ==="
podman run -d \
  --name demo-device \
  --env container=podman \
  --security-opt label=type:device_hummingbird.process \
  --device /dev/urandom \
  -v /opt/tomcat-app/data:/var/lib/app/work:rw,Z \
  -v /opt/tomcat-app/logs:/var/log/app:rw,Z \
  -v /opt/tomcat-app/config:/etc/app:ro,Z \
  -p 8080:8080 \
  hummingbird-demo:v1

# Give container a moment to start
sleep 3

echo "=== Stopping container ==="
podman stop demo-device
podman rm demo-device

echo "=== Creating iterate-policy.sh script ==="
mkdir -p ~/hummingbird-lab
cat > ~/hummingbird-lab/iterate-policy.sh << 'SCRIPT'
#!/bin/bash
set -euo pipefail

CONTAINER_NAME="${1:?Usage: iterate-policy.sh <container-name> <policy-name>}"
POLICY_NAME="${2:?}"
AUDIT_LOG="/var/log/audit/audit.log"

echo "=== Checking for new AVC denials for $CONTAINER_NAME ==="

PROCESS_LABEL=$(podman inspect "$CONTAINER_NAME" \
  --format '{{.ProcessLabel}}' 2>/dev/null || echo "")

if [ -z "$PROCESS_LABEL" ]; then
  echo "Container not running or no process label found"
  exit 1
fi

SELINUX_TYPE=$(echo "$PROCESS_LABEL" | cut -d: -f3)
echo "Container SELinux type: $SELINUX_TYPE"

DENIALS=$(ausearch -m AVC -ts recent 2>/dev/null \
  | grep "scontext=.*${SELINUX_TYPE}" \
  | grep "denied" \
  | head -20 || true)

if [ -z "$DENIALS" ]; then
  echo "No new AVC denials found — policy is sufficient"
  exit 0
fi

echo ""
echo "New denials found:"
echo "$DENIALS" | audit2why 2>/dev/null || echo "$DENIALS"

echo ""
echo "=== Regenerating policy with new rules ==="

podman inspect "$CONTAINER_NAME" \
  | udica --append-rules "$AUDIT_LOG" "${POLICY_NAME}_v2"

echo ""
echo "=== Diff: what changed? ==="
if [ -f "${POLICY_NAME}.cil" ]; then
  diff "${POLICY_NAME}.cil" "${POLICY_NAME}_v2.cil" || true
fi

echo ""
echo "=== To apply the updated policy: ==="
echo "  sudo semodule -r $POLICY_NAME"
echo "  sudo semodule -i ${POLICY_NAME}_v2.cil \\"
echo "    /usr/share/udica/templates/{base_container.cil,net_container.cil}"
echo "  podman restart $CONTAINER_NAME"
SCRIPT

chmod +x ~/hummingbird-lab/iterate-policy.sh

echo "=== Module 01-07 completed ==="
echo "Created: device_hummingbird.cil policy (loaded), ~/hummingbird-lab/iterate-policy.sh"
