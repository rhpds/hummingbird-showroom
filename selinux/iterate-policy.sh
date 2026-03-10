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
