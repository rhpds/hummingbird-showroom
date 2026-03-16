#!/bin/bash
# Script to verify registry references and suggest centralization opportunities
# This helps identify hardcoded registry references that could use the Antora attribute

set -euo pipefail

echo "=========================================="
echo "Registry Reference Verification"
echo "=========================================="
echo ""

# Get current registry from antora.yml
CURRENT_REGISTRY=$(grep "hummingbird-registry:" content/antora.yml | awk '{print $2}' | tr -d "'")
echo "Configured registry: $CURRENT_REGISTRY"
echo ""

# Count total references
echo "Scanning for registry references..."
echo ""

TOTAL=0

# Check AsciiDoc files for hardcoded registry (should use {hummingbird-registry})
echo "1. AsciiDoc files (.adoc):"
ADOC_FILES=$(find content/modules -name "*.adoc" -type f)
ADOC_COUNT=0

for file in $ADOC_FILES; do
    # Look for hardcoded registry references (not using the attribute)
    if grep -q "$CURRENT_REGISTRY" "$file" 2>/dev/null; then
        COUNT=$(grep -c "$CURRENT_REGISTRY" "$file" || true)
        if [[ $COUNT -gt 0 ]]; then
            echo "  $file: $COUNT reference(s)"
            ADOC_COUNT=$((ADOC_COUNT + COUNT))
        fi
    fi
done

echo "  Total hardcoded references in AsciiDoc: $ADOC_COUNT"
echo "  Note: These COULD use {hummingbird-registry} attribute for centralization"
TOTAL=$((TOTAL + ADOC_COUNT))
echo ""

# Check shell scripts
echo "2. Shell scripts (.sh):"
SCRIPT_FILES=$(find . -name "*.sh" -type f -not -path "./.git/*" -not -path "./scripts/verify-registry-refs.sh")
SCRIPT_COUNT=0

for file in $SCRIPT_FILES; do
    if grep -q "$CURRENT_REGISTRY" "$file" 2>/dev/null; then
        COUNT=$(grep -c "$CURRENT_REGISTRY" "$file" || true)
        if [[ $COUNT -gt 0 ]]; then
            echo "  $file: $COUNT reference(s)"
            SCRIPT_COUNT=$((SCRIPT_COUNT + COUNT))
        fi
    fi
done

echo "  Total references in shell scripts: $SCRIPT_COUNT"
TOTAL=$((TOTAL + SCRIPT_COUNT))
echo ""

# Check README
echo "3. Documentation (README.adoc):"
if [[ -f "README.adoc" ]]; then
    README_COUNT=$(grep -c "$CURRENT_REGISTRY" README.adoc 2>/dev/null || true)
    if [[ $README_COUNT -gt 0 ]]; then
        echo "  README.adoc: $README_COUNT reference(s)"
        TOTAL=$((TOTAL + README_COUNT))
    fi
fi
echo ""

# Summary
echo "=========================================="
echo "Summary"
echo "=========================================="
echo "Total registry references found: $TOTAL"
echo ""
echo "Recommendations:"
echo "1. AsciiDoc files: Use {hummingbird-registry} attribute instead of hardcoded registry"
echo "2. Shell scripts: Consider using environment variable HUMMINGBIRD_REGISTRY"
echo "3. Update all at once using: ./scripts/update-registry.sh '<old>' '<new>'"
echo ""
echo "To update the registry, edit content/antora.yml and run update-registry.sh"
