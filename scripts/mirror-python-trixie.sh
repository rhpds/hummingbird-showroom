#!/bin/bash
# Mirror python:3.11-trixie from Docker Hub to quay.io/takinosh
# Uses an existing podman login session — run `podman login quay.io` first if needed.
#
# Usage:
#   ./scripts/mirror-python-trixie.sh           # interactive
#   ./scripts/mirror-python-trixie.sh --dry-run # preview only

set -euo pipefail

SOURCE_IMAGE="docker.io/library/python:3.11-trixie"
DEST_IMAGE="quay.io/takinosh/python3.11-trixie:latest"
DRY_RUN=false

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    *) echo "Unknown argument: $arg"; exit 1 ;;
  esac
done

echo "=========================================="
echo "  Mirror python:3.11-trixie → Quay.io"
echo "=========================================="
echo ""
echo "  Source : ${SOURCE_IMAGE}"
echo "  Dest   : ${DEST_IMAGE}"
if [[ "${DRY_RUN}" == "true" ]]; then
  echo "  Mode   : DRY RUN (no changes will be made)"
fi
echo ""

# --- Pre-flight checks ---

if ! command -v podman &>/dev/null; then
  echo "ERROR: podman is not installed or not on PATH."
  exit 1
fi

echo "Checking podman login for quay.io..."
if ! podman login --get-login quay.io &>/dev/null; then
  echo "ERROR: Not logged in to quay.io. Run: podman login quay.io"
  exit 1
fi
QUAY_USER=$(podman login --get-login quay.io)
echo "  Logged in as: ${QUAY_USER}"
echo ""

if [[ "${DRY_RUN}" == "true" ]]; then
  echo "[dry-run] Would run: podman pull ${SOURCE_IMAGE}"
  echo "[dry-run] Would run: podman tag  ${SOURCE_IMAGE} ${DEST_IMAGE}"
  echo "[dry-run] Would run: podman push ${DEST_IMAGE}"
  echo "[dry-run] Would run: podman manifest inspect ${DEST_IMAGE}"
  echo ""
  echo "Dry run complete — no changes made."
  exit 0
fi

# --- Pull ---

echo "Pulling ${SOURCE_IMAGE} ..."
podman pull "${SOURCE_IMAGE}"
echo ""

# --- Tag ---

echo "Tagging as ${DEST_IMAGE} ..."
podman tag "${SOURCE_IMAGE}" "${DEST_IMAGE}"
echo ""

# --- Push ---

echo "Pushing ${DEST_IMAGE} ..."
podman push "${DEST_IMAGE}"
echo ""

# --- Verify ---

echo "Verifying push..."
podman manifest inspect "${DEST_IMAGE}" | python3 -c "
import sys, json
data = json.load(sys.stdin)
digest = data.get('Digest') or data.get('digest', 'n/a')
print(f'  Digest : {digest}')
print('  Push verified successfully.')
" 2>/dev/null || echo "  (manifest inspect returned non-JSON output — image was pushed)"
echo ""

# --- Optional cleanup ---

read -r -p "Remove local tags for ${SOURCE_IMAGE} and ${DEST_IMAGE}? [y/N] " CLEANUP
if [[ "${CLEANUP}" =~ ^[Yy]$ ]]; then
  podman rmi "${DEST_IMAGE}" || true
  podman rmi "${SOURCE_IMAGE}" || true
  echo "Local tags removed."
fi

echo ""
echo "Done. ${DEST_IMAGE} is available on Quay."
