# Module 01 Registry Migration

Update Module 01 developer environment content from `quay.io/hummingbird*` to `registry.access.redhat.com/hi`

---

## Core Configuration

### content/antora.yml
**Line 38:** Variable definition used by all `.adoc` files

**Current:**
```yaml
hummingbird-registry: 'quay.io/hummingbird'
```

**Action:**
```yaml
hummingbird-registry: 'registry.access.redhat.com/hi'
```

**Verification:**
```bash
grep "hummingbird-registry:" content/antora.yml
# Expected: registry.access.redhat.com/hi
```

### ui-config.yml
**Line 24:** Hummingbird Images website tab

**Current:**
```yaml
url: 'https://web-app-8bd096.gitlab.io/'
```

**Action:**
```yaml
url: 'https://images.redhat.com'
```

**Verification:**
```bash
grep -A 1 "Hummingbird Images" ui-config.yml
# Expected: url: 'https://images.redhat.com'
```

---

## Documentation Files

All files have hardcoded `quay.io/hummingbird*` references in:
- Expected output blocks
- Containerfile examples
- Command examples
- Registry mirror configs

**Files:**
- `content/modules/ROOT/pages/module-01-04-signing.adoc` (line 40)
- `content/modules/ROOT/pages/module-01-07-selinux-advanced.adoc`
- `content/modules/ROOT/pages/module-01-08-chunkah.adoc`
- `content/modules/ROOT/pages/module-01-09-multi-lang-builds.adoc`
- `content/modules/ROOT/pages/module-01-10-chunkah-value.adoc`
- `content/modules/ROOT/pages/module-01-11-tomcat-hummingbird.adoc`
- `content/modules/ROOT/pages/appendix-a-rhel-setup.adoc`

**Action:**
```bash
./scripts/update-registry.sh "quay.io/hummingbird-hatchling" "registry.access.redhat.com/hi"
./scripts/update-registry.sh "quay.io/hummingbird" "registry.access.redhat.com/hi"
```

**Verification:**
```bash
grep -r "quay.io/hummingbird" content/modules/ROOT/pages/module-01-*.adoc content/modules/ROOT/pages/appendix-a-rhel-setup.adoc
# Expected: no matches
```

---

## Scripts

All solve and validate scripts have hardcoded registry references or define HUMMINGBIRD_REGISTRY variable.

**Files:**
- `scripts/solve-module-01-01.sh` through `solve-module-01-08.sh`
- `scripts/validate-module-01-01.sh` through `validate-module-01-05.sh`

**Action:**
Same as documentation (already covered by update-registry.sh commands above)

**Verification:**
```bash
grep -r "quay.io/hummingbird" scripts/solve-module-01-*.sh scripts/validate-module-01-*.sh
# Expected: no matches
```

**Functional Test:**
```bash
./scripts/solve-module-01-01.sh && ./scripts/validate-module-01-01.sh
# Expected: executes without registry errors
```

---

## Example Files

### content/modules/ROOT/examples/setup/quarkus/Containerfile
Contains FROM statements referencing `quay.io/hummingbird/openjdk` images.

**Action:**
Same as documentation (already covered by update-registry.sh commands above)

**Verification:**
```bash
grep "FROM.*quay.io/hummingbird" content/modules/ROOT/examples/setup/quarkus/Containerfile
# Expected: no matches

podman build -f content/modules/ROOT/examples/setup/quarkus/Containerfile
# Expected: builds successfully with new registry
```

---

## Summary

**Files Updated:** 23
- Core config: 2 (manual)
- Documentation: 7 (automated)
- Scripts: 13 (automated)
- Examples: 1 (automated)

**Actions:**
1. Manually update `content/antora.yml` and `ui-config.yml`
2. Run `update-registry.sh` twice (for both old registries)
3. Verify no old references remain
4. Test solve script execution
