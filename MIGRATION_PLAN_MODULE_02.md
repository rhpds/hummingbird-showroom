# Module 02 Registry Migration

Update Module 02 platform engineering content from `registry.access.redhat.com/hi*` to `registry.access.redhat.com/hi`

**Note:** Core configuration (`content/antora.yml`, `ui-config.yml`) is updated in Module 01 plan.

---

## Documentation Files

All files have hardcoded `registry.access.redhat.com/hi*` references in:
- Expected output blocks
- Pipeline/BuildStrategy YAML examples
- Renovate config examples
- Containerfile examples

**Files:**
- `content/modules/ROOT/pages/module-02-01-buildpacks.adoc`
- `content/modules/ROOT/pages/module-02-02-custom-strategies.adoc`
- `content/modules/ROOT/pages/module-02-03-security-pipeline.adoc`
- `content/modules/ROOT/pages/module-02-04-tekton-udica.adoc`
- `content/modules/ROOT/pages/module-02-05-chunkah-pipeline.adoc`
- `content/modules/ROOT/pages/module-02-06-rhtas.adoc`
- `content/modules/ROOT/pages/module-02-07-acs-zero-cve.adoc`
- `content/modules/ROOT/pages/module-02-08-renovate-podman.adoc`
- `content/modules/ROOT/pages/appendix-b-openshift-setup.adoc`

**Action:**
```bash
./scripts/update-registry.sh "registry.access.redhat.com/hi" "registry.access.redhat.com/hi"
./scripts/update-registry.sh "registry.access.redhat.com/hi" "registry.access.redhat.com/hi"
```

**Verification:**
```bash
grep -r "registry.access.redhat.com/hi" content/modules/ROOT/pages/module-02-*.adoc content/modules/ROOT/pages/appendix-b-openshift-setup.adoc
# Expected: no matches
```

---

## Runtime Automation

### runtime-automation/module-02-02/solve.yml
**Line 240:** Containerfile written via heredoc in Ansible task, contains `FROM registry.access.redhat.com/hi/python:latest`

**Action:**
Same as documentation (already covered by update-registry.sh commands above)

**Verification:**
```bash
grep "registry.access.redhat.com/hi" runtime-automation/module-02-02/solve.yml
# Expected: no matches
```

---

## Renovate Configuration

### renovate.json
**Lines 17, 66, 67:** Regex patterns for dependency scanning (contains both plain and escaped registry references)

**Action:**
Same as documentation (already covered by update-registry.sh commands above)

**Note:** The script handles both plain strings (`registry.access.redhat.com/hi`) and escaped regex patterns (`quay\\.io/hummingbird-hatchling`)

**Verification:**
```bash
grep -A 2 "matchPackagePatterns" renovate.json
# Expected: ["registry.access.redhat.com/hi/.*"]

grep "matchStrings" renovate.json | head -1
# Expected: registry\\.access\\.redhat\\.com/hi pattern (escaped dots)
```

---

## Tekton Pipeline Configuration

### bootstrap/09-renovate-build-infra/tekton-pipelines.yaml
**Line 53:** Pipeline parameter default value for `runtime-registry`

**Action:**
Same as documentation (already covered by update-registry.sh commands above)

**Note:** The script processes all `.yaml` files including this pipeline configuration

**Verification:**
```bash
grep -A 2 "runtime-registry" bootstrap/09-renovate-build-infra/tekton-pipelines.yaml | grep default
# Expected: default: "registry.access.redhat.com/hi"

oc apply --dry-run=client -f bootstrap/09-renovate-build-infra/tekton-pipelines.yaml
# Expected: no syntax errors
```

---

## Summary

**Files Updated:** 12
- Documentation: 9 (automated)
- Runtime automation: 1 (automated)
- Renovate config: 1 (automated)
- Tekton pipeline: 1 (automated)

**Actions:**
1. Run `update-registry.sh` twice (handles all files)
2. Verify no old references remain
3. Test pipeline syntax validation
