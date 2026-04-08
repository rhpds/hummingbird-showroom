#!/bin/bash
# =============================================================================
# Hummingbird Workshop: Quay Registry Validation
#
# Performs a complete end-to-end health check of the Quay registry including:
#   1. NooBaa / ODF storage backend health
#   2. Quay operator and pod health
#   3. Quay HTTP health endpoint (all component services)
#   4. Per-user credential validation
#   5. Live skopeo push test to confirm blob upload works
#
# Usage:
#   ./scripts/validate-quay.sh [--users N] [--quick]
#
#   --users N   Number of lab users to test credentials for (default: auto-detect)
#   --quick     Skip the live push test (faster, no blob upload)
#
# Exit code: 0 if all checks pass, 1 if any FAIL.
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
QUICK=false
NUM_USERS=""

pass()  { echo -e "  ${GREEN}[PASS]${NC} $*";  PASS_COUNT=$((PASS_COUNT + 1)); }
warn()  { echo -e "  ${YELLOW}[WARN]${NC} $*"; WARN_COUNT=$((WARN_COUNT + 1)); }
fail()  { local c=$1; shift; echo -e "  ${RED}[FAIL]${NC} $*"; FAIL_COUNT=$((FAIL_COUNT + 1)); FAILED_COMPONENTS+=("$c"); }
section(){ echo ""; echo -e "${CYAN}${BOLD}=== $* ===${NC}"; }

while [[ $# -gt 0 ]]; do
    case $1 in
        --users) NUM_USERS="$2"; shift 2 ;;
        --quick) QUICK=true; shift ;;
        *) echo "Unknown arg: $1"; shift ;;
    esac
done

echo ""
echo -e "${BOLD}============================================================${NC}"
echo -e "${BOLD}  Hummingbird Workshop: Quay Registry Validation${NC}"
echo -e "${BOLD}============================================================${NC}"

if ! oc whoami > /dev/null 2>&1; then
    echo -e "${RED}ERROR: Not logged in to OpenShift. Run: oc login <api-url>${NC}"
    exit 1
fi

CLUSTER=$(oc whoami --show-server 2>/dev/null)
OC_USER=$(oc whoami 2>/dev/null)
echo ""
echo "  Cluster: ${CLUSTER}"
echo "  User:    ${OC_USER}"
echo "  Mode:    $(${QUICK} && echo quick || echo full-push-test)"

# =============================================================================
section "1. NooBaa Storage Backend"
# =============================================================================

NOOBAA_PHASE=$(oc get noobaa noobaa -n openshift-storage \
    -o jsonpath='{.status.phase}' 2>/dev/null || true)
NOOBAA_MODE=$(oc get backingstore noobaa-default-backing-store -n openshift-storage \
    -o jsonpath='{.status.mode.modeCode}' 2>/dev/null || true)
NOOBAA_BS_PHASE=$(oc get backingstore noobaa-default-backing-store -n openshift-storage \
    -o jsonpath='{.status.phase}' 2>/dev/null || true)

case "$NOOBAA_PHASE" in
    Ready)   pass "NooBaa CR: Ready" ;;
    "")      fail "NooBaa" "NooBaa CR not found in openshift-storage" ;;
    *)       warn "NooBaa CR: ${NOOBAA_PHASE} (expected Ready)" ;;
esac

