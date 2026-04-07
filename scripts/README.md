# Workshop Scripts

This directory contains automation scripts for workshop deployment and management.

## Module Automation Scripts

The workshop provides two types of automation scripts for module exercises:

### Solve Scripts (`solve-module-*.sh`)

**Purpose:** Complete module exercises on behalf of users
- **Use case:** User catchup, skip ahead to later modules, demonstrate completed state
- **Approach:** Autonomous execution - runs all required actions without user intervention
- **Focus:** Action steps only (builds, runs, creates, installs)
- **Prerequisites:** Automatically builds missing artifacts (e.g., images)
- **Verification:** Minimal - focuses on completing work, not testing

**Available solve scripts:**
- `solve-module-01-01.sh` - Introduction & Basic Images
- `solve-module-01-02.sh` - Multi-Stage Builds
- `solve-module-01-03.sh` - Vulnerability Scanning & SBOMs
- `solve-module-01-04.sh` - Image Signing & Attestation
- `solve-module-01-05.sh` - Custom Security Configurations
- `solve-module-01-06.sh` - SELinux Hardening with udica
- `solve-module-01-07.sh` - Advanced SELinux
- `solve-module-01-08.sh` - chunkah Layer Splitting (Optional)

**Usage:**
```bash
# Run any solve script independently after setup
./scripts/solve-module-01-06.sh
```

**Key features:**
- Fully autonomous - can run standalone after `setup-rhel.sh`
- Auto-builds prerequisites if missing (e.g., hummingbird-demo:v1)
- Validates setup files exist (errors with "contact instructor" if missing)
- Does NOT ask users to run other scripts
- Streamlined output - major steps only

### Validation Scripts (`validate-module-*.sh`)

**Purpose:** Ensure exercises can be completed as written
- **Use case:** CI/CD testing, module development, content verification
- **Approach:** Comprehensive execution with extensive testing
- **Focus:** All steps including verification, testing, and status checks
- **Verification:** Extensive wait loops, curl tests, image inspection
- **Output:** Detailed progress reporting and success indicators

**Available validation scripts:**
- `validate-bootstrap.sh` - Environment setup validation
- `validate-module-01-01.sh` - Introduction & Basic Images
- `validate-module-01-02.sh` - Multi-Stage Builds
- `validate-module-01-03.sh` - Vulnerability Scanning & SBOMs

**Usage:**
```bash
# Validate a module can be completed
./scripts/validate-module-01-01.sh
```

### Comparison: Solve vs Validate

| Aspect | Solve Scripts | Validate Scripts |
|--------|---------------|------------------|
| **Purpose** | Complete on behalf of user | Verify exercises work |
| **Size** | ~50-160 lines | ~150-270 lines |
| **Prerequisites** | Auto-builds if missing | Expects correct state |
| **Wait loops** | Minimal (2-5s sleeps) | Extensive retry logic |
| **Testing** | None | curl, inspect, status checks |
| **Output** | Major steps only | Detailed progress |
| **Use case** | User catchup, demos | CI/CD, testing |

### Example Workflow

**User skips to module 01-06:**
```bash
# After setup-rhel.sh, run solve script
./scripts/solve-module-01-06.sh

# Script automatically:
# - Checks for /opt/myapp/ (errors if missing - setup issue)
# - Builds hummingbird-demo:v1 (prerequisite from module 01-02)
# - Generates and loads SELinux policy
# - Completes in ~2-3 minutes
```

**CI/CD validation:**
```bash
# Validate all modules work correctly
for script in scripts/validate-module-01-*.sh; do
    echo "Validating $(basename $script)..."
    $script || exit 1
done
```

---

## Workshop User Setup

### `setup-workshop-users.sh`

Creates per-user workshop environments with unified identity across all services (OpenShift, Quay, Gitea, Keycloak).

**Quick start:**
```bash
NUM_USERS=3 DEPLOY_SHOWROOM=true ./scripts/setup-workshop-users.sh
```

**What it does per user:**
1. Creates Keycloak SSO user for OpenShift login
2. Creates per-user build namespace (`hummingbird-builds-lab-user-N`)
3. Grants admin RBAC on shared + per-user + renovate-pipelines namespaces
4. Configures privileged SCC for pipeline/default ServiceAccounts
5. Creates Quay user account (via DB) + registry-credentials secret
6. Grants self-provisioner, workshop-participant ClusterRole, infra namespace view
7. Grants ACS secret reader, fixes Gitea must-change-password
8. Optionally deploys per-user Showroom instance with embedded terminal
9. Writes all credentials/URLs to `workshop-users-access.txt`

