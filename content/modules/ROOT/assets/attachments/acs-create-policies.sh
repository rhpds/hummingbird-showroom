#!/usr/bin/env bash
# Create ACS enforcement policies for the Zero-CVE workshop.
# Usage: bash acs-create-policies.sh
#
# Requires: ROX_API_TOKEN and ACS_ROUTE environment variables.

set -euo pipefail

: "${ROX_API_TOKEN:?ROX_API_TOKEN is not set}"
: "${ACS_ROUTE:?ACS_ROUTE is not set}"

API="https://${ACS_ROUTE}/v1/policies"
AUTH="Authorization: Bearer ${ROX_API_TOKEN}"

create_policy() {
  local json_file="$1"
  local name
  name=$(python3 -c "import json; print(json.load(open('${json_file}'))['name'])")

  existing=$(curl -sk -H "${AUTH}" "${API}" | \
    python3 -c "import json,sys; ids=[p['id'] for p in json.load(sys.stdin).get('policies',[]) if p['name']=='${name}']; print(ids[0] if ids else '')" 2>/dev/null)

  if [ -n "${existing}" ]; then
    echo "Policy '${name}' already exists (id: ${existing}). Ensuring enforcement is enabled..."
    curl -sk -H "${AUTH}" "${API}/${existing}" | \
      python3 -c "
import json, sys
p = json.load(sys.stdin)
desired = ['SCALE_TO_ZERO_ENFORCEMENT']
if p.get('enforcementActions') == desired:
    print(f'  Enforcement already set: {desired}')
else:
    p['enforcementActions'] = desired
    json.dump(p, open('/tmp/policy-update.json','w'))
    print('  Updating enforcement to SCALE_TO_ZERO_ENFORCEMENT...')
" 2>/dev/null
    if [ -f /tmp/policy-update.json ]; then
      curl -sk -X PUT -H "${AUTH}" -H "Content-Type: application/json" \
        "${API}/${existing}" -d @/tmp/policy-update.json > /dev/null
      rm -f /tmp/policy-update.json
      echo "  Enforcement enabled."
    fi
    return 0
  fi

  response=$(curl -sk -X POST -H "${AUTH}" -H "Content-Type: application/json" "${API}" -d @"${json_file}")
  echo "${response}" | python3 -c "
import json, sys
d = json.load(sys.stdin)
if 'id' in d:
    print(f\"Created policy: {d.get('name', 'unknown')} (id: {d['id']})\")
else:
    print(f\"Error: {d.get('message', d)}\")
"
}

# --- Policy 1: Zero Fixable CVEs Required ---
cat > /tmp/acs-policy-zero-cve.json << 'EOF'
{
  "name": "Zero Fixable CVEs Required",
  "description": "Reject deployments where the image has any fixable CVE. Enforces proactive attack surface eradication over reactive patching.",
  "severity": "CRITICAL_SEVERITY",
  "categories": ["Vulnerability Management"],
  "lifecycleStages": ["DEPLOY"],
  "enforcementActions": ["SCALE_TO_ZERO_ENFORCEMENT"],
  "eventSource": "NOT_APPLICABLE",
  "disabled": false,
  "scope": [{"namespace": "hummingbird-acs-lab"}],
  "policySections": [{
    "sectionName": "Fixable CVE threshold",
    "policyGroups": [
      {"fieldName": "Fixed By", "booleanOperator": "OR", "negate": false, "values": [{"value": ".*"}]},
      {"fieldName": "CVSS", "booleanOperator": "OR", "negate": false, "values": [{"value": ">= 0.000000"}]}
    ]
  }]
}
EOF

echo "=== Creating policy: Zero Fixable CVEs Required ==="
create_policy /tmp/acs-policy-zero-cve.json

# --- Policy 2: Image Scan Required ---
cat > /tmp/acs-policy-scan-required.json << 'EOF'
{
  "name": "Image Scan Required",
  "description": "Reject deployments where the image has not been scanned by ACS. Ensures every runtime artifact has a verified vulnerability assessment.",
  "severity": "HIGH_SEVERITY",
  "categories": ["DevOps Best Practices"],
  "lifecycleStages": ["DEPLOY"],
  "enforcementActions": ["SCALE_TO_ZERO_ENFORCEMENT"],
  "eventSource": "NOT_APPLICABLE",
  "disabled": false,
  "scope": [{"namespace": "hummingbird-acs-lab"}],
  "policySections": [{
    "sectionName": "Scan status",
    "policyGroups": [
      {"fieldName": "Unscanned Image", "booleanOperator": "OR", "negate": false, "values": [{"value": "true"}]}
    ]
  }]
}
EOF

echo "=== Creating policy: Image Scan Required ==="
create_policy /tmp/acs-policy-scan-required.json

echo ""
echo "Done. Verify in ACS UI: Platform Configuration -> Policy Management"
