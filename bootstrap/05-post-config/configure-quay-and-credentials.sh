#!/bin/bash
set -euo pipefail

QUAY_NAMESPACE="${QUAY_NAMESPACE:-quay}"
BUILDS_NAMESPACE="${BUILDS_NAMESPACE:-hummingbird-builds}"
REGISTRY_USER="${REGISTRY_USER:-workshopuser}"
REGISTRY_PASSWORD="${REGISTRY_PASSWORD:-workshoppass123}"
REGISTRY_EMAIL="${REGISTRY_EMAIL:-workshop@example.com}"
NUM_USERS="${NUM_USERS:-1}"

echo "=== Quay Post-Configuration ==="
echo "  NUM_USERS=${NUM_USERS}"
echo ""

# --- Get Quay route ---
echo "[1/6] Discovering Quay registry route..."
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

# --- Initialize first user (superuser) ---
echo "[2/6] Initializing Quay first user (${REGISTRY_USER})..."
INIT_RESPONSE=$(curl -sk "https://${QUAY_ROUTE}/api/v1/user/initialize" \
    -H 'Content-Type: application/json' \
    -d "{
        \"username\": \"${REGISTRY_USER}\",
        \"password\": \"${REGISTRY_PASSWORD}\",
        \"email\": \"${REGISTRY_EMAIL}\",
        \"access_token\": true
    }" 2>/dev/null || true)

ACCESS_TOKEN=""
if echo "$INIT_RESPONSE" | grep -q "access_token"; then
    ACCESS_TOKEN=$(echo "$INIT_RESPONSE" | python3 -c "import json,sys; print(json.load(sys.stdin).get('access_token',''))" 2>/dev/null || true)
    echo "  First user created successfully. Access token obtained."
elif echo "$INIT_RESPONSE" | grep -q "already been initialized"; then
    echo "  Quay already initialized (first user exists). Continuing..."
else
    echo "  WARNING: Unexpected response from Quay init API:"
    echo "  $INIT_RESPONSE"
    echo "  Continuing anyway -- you may need to create the user manually via the Quay console."
fi

# --- Create registry-credentials for primary user ---
echo "[3/6] Creating registry-credentials secret for ${REGISTRY_USER} in ${BUILDS_NAMESPACE}..."
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
echo "[4/6] Linking secret to pipeline ServiceAccount..."
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

# --- Create additional workshop users (if NUM_USERS > 1) ---
echo "[5/6] Creating additional workshop users..."
if [ "${NUM_USERS}" -gt 1 ]; then
    if [ -z "$ACCESS_TOKEN" ]; then
        echo "  WARNING: No API token available. Attempting to obtain one via OAuth..."
        ACCESS_TOKEN=$(curl -sk "https://${QUAY_ROUTE}/api/v1/user/initialize" \
            -H 'Content-Type: application/json' \
            -d "{
                \"username\": \"${REGISTRY_USER}\",
                \"password\": \"${REGISTRY_PASSWORD}\",
                \"email\": \"${REGISTRY_EMAIL}\",
                \"access_token\": true
            }" 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin).get('access_token',''))" 2>/dev/null || true)
    fi

    for n in $(seq 1 "${NUM_USERS}"); do
        USER="workshopuser${n}"
        PASS="workshoppass${n}"
        EMAIL="workshop${n}@example.com"
        SECRET_NAME="registry-credentials-user${n}"

        echo "  Creating user: ${USER}"

        if [ -n "$ACCESS_TOKEN" ]; then
            curl -sk "https://${QUAY_ROUTE}/api/v1/superuser/users/" \
                -H "Authorization: Bearer ${ACCESS_TOKEN}" \
                -H 'Content-Type: application/json' \
                -d "{\"username\": \"${USER}\", \"email\": \"${EMAIL}\", \"password\": \"${PASS}\"}" \
                > /dev/null 2>&1 || echo "    User ${USER} may already exist."
        else
            echo "    WARNING: No API token -- create ${USER} manually in Quay console."
        fi

        if oc get secret "${SECRET_NAME}" -n "${BUILDS_NAMESPACE}" > /dev/null 2>&1; then
            oc delete secret "${SECRET_NAME}" -n "${BUILDS_NAMESPACE}"
        fi

        oc create secret docker-registry "${SECRET_NAME}" \
            --docker-server="${QUAY_ROUTE}" \
            --docker-username="${USER}" \
            --docker-password="${PASS}" \
            -n "${BUILDS_NAMESPACE}"

        if oc get sa pipeline -n "${BUILDS_NAMESPACE}" > /dev/null 2>&1; then
            oc secrets link pipeline "${SECRET_NAME}" --for=pull,mount -n "${BUILDS_NAMESPACE}"
        fi

        echo "    ${USER}: secret ${SECRET_NAME} created and linked."
    done
else
    echo "  NUM_USERS=1 -- single-user mode, no additional users needed."
fi

# --- Verify Clair ---
echo "[6/6] Verifying Clair vulnerability scanner..."
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
if [ "${NUM_USERS}" -gt 1 ]; then
    echo "Extra users: workshopuser1 through workshopuser${NUM_USERS}"
    echo "Secrets:     registry-credentials-user1 through registry-credentials-user${NUM_USERS}"
fi
