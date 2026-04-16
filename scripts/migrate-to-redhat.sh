#!/bin/bash
# One-time migration script: Hummingbird Project → Red Hat Registry
# Migrates all registry references, cosign keys, and UI URLs to Red Hat infrastructure
#
# Usage: ./scripts/migrate-to-redhat.sh
#
# This script is idempotent - safe to run multiple times

set -euo pipefail

echo "=========================================="
echo "Red Hat Registry Migration"
echo "=========================================="
echo ""
echo "This script will migrate all references from:"
echo "  - quay.io/hummingbird-hatchling → registry.access.redhat.com/hi"
echo "  - quay.io/hummingbird → registry.access.redhat.com/hi"
echo "  - catalog.hummingbird-project.io → security.access.redhat.com"
echo "  - web-app-8bd096.gitlab.io → images.redhat.com"
echo ""

# Known old and new values
declare -A REGISTRY_MAPPINGS=(
    ["quay.io/hummingbird-hatchling"]="registry.access.redhat.com/hi"
    ["quay.io/hummingbird"]="registry.access.redhat.com/hi"
)

OLD_COSIGN_KEY="https://catalog.hummingbird-project.io/cosign.pub"
NEW_COSIGN_KEY="https://security.access.redhat.com/data/63405576.txt"

OLD_UI_URL="https://web-app-8bd096.gitlab.io/"
NEW_UI_URL="https://images.redhat.com"

NEW_REGISTRY="registry.access.redhat.com/hi"

# Track if any updates were made
UPDATES_MADE=false

# Function to update files with plain text replacement
update_files_plain() {
    local old_value=$1
    local new_value=$2
    local description=$3

    echo "Updating: $description"
    echo "  From: $old_value"
    echo "  To:   $new_value"

    # Escape for sed
    local old_escaped=$(echo "$old_value" | sed 's/\//\\\//g')
    local new_escaped=$(echo "$new_value" | sed 's/\//\\\//g')

    local files=$(find . -type f \
        \( -name "*.adoc" -o -name "*.yml" -o -name "*.yaml" -o -name "*.json" -o -name "*.sh" -o -name "Containerfile" -o -name "Dockerfile" -o -name "*.md" \) \
        -not -path "./.git/*" \
        -not -path "./node_modules/*" \
        -not -path "./scripts/migrate-to-redhat.sh" \
        -not -path "./scripts/update-registry.sh")

    local count=0
    if [[ -n "$files" ]]; then
        echo "$files" | while read -r file; do
            if grep -q "$old_value" "$file" 2>/dev/null; then
                echo "  - $file"
                sed -i "s/$old_escaped/$new_escaped/g" "$file"
                ((count++)) || true
            fi
        done
    fi

    if [[ $count -gt 0 ]]; then
        UPDATES_MADE=true
    fi
    echo ""
}

# Function to update JSON files with escaped regex patterns
update_json_escaped() {
    local old_value=$1
    local new_value=$2

    echo "Updating JSON escaped patterns:"
    echo "  From: ${old_value//./\\.}"
    echo "  To:   ${new_value//./\\.}"

    # Need 4 backslashes per dot to match JSON-escaped patterns like "quay\\.io"
    local old_pattern=$(echo "$old_value" | sed 's/\./\\\\\\\\./g')
    local new_pattern=$(echo "$new_value" | sed 's/\./\\\\\\\\./g')

    local files=$(find . -type f -name "*.json" \
        -not -path "./.git/*" \
        -not -path "./node_modules/*" \
        -not -path "./package-lock.json")

    if [[ -n "$files" ]]; then
        echo "$files" | while read -r file; do
            if grep -q "$old_pattern" "$file" 2>/dev/null; then
                echo "  - $file"
                sed -i "s#$old_pattern#$new_pattern#g" "$file"
                UPDATES_MADE=true
            fi
        done
    fi
    echo ""
}

# 1. Update registry references (plain text)
echo "=========================================="
echo "Step 1: Registry URL Migration"
echo "=========================================="
echo ""

for old_reg in "${!REGISTRY_MAPPINGS[@]}"; do
    new_reg="${REGISTRY_MAPPINGS[$old_reg]}"
    update_files_plain "$old_reg" "$new_reg" "Registry: $old_reg"
done

