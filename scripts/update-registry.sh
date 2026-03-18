#!/bin/bash
# Script to update container registry references throughout the project
# Usage: ./scripts/update-registry.sh <old-registry> <new-registry>
#
# Example:
#   ./scripts/update-registry.sh "quay.io/hummingbird-hatchling" "registry.example.com/hummingbird"

set -euo pipefail

OLD_REGISTRY="${1:-}"
NEW_REGISTRY="${2:-}"

if [[ -z "$OLD_REGISTRY" ]] || [[ -z "$NEW_REGISTRY" ]]; then
    echo "Usage: $0 <old-registry> <new-registry>"
    echo ""
    echo "Example:"
    echo "  $0 'quay.io/hummingbird-hatchling' 'registry.example.com/hummingbird'"
    exit 1
fi

# Escape slashes for sed
OLD_ESCAPED=$(echo "$OLD_REGISTRY" | sed 's/\//\\\//g')
NEW_ESCAPED=$(echo "$NEW_REGISTRY" | sed 's/\//\\\//g')

echo "=========================================="
echo "Registry Update Script"
echo "=========================================="
echo "Old registry: $OLD_REGISTRY"
echo "New registry: $NEW_REGISTRY"
echo ""

# Function to update files
update_files() {
    local pattern=$1
    local description=$2

    echo "Updating: $description"

    # Find and update files
    local files=$(find . -type f \( -name "$pattern" \) \
        -not -path "./.git/*" \
        -not -path "./node_modules/*" \
        -not -path "./.cache/*" \
        -not -path "./build/*" \
        -not -path "./scripts/update-registry.sh")

    if [[ -n "$files" ]]; then
        echo "$files" | while read -r file; do
            if grep -q "$OLD_REGISTRY" "$file" 2>/dev/null; then
                echo "  - $file"
                sed -i "s/$OLD_ESCAPED/$NEW_ESCAPED/g" "$file"
            fi
        done
    fi
}

# 1. Update Antora configuration (central source of truth)
echo "1. Updating Antora configuration..."
if [[ -f "content/antora.yml" ]]; then
    if grep -q "$OLD_REGISTRY" content/antora.yml; then
        echo "  - content/antora.yml"
        sed -i "s/$OLD_ESCAPED/$NEW_ESCAPED/g" content/antora.yml
    fi
fi

# 2. Update AsciiDoc documentation files
echo ""
echo "2. Updating AsciiDoc documentation..."
update_files "*.adoc" "AsciiDoc files"

# 3. Update shell scripts
echo ""
echo "3. Updating shell scripts..."
update_files "*.sh" "Shell scripts"

# 4. Update Containerfiles/Dockerfiles
echo ""
echo "4. Updating Containerfiles..."
find . -type f \( -name "Containerfile" -o -name "Dockerfile" \) \
    -not -path "./.git/*" \
    -not -path "./node_modules/*" | while read -r file; do
    if grep -q "$OLD_REGISTRY" "$file" 2>/dev/null; then
        echo "  - $file"
        sed -i "s/$OLD_ESCAPED/$NEW_ESCAPED/g" "$file"
    fi
done

# 5. Update YAML files
echo ""
echo "5. Updating YAML files..."
update_files "*.yml" "YAML files"
update_files "*.yaml" "YAML files"

# 6. Update README
echo ""
echo "6. Updating README..."
if [[ -f "README.adoc" ]]; then
    if grep -q "$OLD_REGISTRY" README.adoc; then
        echo "  - README.adoc"
        sed -i "s/$OLD_ESCAPED/$NEW_ESCAPED/g" README.adoc
    fi
fi

echo ""
echo "=========================================="
echo "Update complete!"
echo "=========================================="
echo ""
echo "Summary of changes:"
git diff --stat 2>/dev/null || echo "(Git not available or no changes detected)"
echo ""
echo "Next steps:"
echo "1. Review changes: git diff"
echo "2. Test the updated configuration"
echo "3. Commit changes: git add -A && git commit -m 'Update registry from $OLD_REGISTRY to $NEW_REGISTRY'"
