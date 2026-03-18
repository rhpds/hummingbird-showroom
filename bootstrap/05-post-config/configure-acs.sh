#!/bin/bash
set -euo pipefail

ACS_NAMESPACE="${ACS_NAMESPACE:-stackrox}"

echo "=== ACS Post-Configuration ==="
echo ""

# --- Wait for Central deployment ---
echo "[1/6] Waiting for ACS Central to be ready..."
for i in $(seq 1 60); do
    if oc get deployment central -n "${ACS_NAMESPACE}" > /dev/null 2>&1; then
        AVAILABLE=$(oc get deployment central -n "${ACS_NAMESPACE}" -o jsonpath='{.status.availableReplicas}' 2>/dev/null || echo "0")
        if [ "${AVAILABLE:-0}" -ge 1 ]; then
            echo "  Central is ready."
            break
        fi
    fi
    if [ "$i" -eq 60 ]; then
        echo "  WARNING: Central not ready after 5 minutes. Continuing..."
    fi
    echo "  Waiting for Central deployment... (${i}/60)"
    sleep 5
done

# --- Get ACS admin password ---
echo "[2/6] Retrieving ACS admin password..."
ACS_PASSWORD=""
if oc get secret central-htpasswd -n "${ACS_NAMESPACE}" > /dev/null 2>&1; then
    ACS_PASSWORD=$(oc get secret central-htpasswd -n "${ACS_NAMESPACE}" -o jsonpath='{.data.password}' | base64 -d)
    echo "  ACS admin password: ${ACS_PASSWORD}"
else
    echo "  WARNING: central-htpasswd secret not found. Central may still be initializing."
fi

# --- Get ACS route ---
echo "[3/6] Discovering ACS Central route..."
ACS_ROUTE=""
for i in $(seq 1 12); do
    ACS_ROUTE=$(oc get route central -n "${ACS_NAMESPACE}" -o jsonpath='{.spec.host}' 2>/dev/null || true)
    if [ -n "$ACS_ROUTE" ]; then
        break
    fi
    echo "  Waiting for ACS route... (${i}/12)"
    sleep 10
done

if [ -n "$ACS_ROUTE" ]; then
    echo "  ACS Central URL: https://${ACS_ROUTE}"
else
    echo "  WARNING: Could not discover ACS Central route."
fi

# --- Generate and apply init bundle for SecuredCluster ---
echo "[4/6] Generating cluster init bundle for SecuredCluster..."
if [ -n "$ACS_ROUTE" ] && [ -n "$ACS_PASSWORD" ]; then
    if oc get secret sensor-tls -n "${ACS_NAMESPACE}" > /dev/null 2>&1; then
        echo "  Init bundle secrets already exist. Skipping."
    else
        BUNDLE_NAME="workshop-cluster-$(date +%s)"
        curl -sk -u "admin:${ACS_PASSWORD}" \
            "https://${ACS_ROUTE}/v1/cluster-init/init-bundles" \
            -X POST -H 'Content-Type: application/json' \
            -d "{\"name\": \"${BUNDLE_NAME}\"}" \
            -o /tmp/init-bundle.json

        python3 -c "
import json, base64
with open('/tmp/init-bundle.json') as f:
    data = json.load(f)
    bundle = data.get('kubectlBundle', '')
    decoded = base64.b64decode(bundle).decode('utf-8')
    with open('/tmp/init-bundle-secrets.yaml', 'w') as out:
        out.write(decoded)
"
        oc apply -f /tmp/init-bundle-secrets.yaml -n "${ACS_NAMESPACE}"
        rm -f /tmp/init-bundle.json /tmp/init-bundle-secrets.yaml
        echo "  Init bundle applied. SecuredCluster will reconcile shortly."

        echo "  Waiting for SecuredCluster to become ready (up to 3 minutes)..."
        for i in $(seq 1 36); do
            SC_STATUS=$(oc get securedcluster -n "${ACS_NAMESPACE}" -o jsonpath='{.items[0].status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "Unknown")
            if [ "$SC_STATUS" = "True" ]; then
                echo "  SecuredCluster is available."
                break
            fi
            sleep 5
        done
    fi
else
    echo "  WARNING: Cannot generate init bundle (missing route or password)."
fi

# --- Install roxctl ---
echo "[5/6] Installing roxctl CLI..."
if [ -n "$ACS_ROUTE" ]; then
    curl -sk "https://${ACS_ROUTE}/api/cli/download/roxctl-linux" -o /tmp/roxctl 2>/dev/null
    if [ -s /tmp/roxctl ]; then
        chmod +x /tmp/roxctl
        sudo mv /tmp/roxctl /usr/local/bin/roxctl 2>/dev/null || mv /tmp/roxctl "${HOME}/.local/bin/roxctl" 2>/dev/null || {
            mkdir -p "${HOME}/.local/bin"
            mv /tmp/roxctl "${HOME}/.local/bin/roxctl"
        }
        echo "  roxctl installed: $(roxctl version 2>/dev/null || echo 'installed but not in PATH')"
    else
        echo "  WARNING: roxctl download was empty. Central may not be fully ready."
    fi
else
    echo "  Skipping roxctl install (no ACS route available)."
fi

# --- Verify ACS pods and webhook ---
echo "[6/6] Verifying ACS installation..."
echo "  Pods in ${ACS_NAMESPACE}:"
oc get pods -n "${ACS_NAMESPACE}" --no-headers 2>/dev/null || echo "  (no pods found)"
echo ""

WEBHOOK_COUNT=$(oc get ValidatingWebhookConfiguration -l app.kubernetes.io/name=stackrox --no-headers 2>/dev/null | wc -l)
if [ "$WEBHOOK_COUNT" -gt 0 ]; then
    echo "  Admission control webhook: registered"
    oc get ValidatingWebhookConfiguration -l app.kubernetes.io/name=stackrox --no-headers
else
    echo "  Admission control webhook: not yet registered (SecuredCluster may still be starting)"
fi

echo ""
echo "=== ACS Configuration Complete ==="
if [ -n "$ACS_ROUTE" ]; then
    echo "Central URL: https://${ACS_ROUTE}"
fi
if [ -n "$ACS_PASSWORD" ]; then
    echo "Admin user:  admin"
    echo "Password:    ${ACS_PASSWORD}"
fi
