#!/usr/bin/env python3
"""Check ACS admission controller configuration.

Usage:
    curl -sk -H "Authorization: Bearer $ROX_API_TOKEN" \
      "https://$ACS_ROUTE/v1/clusters" | python3 acs-check-admission.py
"""
import json
import sys

data = json.load(sys.stdin)
cluster = data["clusters"][0]
ac = cluster.get("dynamicConfig", {}).get("admissionControllerConfig", {})

print(f"Cluster:              {cluster['name']}")
print(f"Admission controller: {ac.get('enabled', False)}")
print(f"Scan inline:          {ac.get('scanInline', False)}")
print(f"Enforce on updates:   {ac.get('enforceOnUpdates', False)}")
