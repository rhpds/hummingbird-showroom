#!/bin/bash
# =============================================================================
# Hummingbird Workshop: OpenShift Platform Environment Setup
#
# Prepares an OpenShift cluster for Module 2 labs.
# Verifies cluster access, creates the workshop namespace, installs
# OpenShift Pipelines (Tekton) and Builds for Red Hat OpenShift (Shipwright)
# operators, and verifies CRDs.
#
# Prerequisites:
#   - oc CLI installed and logged in with cluster-admin privileges
#
# Usage:
#   chmod +x setup-openshift-platform.sh
#   ./setup-openshift-platform.sh
#
# For more details, see Appendix B in the workshop guide.
# =============================================================================
set -euo pipefail

echo "=== Hummingbird Workshop: OpenShift Platform Setup ==="
echo ""

# --- Verify Cluster Access ---
echo "[1/6] Verifying OpenShift cluster access..."
if ! oc whoami > /dev/null 2>&1; then
    echo "ERROR: Not logged in to OpenShift. Run: oc login <api-url> -u <user>"
    exit 1
fi
echo "  Logged in as: $(oc whoami)"
echo "  Server: $(oc whoami --show-server)"

# --- Verify Cluster-Admin ---
echo "[2/6] Verifying cluster-admin privileges..."
if ! oc auth can-i create clusterrole > /dev/null 2>&1; then
    echo "ERROR: cluster-admin privileges required."
    exit 1
fi
echo "  cluster-admin: confirmed"

# --- Create Namespace ---
echo "[3/6] Creating hummingbird-builds namespace..."
if oc get project hummingbird-builds > /dev/null 2>&1; then
    echo "  Namespace already exists, switching to it..."
    oc project hummingbird-builds
else
    oc new-project hummingbird-builds
fi

# --- Install OpenShift Pipelines (Tekton) ---
echo "[4/6] Verifying/Installing OpenShift Pipelines (Tekton)..."
if oc get pods -n openshift-pipelines 2>/dev/null | grep -q Running; then
    echo "  OpenShift Pipelines already installed and running."
else
    echo "  Installing OpenShift Pipelines operator..."
    cat << 'TEKTON_EOF' | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: openshift-pipelines-operator
  namespace: openshift-operators
spec:
  channel: latest
  name: openshift-pipelines-operator-rh
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
TEKTON_EOF

    echo "  Waiting for OpenShift Pipelines to become ready (up to 5 minutes)..."
    for i in $(seq 1 60); do
        if oc get pods -n openshift-pipelines 2>/dev/null | grep -q Running; then
            echo "  OpenShift Pipelines installed successfully."
            break
        fi
        if [ "$i" -eq 60 ]; then
            echo "  WARNING: OpenShift Pipelines not yet ready. Check: oc get pods -n openshift-pipelines"
        fi
        sleep 5
    done
fi

# --- Install Builds Operator ---
echo "[5/6] Installing Builds for Red Hat OpenShift operator..."
cat << 'EOF' | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-builds
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: openshift-builds-operator-group
  namespace: openshift-builds
spec: {}
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: openshift-builds-operator
  namespace: openshift-builds
spec:
  channel: latest
  name: openshift-builds-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
EOF

echo "  Waiting for operator to reach Succeeded phase (up to 5 minutes)..."
for i in $(seq 1 60); do
    PHASE=$(oc get csv -n openshift-builds -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "Pending")
    if [ "$PHASE" = "Succeeded" ]; then
        echo "  Operator installed successfully."
        break
    fi
    if [ "$i" -eq 60 ]; then
        echo "  WARNING: Operator not yet in Succeeded phase. Check with: oc get csv -n openshift-builds"
    fi
    sleep 5
done

# --- Verify CRDs ---
echo "[6/6] Verifying Shipwright CRDs and Tekton..."
for CRD in builds.shipwright.io buildruns.shipwright.io buildstrategies.shipwright.io clusterbuildstrategies.shipwright.io; do
    if oc get crd "$CRD" > /dev/null 2>&1; then
        echo "  $CRD: found"
    else
        echo "  $CRD: NOT FOUND (operator may still be installing)"
    fi
done

TEKTON_STATUS="unknown"
if oc get pods -n openshift-pipelines 2>/dev/null | grep -q Running; then
    TEKTON_STATUS="running"
    echo "  OpenShift Pipelines (Tekton): running"
else
    TEKTON_STATUS="not ready"
    echo "  OpenShift Pipelines (Tekton): NOT READY"
fi

echo ""
echo "=== Setup Complete ==="
echo "Cluster:    $(oc whoami --show-server)"
echo "User:       $(oc whoami)"
echo "Namespace:  hummingbird-builds"
echo "Builds:     $(oc get csv -n openshift-builds -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo 'installing...')"
echo "Pipelines:  $TEKTON_STATUS"
echo ""
echo "Proceed to Module 2 to start the workshop labs."
