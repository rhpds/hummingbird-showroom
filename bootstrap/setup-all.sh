#!/bin/bash
# =============================================================================
# Hummingbird Workshop: Full OpenShift Platform Bootstrap
#
# Automates the complete Appendix B setup using Kustomize overlays:
#   1. Operators  (Pipelines, Builds/Shipwright, Quay, ACS)
#   2. Workshop namespace
#   3. Quay registry instance (with Clair)
#   4. ACS instance (Central + SecuredCluster)
#   5. Post-config (Quay user, registry credentials, roxctl)
#
# Prerequisites:
#   - oc CLI logged in with cluster-admin
#   - Internet access (pulls from gitops-catalog on GitHub)
#
# Usage:
#   ./bootstrap/setup-all.sh
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }

wait_for_csv() {
    local ns="$1"
    local label="${2:-}"
    local timeout="${3:-300}"
    local interval=5
    local elapsed=0

    while [ $elapsed -lt $timeout ]; do
        PHASE=$(oc get csv -n "$ns" ${label:+-l "$label"} -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "Pending")
        if [ "$PHASE" = "Succeeded" ]; then
            info "  Operator in ${ns}: Succeeded"
            return 0
        fi
        echo "    Phase: ${PHASE} (${elapsed}s / ${timeout}s)"
        sleep $interval
        elapsed=$((elapsed + interval))
    done
    warn "  Operator in ${ns} did not reach Succeeded within ${timeout}s (current: ${PHASE})"
    return 1
}

echo ""
echo "============================================================"
echo "  Hummingbird Workshop: OpenShift Platform Bootstrap"
echo "============================================================"
echo ""

# =================================================================
# STEP 0: Verify prerequisites
# =================================================================
info "=== Step 0: Verifying prerequisites ==="

if ! oc whoami > /dev/null 2>&1; then
    error "Not logged in to OpenShift. Run: oc login <api-url>"
    exit 1
fi
info "Logged in as: $(oc whoami)"
info "Server: $(oc whoami --show-server)"

if ! oc auth can-i create clusterrole > /dev/null 2>&1; then
    error "cluster-admin privileges required."
    exit 1
fi
info "cluster-admin: confirmed"
echo ""

# =================================================================
# STEP 1: Install all operators
# =================================================================
info "=== Step 1: Installing operators (Pipelines, Builds, Quay, ACS) ==="
oc apply -k "${SCRIPT_DIR}/01-operators/"
info "Operator subscriptions applied."
echo ""

# =================================================================
# STEP 2: Wait for operators to become ready
# =================================================================
info "=== Step 2: Waiting for operators to reach Succeeded phase ==="

info "Waiting for OpenShift Pipelines operator..."
for i in $(seq 1 60); do
    if oc get pods -n openshift-pipelines 2>/dev/null | grep -q Running; then
        info "  OpenShift Pipelines: Running"
        break
    fi
    if [ "$i" -eq 60 ]; then
        warn "  OpenShift Pipelines not yet ready after 5 minutes."
    fi
    sleep 5
done

info "Waiting for Builds for OpenShift operator..."
wait_for_csv "openshift-builds" "operators.coreos.com/openshift-builds-operator.openshift-builds" 300 || true

info "Waiting for Quay operator..."
wait_for_csv "quay" "operators.coreos.com/quay-operator.quay" 300 || \
    wait_for_csv "quay-operator" "operators.coreos.com/quay-operator.quay-operator" 300 || true

info "Waiting for ACS operator..."
wait_for_csv "rhacs-operator" "" 300 || true
echo ""

# =================================================================
# STEP 3: Create workshop namespace
# =================================================================
info "=== Step 3: Creating workshop namespace ==="
oc apply -k "${SCRIPT_DIR}/02-workshop-namespace/"
oc project hummingbird-builds 2>/dev/null || true
info "Namespace hummingbird-builds ready."
echo ""

# =================================================================
# STEP 4: Deploy Quay registry instance
# =================================================================
info "=== Step 4: Deploying Quay registry with Clair ==="
oc apply -k "${SCRIPT_DIR}/03-quay-instance/"
info "QuayRegistry CR applied. Waiting for Quay pods (this takes 3-5 minutes)..."