# 2. Update JSON escaped patterns
echo "=========================================="
echo "Step 2: JSON Escaped Pattern Migration"
echo "=========================================="
echo ""

for old_reg in "${!REGISTRY_MAPPINGS[@]}"; do
    new_reg="${REGISTRY_MAPPINGS[$old_reg]}"
    update_json_escaped "$old_reg" "$new_reg"
done

# 3. Update cosign key URL
echo "=========================================="
echo "Step 3: Cosign Key URL Migration"
echo "=========================================="
echo ""

update_files_plain "$OLD_COSIGN_KEY" "$NEW_COSIGN_KEY" "Cosign public key URL"

# 4. Update UI tab URL
echo "=========================================="
echo "Step 4: UI Tab URL Migration"
echo "=========================================="
echo ""

update_files_plain "$OLD_UI_URL" "$NEW_UI_URL" "Hummingbird Images tab URL"

# Comprehensive Verification
echo "=========================================="
echo "Comprehensive Verification"
echo "=========================================="
echo ""

VERIFICATION_FAILED=false

# Check 1: No remaining old registry references anywhere
echo "Checking for remaining old registry references..."
for old_reg in "${!REGISTRY_MAPPINGS[@]}"; do
    REMAINING=$(find . -type f \
        \( -name "*.adoc" -o -name "*.yml" -o -name "*.yaml" -o -name "*.json" -o -name "*.sh" -o -name "Containerfile" -o -name "Dockerfile" -o -name "*.md" \) \
        -not -path "./.git/*" \
        -not -path "./node_modules/*" \
        -not -path "./scripts/migrate-to-redhat.sh" \
        -not -path "./scripts/update-registry.sh" \
        -not -path "./MIGRATION_PLAN_MODULE_01.md" \
        -not -path "./MIGRATION_PLAN_MODULE_02.md" \
        -exec grep -l "$old_reg" {} \; 2>/dev/null || true)

    if [[ -n "$REMAINING" ]]; then
        echo "✗ Files still contain '$old_reg':"
        echo "$REMAINING" | while read -r file; do
            count=$(grep -c "$old_reg" "$file" 2>/dev/null || echo "0")
            echo "  - $file ($count occurrence(s))"
        done
        VERIFICATION_FAILED=true
    else
        echo "✓ No remaining references to '$old_reg'"
    fi
done

# Check 2: No old cosign key URL
echo ""
echo "Checking cosign key URL..."
OLD_KEY_REMAINING=$(find . -type f \
    \( -name "*.adoc" -o -name "*.sh" -o -name "*.md" \) \
    -not -path "./.git/*" \
    -not -path "./scripts/migrate-to-redhat.sh" \
    -not -path "./scripts/update-registry.sh" \
    -not -path "./MIGRATION_PLAN_MODULE_01.md" \
    -not -path "./MIGRATION_PLAN_MODULE_02.md" \
    -exec grep -l "$OLD_COSIGN_KEY" {} \; 2>/dev/null || true)

if [[ -n "$OLD_KEY_REMAINING" ]]; then
    echo "✗ Old cosign key URL still present:"
    echo "$OLD_KEY_REMAINING" | while read -r file; do
        echo "  - $file"
    done
    VERIFICATION_FAILED=true
else
    echo "✓ No remaining old cosign key URLs"
fi

# Check 3: No old UI URL
echo ""
echo "Checking UI tab URL..."
if [[ -f "ui-config.yml" ]]; then
    if grep -q "$OLD_UI_URL" ui-config.yml 2>/dev/null; then
        echo "✗ Old UI tab URL still present in ui-config.yml"
        VERIFICATION_FAILED=true
    else
        echo "✓ UI tab URL updated"
    fi
fi

# Check 4: Core configuration files
echo ""
echo "Verifying core configuration files..."

if [[ -f "content/antora.yml" ]]; then
    if grep -q "$NEW_REGISTRY" content/antora.yml 2>/dev/null; then
        echo "✓ content/antora.yml"
    else
        echo "✗ content/antora.yml (missing '$NEW_REGISTRY')"
        VERIFICATION_FAILED=true
    fi
else
    echo "⚠ content/antora.yml (file not found)"
    VERIFICATION_FAILED=true
fi

