#!/usr/bin/env python3
"""
Create per-student ACS image integrations for a private on-cluster Quay registry.

ACS auto-generated image integrations have no credentials, so they cannot scan
private Quay repositories created by workshop students.  This script creates one
named integration per student (e.g. "Workshop Quay - lab-user-2") so that ACS
Central can authenticate and scan each student's images.

The script is idempotent: integrations whose name already exists are skipped.

Usage
-----
  python3 setup-acs-image-integrations.py \\
      --acs-route  central-stackrox.apps.cluster.example.com \\
      --acs-token  eyJ... \\
      --quay-endpoint https://quay-registry-quay-quay.apps.cluster.example.com \\
      --users lab-user-1:openshift lab-user-2:openshift lab-user-3:openshift

  # or via environment variables:
  export ACS_ROUTE=central-stackrox.apps.cluster.example.com
  export ACS_ADMIN_TOKEN=eyJ...
  export QUAY_ENDPOINT=https://quay-registry-quay-quay.apps.cluster.example.com
  python3 setup-acs-image-integrations.py --users lab-user-1:openshift

  # dry-run (no API calls, just show what would be created):
  python3 setup-acs-image-integrations.py --dry-run --users lab-user-1:openshift

Environment variable fallbacks
-------------------------------
  ACS_ROUTE          ACS Central hostname without scheme (maps to --acs-route)
  ACS_ADMIN_TOKEN    Bearer token with ACS Admin role  (maps to --acs-token)
  QUAY_ENDPOINT      Full Quay URL including https://   (maps to --quay-endpoint)
"""

import argparse
import json
import os
import ssl
import sys
import urllib.request
import urllib.error


INTEGRATION_NAME_PREFIX = "Workshop Quay - "


def build_ssl_ctx():
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    return ctx


def api_request(url, token, method="GET", body=None):
    headers = {
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json",
    }
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    ctx = build_ssl_ctx()
    with urllib.request.urlopen(req, context=ctx) as resp:
        raw = resp.read()
        return json.loads(raw) if raw else {}


def get_existing_integrations(acs_url, token):
    resp = api_request(f"{acs_url}/v1/imageintegrations", token)
    return {i["name"]: i["id"] for i in resp.get("integrations", [])}


def create_integration(acs_url, token, quay_endpoint, username, password):
    payload = {
        "name": f"{INTEGRATION_NAME_PREFIX}{username}",
        "type": "docker",
        "categories": ["REGISTRY"],
        "docker": {
            "endpoint": quay_endpoint,
            "username": username,
            "password": password,
            "insecure": True,
        },
        "skipTestIntegration": False,
    }
    return api_request(f"{acs_url}/v1/imageintegrations", token, method="POST", body=payload)


def parse_args():
    p = argparse.ArgumentParser(
        description="Create per-student ACS image integrations for private Quay repos.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    p.add_argument(
        "--acs-route",
        default=os.environ.get("ACS_ROUTE"),
        help="ACS Central hostname without scheme, e.g. central-stackrox.apps.cluster.example.com "
             "(env: ACS_ROUTE)",
    )
    p.add_argument(
        "--acs-token",
        default=os.environ.get("ACS_ADMIN_TOKEN"),
        help="Bearer token with ACS Admin role (env: ACS_ADMIN_TOKEN)",
    )
    p.add_argument(
        "--quay-endpoint",
        default=os.environ.get("QUAY_ENDPOINT"),
        help="Full Quay URL including https://, e.g. https://quay-registry-quay-quay.apps.cluster.example.com "
             "(env: QUAY_ENDPOINT)",
    )
    p.add_argument(
        "--users",
        nargs="+",
        required=True,
        metavar="USER:PASSWORD",
        help="One or more user:password pairs, e.g. lab-user-1:openshift lab-user-2:openshift",
    )
    p.add_argument(
        "--dry-run",
        action="store_true",
        help="Print what would be created without making any API calls",
    )
    return p.parse_args()


def main():
    args = parse_args()

    missing = []
    if not args.acs_route:
        missing.append("--acs-route / ACS_ROUTE")
    if not args.acs_token:
        missing.append("--acs-token / ACS_ADMIN_TOKEN")
    if not args.quay_endpoint:
        missing.append("--quay-endpoint / QUAY_ENDPOINT")
    if missing:
        print(f"ERROR: missing required arguments: {', '.join(missing)}", file=sys.stderr)
        sys.exit(1)

    acs_url = f"https://{args.acs_route}"
    quay_endpoint = args.quay_endpoint.rstrip("/")

    if args.dry_run:
        print("[DRY-RUN] No API calls will be made.")

    existing = {} if args.dry_run else get_existing_integrations(acs_url, args.acs_token)

    created = skipped = errors = 0

    for user_pair in args.users:
        if ":" not in user_pair:
            print(f"  SKIP  {user_pair!r} — expected USER:PASSWORD format", file=sys.stderr)
            errors += 1
            continue

        username, password = user_pair.split(":", 1)
        name = f"{INTEGRATION_NAME_PREFIX}{username}"

        if args.dry_run:
            print(f"  [DRY-RUN] Would create: {name}")
            created += 1
            continue

        if name in existing:
            print(f"  EXISTS  {name} (id: {existing[name]})")
            skipped += 1
            continue

        try:
            resp = create_integration(acs_url, args.acs_token, quay_endpoint, username, password)
            if "id" in resp:
                print(f"  CREATED {name} (id: {resp['id']})")
                created += 1
            else:
                print(f"  ERROR   {name}: {json.dumps(resp)[:200]}", file=sys.stderr)
                errors += 1
        except urllib.error.HTTPError as exc:
            body = exc.read().decode(errors="replace")[:200]
            print(f"  ERROR   {name}: HTTP {exc.code} — {body}", file=sys.stderr)
            errors += 1

    print(f"\nDone: {created} created, {skipped} already existed, {errors} errors.")
    if errors:
        sys.exit(1)


if __name__ == "__main__":
    main()
