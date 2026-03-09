#!/bin/bash
# =============================================================================
# Hummingbird Workshop: RHEL Developer Environment Setup
#
# Prepares a RHEL 9/10 or Fedora workstation for Module 1 labs.
# Installs Podman, Buildah, Skopeo, configures rootless operation,
# sets up registries, storage, Podman Desktop, JDK 21, and Quarkus CLI.
#
# Usage:
#   chmod +x setup-rhel-developer.sh
#   ./setup-rhel-developer.sh
#
# For more details, see Appendix A in the workshop guide.
# =============================================================================
set -euo pipefail

echo "=== Hummingbird Workshop: RHEL Developer Environment Setup ==="
echo ""

# --- System Update ---
echo "[1/10] Updating system packages..."
sudo dnf update -y

# --- Core Container Tools ---
echo "[2/10] Installing Podman, Buildah, Skopeo, and container-tools..."
sudo dnf install -y podman buildah skopeo container-tools

# --- JDK 21 ---
echo "[3/10] Installing OpenJDK 21..."
sudo dnf install -y java-21-openjdk-devel

# --- Quarkus CLI via JBang ---
echo "[4/10] Installing Quarkus CLI (via JBang)..."
curl -Ls https://sh.jbang.dev | bash -s - trust add https://repo1.maven.org/maven2/io/quarkus/quarkus-cli/
curl -Ls https://sh.jbang.dev | bash -s - app install --fresh --force quarkus@quarkusio
export PATH="$HOME/.jbang/bin:$PATH"
if ! grep -q '.jbang/bin' ~/.bashrc 2>/dev/null; then
    echo 'export PATH="$HOME/.jbang/bin:$PATH"' >> ~/.bashrc
fi

# --- Rootless Podman: subuid/subgid ---
echo "[5/10] Configuring rootless Podman (subuid/subgid)..."
if ! grep -q "^$(whoami):" /etc/subuid; then
    echo "$(whoami):100000:65536" | sudo tee -a /etc/subuid
fi
if ! grep -q "^$(whoami):" /etc/subgid; then
    echo "$(whoami):100000:65536" | sudo tee -a /etc/subgid
fi

# --- User Lingering ---
echo "[6/10] Enabling user lingering..."
sudo loginctl enable-linger $(whoami)

# --- Podman Socket ---
echo "[7/10] Enabling Podman socket..."
systemctl --user enable --now podman.socket

# --- Registry Configuration ---
echo "[8/10] Configuring container registries..."
mkdir -p ~/.config/containers

cat > ~/.config/containers/registries.conf << 'EOF'
unqualified-search-registries = ["registry.access.redhat.com", "quay.io", "docker.io"]

[[registry]]
location = "registry.access.redhat.com"
insecure = false
blocked = false

[[registry]]
location = "registry.redhat.io"
insecure = false
blocked = false

[[registry]]
location = "quay.io"
insecure = false
blocked = false

[[registry]]
location = "quay.io/hummingbird-hatchling"
insecure = false
blocked = false
EOF

# --- Storage Configuration ---
echo "[9/10] Configuring container storage..."
cat > ~/.config/containers/storage.conf << 'EOF'
[storage]
driver = "overlay"

[storage.options]
mount_program = "/usr/bin/fuse-overlayfs"

[storage.options.overlay]
mountopt = "nodev,metacopy=on"
EOF

# --- Podman Desktop ---
echo "[10/10] Installing Podman Desktop..."
RHEL_MAJOR=$(rpm -E '%{rhel}' 2>/dev/null || echo "9")
ARCH=$(uname -m)
LAUNCH_CMD="podman-desktop"

if [[ "${RHEL_MAJOR}" -ge 10 ]]; then
    # RHEL 10+: official Red Hat build via extensions repo
    sudo subscription-manager repos --enable "rhel-${RHEL_MAJOR}-for-${ARCH}-extensions-rpms" 2>/dev/null || true
    if sudo dnf install -y rh-podman-desktop 2>/dev/null; then
        echo "Podman Desktop (Red Hat build) installed via dnf."
    else
        flatpak remote-add --if-not-exists --user flathub https://flathub.org/repo/flathub.flatpakrepo
        flatpak install --user -y flathub io.podman_desktop.PodmanDesktop
        LAUNCH_CMD="flatpak run io.podman_desktop.PodmanDesktop"
        echo "Podman Desktop installed via Flatpak."
    fi
else
    # RHEL 9: Flatpak from Flathub (official recommendation for Linux)
    flatpak remote-add --if-not-exists --user flathub https://flathub.org/repo/flathub.flatpakrepo
    if flatpak install --user -y flathub io.podman_desktop.PodmanDesktop 2>/dev/null; then
        LAUNCH_CMD="flatpak run io.podman_desktop.PodmanDesktop"
        echo "Podman Desktop installed via Flatpak."
    else
        echo "Warning: Podman Desktop could not be installed automatically."
        echo "Install manually from https://podman-desktop.io/downloads"
        LAUNCH_CMD="# see https://podman-desktop.io/downloads"
    fi
fi

echo ""
echo "=== Setup Complete ==="
echo "Podman:      $(podman --version)"
echo "Buildah:     $(buildah --version)"
echo "Skopeo:      $(skopeo --version)"
echo "Java:        $(java --version 2>&1 | head -1)"
echo "Quarkus CLI: $(quarkus --version)"
echo "Rootless:    $(podman info --format '{{.Host.Security.Rootless}}')"
echo "Storage:     $(podman info --format '{{.Store.GraphDriverName}}')"
echo ""
echo "You can now launch Podman Desktop with: ${LAUNCH_CMD} &"
echo ""
echo "IMPORTANT: Run the following command (or open a new terminal) to"
echo "make the Quarkus CLI available in your current shell:"
echo ""
echo "    source ~/.bashrc"
echo ""
echo "Proceed to Module 1 to start the workshop labs."
