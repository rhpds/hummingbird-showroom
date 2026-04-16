# Module 01 Registry Migration

Update Module 01 developer environment content from `registry.access.redhat.com/hi*` to `registry.access.redhat.com/hi`

## Quick Start

Run the update script twice to replace both old registry prefixes:

```bash
./scripts/update-registry.sh "registry.access.redhat.com/hi" "registry.access.redhat.com/hi"
./scripts/update-registry.sh "registry.access.redhat.com/hi" "registry.access.redhat.com/hi"
```

All files are updated automatically - no manual edits required.

---

## Core Configuration

**Note:** Both files are automatically updated by `update-registry.sh` - no manual edits needed.

### content/antora.yml
**Line 38:** Variable definition used by all `.adoc` files

**Will be updated from:**
```yaml
hummingbird-registry: 'registry.access.redhat.com/hi'
```

**To:**
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

**Will be updated from:**
```yaml
url: 'https://images.redhat.com'
```

**To:**
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

All files have hardcoded `registry.access.redhat.com/hi*` references in:
- Expected output blocks
- Containerfile examples
- Command examples
- Registry mirror configs

**Files to be updated:**
- `content/modules/ROOT/pages/module-01-04-signing.adoc`
- `content/modules/ROOT/pages/module-01-07-selinux-advanced.adoc`
- `content/modules/ROOT/pages/module-01-08-chunkah.adoc`
- `content/modules/ROOT/pages/module-01-09-multi-lang-builds.adoc`
- `content/modules/ROOT/pages/module-01-10-chunkah-value.adoc`
- `content/modules/ROOT/pages/module-01-11-tomcat-hummingbird.adoc`
- `content/modules/ROOT/pages/appendix-a-rhel-setup.adoc`

**Verification:**
```bash
grep -r "registry.access.redhat.com/hi" content/modules/ROOT/pages/module-01-*.adoc content/modules/ROOT/pages/appendix-a-rhel-setup.adoc
# Expected: no matches
```

---

## Scripts

All solve and validate scripts have hardcoded registry references or define HUMMINGBIRD_REGISTRY variable.

**Files to be updated:**
- `scripts/solve-module-01-01.sh` through `solve-module-01-08.sh`
- `scripts/validate-module-01-01.sh` through `validate-module-01-05.sh`

**Verification:**
```bash
grep -r "registry.access.redhat.com/hi" scripts/solve-module-01-*.sh scripts/validate-module-01-*.sh
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
Contains FROM statements referencing `registry.access.redhat.com/hi/openjdk` images.

**Verification:**
```bash
grep "FROM.*registry.access.redhat.com/hi" content/modules/ROOT/examples/setup/quarkus/Containerfile
# Expected: no matches

podman build -f content/modules/ROOT/examples/setup/quarkus/Containerfile
# Expected: builds successfully with new registry
```

---

## Cosign Signing Key Migration

When migrating to the Red Hat registry, the cosign public key URL must also be updated from the Hummingbird project key to the official Red Hat signing key.

**Automated by:** `update-registry.sh` (when new registry is `registry.access.redhat.com/hi`)

**Files Updated:**
- `content/modules/ROOT/pages/module-01-04-signing.adoc`
- `scripts/validate-module-01-04.sh`

**Key Change:**
- Old: `https://security.access.redhat.com/data/63405576.txt`
- New: `https://security.access.redhat.com/data/63405576.txt`

**Verification:**
```bash
# Ensure old key URL is gone
grep "catalog.hummingbird-project.io/cosign.pub" content/modules/ROOT/pages/module-01-04-signing.adoc scripts/validate-module-01-04.sh
# Expected: no matches

# Check new key URL is present
grep "security.access.redhat.com/data/63405576.txt" content/modules/ROOT/pages/module-01-04-signing.adoc scripts/validate-module-01-04.sh
# Expected: 2 matches
```

---

## Summary

**Files Updated:** 25
- Core config: 2 (automated)
- Documentation: 7 (automated)
- Scripts: 13 (automated)
- Examples: 1 (automated)
- Signing keys: 2 (automated)

**Actions:**
1. Run `update-registry.sh` twice (for both old registries)
2. Verify no old references remain
3. Test solve script execution

**Note:** All files are updated automatically by the script, including `content/antora.yml` and `ui-config.yml`.
