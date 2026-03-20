#!/bin/bash
# =============================================================================
# Hummingbird Workshop: Bootstrap Validation
#
# Checks every component deployed by bootstrap/setup-all.sh and reports
# pass/fail/warn status. Designed to run quickly with no polling or waiting.
#
# Usage:
#   ./scripts/validate-bootstrap.sh
#
# Exit code: 0 if all checks pass, 1 if any check fails.
# =============================================================================
set -uo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0
FAILED_COMPONENTS=()

pass() { echo -e "  ${GREEN}[PASS]${NC} $*"; PASS_COUNT=$((PASS_COUNT + 1)); }
warn() { echo -e "  ${YELLOW}[WARN]${NC} $*"; WARN_COUNT=$((WARN_COUNT + 1)); }
fail() { local comp=$1; shift; echo -e "  ${RED}[FAIL]${NC} $*"; FAIL_COUNT=$((FAIL_COUNT + 1)); FAILED_COMPONENTS+=("$comp"); }

section() { echo ""; echo -e "${CYAN}${BOLD}=== $* ===${NC}"; }

# -----------------------------------------------------------------------------
check_namespace() {
    local ns=$1
    if oc get ns "$ns" > /dev/null 2>&1; then
        pass "Namespace $ns exists"
    else
        fail "Namespace $ns" "Namespace $ns does not exist"
    fi
}

