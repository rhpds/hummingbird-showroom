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

# --- Create per-user Quay accounts via DB (if NUM_USERS > 1) ---
USER_PREFIX="${USER_PREFIX:-lab-user}"
USER_PASSWORD="${USER_PASSWORD:-openshift}"

echo "[5/6] Creating per-user Quay accounts..."
if [ "${NUM_USERS}" -gt 1 ]; then
    QUAY_APP_POD=$(oc get pods -n "${QUAY_NAMESPACE}" -l quay-component=quay-app \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    QUAY_DB_POD=$(oc get pods -n "${QUAY_NAMESPACE}" -l quay-component=postgres \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

    if [ -n "${QUAY_APP_POD}" ] && [ -n "${QUAY_DB_POD}" ]; then
        echo "  Generating bcrypt hash for per-user password..."
        BCRYPT_HASH=$(oc exec -n "${QUAY_NAMESPACE}" "${QUAY_APP_POD}" -- \
            python3 -c "import bcrypt; print(bcrypt.hashpw(b'${USER_PASSWORD}', bcrypt.gensalt(rounds=12)).decode())" 2>/dev/null || true)

        if [ -n "${BCRYPT_HASH}" ]; then
            QUAY_DB_USER=$(oc get pods -n "${QUAY_NAMESPACE}" "${QUAY_DB_POD}" \
                -o jsonpath='{.spec.containers[0].env[?(@.name=="POSTGRESQL_USER")].value}' 2>/dev/null || echo "quay-registry-quay-database")
            QUAY_DB_NAME="${QUAY_DB_USER}"

            for n in $(seq 1 "${NUM_USERS}"); do
                USERNAME="${USER_PREFIX}-${n}"
                USER_EMAIL="${USERNAME}@demo.redhat.com"
                USER_UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || python3 -c "import uuid; print(str(uuid.uuid4()))")
                SECRET_NAME="registry-credentials-${USERNAME}"

                echo "  Creating Quay user: ${USERNAME}"
                oc exec -n "${QUAY_NAMESPACE}" "${QUAY_DB_POD}" -- \
                    psql -U "${QUAY_DB_USER}" -d "${QUAY_DB_NAME}" -c \
                    "INSERT INTO \"user\" (uuid, username, password_hash, email, verified, organization, robot, invoice_email, invalid_login_attempts, last_invalid_login, removed_tag_expiration_s, enabled, creation_date)
                     VALUES ('${USER_UUID}', '${USERNAME}', '${BCRYPT_HASH}', '${USER_EMAIL}', true, false, false, false, 0, '1970-01-01 00:00:00', 1209600, true, now())
                     ON CONFLICT (username) DO UPDATE SET password_hash = EXCLUDED.password_hash, verified = true, organization = false, enabled = true;" \
                    2>/dev/null && echo "    Quay user ${USERNAME}: OK" || echo "    Quay user ${USERNAME}: WARN - check manually"

                if oc get secret "${SECRET_NAME}" -n "${BUILDS_NAMESPACE}" > /dev/null 2>&1; then
                    oc delete secret "${SECRET_NAME}" -n "${BUILDS_NAMESPACE}"
                fi

                oc create secret docker-registry "${SECRET_NAME}" \
                    --docker-server="${QUAY_ROUTE}" \
                    --docker-username="${USERNAME}" \
                    --docker-password="${USER_PASSWORD}" \
                    -n "${BUILDS_NAMESPACE}"

                if oc get sa pipeline -n "${BUILDS_NAMESPACE}" > /dev/null 2>&1; then
                    oc secrets link pipeline "${SECRET_NAME}" --for=pull,mount -n "${BUILDS_NAMESPACE}"
                fi

                echo "    ${USERNAME}: secret ${SECRET_NAME} created and linked."
            done
        else
            echo "  WARNING: Could not generate bcrypt hash. Per-user accounts not created."
            echo "  Use scripts/setup-workshop-users.sh for full per-user provisioning."
        fi
    else
        echo "  WARNING: Quay app or DB pod not found. Per-user accounts not created."
    fi
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
    echo "Per-user:    ${USER_PREFIX}-1 through ${USER_PREFIX}-${NUM_USERS} (password: ${USER_PASSWORD})"
    echo "Secrets:     registry-credentials-${USER_PREFIX}-1 through registry-credentials-${USER_PREFIX}-${NUM_USERS}"
fi