**Environment variables:**

| Variable | Default | Description |
|---|---|---|
| `NUM_USERS` | `1` | Number of users to create |
| `USER_PREFIX` | `lab-user` | Username prefix (users: `<prefix>-1`, `<prefix>-2`, ...) |
| `PASSWORD` | `openshift` | Password for all users (all services) |
| `DEPLOY_SHOWROOM` | `false` | Deploy per-user Showroom instances |
| `SHOWROOM_REPO` | fork URL | Git repo for Showroom content |
| `SHOWROOM_BRANCH` | `main` | Git branch for Showroom content |
| `SKIP_KEYCLOAK` | `false` | Skip Keycloak user creation |
| `BUILDS_NS` | `hummingbird-builds` | Shared builds namespace |
| `QUAY_NAMESPACE` | `quay` | Quay namespace |

The script is **idempotent** -- safe to re-run to add more users or repair state.

---

# Registry Management Scripts

This directory also contains automation scripts for managing container registry references throughout the project.

## Overview

The project references container images from a registry (currently `quay.io/hummingbird-hatchling`). These scripts help you:
1. Update all registry references consistently
2. Verify where registry references exist
3. Migrate to a new registry when needed

## Scripts

### `update-registry.sh`

Updates all registry references throughout the project in a single operation.

**Usage:**
```bash
./scripts/update-registry.sh <old-registry> <new-registry>
```

**Example:**
```bash
# Migrate from current registry to a new one
./scripts/update-registry.sh \
  "quay.io/hummingbird-hatchling" \
  "registry.example.com/hummingbird"
```

**What it updates:**
- `content/antora.yml` - Central configuration
- All `.adoc` files (documentation)
- All `.sh` files (shell scripts)
- `Containerfile` and `Dockerfile` files
- YAML configuration files
- `README.adoc`

**After running:**
1. Review changes: `git diff`
2. Test the configuration
3. Commit: `git commit -am "Update registry to <new-registry>"`

### `verify-registry-refs.sh`

Scans the project to find all registry references and reports where they're used.

**Usage:**
```bash
./scripts/verify-registry-refs.sh
```

**Output:**
- Lists all files containing registry references
- Counts total references by file type
- Provides recommendations for centralization

## Architecture

### Centralized Configuration

The project uses a **single source of truth** approach:

1. **AsciiDoc files**: Registry is defined in `content/antora.yml`:
   ```yaml
   asciidoc:
     attributes:
       hummingbird-registry: 'quay.io/hummingbird-hatchling'
   ```

2. **AsciiDoc documents** can reference it using:
   ```asciidoc
   FROM {hummingbird-registry}/python:3.14-builder
   ```

3. **Shell scripts and other files**: Direct references are updated by the migration script.

### Migration Workflow

When changing registries:

```bash
# 1. Verify current state
./scripts/verify-registry-refs.sh

# 2. Update to new registry
./scripts/update-registry.sh \
  "quay.io/hummingbird-hatchling" \
  "registry.internal.example.com/hummingbird"

# 3. Review changes
git diff

# 4. Test
# Run your tests, build documentation, etc.

# 5. Commit
git add -A
git commit -m "Migrate to new registry: registry.internal.example.com/hummingbird"
```

## Future Enhancements

Potential improvements for even better registry management:

1. **Environment variable support**: Add `HUMMINGBIRD_REGISTRY` env var support to shell scripts
2. **Validation**: Pre-commit hook to prevent hardcoded registries in new files
3. **Registry aliases**: Support multiple registry configurations (dev, staging, prod)
4. **Automatic attribute usage**: Script to convert hardcoded references to `{hummingbird-registry}` in AsciiDoc files

## Troubleshooting

### Script says "No changes detected"
- Verify the old registry path is correct
- Check if git is initialized in the repo
- Ensure you have write permissions

### Changes not applied to some files
- Check if files are in excluded paths (`.git`, `node_modules`, etc.)
- Verify file permissions
- Review script output for any errors

### Documentation not rendering new registry
- Rebuild Antora documentation after changes
- Clear any documentation build caches
