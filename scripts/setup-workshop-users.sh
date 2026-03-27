#!/bin/bash
# =============================================================================
# Hummingbird Workshop: Per-User Environment Setup
#
# Creates workshop user accounts and their per-user namespaces with all
# required RBAC, SCC bindings, and registry credentials.
#
# For each user this script:
#   1.  Creates the user in the Keycloak SSO realm (for OpenShift login)
#   2.  Creates hummingbird-builds-<user> namespace
#   3.  Grants admin RoleBinding on shared + per-user + renovate-pipelines namespaces
#   4.  Configures privileged SCC for pipeline and default ServiceAccounts
#   5.  Creates per-user Quay account (via DB) + registry-credentials secret
#   6.  Grants self-provisioner so user can create projects during labs
#   7.  Binds workshop-participant ClusterRole (ClusterBuildStrategy, imageregistry, webhooks)
#   8.  Grants view on infrastructure namespaces (quay, stackrox, keycloak, RHTAS, gitea)
#   9.  Grants ACS secret reader for central-htpasswd in stackrox
#   10. Fixes Gitea must-change-password flag
#   11. (Optional) Deploys a per-user Showroom instance with embedded terminal
#   12. (Optional) Updates existing Showroom ConfigMap if Showroom already deployed
#
# On completion, writes workshop-users-access.txt with all credentials and URLs.
#
# Usage:
#   NUM_USERS=3 ./scripts/setup-workshop-users.sh
#   NUM_USERS=3 DEPLOY_SHOWROOM=true ./scripts/setup-workshop-users.sh
#   NUM_USERS=1 USER_PREFIX=lab-user PASSWORD=openshift ./scripts/setup-workshop-users.sh
#
# Environment variables:
#   NUM_USERS      - Number of users to create (default: 1)
#   USER_PREFIX    - Username prefix; users are named <prefix>-1, <prefix>-2, etc. (default: lab-user)
#   PASSWORD       - Password for all users (default: openshift)
#   BUILDS_NS      - Shared builds namespace (default: hummingbird-builds)
#   QUAY_NAMESPACE - Quay namespace (default: quay)
#   KC_ADMIN_USER  - Keycloak admin username (default: temp-admin)
#   KC_ADMIN_PASS  - Keycloak admin password (auto-detected from secret if not set)
#   SKIP_KEYCLOAK  - Set to "true" to skip Keycloak user creation (default: false)
#   DEPLOY_SHOWROOM - Set to "true" to deploy a per-user Showroom instance (default: false)
#   SHOWROOM_REPO  - Git repo URL for Showroom content (default: https://github.com/tosin2013/zero-cve-hummingbird-showroom.git)
#   SHOWROOM_BRANCH - Git branch for Showroom content (default: main)
# =============================================================================
set -euo pipefail

NUM_USERS="${NUM_USERS:-1}"
USER_PREFIX="${USER_PREFIX:-lab-user}"
PASSWORD="${PASSWORD:-openshift}"
BUILDS_NS="${BUILDS_NS:-hummingbird-builds}"
QUAY_NAMESPACE="${QUAY_NAMESPACE:-quay}"
KC_ADMIN_USER="${KC_ADMIN_USER:-temp-admin}"
KC_ADMIN_PASS="${KC_ADMIN_PASS:-}"
SKIP_KEYCLOAK="${SKIP_KEYCLOAK:-false}"
DEPLOY_SHOWROOM="${DEPLOY_SHOWROOM:-false}"
SHOWROOM_REPO="${SHOWROOM_REPO:-https://github.com/tosin2013/zero-cve-hummingbird-showroom.git}"
SHOWROOM_BRANCH="${SHOWROOM_BRANCH:-main}"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ---- Prerequisites ----
if ! oc whoami > /dev/null 2>&1; then
    error "Not logged in to OpenShift. Run: oc login <api-url>"
fi
if ! oc auth can-i create namespace > /dev/null 2>&1; then
    error "cluster-admin privileges required."
fi

CLUSTER_DOMAIN=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}' 2>/dev/null || echo "")

