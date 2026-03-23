#!/usr/bin/env python3
"""Parse roxctl image scan JSON output and print a vulnerability summary.

Usage:
    roxctl image scan --image=IMAGE --output=json | python3 acs-scan-summary.py
    roxctl image scan --image=IMAGE --output=json | python3 acs-scan-summary.py --brief
"""
import json
import sys

data = json.load(sys.stdin)
summary = data.get("result", {}).get("summary", {})
vulns = data.get("result", {}).get("vulnerabilities", [])
fixable = sum(1 for v in vulns if v.get("componentFixedVersion"))

if "--brief" in sys.argv:
    print(
        f"  Components: {summary.get('TOTAL-COMPONENTS', 'N/A')}"
        f"  |  Vulnerabilities: {summary.get('TOTAL-VULNERABILITIES', 0)}"
        f"  |  Fixable: {fixable}"
    )
else:
    print(f"Total components:       {summary.get('TOTAL-COMPONENTS', 'N/A')}")
    print(f"Total vulnerabilities:  {summary.get('TOTAL-VULNERABILITIES', 0)}")
    print(f"Critical:               {summary.get('CRITICAL', 0)}")
    print(f"Important:              {summary.get('IMPORTANT', 0)}")
    print(f"Moderate:               {summary.get('MODERATE', 0)}")
    print(f"Low:                    {summary.get('LOW', 0)}")
    print(f"Fixable vulnerabilities: {fixable}")