if [[ -f "renovate.json" ]]; then
    if grep -q "$NEW_REGISTRY" renovate.json 2>/dev/null; then
        echo "✓ renovate.json"
    else
        echo "✗ renovate.json (missing '$NEW_REGISTRY')"
        VERIFICATION_FAILED=true
    fi
else
    echo "⚠ renovate.json (file not found)"
    VERIFICATION_FAILED=true
fi

if [[ -f "ui-config.yml" ]]; then
    if grep -q "$NEW_UI_URL" ui-config.yml 2>/dev/null; then
        echo "✓ ui-config.yml"
    else
        echo "✗ ui-config.yml (missing '$NEW_UI_URL')"
        VERIFICATION_FAILED=true
    fi
else
    echo "⚠ ui-config.yml (file not found)"
    VERIFICATION_FAILED=true
fi

# Check 5: Sample Containerfile
echo ""
echo "Verifying sample Containerfile..."
SAMPLE_CONTAINERFILE="content/modules/ROOT/examples/setup/quarkus/Containerfile"
if [[ -f "$SAMPLE_CONTAINERFILE" ]]; then
    if grep "^FROM" "$SAMPLE_CONTAINERFILE" | grep -q "$NEW_REGISTRY"; then
        echo "✓ $SAMPLE_CONTAINERFILE"
    else
        echo "✗ $SAMPLE_CONTAINERFILE (FROM lines don't use '$NEW_REGISTRY')"
        VERIFICATION_FAILED=true
    fi
else
    echo "⚠ $SAMPLE_CONTAINERFILE (file not found)"
    VERIFICATION_FAILED=true
fi

# Check 6: Infrastructure files
echo ""
echo "Verifying infrastructure files..."

TEKTON_PIPELINE="bootstrap/09-renovate-build-infra/tekton-pipelines.yaml"
if [[ -f "$TEKTON_PIPELINE" ]]; then
    if grep -A2 "runtime-registry" "$TEKTON_PIPELINE" | grep "default:" | grep -q "$NEW_REGISTRY"; then
        echo "✓ $TEKTON_PIPELINE (runtime-registry default)"
    else
        echo "✗ $TEKTON_PIPELINE (runtime-registry default not set to '$NEW_REGISTRY')"
        VERIFICATION_FAILED=true
    fi
else
    echo "⚠ $TEKTON_PIPELINE (file not found)"
fi

# Check 7: All solve scripts
echo ""
echo "Verifying solve scripts..."
SOLVE_SCRIPTS_FAILED=false
for script in scripts/solve-module-*.sh; do
    if [[ -f "$script" ]]; then
        # Check if script has any old registry references
        HAS_OLD=false
        for old_reg in "${!REGISTRY_MAPPINGS[@]}"; do
            if grep -q "$old_reg" "$script" 2>/dev/null; then
                echo "✗ $script (contains '$old_reg')"
                HAS_OLD=true
                SOLVE_SCRIPTS_FAILED=true
                VERIFICATION_FAILED=true
                break
            fi
        done

        if [[ "$HAS_OLD" == "false" ]]; then
            # If script references a registry at all, verify it's the new one
            if grep -q "REGISTRY=" "$script" 2>/dev/null; then
                if grep "REGISTRY=" "$script" | grep -q "$NEW_REGISTRY"; then
                    echo "✓ $script"
                else
                    echo "⚠ $script (has REGISTRY var but not set to new registry)"
                fi
            else
                echo "✓ $script (no registry references)"
            fi
        fi
    fi
done

if [[ "$SOLVE_SCRIPTS_FAILED" == "false" ]]; then
    echo "✓ All solve scripts verified"
fi

# Check 8: All validate scripts
echo ""
echo "Verifying validate scripts..."
VALIDATE_SCRIPTS_FAILED=false
for script in scripts/validate-module-*.sh; do
    if [[ -f "$script" ]]; then
        # Check if script has any old registry references
        HAS_OLD=false
        for old_reg in "${!REGISTRY_MAPPINGS[@]}"; do
            if grep -q "$old_reg" "$script" 2>/dev/null; then
                echo "✗ $script (contains '$old_reg')"
                HAS_OLD=true
                VALIDATE_SCRIPTS_FAILED=true
                VERIFICATION_FAILED=true
                break
            fi
        done

        if [[ "$HAS_OLD" == "false" ]]; then
            # If script references a registry at all, verify it's the new one
            if grep -q "REGISTRY=" "$script" 2>/dev/null; then
                if grep "REGISTRY=" "$script" | grep -q "$NEW_REGISTRY"; then
                    echo "✓ $script"
                else
                    echo "⚠ $script (has REGISTRY var but not set to new registry)"
                fi
            else
                echo "✓ $script (no registry references)"
            fi
        fi
    fi
