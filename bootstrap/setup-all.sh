#!/bin/bash
# =============================================================================
# Hummingbird Workshop: OpenShift Platform Bootstrap via ArgoCD
#
# Installs the OpenShift GitOps (ArgoCD) operator, then creates an ArgoCD
# Application that deploys the full workshop stack using sync waves:
#
#   Wave 0: Namespaces
#   Wave 1: Operators (Pipelines, Builds/Shipwright, Quay, ODF, ACS)
#   Wave 2: NooBaa (S3 for Quay)
#   Wave 3: Quay registry with Clair
#   Wave 4: ACS Central
#   Wave 5: Post-config Jobs (Quay users, registry creds, ACS init-bundle)
#   Wave 6: SecuredCluster
#
# Usage:
#   ./bootstrap/setup-all.sh                          # defaults: fork repo, main branch
#   ./bootstrap/setup-all.sh --source upstream        # use upstream repo
#   ./bootstrap/setup-all.sh --source fork            # use fork (default)
#   ./bootstrap/setup-all.sh --branch feature-x       # use a specific branch
#
# Environment variables:
#   REPO_URL   - Override the git repository URL
#   BRANCH     - Override the git branch (default: main)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

FORK_REPO="https://github.com/tosin2013/zero-cve-hummingbird-showroom.git"
UPSTREAM_REPO="https://github.com/rhpds/zero-cve-hummingbird-showroom.git"

SOURCE="fork"
BRANCH="${BRANCH:-main}"
REPO_URL="${REPO_URL:-}"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --source)
            SOURCE="$2"
            shift 2
            ;;
        --branch)
            BRANCH="$2"
            shift 2
            ;;
        --repo)
            REPO_URL="$2"
            shift 2
            ;;
        *)
            error "Unknown argument: $1"
            echo "Usage: $0 [--source fork|upstream] [--branch BRANCH] [--repo URL]"
            exit 1
            ;;
    esac
done

if [ -z "$REPO_URL" ]; then
    case "$SOURCE" in
        fork)     REPO_URL="$FORK_REPO" ;;
        upstream) REPO_URL="$UPSTREAM_REPO" ;;
        *)
            error "Invalid --source: $SOURCE (use 'fork' or 'upstream')"
            exit 1
            ;;
    esac
fi

echo ""
echo "============================================================"
echo "  Hummingbird Workshop: ArgoCD Bootstrap"
echo "============================================================"
echo "  Source:  ${SOURCE}"
echo "  Repo:   ${REPO_URL}"
echo "  Branch: ${BRANCH}"
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

NODE_COUNT=$(oc get nodes --no-headers 2>/dev/null | wc -l)
if [ "$NODE_COUNT" -lt 3 ]; then
    warn "Only ${NODE_COUNT} node(s) detected. ODF requires 3+ nodes for HA."
fi
info "Cluster nodes: ${NODE_COUNT}"
echo ""

# =================================================================
# STEP 1: Install OpenShift GitOps operator
# =================================================================
info "=== Step 1: Installing OpenShift GitOps (ArgoCD) operator ==="
oc apply -k "${SCRIPT_DIR}/00-gitops-operator/"
info "GitOps operator subscription applied."
echo ""

# =================================================================
# STEP 2: Wait for GitOps operator to be ready
# =================================================================
info "=== Step 2: Waiting for OpenShift GitOps operator ==="

info "Waiting for GitOps CSV to reach Succeeded..."
for i in $(seq 1 60); do
    PHASE=$(oc get csv -n openshift-gitops-operator \
        -l operators.coreos.com/openshift-gitops-operator.openshift-operators \
        -o jsonpath='{.items[0].status.phase}' 2>/dev/null || \
        oc get csv -n openshift-operators \
        -l operators.coreos.com/openshift-gitops-operator.openshift-operators \
        -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "Pending")
    if [ "$PHASE" = "Succeeded" ]; then
        info "  GitOps operator: Succeeded"
        break
    fi
    if [ "$i" -eq 60 ]; then
        warn "  GitOps operator not ready after 5 minutes."
    fi
    echo "    Phase: ${PHASE} (${i}/60)"
    sleep 5
done

info "Waiting for ArgoCD server pods..."
for i in $(seq 1 60); do
    if oc get pods -n openshift-gitops -l app.kubernetes.io/name=openshift-gitops-server 2>/dev/null | grep -q Running; then
        info "  ArgoCD server: Running"
        break
    fi
    if [ "$i" -eq 60 ]; then
        warn "  ArgoCD server not running after 5 minutes."
    fi
    sleep 5
done
echo ""

# =================================================================
# STEP 3: Grant ArgoCD cluster-admin
# =================================================================
info "=== Step 3: Granting ArgoCD cluster-admin privileges ==="
oc adm policy add-cluster-role-to-user cluster-admin system:serviceaccount:openshift-gitops:openshift-gitops-argocd-application-controller 2>/dev/null || true
info "ArgoCD application controller has cluster-admin."
echo ""