case "$NOOBAA_BS_PHASE/$NOOBAA_MODE" in
    Ready/OPTIMAL) pass "BackingStore: Ready / OPTIMAL" ;;
    Ready/*)       warn "BackingStore: Ready but mode=${NOOBAA_MODE} (expected OPTIMAL)" ;;
    ""/*)          warn "BackingStore: noobaa-default-backing-store not found or mode unknown" ;;
    *)             fail "BackingStore" "BackingStore: phase=${NOOBAA_BS_PHASE} mode=${NOOBAA_MODE} (want Ready/OPTIMAL)" ;;
esac

# Check for OOMKill restarts on the backing-store pod
BS_POD=$(oc get pods -n openshift-storage -l pool=noobaa-default-backing-store \
    --no-headers 2>/dev/null | awk '{print $1}' | head -1 || true)
if [ -n "$BS_POD" ]; then
    BS_RESTARTS=$(oc get pod "$BS_POD" -n openshift-storage \
        -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null || echo "0")
    BS_READY=$(oc get pod "$BS_POD" -n openshift-storage \
        -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null || echo "false")
    LAST_REASON=$(oc get pod "$BS_POD" -n openshift-storage \
        -o jsonpath='{.status.containerStatuses[0].lastState.terminated.reason}' 2>/dev/null || true)
    if [ "$BS_READY" = "true" ] && [ "${BS_RESTARTS}" -le 2 ]; then
        pass "BackingStore pod ($BS_POD): ready, ${BS_RESTARTS} restart(s)"
    elif [ "$BS_READY" = "true" ]; then
        warn "BackingStore pod ($BS_POD): ready but ${BS_RESTARTS} restarts — last termination: ${LAST_REASON:-unknown}"
        echo "       TIP: High restarts often mean OOMKill during large blob uploads."
        echo "            Check: oc describe pod $BS_POD -n openshift-storage"
    else
        fail "BackingStore pod" "BackingStore pod $BS_POD not ready (restarts=${BS_RESTARTS}, last=${LAST_REASON:-?})"
        echo "       FIX: oc delete pod $BS_POD -n openshift-storage"
    fi
else
    warn "BackingStore pod: could not locate (label pool-secret=noobaa-default-backing-store)"
fi

# =============================================================================
section "2. Quay Operator & Pods"
# =============================================================================

QUAY_CSV=$(oc get csv -n quay -l operators.coreos.com/quay-operator.quay \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
QUAY_CSV_PHASE=$(oc get csv -n quay -l operators.coreos.com/quay-operator.quay \
    -o jsonpath='{.items[0].status.phase}' 2>/dev/null || true)
case "$QUAY_CSV_PHASE" in
    Succeeded) pass "Quay operator CSV: Succeeded ($QUAY_CSV)" ;;
    "")        fail "Quay operator" "Quay operator CSV not found in quay namespace" ;;
    *)         warn "Quay operator CSV: ${QUAY_CSV_PHASE} ($QUAY_CSV)" ;;
esac

QUAY_APP=$(oc get pods -n quay -l quay-component=quay-app --no-headers 2>/dev/null | grep Running | wc -l || echo 0)
if [ "$QUAY_APP" -gt 0 ]; then
    QUAY_RESTARTS=$(oc get pods -n quay -l quay-component=quay-app --no-headers 2>/dev/null | \
        awk '{sum+=$4} END {print sum+0}')
    pass "Quay app pods: ${QUAY_APP} running (total restarts: ${QUAY_RESTARTS})"
    [ "${QUAY_RESTARTS}" -gt 5 ] && warn "Quay app has ${QUAY_RESTARTS} total restarts — may be unstable"
else
    fail "Quay app" "Quay app: no running pods. Check: oc get pods -n quay"
fi

CLAIR=$(oc get pods -n quay -l quay-component=clair-app --no-headers 2>/dev/null | grep -c Running || echo 0)
if [ "$CLAIR" -gt 0 ]; then
    pass "Clair scanner: ${CLAIR} pod(s) running"
else
    warn "Clair scanner: not running (vulnerability scanning unavailable)"
fi

MIRROR=$(oc get pods -n quay -l quay-component=quay-mirror --no-headers 2>/dev/null | grep -c Running 2>/dev/null || true)
MIRROR=${MIRROR:-0}
[ "${MIRROR}" -gt 0 ] && pass "Quay mirror: ${MIRROR} pod(s) running" || warn "Quay mirror: not running"

# =============================================================================
section "3. Quay HTTP Health Endpoint"
# =============================================================================

QUAY_ROUTE=$(oc get route -n quay -l quay-operator/quayregistry=quay-registry \
    -o jsonpath='{.items[0].spec.host}' 2>/dev/null || true)

if [ -z "$QUAY_ROUTE" ]; then
    fail "Quay route" "Quay route not found — cannot run HTTP or push tests"
else
    pass "Quay route: https://${QUAY_ROUTE}"

    HTTP_STATUS=$(curl -sk --max-time 10 -o /dev/null -w '%{http_code}' \
        "https://${QUAY_ROUTE}/health/instance" 2>/dev/null || echo "000")
    if [ "$HTTP_STATUS" = "200" ]; then
        pass "Health endpoint HTTP: 200"
    else
        fail "Quay health HTTP" "Health endpoint returned HTTP ${HTTP_STATUS} (expected 200)"
    fi

    HEALTH_JSON=$(curl -sk --max-time 10 "https://${QUAY_ROUTE}/health/instance" 2>/dev/null || echo "{}")
    ALL_HEALTHY=$(echo "$HEALTH_JSON" | python3 -c "
import json,sys
try:
    d = json.load(sys.stdin)
    svcs = d.get('data',{}).get('services',{})
    failing = [k for k,v in svcs.items() if not v]
    print('OK' if not failing else 'FAIL:' + ','.join(failing))
except Exception as e:
    print('PARSE_ERROR:' + str(e))
" 2>/dev/null || echo "PARSE_ERROR")

    case "$ALL_HEALTHY" in
        OK)             pass "Quay services: all healthy (auth, db, disk, registry, web)" ;;
        FAIL:*)         fail "Quay services" "Unhealthy components: ${ALL_HEALTHY#FAIL:}" ;;
        PARSE_ERROR:*)  warn "Quay health: could not parse response (${ALL_HEALTHY})" ;;
        *)              warn "Quay health: unexpected response" ;;
    esac
fi

# =============================================================================
section "4. Per-User Credentials"
# =============================================================================

# Auto-detect users if not specified
if [ -z "$NUM_USERS" ]; then
    NUM_USERS=$(oc get namespace --no-headers 2>/dev/null | \
        grep -c 'hummingbird-builds-lab-user-' || echo 0)
fi

echo "  Checking ${NUM_USERS} user namespace(s)..."

for i in $(seq 1 "${NUM_USERS}"); do
    USER="lab-user-${i}"
    NS="hummingbird-builds-${USER}"

    # Namespace
    if ! oc get ns "$NS" > /dev/null 2>&1; then
        fail "NS ${NS}" "Namespace ${NS} does not exist"
        continue
    fi

    # registry-credentials secret
    if ! oc get secret registry-credentials -n "$NS" > /dev/null 2>&1; then
        fail "Creds ${USER}" "registry-credentials secret missing in ${NS}"
        continue
    fi

    # Decode and verify it has the right registry host
    DECODED=$(oc get secret registry-credentials -n "$NS" \
        -o jsonpath='{.data.\.dockerconfigjson}' 2>/dev/null | base64 -d 2>/dev/null || echo "{}")
    if echo "$DECODED" | grep -q "$QUAY_ROUTE" 2>/dev/null; then
        pass "registry-credentials (${USER}): valid, targets ${QUAY_ROUTE}"
    else
        fail "Creds ${USER}" "registry-credentials in ${NS} does not reference ${QUAY_ROUTE}"
    fi

    # quay-pull-secret (used in ACS lab)
    ACS_NS="hummingbird-acs-lab"
    if oc get secret quay-pull-secret -n "$ACS_NS" > /dev/null 2>&1; then
        pass "quay-pull-secret: present in ${ACS_NS}"
    else
        warn "quay-pull-secret: missing in ${ACS_NS} (needed for ACS lab builds)"
    fi
done

# =============================================================================
section "5. Live Push Test (skopeo)"
# =============================================================================

if $QUICK; then
    warn "Live push test: SKIPPED (--quick mode)"
elif [ -z "$QUAY_ROUTE" ]; then
    fail "Push test" "Push test: skipped — Quay route not found"
else
    # Use lab-user-1 credentials (default password = openshift)
    TEST_USER="lab-user-1"
    TEST_PASS=$(oc get secret registry-credentials -n "hummingbird-builds-${TEST_USER}" \
        -o jsonpath='{.data.\.dockerconfigjson}' 2>/dev/null | \
        base64 -d 2>/dev/null | \
        python3 -c "import json,sys; d=json.load(sys.stdin); \
            auths=d.get('auths',{}); \
            entry=list(auths.values())[0] if auths else {}; \
            print(entry.get('password',''))" 2>/dev/null || echo "openshift")

    TEST_IMAGE="docker://${QUAY_ROUTE}/${TEST_USER}/validate-push-test:latest"

    echo ""
    echo "  Pushing alpine:3.20.3 → ${TEST_IMAGE}"
    echo "  (This confirms blob upload to NooBaa storage works end-to-end)"
    echo ""

    PUSH_OUTPUT=$(skopeo copy --dest-tls-verify=false \
        --dest-creds="${TEST_USER}:${TEST_PASS}" \
        docker://docker.io/library/alpine:3.20.3 \
        "${TEST_IMAGE}" 2>&1)
    PUSH_EXIT=$?

    echo "$PUSH_OUTPUT" | sed 's/^/    /'

    if [ $PUSH_EXIT -eq 0 ]; then
        pass "Live push test: SUCCESS — blob upload to Quay + NooBaa works"
    else
        if echo "$PUSH_OUTPUT" | grep -qiE "blob upload invalid|EOF|connection reset"; then
            fail "Push test" "Push FAILED with blob upload error — NooBaa may be OOMKilling again"
            echo ""
            echo "  DIAGNOSIS:"
            BS_POD2=$(oc get pods -n openshift-storage -l pool=noobaa-default-backing-store \
                --no-headers 2>/dev/null | awk '{print $1}' | head -1 || true)
            if [ -n "$BS_POD2" ]; then
                REST2=$(oc get pod "$BS_POD2" -n openshift-storage \
                    -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null || echo "?")
                READY2=$(oc get pod "$BS_POD2" -n openshift-storage \
                    -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null || echo "?")
                echo "    BackingStore pod: ${BS_POD2} | ready=${READY2} | restarts=${REST2}"
            fi
            echo "  FIX: oc delete pod $BS_POD -n openshift-storage  # force restart"
        elif echo "$PUSH_OUTPUT" | grep -qi "unauthorized\|authentication"; then
            fail "Push test" "Push FAILED with auth error — check registry-credentials secret for ${TEST_USER}"
        else
            fail "Push test" "Push FAILED (exit=${PUSH_EXIT}) — see output above"
        fi
    fi
fi

# =============================================================================
# SUMMARY
# =============================================================================
echo ""
echo -e "${BOLD}============================================================${NC}"
echo -e "${BOLD}  Quay Validation Summary${NC}"
echo -e "${BOLD}============================================================${NC}"
echo ""
echo -e "  ${GREEN}PASS: ${PASS_COUNT}${NC}    ${YELLOW}WARN: ${WARN_COUNT}${NC}    ${RED}FAIL: ${FAIL_COUNT}${NC}"
echo ""

if [ ${#FAILED_COMPONENTS[@]} -gt 0 ]; then
    echo -e "  ${RED}Failed:${NC}"
    for c in "${FAILED_COMPONENTS[@]}"; do
        echo -e "    ${RED}•${NC} $c"
    done
    echo ""
fi

if [ "$FAIL_COUNT" -gt 0 ]; then
    echo -e "  ${RED}Quay registry has failures. Review output above for fixes.${NC}"
    echo ""
    exit 1
elif [ "$WARN_COUNT" -gt 0 ]; then
    echo -e "  ${YELLOW}Quay is functional but some non-critical components need attention.${NC}"
    echo ""
    exit 0
else
    echo -e "  ${GREEN}All Quay checks passed — registry is fully healthy.${NC}"
    echo ""
    exit 0
fi