done

if [[ "$VALIDATE_SCRIPTS_FAILED" == "false" ]]; then
    echo "✓ All validate scripts verified"
fi

# Check 9: Setup script
echo ""
echo "Verifying setup script..."
if [[ -f "scripts/setup-rhel.sh" ]]; then
    HAS_OLD=false
    for old_reg in "${!REGISTRY_MAPPINGS[@]}"; do
        if grep -q "$old_reg" "scripts/setup-rhel.sh" 2>/dev/null; then
            echo "✗ scripts/setup-rhel.sh (contains '$old_reg')"
            HAS_OLD=true
            VERIFICATION_FAILED=true
            break
        fi
    done

    if [[ "$HAS_OLD" == "false" ]]; then
        echo "✓ scripts/setup-rhel.sh"
    fi
fi

# Check 10: Runtime automation
echo ""
echo "Verifying runtime automation..."
if [[ -d "runtime-automation" ]]; then
    RUNTIME_FILES=$(find runtime-automation -type f \( -name "*.yml" -o -name "*.yaml" \))
    if [[ -n "$RUNTIME_FILES" ]]; then
        RUNTIME_FAILED=false
        echo "$RUNTIME_FILES" | while read -r file; do
            HAS_OLD=false
            for old_reg in "${!REGISTRY_MAPPINGS[@]}"; do
                if grep -q "$old_reg" "$file" 2>/dev/null; then
                    echo "✗ $file (contains '$old_reg')"
                    HAS_OLD=true
                    RUNTIME_FAILED=true
                    break
                fi
            done

            if [[ "$HAS_OLD" == "false" ]]; then
                echo "✓ $file"
            fi
        done

        if [[ "$RUNTIME_FAILED" == "true" ]]; then
            VERIFICATION_FAILED=true
        fi
    fi
fi

# Check 11: Documentation modules
echo ""
echo "Verifying documentation modules..."
DOC_MODULES=$(find content/modules/ROOT/pages -name "module-*.adoc" -o -name "appendix-*.adoc")
if [[ -n "$DOC_MODULES" ]]; then
    DOC_FAILED=false
    TOTAL_DOCS=0
    PASSED_DOCS=0

    echo "$DOC_MODULES" | while read -r file; do
        ((TOTAL_DOCS++)) || true
        HAS_OLD=false
        for old_reg in "${!REGISTRY_MAPPINGS[@]}"; do
            if grep -q "$old_reg" "$file" 2>/dev/null; then
                echo "✗ $file (contains '$old_reg')"
                HAS_OLD=true
                DOC_FAILED=true
                break
            fi
        done

        if [[ "$HAS_OLD" == "false" ]]; then
            ((PASSED_DOCS++)) || true
        fi
    done

    if [[ "$DOC_FAILED" == "true" ]]; then
        VERIFICATION_FAILED=true
        echo "⚠ Some documentation files failed verification"
    else
        echo "✓ All documentation modules verified"
    fi
fi

# Final result
echo ""
echo "=========================================="
if [[ "$VERIFICATION_FAILED" == "true" ]]; then
    echo "✗ MIGRATION FAILED VERIFICATION"
    echo "=========================================="
    echo ""
    echo "One or more checks failed. Review errors above."
    echo ""
    echo "Git diff summary:"
    git diff --stat 2>/dev/null || echo "(Git not available)"
    echo ""
    echo "To see detailed changes: git diff"
    exit 1
else
    echo "✓ MIGRATION SUCCESSFUL"
    echo "=========================================="
    echo ""
    echo "All verification checks passed!"
    echo ""
    echo "Summary of changes:"
    git diff --stat 2>/dev/null || echo "(Git not available)"
    echo ""
    echo "Next steps:"
    echo "1. Review changes: git diff"
    echo "2. Test build: cd content/modules/ROOT/examples/setup/quarkus && podman build ."
    echo "3. Commit changes: git add -A && git commit -m 'Migrate to Red Hat registry and infrastructure'"
    echo ""
fi