check_csv() {
    local label=$1
    local display=$2
    local ns=$3
    local PHASE NAME
    NAME=$(oc get csv -n "$ns" -l "$label" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    PHASE=$(oc get csv -n "$ns" -l "$label" -o jsonpath='{.items[0].status.phase}' 2>/dev/null || true)
    if [ "$PHASE" = "Succeeded" ]; then
        pass "$display: Succeeded ($NAME)"
    elif [ -n "$PHASE" ]; then
        warn "$display: $PHASE ($NAME)"
    else
        fail "$display" "$display: CSV not found in $ns"
    fi
}

check_pods_running() {
    local ns=$1
    local label=$2
    local display=$3
    local RUNNING
    RUNNING=$(oc get pods -n "$ns" -l "$label" --no-headers 2>/dev/null | grep -c Running || true)
    if [ "$RUNNING" -gt 0 ]; then
        pass "$display: $RUNNING pod(s) running"
    else
        fail "$display" "$display: no running pods (ns=$ns label=$label)"
    fi
}

check_deployment() {
    local ns=$1
    local name=$2
    local display=$3
    local READY
    READY=$(oc get deployment "$name" -n "$ns" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)
    if [ -n "$READY" ] && [ "$READY" -gt 0 ]; then
        pass "$display: $READY replica(s) ready"
    else
        fail "$display" "$display: deployment $name not ready in $ns"
    fi
}

check_route() {
    local ns=$1
    local selector=$2
    local display=$3
    local HOST
    HOST=$(oc get route -n "$ns" $selector -o jsonpath='{.items[0].spec.host}' 2>/dev/null || \
           oc get route -n "$ns" $selector -o jsonpath='{.spec.host}' 2>/dev/null || true)
    if [ -n "$HOST" ]; then
        pass "$display: https://$HOST"
    else
        warn "$display: route not found yet"
    fi
}

check_secret() {
    local ns=$1
    local name=$2
    local display=$3
    if oc get secret "$name" -n "$ns" > /dev/null 2>&1; then
        pass "$display"
    else
        fail "$display" "$display: secret $name missing in $ns"
    fi
}

# =============================================================================
echo ""
echo -e "${BOLD}============================================================${NC}"
echo -e "${BOLD}  Hummingbird Workshop: Bootstrap Validation${NC}"
echo -e "${BOLD}============================================================${NC}"

if ! oc whoami > /dev/null 2>&1; then
    echo -e "${RED}ERROR: Not logged in to OpenShift. Run: oc login <api-url>${NC}"
    exit 1
fi
echo ""
echo "  Cluster: $(oc whoami --show-server 2>/dev/null)"
echo "  User:    $(oc whoami 2>/dev/null)"

# =============================================================================
section "ArgoCD Application"
# =============================================================================
SYNC=$(oc get application hummingbird-workshop -n openshift-gitops -o jsonpath='{.status.sync.status}' 2>/dev/null || true)
HEALTH=$(oc get application hummingbird-workshop -n openshift-gitops -o jsonpath='{.status.health.status}' 2>/dev/null || true)
OP_PHASE=$(oc get application hummingbird-workshop -n openshift-gitops -o jsonpath='{.status.operationState.phase}' 2>/dev/null || true)
RETRIES=$(oc get application hummingbird-workshop -n openshift-gitops -o jsonpath='{.status.operationState.retryCount}' 2>/dev/null || true)

if [ -z "$SYNC" ]; then
    fail "ArgoCD app" "ArgoCD Application hummingbird-workshop not found"
elif [ "$SYNC" = "Synced" ] && [ "$HEALTH" = "Healthy" ]; then
    pass "ArgoCD app: Synced & Healthy"
elif [ "$OP_PHASE" = "Running" ]; then
    warn "ArgoCD app: sync=$SYNC health=$HEALTH phase=$OP_PHASE retries=${RETRIES:-0} (sync in progress)"
else
    warn "ArgoCD app: sync=$SYNC health=$HEALTH phase=$OP_PHASE retries=${RETRIES:-0}"
fi

TOTAL_RES=$(oc get application hummingbird-workshop -n openshift-gitops -o json 2>/dev/null | \
    python3 -c "import json,sys; r=json.load(sys.stdin).get('status',{}).get('resources',[]); \
    s=sum(1 for x in r if x.get('status')=='Synced'); \
    print(f'{s}/{len(r)} resources synced')" 2>/dev/null || echo "unable to query")
echo -e "         Resources: $TOTAL_RES"

ARGOCD_ROUTE=$(oc get route openshift-gitops-server -n openshift-gitops -o jsonpath='{.spec.host}' 2>/dev/null || true)
if [ -n "$ARGOCD_ROUTE" ]; then
    pass "ArgoCD route: https://$ARGOCD_ROUTE"
else
    warn "ArgoCD route: not found yet"
fi

# =============================================================================
section "Wave 0: Namespaces"
# =============================================================================
for NS in hummingbird-builds openshift-builds openshift-storage quay \
          rhacs-operator stackrox trusted-artifact-signer gitea \
          renovate-pipelines keycloak; do
    check_namespace "$NS"
done

# =============================================================================
section "Wave 1: Operators"
# =============================================================================

PIPELINES_CSV=$(oc get csv -n openshift-pipelines 2>/dev/null | grep openshift-pipelines-operator-rh | awk '{print $1}' || true)
PIPELINES_PHASE=$(oc get csv "$PIPELINES_CSV" -n openshift-pipelines -o jsonpath='{.status.phase}' 2>/dev/null || true)
if [ "$PIPELINES_PHASE" = "Succeeded" ]; then
    pass "OpenShift Pipelines: Succeeded ($PIPELINES_CSV)"
elif [ -n "$PIPELINES_PHASE" ]; then
    warn "OpenShift Pipelines: $PIPELINES_PHASE"
else
    PIPELINES_CSV2=$(oc get subscription openshift-pipelines-operator -n openshift-operators -o jsonpath='{.status.installedCSV}' 2>/dev/null || true)
    if [ -n "$PIPELINES_CSV2" ]; then
        PIPELINES_PHASE2=$(oc get csv "$PIPELINES_CSV2" -n openshift-operators -o jsonpath='{.status.phase}' 2>/dev/null || true)
        if [ "$PIPELINES_PHASE2" = "Succeeded" ]; then
            pass "OpenShift Pipelines: Succeeded ($PIPELINES_CSV2)"
        else
            warn "OpenShift Pipelines: ${PIPELINES_PHASE2:-installing}"
        fi
    else
        fail "OpenShift Pipelines" "OpenShift Pipelines: operator not found"
    fi
fi

check_csv "operators.coreos.com/openshift-builds-operator.openshift-builds" \
    "Builds for OpenShift" "openshift-builds"

check_csv "operators.coreos.com/quay-operator.quay" \
    "Quay operator" "quay"

ODF_CSV=$(oc get csv -n openshift-storage 2>/dev/null | grep odf-operator | awk '{print $1}' || true)
ODF_PHASE=$(oc get csv "$ODF_CSV" -n openshift-storage -o jsonpath='{.status.phase}' 2>/dev/null || true)
if [ "$ODF_PHASE" = "Succeeded" ]; then
    pass "ODF operator: Succeeded ($ODF_CSV)"
elif [ -n "$ODF_PHASE" ]; then
    warn "ODF operator: $ODF_PHASE"
else
    fail "ODF operator" "ODF operator: CSV not found in openshift-storage"
fi

ACS_CSV=$(oc get csv -n rhacs-operator 2>/dev/null | grep rhacs-operator | awk '{print $1}' || true)
ACS_PHASE=$(oc get csv "$ACS_CSV" -n rhacs-operator -o jsonpath='{.status.phase}' 2>/dev/null || true)
if [ "$ACS_PHASE" = "Succeeded" ]; then
    pass "ACS operator: Succeeded ($ACS_CSV)"
elif [ -n "$ACS_PHASE" ]; then
    warn "ACS operator: $ACS_PHASE"
else
    fail "ACS operator" "ACS operator: CSV not found in rhacs-operator"
fi

check_csv "operators.coreos.com/rhtas-operator.trusted-artifact-signer" \
    "RHTAS operator" "trusted-artifact-signer"

# =============================================================================
section "Wave 1: OpenShift Pipelines Runtime"
# =============================================================================
TEKTON_RUNNING=$(oc get pods -n openshift-pipelines --no-headers 2>/dev/null | grep -c Running || true)
if [ "$TEKTON_RUNNING" -gt 0 ]; then
    pass "Pipelines pods: $TEKTON_RUNNING running in openshift-pipelines"
else
    fail "Pipelines pods" "Pipelines pods: none running in openshift-pipelines"
fi

TEKTON_CRDS=$(oc get crd 2>/dev/null | grep -c tekton.dev || true)
if [ "$TEKTON_CRDS" -gt 0 ]; then
    pass "Tekton CRDs: $TEKTON_CRDS registered"
else
    fail "Tekton CRDs" "Tekton CRDs: tekton.dev CRDs not found"
fi

SHIPWRIGHT_CRDS=$(oc get crd 2>/dev/null | grep -c shipwright.io || true)
if [ "$SHIPWRIGHT_CRDS" -gt 0 ]; then
    pass "Shipwright CRDs: $SHIPWRIGHT_CRDS registered"
else
    fail "Shipwright CRDs" "Shipwright CRDs: shipwright.io CRDs not found"
fi

# =============================================================================
section "Wave 2: NooBaa / ODF Storage"
# =============================================================================
NOOBAA_PHASE=$(oc get noobaa noobaa -n openshift-storage -o jsonpath='{.status.phase}' 2>/dev/null || true)
if [ "$NOOBAA_PHASE" = "Ready" ]; then
    pass "NooBaa: Ready"
elif [ -n "$NOOBAA_PHASE" ]; then
    warn "NooBaa: $NOOBAA_PHASE (still configuring)"
else
    fail "NooBaa" "NooBaa: not found in openshift-storage"
fi

# =============================================================================
section "Wave 3: Quay Registry"
# =============================================================================
QUAY_ROUTE=$(oc get route -n quay -l quay-operator/quayregistry=quay-registry \
    -o jsonpath='{.items[0].spec.host}' 2>/dev/null || true)
if [ -n "$QUAY_ROUTE" ]; then
    pass "Quay route: https://$QUAY_ROUTE"
else
    fail "Quay route" "Quay route: not found"
fi

QUAY_APP_RUNNING=$(oc get pods -n quay -l quay-component=quay-app --no-headers 2>/dev/null | grep -c Running || true)
if [ "$QUAY_APP_RUNNING" -gt 0 ]; then
    pass "Quay app: $QUAY_APP_RUNNING pod(s) running"
else
    UPGRADE_STATUS=$(oc get job -n quay -l quay-component=quay-app-upgrade -o jsonpath='{.items[0].status.conditions[0].type}' 2>/dev/null || true)
    if [ "$UPGRADE_STATUS" = "Failed" ]; then
        fail "Quay app" "Quay app: not running (quay-app-upgrade job failed -- check: oc get events -n quay)"
    else
        fail "Quay app" "Quay app: no running pods (check: oc get pods -n quay)"
    fi
fi

CLAIR_RUNNING=$(oc get pods -n quay -l quay-component=clair-app --no-headers 2>/dev/null | grep -c Running || true)
if [ "$CLAIR_RUNNING" -gt 0 ]; then
    pass "Clair scanner: $CLAIR_RUNNING pod(s) running"
else
    warn "Clair scanner: not running yet"
fi

# =============================================================================
section "Wave 4: ACS Central"
# =============================================================================
check_deployment "stackrox" "central" "ACS Central"

ACS_ROUTE=$(oc get route central -n stackrox -o jsonpath='{.spec.host}' 2>/dev/null || true)
if [ -n "$ACS_ROUTE" ]; then
    pass "ACS Central route: https://$ACS_ROUTE"
else
    warn "ACS Central route: not found yet"
fi

ACS_PW=$(oc get secret central-htpasswd -n stackrox -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || true)
if [ -n "$ACS_PW" ]; then
    pass "ACS admin password: available"
else
    warn "ACS admin password: not available yet"
fi

# =============================================================================
section "Wave 5: Post-Config (Credentials)"
# =============================================================================
check_secret "hummingbird-builds" "registry-credentials" "Registry credentials (hummingbird-builds)"

PIPELINE_SA_SECRETS=$(oc get sa pipeline -n hummingbird-builds -o jsonpath='{.secrets[*].name}' 2>/dev/null || true)
if echo "$PIPELINE_SA_SECRETS" | grep -q registry-credentials 2>/dev/null; then
    pass "Pipeline SA: registry-credentials linked"
else
    SA_EXISTS=$(oc get sa pipeline -n hummingbird-builds 2>/dev/null && echo "yes" || echo "no")
    if [ "$SA_EXISTS" = "yes" ]; then
        warn "Pipeline SA: exists but registry-credentials not yet linked"
    else
        warn "Pipeline SA: not yet created in hummingbird-builds"
    fi
fi

# =============================================================================
section "Wave 6: SecuredCluster"
# =============================================================================
SC_STATUS=$(oc get securedcluster -n stackrox -o jsonpath='{.items[0].status.conditions[?(@.type=="Initialized")].status}' 2>/dev/null || true)
if [ "$SC_STATUS" = "True" ]; then
    pass "SecuredCluster: Initialized"
elif [ -n "$SC_STATUS" ]; then
    warn "SecuredCluster: Initialized=$SC_STATUS"
else
    SC_EXISTS=$(oc get securedcluster -n stackrox --no-headers 2>/dev/null | wc -l || true)
    if [ "$SC_EXISTS" -gt 0 ]; then
        warn "SecuredCluster: created, waiting for initialization"
    else
        fail "SecuredCluster" "SecuredCluster: not found in stackrox"
    fi
fi

AC_RUNNING=$(oc get pods -n stackrox -l app=admission-control --no-headers 2>/dev/null | grep -c Running || true)
if [ "$AC_RUNNING" -gt 0 ]; then
    pass "Admission control: $AC_RUNNING pod(s) running"
else
    warn "Admission control: not running yet"
fi

INIT_BUNDLE=$(oc get secret sensor-tls -n stackrox 2>/dev/null && echo "yes" || echo "no")
if [ "$INIT_BUNDLE" = "yes" ]; then
    pass "ACS init-bundle: sensor-tls secret exists"
else
    warn "ACS init-bundle: sensor-tls not found (init-bundle may not be applied yet)"
fi

# =============================================================================
section "Wave 7: RHTAS Operator"
# =============================================================================
RHTAS_CSV_NAME=$(oc get csv -n trusted-artifact-signer -l operators.coreos.com/rhtas-operator.trusted-artifact-signer \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
RHTAS_PHASE=$(oc get csv -n trusted-artifact-signer -l operators.coreos.com/rhtas-operator.trusted-artifact-signer \
    -o jsonpath='{.items[0].status.phase}' 2>/dev/null || true)
if [ "$RHTAS_PHASE" = "Succeeded" ]; then
    pass "RHTAS operator: Succeeded ($RHTAS_CSV_NAME)"
elif [ -n "$RHTAS_PHASE" ]; then
    warn "RHTAS operator: $RHTAS_PHASE"
else
    fail "RHTAS operator" "RHTAS operator: CSV not found"
fi

# =============================================================================
section "Wave 8: Keycloak Realm"
# =============================================================================
KC_REALM=$(oc get keycloakrealmimport trusted-artifact-signer -n keycloak \
    -o jsonpath='{.status.conditions[?(@.type=="Done")].status}' 2>/dev/null || true)
if [ "$KC_REALM" = "True" ]; then
    pass "Keycloak realm (trusted-artifact-signer): Done"
elif [ -n "$KC_REALM" ]; then
    warn "Keycloak realm: Done=$KC_REALM"
else
    KC_EXISTS=$(oc get keycloakrealmimport trusted-artifact-signer -n keycloak 2>/dev/null && echo "yes" || echo "no")
    if [ "$KC_EXISTS" = "yes" ]; then
        warn "Keycloak realm: created, import in progress"
    else
        fail "Keycloak realm" "Keycloak realm: KeycloakRealmImport not found in keycloak namespace"
    fi
fi

# =============================================================================
section "Wave 9: Gitea"
# =============================================================================
check_deployment "gitea" "gitea-operator" "Gitea operator"

GITEA_ROUTE=$(oc get route gitea-server -n gitea -o jsonpath='{.spec.host}' 2>/dev/null || true)
if [ -n "$GITEA_ROUTE" ]; then
    pass "Gitea route: https://$GITEA_ROUTE"
else
    GITEA_DEPLOY=$(oc get deployment gitea-server -n gitea -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)
    if [ -n "$GITEA_DEPLOY" ] && [ "$GITEA_DEPLOY" -gt 0 ] 2>/dev/null; then
        warn "Gitea: instance running but route not found"
    else
        warn "Gitea: instance not ready yet"
    fi
fi

# =============================================================================
section "Wave 10: Renovate Build Infrastructure"
# =============================================================================
check_namespace "renovate-pipelines"

PIPELINE_COUNT=$(oc get pipelines -n renovate-pipelines --no-headers 2>/dev/null | wc -l || true)
if [ "$PIPELINE_COUNT" -ge 2 ]; then
    pass "Tekton Pipelines: $PIPELINE_COUNT found (expected 2)"
else
    fail "Tekton Pipelines" "Tekton Pipelines: $PIPELINE_COUNT found in renovate-pipelines (expected 2)"
fi

TASK_COUNT=$(oc get tasks -n renovate-pipelines --no-headers 2>/dev/null | wc -l || true)
if [ "$TASK_COUNT" -ge 6 ]; then
    pass "Tekton Tasks: $TASK_COUNT found (expected 6)"
else
    fail "Tekton Tasks" "Tekton Tasks: $TASK_COUNT found in renovate-pipelines (expected 6)"
fi

for SA in tekton-triggers-sa renovate-trigger-sa; do
    if oc get sa "$SA" -n renovate-pipelines > /dev/null 2>&1; then
        pass "ServiceAccount $SA exists"
    else
        fail "SA $SA" "ServiceAccount $SA missing in renovate-pipelines"
    fi
done

check_secret "renovate-pipelines" "internal-registry-credentials" "Renovate registry credentials"
check_secret "renovate-pipelines" "cosign-signing-keys" "Cosign signing keys"

# =============================================================================
# SUMMARY
# =============================================================================
echo ""
echo -e "${BOLD}============================================================${NC}"
echo -e "${BOLD}  Validation Summary${NC}"
echo -e "${BOLD}============================================================${NC}"
echo ""
echo -e "  ${GREEN}PASS: ${PASS_COUNT}${NC}    ${YELLOW}WARN: ${WARN_COUNT}${NC}    ${RED}FAIL: ${FAIL_COUNT}${NC}"
echo ""

if [ ${#FAILED_COMPONENTS[@]} -gt 0 ]; then
    echo -e "  ${RED}Failed components:${NC}"
    for comp in "${FAILED_COMPONENTS[@]}"; do
        echo -e "    ${RED}•${NC} $comp"
    done
    echo ""
fi

if [ "$FAIL_COUNT" -gt 0 ]; then
    echo -e "  ${RED}Some checks failed. Review the output above for troubleshooting hints.${NC}"
    echo ""
    exit 1
elif [ "$WARN_COUNT" -gt 0 ]; then
    echo -e "  ${YELLOW}All critical checks passed but some components are still initializing.${NC}"
    echo -e "  ${YELLOW}Re-run this script in a few minutes to verify.${NC}"
    echo ""
    exit 0
else
    echo -e "  ${GREEN}All checks passed! Workshop environment is fully ready.${NC}"
    echo ""
    exit 0
fi