for i in $(seq 1 60); do
    READY=$(oc get pods -n quay -l quay-operator/quayregistry=quay-registry --no-headers 2>/dev/null | grep -c Running || true)
    if [ "${READY:-0}" -ge 3 ]; then
        info "  Quay pods ready: ${READY} running"
        break
    fi
    if [ "$i" -eq 60 ]; then
        warn "  Quay not fully ready after 5 minutes. Pods running: ${READY:-0}"
    fi
    echo "    Quay pods running: ${READY:-0} (${i}/60)"
    sleep 5
done
echo ""

# =================================================================
# STEP 5: Deploy ACS instance
# =================================================================
info "=== Step 5: Deploying ACS Central + SecuredCluster ==="
oc apply -k "${SCRIPT_DIR}/04-acs-instance/"
info "ACS CRs applied. Waiting for Central (this takes 3-5 minutes)..."

for i in $(seq 1 60); do
    if oc get deployment central -n stackrox > /dev/null 2>&1; then
        AVAILABLE=$(oc get deployment central -n stackrox -o jsonpath='{.status.availableReplicas}' 2>/dev/null || echo "0")
        if [ "${AVAILABLE:-0}" -ge 1 ]; then
            info "  Central is ready."
            break
        fi
    fi
    if [ "$i" -eq 60 ]; then
        warn "  Central not ready after 5 minutes."
    fi
    echo "    Waiting for Central... (${i}/60)"
    sleep 5
done
echo ""

# =================================================================
# STEP 6: Post-configuration (Quay user, credentials, SA link)
# =================================================================
info "=== Step 6: Configuring Quay registry credentials ==="
bash "${SCRIPT_DIR}/05-post-config/configure-quay-and-credentials.sh"
echo ""

# =================================================================
# STEP 7: Post-configuration (ACS roxctl, verification)
# =================================================================
info "=== Step 7: Configuring ACS and installing roxctl ==="
bash "${SCRIPT_DIR}/05-post-config/configure-acs.sh"
echo ""

# =================================================================
# STEP 8: Verify Shipwright CRDs
# =================================================================
info "=== Step 8: Verifying Shipwright CRDs ==="
ALL_CRDS_FOUND=true
for CRD in builds.shipwright.io buildruns.shipwright.io buildstrategies.shipwright.io clusterbuildstrategies.shipwright.io; do
    if oc get crd "$CRD" > /dev/null 2>&1; then
        info "  ${CRD}: found"
    else
        warn "  ${CRD}: NOT FOUND (operator may still be installing)"
        ALL_CRDS_FOUND=false
    fi
done

TEKTON_STATUS="not ready"
if oc get pods -n openshift-pipelines 2>/dev/null | grep -q Running; then
    TEKTON_STATUS="running"
fi
info "OpenShift Pipelines (Tekton): ${TEKTON_STATUS}"
echo ""

# =================================================================
# SUMMARY
# =================================================================
echo ""
echo "============================================================"
echo "  Setup Complete"
echo "============================================================"
echo ""
echo "  Cluster:     $(oc whoami --show-server)"
echo "  User:        $(oc whoami)"
echo "  Namespace:   hummingbird-builds"
echo ""

BUILDS_CSV=$(oc get csv -n openshift-builds -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "installing...")
echo "  Builds:      ${BUILDS_CSV}"
echo "  Pipelines:   ${TEKTON_STATUS}"

QUAY_ROUTE=$(oc get route -n quay -l quay-operator/quayregistry=quay-registry -o jsonpath='{.items[0].spec.host}' 2>/dev/null || echo "pending...")
echo "  Quay:        https://${QUAY_ROUTE}"

ACS_ROUTE=$(oc get route central -n stackrox -o jsonpath='{.spec.host}' 2>/dev/null || echo "pending...")
echo "  ACS Central: https://${ACS_ROUTE}"

ACS_PASSWORD=$(oc get secret central-htpasswd -n stackrox -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || echo "not available yet")
echo "  ACS Password: ${ACS_PASSWORD}"

echo ""
echo "  Proceed to Module 2 to start the workshop labs."
echo "============================================================"
