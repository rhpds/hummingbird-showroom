# Registry Management Scripts

This directory contains automation scripts for managing container registry references throughout the project.

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