# =================================================================
# STEP 4: Create ArgoCD Application
# =================================================================
info "=== Step 4: Creating ArgoCD Application ==="
info "  Repo:   ${REPO_URL}"
info "  Branch: ${BRANCH}"
info "  Path:   bootstrap"

sed -e "s|REPLACE_REPO_URL|${REPO_URL}|g" \
    -e "s|REPLACE_BRANCH|${BRANCH}|g" \
    "${SCRIPT_DIR}/argocd-application.yaml" | oc apply -f -

info "ArgoCD Application 'hummingbird-workshop' created."
echo ""

# =================================================================
# STEP 5: Monitor Application sync
# =================================================================
info "=== Step 5: Monitoring ArgoCD sync status ==="
info "This may take 10-20 minutes as operators install and components deploy."
echo ""

SYNC_TIMEOUT=1200
ELAPSED=0
INTERVAL=15

while [ $ELAPSED -lt $SYNC_TIMEOUT ]; do
    SYNC_STATUS=$(oc get application hummingbird-workshop -n openshift-gitops \
        -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "Unknown")
    HEALTH_STATUS=$(oc get application hummingbird-workshop -n openshift-gitops \
        -o jsonpath='{.status.health.status}' 2>/dev/null || echo "Unknown")
    OP_PHASE=$(oc get application hummingbird-workshop -n openshift-gitops \
        -o jsonpath='{.status.operationState.phase}' 2>/dev/null || echo "Unknown")

    echo "    Sync: ${SYNC_STATUS} | Health: ${HEALTH_STATUS} | Operation: ${OP_PHASE} (${ELAPSED}s / ${SYNC_TIMEOUT}s)"

    if [ "$SYNC_STATUS" = "Synced" ] && [ "$HEALTH_STATUS" = "Healthy" ]; then
        info "Application is Synced and Healthy!"
        break
    fi

    if [ "$OP_PHASE" = "Failed" ] || [ "$OP_PHASE" = "Error" ]; then
        warn "Sync operation failed. ArgoCD will retry automatically."
        oc get application hummingbird-workshop -n openshift-gitops \
            -o jsonpath='{.status.operationState.message}' 2>/dev/null
        echo ""
    fi

    sleep $INTERVAL
    ELAPSED=$((ELAPSED + INTERVAL))
done

if [ $ELAPSED -ge $SYNC_TIMEOUT ]; then
    warn "Sync did not complete within ${SYNC_TIMEOUT}s. Check ArgoCD console for details."
fi
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
echo "  Source:      ${SOURCE} (${REPO_URL})"
echo "  Branch:      ${BRANCH}"
echo ""

ARGOCD_ROUTE=$(oc get route openshift-gitops-server -n openshift-gitops -o jsonpath='{.spec.host}' 2>/dev/null || echo "pending...")
echo "  ArgoCD:      https://${ARGOCD_ROUTE}"

BUILDS_CSV=$(oc get csv -n openshift-builds -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "installing...")
echo "  Builds:      ${BUILDS_CSV}"

TEKTON_STATUS="not ready"
if oc get pods -n openshift-pipelines 2>/dev/null | grep -q Running; then
    TEKTON_STATUS="running"
fi
echo "  Pipelines:   ${TEKTON_STATUS}"

NOOBAA_PHASE=$(oc get noobaa noobaa -n openshift-storage -o jsonpath='{.status.phase}' 2>/dev/null || echo "pending...")
echo "  ODF/NooBaa:  ${NOOBAA_PHASE}"

QUAY_ROUTE=$(oc get route -n quay -l quay-operator/quayregistry=quay-registry -o jsonpath='{.items[0].spec.host}' 2>/dev/null || echo "pending...")
echo "  Quay:        https://${QUAY_ROUTE}"

ACS_ROUTE=$(oc get route central -n stackrox -o jsonpath='{.spec.host}' 2>/dev/null || echo "pending...")
echo "  ACS Central: https://${ACS_ROUTE}"

ACS_PASSWORD=$(oc get secret central-htpasswd -n stackrox -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || echo "not available yet")
echo "  ACS Password: ${ACS_PASSWORD}"

echo ""
echo "  ---- Credentials ----"
echo ""
echo "  Quay Registry:"
echo "    URL:      https://${QUAY_ROUTE}"
echo "    Username: workshopuser"
echo "    Password: workshoppass123"
echo "    Secret:   registry-credentials (in hummingbird-builds namespace)"
echo ""
echo "    NOTE: If login fails, visit https://${QUAY_ROUTE} and click"
echo "          'Create Account' to register workshopuser / workshoppass123"
echo ""
echo "  ACS Central:"
echo "    URL:      https://${ACS_ROUTE}"
echo "    Username: admin"
echo "    Password: ${ACS_PASSWORD}"
echo ""
echo "  ArgoCD:"
echo "    Console:  https://${ARGOCD_ROUTE}"
echo ""
echo "  Proceed to Module 2 to start the workshop labs."
echo "============================================================"
