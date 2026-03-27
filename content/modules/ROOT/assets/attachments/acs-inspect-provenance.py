#!/usr/bin/env python3
"""Inspect SBOM and SLSA provenance attestations from a skopeo --raw manifest.

Usage:
    skopeo inspect --raw docker://REGISTRY/IMAGE:TAG | python3 acs-inspect-provenance.py
"""
import json
import sys

try:
    manifest = json.load(sys.stdin)
except json.JSONDecodeError as e:
    print(f"Error: could not parse manifest JSON ({e})")
    sys.exit(1)

if manifest.get("mediaType") == "application/vnd.oci.image.index.v1+json":
    found = False
    for m in manifest.get("manifests", []):
        ann = m.get("annotations", {})
        artifact_type = m.get("artifactType", "")
        if "vnd.sigstore" in json.dumps(ann) or "sbom" in artifact_type.lower():
            found = True
            print(f"  Artifact: {artifact_type or 'unknown'}")
            print(f"  Digest:   {m.get('digest', 'unknown')}")
            print()
    if not found:
        print("No SBOM or sigstore attestations found in the manifest index.")
else:
    print("Single-arch manifest (inspect child manifests for attestations)")