if [ "${DEPLOY_SHOWROOM}" = "true" ]; then
    HELM_BIN=$(command -v helm 2>/dev/null || echo "")
    if [ -z "${HELM_BIN}" ]; then
        warn "helm not found in PATH. Attempting to install..."
        curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | HELM_INSTALL_DIR="${HOME}/.local/bin" bash 2>/dev/null || true
        HELM_BIN=$(command -v helm 2>/dev/null || echo "")
        if [ -z "${HELM_BIN}" ]; then
            warn "Could not install helm. Skipping Showroom deployment."
            DEPLOY_SHOWROOM="false"
        fi
    fi
    if [ "${DEPLOY_SHOWROOM}" = "true" ]; then
        ${HELM_BIN} repo add rhpds https://rhpds.github.io/showroom-deployer 2>/dev/null || true
        ${HELM_BIN} repo update 2>/dev/null || true
        SHOWROOM_CHART_DIR=$(mktemp -d)
        ${HELM_BIN} fetch rhpds/showroom-single-pod --untar --untardir "${SHOWROOM_CHART_DIR}" 2>/dev/null
        SHOWROOM_CHART="${SHOWROOM_CHART_DIR}/showroom-single-pod"
        info "Showroom chart fetched to ${SHOWROOM_CHART}"
    fi
fi

echo ""
echo "============================================================"
echo "  Hummingbird Workshop: User Setup"
echo "============================================================"
echo "  Users:    ${NUM_USERS} (${USER_PREFIX}-1 .. ${USER_PREFIX}-${NUM_USERS})"
echo "  Password: ${PASSWORD}"
echo "  Shared:   ${BUILDS_NS}"
echo ""

# ---- Discover Keycloak ----
KC_TOKEN=""
if [ "${SKIP_KEYCLOAK}" != "true" ]; then
    KC_ROUTE=$(oc get route keycloak -n keycloak -o jsonpath='{.spec.host}' 2>/dev/null || true)
    if [ -z "${KC_ROUTE}" ]; then
        warn "Keycloak route not found. Skipping Keycloak user creation."
        SKIP_KEYCLOAK="true"
    else
        if [ -z "${KC_ADMIN_PASS}" ]; then
            KC_ADMIN_PASS=$(oc get secret keycloak-initial-admin -n keycloak -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || true)
        fi
        if [ -z "${KC_ADMIN_PASS}" ]; then
            warn "Cannot determine Keycloak admin password. Set KC_ADMIN_PASS env var."
            warn "Skipping Keycloak user creation."
            SKIP_KEYCLOAK="true"
        else
            KC_TOKEN=$(curl -sk "https://${KC_ROUTE}/realms/master/protocol/openid-connect/token" \
                -d "client_id=admin-cli" \
                -d "username=${KC_ADMIN_USER}" \
                -d "password=${KC_ADMIN_PASS}" \
                -d "grant_type=password" | python3 -c "import json,sys; print(json.load(sys.stdin).get('access_token',''))" 2>/dev/null || true)
            if [ -z "${KC_TOKEN}" ]; then
                warn "Failed to obtain Keycloak admin token. Skipping Keycloak user creation."
                SKIP_KEYCLOAK="true"
            else
                info "Keycloak admin token obtained from https://${KC_ROUTE}"
            fi
        fi
    fi
fi

# ---- Discover Quay ----
QUAY_ROUTE=$(oc get route -n "${QUAY_NAMESPACE}" -l quay-operator/quayregistry=quay-registry \
    -o jsonpath='{.items[0].spec.host}' 2>/dev/null || true)
if [ -z "${QUAY_ROUTE}" ]; then
    warn "Quay route not found. Registry credential secrets will be skipped."
fi

# ---- One-time: Enable internal image registry default route ----
info "Enabling OpenShift internal image registry default route (idempotent)..."
oc patch configs.imageregistry.operator.openshift.io/cluster \
    --type merge \
    --patch '{"spec":{"defaultRoute":true}}' 2>/dev/null && \
    info "  Image registry default route enabled." || \
    warn "  Could not patch image registry config. Module 2.2 users may need to enable it manually."

