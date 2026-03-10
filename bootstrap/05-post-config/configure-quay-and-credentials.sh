#!/bin/bash
set -euo pipefail

QUAY_NAMESPACE="${QUAY_NAMESPACE:-quay}"
BUILDS_NAMESPACE="${BUILDS_NAMESPACE:-hummingbird-builds}"
REGISTRY_USER="${REGISTRY_USER:-workshopuser}"
REGISTRY_PASSWORD="${REGISTRY_PASSWORD:-workshoppass123}"
REGISTRY_EMAIL="${REGISTRY_EMAIL:-workshop@example.com}"

echo "=== Quay Post-Configuration ==="
echo ""

# --- Get Quay route ---
echo "[1/5] Discovering Quay registry route..."
QUAY_ROUTE=""
for i in $(seq 1 30); do
    QUAY_ROUTE=$(oc get route -n "${QUAY_NAMESPACE}" -l quay-operator/quayregistry=quay-registry \
        -o jsonpath='{.items[0].spec.host}' 2>/dev/null || true)
    if [ -n "$QUAY_ROUTE" ]; then
        break
    fi
    echo "  Waiting for Quay route to appear... (${i}/30)"
    sleep 10
done

if [ -z "$QUAY_ROUTE" ]; then
    echo "ERROR: Could not discover Quay route after 5 minutes."
    echo "  Check: oc get routes -n ${QUAY_NAMESPACE}"
    exit 1
fi
echo "  Quay registry: ${QUAY_ROUTE}"
echo "  Quay console:  https://${QUAY_ROUTE}"

# --- Initialize first user ---
echo "[2/5] Initializing Quay first user..."
INIT_RESPONSE=$(curl -sk "https://${QUAY_ROUTE}/api/v1/user/initialize" \
    -H 'Content-Type: application/json' \
    -d "{
        \"username\": \"${REGISTRY_USER}\",
        \"password\": \"${REGISTRY_PASSWORD}\",
        \"email\": \"${REGISTRY_EMAIL}\",
        \"access_token\": true
    }" 2>/dev/null || true)

if echo "$INIT_RESPONSE" | grep -q "access_token"; then
    echo "  First user created successfully."
elif echo "$INIT_RESPONSE" | grep -q "already been initialized"; then
    echo "  Quay already initialized (first user exists). Continuing..."
else
    echo "  WARNING: Unexpected response from Quay init API:"
    echo "  $INIT_RESPONSE"
    echo "  Continuing anyway -- you may need to create the user manually via the Quay console."
fi

# --- Create registry-credentials secret ---
echo "[3/5] Creating registry-credentials secret in ${BUILDS_NAMESPACE}..."
if oc get secret registry-credentials -n "${BUILDS_NAMESPACE}" > /dev/null 2>&1; then
    echo "  Secret already exists, deleting and recreating..."
    oc delete secret registry-credentials -n "${BUILDS_NAMESPACE}"
fi

oc create secret docker-registry registry-credentials \
    --docker-server="${QUAY_ROUTE}" \
    --docker-username="${REGISTRY_USER}" \
    --docker-password="${REGISTRY_PASSWORD}" \
    -n "${BUILDS_NAMESPACE}"
echo "  Secret created."

# --- Link secret to pipeline ServiceAccount ---
echo "[4/5] Linking secret to pipeline ServiceAccount..."
for i in $(seq 1 12); do
    if oc get sa pipeline -n "${BUILDS_NAMESPACE}" > /dev/null 2>&1; then
        break
    fi
    echo "  Waiting for pipeline ServiceAccount... (${i}/12)"
    sleep 10
done

if oc get sa pipeline -n "${BUILDS_NAMESPACE}" > /dev/null 2>&1; then
    oc secrets link pipeline registry-credentials --for=pull,mount -n "${BUILDS_NAMESPACE}"
    echo "  Secret linked to pipeline ServiceAccount."
else
    echo "  WARNING: pipeline ServiceAccount not found. Link manually after Pipelines operator is ready:"
    echo "    oc secrets link pipeline registry-credentials --for=pull,mount -n ${BUILDS_NAMESPACE}"
fi

# --- Verify Clair ---
echo "[5/5] Verifying Clair vulnerability scanner..."
CLAIR_PODS=$(oc get pods -n "${QUAY_NAMESPACE}" -l quay-component=clair-app --no-headers 2>/dev/null | wc -l)
if [ "$CLAIR_PODS" -gt 0 ]; then
    echo "  Clair pods found: ${CLAIR_PODS}"
    oc get pods -n "${QUAY_NAMESPACE}" -l quay-component=clair-app --no-headers
else
    echo "  WARNING: No Clair pods found yet. They may still be starting."
fi

echo ""
echo "=== Quay Configuration Complete ==="
echo "Registry:    ${QUAY_ROUTE}"
echo "Console:     https://${QUAY_ROUTE}"
echo "User:        ${REGISTRY_USER}"
echo "Secret:      registry-credentials (in ${BUILDS_NAMESPACE})"