# ---- One-time: Prepare Quay DB user provisioning ----
QUAY_DB_POD=""
QUAY_BCRYPT_HASH=""
if [ -n "${QUAY_ROUTE}" ]; then
    QUAY_APP_POD=$(oc get pods -n "${QUAY_NAMESPACE}" -l quay-component=quay-app \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    QUAY_DB_POD=$(oc get pods -n "${QUAY_NAMESPACE}" -l quay-component=postgres \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    QUAY_DB_USER=$(oc get secret -n "${QUAY_NAMESPACE}" \
        -l quay-component=postgres \
        -o jsonpath='{.items[0].data.database-username}' 2>/dev/null | base64 -d 2>/dev/null || echo "quay-registry-quay-database")
    QUAY_DB_NAME="${QUAY_DB_USER}"

    if [ -n "${QUAY_APP_POD}" ] && [ -n "${QUAY_DB_POD}" ]; then
        info "Generating bcrypt password hash for Quay user creation..."
        QUAY_BCRYPT_HASH=$(oc exec -n "${QUAY_NAMESPACE}" "${QUAY_APP_POD}" -- \
            python3 -c "import bcrypt; print(bcrypt.hashpw(b'${PASSWORD}', bcrypt.gensalt(rounds=12)).decode())" 2>/dev/null || true)
        if [ -n "${QUAY_BCRYPT_HASH}" ]; then
            info "Quay bcrypt hash generated. DB pod: ${QUAY_DB_POD}"
        else
            warn "Could not generate bcrypt hash from Quay app pod. Quay user creation will be skipped."
        fi
    else
        warn "Quay app or DB pod not found. Quay user creation will be skipped."
    fi
fi

# ---- One-time: Create workshop-participant ClusterRole ----
info "Creating workshop-participant ClusterRole (idempotent)..."
cat <<'WPCR' | oc apply -f - 2>/dev/null
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: workshop-participant
  labels:
    workshop: zero-cve-hummingbird
rules:
  - apiGroups: ["shipwright.io"]
    resources: ["clusterbuildstrategies"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: ["imageregistry.operator.openshift.io"]
    resources: ["configs"]
    verbs: ["get", "patch"]
  - apiGroups: ["admissionregistration.k8s.io"]
    resources: ["validatingwebhookconfigurations"]
    verbs: ["get", "list"]
WPCR

# ---- One-time: Create ACS secret reader Role in stackrox ----
if oc get namespace stackrox > /dev/null 2>&1; then
    info "Creating ACS secret reader Role in stackrox (idempotent)..."
    cat <<'ACSR' | oc apply -f - 2>/dev/null
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: workshop-acs-secret-reader
  namespace: stackrox
  labels:
    workshop: zero-cve-hummingbird
rules:
  - apiGroups: [""]
    resources: ["secrets"]
    resourceNames: ["central-htpasswd"]
    verbs: ["get"]
ACSR
fi

# ---- Output file ----
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACCESS_INFO_FILE="${SCRIPT_DIR}/../workshop-users-access.txt"

# ---- Loop over users ----
for N in $(seq 1 "${NUM_USERS}"); do
    USERNAME="${USER_PREFIX}-${N}"
    USER_NS="hummingbird-builds-${USERNAME}"

    echo ""
    info "========== Setting up ${USERNAME} (${N}/${NUM_USERS}) =========="

    # 1. Keycloak user
    if [ "${SKIP_KEYCLOAK}" != "true" ]; then
        info "[1/6] Creating Keycloak SSO user: ${USERNAME}"
        HTTP_CODE=$(curl -sk -o /dev/null -w "%{http_code}" \
            -X POST "https://${KC_ROUTE}/admin/realms/sso/users" \
            -H "Authorization: Bearer ${KC_TOKEN}" \
            -H "Content-Type: application/json" \
            -d "{
                \"username\": \"${USERNAME}\",
                \"email\": \"${USERNAME}@demo.redhat.com\",
                \"firstName\": \"Lab\",
                \"lastName\": \"User${N}\",
                \"enabled\": true,
                \"emailVerified\": true,
                \"credentials\": [{
                    \"type\": \"password\",
                    \"value\": \"${PASSWORD}\",
                    \"temporary\": false
                }]
            }" 2>/dev/null)

        case "${HTTP_CODE}" in
            201) info "  User created in Keycloak." ;;
            409) info "  User already exists in Keycloak." ;;
            *)   warn "  Keycloak returned HTTP ${HTTP_CODE}. Check manually." ;;
        esac

        USER_ID=$(curl -sk "https://${KC_ROUTE}/admin/realms/sso/users?username=${USERNAME}&exact=true" \
            -H "Authorization: Bearer ${KC_TOKEN}" | python3 -c "import json,sys; users=json.load(sys.stdin); print(users[0]['id'] if users else '')" 2>/dev/null || true)

        if [ -n "${USER_ID}" ]; then
            ROLE_JSON=$(curl -sk "https://${KC_ROUTE}/admin/realms/sso/roles/user" \
                -H "Authorization: Bearer ${KC_TOKEN}" 2>/dev/null || true)
            if [ -n "${ROLE_JSON}" ] && echo "${ROLE_JSON}" | grep -q '"name"'; then
                curl -sk -o /dev/null \
                    -X POST "https://${KC_ROUTE}/admin/realms/sso/users/${USER_ID}/role-mappings/realm" \
                    -H "Authorization: Bearer ${KC_TOKEN}" \
                    -H "Content-Type: application/json" \
                    -d "[${ROLE_JSON}]" 2>/dev/null || true
                info "  Realm role 'user' assigned."
            fi
        fi
    else
        info "[1/6] Skipping Keycloak (SKIP_KEYCLOAK=true)"
    fi

    # 2. Per-user namespace
    info "[2/6] Creating namespace: ${USER_NS}"
    oc create namespace "${USER_NS}" --dry-run=client -o yaml | \
        oc label --local -f - workshop=zero-cve-hummingbird workshop-user="${USERNAME}" -o yaml | \
        oc apply -f - 2>/dev/null
    info "  Namespace ready."

    # 3. RBAC: admin on shared + per-user + renovate-pipelines namespaces
    info "[3/11] Granting admin RBAC"
    ADMIN_NAMESPACES="${BUILDS_NS} ${USER_NS}"
    if oc get namespace renovate-pipelines > /dev/null 2>&1; then
        ADMIN_NAMESPACES="${ADMIN_NAMESPACES} renovate-pipelines"
    fi
    for NS in ${ADMIN_NAMESPACES}; do
        cat <<RBAC | oc apply -f - 2>/dev/null
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ${USERNAME}-admin
  namespace: ${NS}
subjects:
  - kind: User
    name: ${USERNAME}
    apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: admin
  apiGroup: rbac.authorization.k8s.io
RBAC
    done
    info "  Admin on: ${ADMIN_NAMESPACES}"

    # 4. SCC bindings
    info "[4/11] Configuring privileged SCC for pipeline/default SAs"
    for SA in pipeline default; do
        cat <<SCC | oc apply -f - 2>/dev/null
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: hummingbird-${USERNAME}-${SA}-privileged-scc
subjects:
  - kind: ServiceAccount
    name: ${SA}
    namespace: ${USER_NS}
roleRef:
  kind: ClusterRole
  name: system:openshift:scc:privileged
  apiGroup: rbac.authorization.k8s.io
SCC
    done
    info "  SCC bindings created."

    # 5. Quay user account + registry credentials
    if [ -n "${QUAY_ROUTE}" ]; then
        if [ -n "${QUAY_BCRYPT_HASH}" ] && [ -n "${QUAY_DB_POD}" ]; then
            info "[5/12] Creating Quay user account: ${USERNAME}"
            QUAY_UUID=$(python3 -c "import uuid; print(str(uuid.uuid4()))")
            oc exec -n "${QUAY_NAMESPACE}" "${QUAY_DB_POD}" -- \
                psql -U "${QUAY_DB_USER}" -d "${QUAY_DB_NAME}" -c \
                "INSERT INTO \"user\" (uuid, username, password_hash, email, verified, organization, robot, invoice_email, invalid_login_attempts, last_invalid_login, removed_tag_expiration_s, enabled, creation_date)
                 VALUES ('${QUAY_UUID}', '${USERNAME}', '${QUAY_BCRYPT_HASH}', '${USERNAME}@demo.redhat.com', true, false, false, false, 0, '1970-01-01 00:00:00', 1209600, true, now())
                 ON CONFLICT (username) DO UPDATE SET password_hash = EXCLUDED.password_hash, verified = true, organization = false, enabled = true;" \
                2>/dev/null && info "  Quay user ${USERNAME} ready." || \
                warn "  Quay user creation had errors. Check manually."
        else
            info "[5/12] Skipping Quay user creation (no DB access)"
        fi

        info "[5b/12] Creating registry-credentials in ${USER_NS}"
        oc delete secret registry-credentials -n "${USER_NS}" 2>/dev/null || true
        oc create secret docker-registry registry-credentials \
            --docker-server="${QUAY_ROUTE}" \
            --docker-username="${USERNAME}" \
            --docker-password="${PASSWORD}" \
            -n "${USER_NS}" 2>/dev/null
        if oc get sa pipeline -n "${USER_NS}" > /dev/null 2>&1; then
            oc secrets link pipeline registry-credentials --for=pull,mount -n "${USER_NS}"
            info "  Secret linked to pipeline SA."
        else
            info "  pipeline SA not yet available; secret created but not linked."
        fi
    else
        info "[5/12] Skipping registry credentials (no Quay route)"
    fi

    # 6. Self-provisioner
    info "[6/12] Granting self-provisioner"
    cat <<SP | oc apply -f - 2>/dev/null
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: ${USERNAME}-self-provisioner
subjects:
  - kind: User
    name: ${USERNAME}
    apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: self-provisioner
  apiGroup: rbac.authorization.k8s.io
SP
    info "  Self-provisioner granted."

    # 7. workshop-participant ClusterRoleBinding
    info "[7/12] Binding workshop-participant ClusterRole"
    cat <<WP | oc apply -f - 2>/dev/null
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: ${USERNAME}-workshop-participant
  labels:
    workshop: zero-cve-hummingbird
subjects:
  - kind: User
    name: ${USERNAME}
    apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: workshop-participant
  apiGroup: rbac.authorization.k8s.io
WP
    info "  ClusterBuildStrategy + imageregistry + webhook access granted."

    # 8. View on infrastructure namespaces
    info "[8/12] Granting view on infrastructure namespaces"
    for NS in quay trusted-artifact-signer keycloak stackrox gitea openshift-image-registry; do
        if oc get namespace "${NS}" > /dev/null 2>&1; then
            cat <<VIEW | oc apply -f - 2>/dev/null
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ${USERNAME}-view
  namespace: ${NS}
  labels:
    workshop: zero-cve-hummingbird
subjects:
  - kind: User
    name: ${USERNAME}
    apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: view
  apiGroup: rbac.authorization.k8s.io
VIEW
        fi
    done
    info "  View granted on quay, trusted-artifact-signer, keycloak, stackrox, gitea, openshift-image-registry."

    # 9. ACS secret reader (stackrox/central-htpasswd)
    if oc get namespace stackrox > /dev/null 2>&1; then
        info "[9/12] Granting ACS secret reader in stackrox"
        cat <<ACSR | oc apply -f - 2>/dev/null
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ${USERNAME}-acs-secret-reader
  namespace: stackrox
  labels:
    workshop: zero-cve-hummingbird
subjects:
  - kind: User
    name: ${USERNAME}
    apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: Role
  name: workshop-acs-secret-reader
  apiGroup: rbac.authorization.k8s.io
ACSR
        info "  ACS central-htpasswd read access granted."
    else
        info "[9/12] stackrox namespace not found, skipping ACS secret reader."
    fi

    # 10. Fix Gitea must-change-password flag
    GITEA_POD=$(oc get pods -n gitea -l app=gitea-server -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    if [ -n "${GITEA_POD}" ]; then
        info "[10/12] Resetting Gitea must-change-password for ${USERNAME}"
        oc exec -n gitea "${GITEA_POD}" -- \
            /home/gitea/gitea -c /home/gitea/conf/app.ini admin user change-password \
            --username "${USERNAME}" --password "${PASSWORD}" --must-change-password=false 2>/dev/null && \
            info "  Gitea password reset (must-change-password=false)." || \
            warn "  Gitea user ${USERNAME} may not exist yet. Create manually or re-run after Gitea setup."
    else
        warn "[10/12] Gitea pod not found. Skipping must-change-password fix."
    fi

    # 11. Deploy per-user Showroom instance (optional)
    if [ "${DEPLOY_SHOWROOM}" = "true" ] && [ -n "${SHOWROOM_CHART:-}" ]; then
        SHOWROOM_NS="showroom-${USERNAME}"
        info "[11/12] Deploying Showroom in ${SHOWROOM_NS}"
        oc create namespace "${SHOWROOM_NS}" --dry-run=client -o yaml | oc apply -f - 2>/dev/null

        USERDATA_FILE=$(mktemp)
        cat > "${USERDATA_FILE}" <<USERDATA
user: ${USERNAME}
password: ${PASSWORD}
openshift_api_server_url: $(oc whoami --show-server)
openshift_console_url: https://console-openshift-console.${CLUSTER_DOMAIN}
guid: ${USERNAME}
quay_hostname: ${QUAY_ROUTE:-quay-not-found}
quay_user: ${USERNAME}
quay_password: ${PASSWORD}
quay_console_url: https://${QUAY_ROUTE:-quay-not-found}
quay_url: https://${QUAY_ROUTE:-quay-not-found}
USERDATA

        ${HELM_BIN} template "showroom" "${SHOWROOM_CHART}" \
            --namespace "${SHOWROOM_NS}" \
            --set deployer.domain="${CLUSTER_DOMAIN}" \
            --set guid="${USERNAME}" \
            --set user="${USERNAME}" \
            --set content.repoUrl="${SHOWROOM_REPO}" \
            --set content.repoRef="${SHOWROOM_BRANCH}" \
            --set-file content.user_data="${USERDATA_FILE}" \
            --set-string terminal.setup="true" \
            --set-string wetty.setup="false" \
            --set-string nookbag_sidecar.setup="true" \
            --set-string terminal.storage.setup="true" \
            --set-string novnc.setup="false" \
            2>/dev/null | oc apply -n "${SHOWROOM_NS}" -f - 2>/dev/null && \
            info "  Showroom deployed." || \
            warn "  Showroom deployment had errors. Check namespace ${SHOWROOM_NS}."

        rm -f "${USERDATA_FILE}"
    fi

    # 12. Patch existing Showroom ConfigMap if namespace exists but Showroom was not just deployed
    if [ "${DEPLOY_SHOWROOM}" != "true" ] && oc get namespace "showroom-${USERNAME}" > /dev/null 2>&1; then
        if oc get configmap showroom-userdata -n "showroom-${USERNAME}" > /dev/null 2>&1; then
            info "[12/12] Patching existing Showroom user_data for ${USERNAME}"
            oc create configmap showroom-userdata -n "showroom-${USERNAME}" \
                --from-literal=user_data.yml="$(cat <<UDPATCH
user: ${USERNAME}
password: ${PASSWORD}
openshift_api_server_url: $(oc whoami --show-server)
openshift_console_url: https://console-openshift-console.${CLUSTER_DOMAIN}
guid: ${USERNAME}
quay_hostname: ${QUAY_ROUTE:-quay-not-found}
quay_user: ${USERNAME}
quay_password: ${PASSWORD}
quay_console_url: https://${QUAY_ROUTE:-quay-not-found}
quay_url: https://${QUAY_ROUTE:-quay-not-found}
UDPATCH
)" \
                --dry-run=client -o yaml | oc apply -f - 2>/dev/null
            oc rollout restart deployment/showroom -n "showroom-${USERNAME}" 2>/dev/null || true
            info "  Showroom ConfigMap patched and pod restarted."
        fi
    fi

    info "========== ${USERNAME} complete =========="
done

# Clean up showroom chart temp dir
if [ -n "${SHOWROOM_CHART_DIR:-}" ] && [ -d "${SHOWROOM_CHART_DIR:-}" ]; then
    rm -rf "${SHOWROOM_CHART_DIR}"
fi

# ---- Gather service URLs for summary ----
OCP_API=$(oc whoami --show-server 2>/dev/null || echo "https://api.cluster.example.com:6443")
OCP_CONSOLE="https://console-openshift-console.${CLUSTER_DOMAIN}"
QUAY_CONSOLE="https://${QUAY_ROUTE:-quay-not-found}"
ACS_ROUTE=$(oc get route central -n stackrox -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
ACS_PASS=$(oc get secret central-htpasswd -n stackrox -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || echo "N/A")
ARGOCD_ROUTE=$(oc get route openshift-gitops-server -n openshift-gitops -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
GITEA_ROUTE=$(oc get route gitea-server -n gitea -o jsonpath='{.spec.host}' 2>/dev/null || echo "")

# ---- Write access info file ----
{
    echo "========================================================================"
    echo "  Hummingbird Workshop: User Access Information"
    echo "  Generated: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    echo "========================================================================"
    echo ""
    echo "=== Shared Service URLs ==="
    echo ""
    echo "  OpenShift Console:  ${OCP_CONSOLE}"
    echo "  OpenShift API:      ${OCP_API}"
    echo "  Quay Registry:      ${QUAY_CONSOLE}"
    echo "  ACS Central:        https://${ACS_ROUTE}"
    echo "  ArgoCD:             https://${ARGOCD_ROUTE}"
    echo "  Gitea:              https://${GITEA_ROUTE}"
    echo ""
    echo "=== Shared Credentials ==="
    echo ""
    echo "  ACS Central:   admin / ${ACS_PASS}"
    echo "  Identity Provider: rhbk (select on OpenShift login page)"
    echo ""
    echo "=== Per-User Credentials (unified identity across all services) ==="
    echo ""
    for N in $(seq 1 "${NUM_USERS}"); do
        USERNAME="${USER_PREFIX}-${N}"
        echo "  --- ${USERNAME} ---"
        echo "  Password (all services): ${PASSWORD}"
        echo "  OpenShift login:  oc login -u ${USERNAME} -p ${PASSWORD} ${OCP_API} --insecure-skip-tls-verify"
        echo "  Gitea login:      ${USERNAME} / ${PASSWORD}"
        echo "  Quay login:       ${USERNAME} / ${PASSWORD}"
        echo "  Quay namespace:   https://${QUAY_ROUTE:-quay-not-found}/user/${USERNAME}/"
        echo "  Build namespace:  hummingbird-builds-${USERNAME}"
        echo "  Namespaces:"
        echo "    - hummingbird-builds (shared, admin)"
        echo "    - hummingbird-builds-${USERNAME} (per-user, admin)"
        echo "    - renovate-pipelines (admin)"
        echo "    - quay, stackrox, keycloak, trusted-artifact-signer, gitea (view)"
        SHOWROOM_ROUTE=$(oc get route showroom -n "showroom-${USERNAME}" -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
        if [ -n "${SHOWROOM_ROUTE}" ]; then
            echo "  Showroom:         https://${SHOWROOM_ROUTE}"
        fi
        echo ""
    done
    echo "========================================================================"
} > "${ACCESS_INFO_FILE}"

info "Access info written to ${ACCESS_INFO_FILE}"

# ---- Print summary to console ----
echo ""
cat "${ACCESS_INFO_FILE}"
