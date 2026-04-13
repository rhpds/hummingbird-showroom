#! /bin/bash
# dnf install -y container-tools java-21-openjdk-devel python3-pip vim-enhanced cloud-init git-all
dnf install -y nano emacs-nw

# GitHub repository references
GITHUB_ORG="${GITHUB_ORG:-rhpds}"
GITHUB_REPO="${GITHUB_REPO:-hummingbird-showroom}"
GITHUB_BRANCH="${GITHUB_BRANCH:-main}"
GITHUB_BASE_URL="https://raw.githubusercontent.com/${GITHUB_ORG}/${GITHUB_REPO}/refs/heads/${GITHUB_BRANCH}"

# Clone repository to get template and script files
TEMP_REPO="/tmp/hummingbird-setup-$$"
echo "=== Cloning repository for setup files ==="
git clone --depth 1 --branch ${GITHUB_BRANCH} \
  https://github.com/${GITHUB_ORG}/${GITHUB_REPO}.git \
  ${TEMP_REPO}

# Verify clone succeeded
if [ ! -d "${TEMP_REPO}/content/modules/ROOT/examples/setup" ] || [ ! -d "${TEMP_REPO}/scripts" ]; then
  echo "ERROR: Failed to clone repository or required files not found"
  rm -rf ${TEMP_REPO}
  exit 1
fi

SETUP_FILES="${TEMP_REPO}/content/modules/ROOT/examples/setup"
SCRIPT_FILES="${TEMP_REPO}/scripts"

# Download Flask packages locally
mkdir -p /var/pypi-cache
pip download  --python-version=3.14 --only-binary=:all: flask -d /var/pypi-cache/
pip download  --python-version=3.12 --only-binary=:all: flask -d /var/pypi-cache/

cp ${SETUP_FILES}/systemd/pypiserver.container /etc/containers/systemd/
systemctl daemon-reload
systemctl start pypiserver

# Install cosign from GitHub releases
COSIGN_VERSION=v2.6.3
curl -LO https://github.com/sigstore/cosign/releases/download/${COSIGN_VERSION}/cosign-linux-amd64
sudo install -m 755 cosign-linux-amd64 /usr/local/bin/cosign
rm cosign-linux-amd64

# Verify installation
/usr/local/bin/cosign version

# Install syft
SYFT_VERSION=v1.42.4
curl -sSfL https://raw.githubusercontent.com/anchore/syft/main/install.sh | sudo sh -s -- -b /usr/local/bin ${SYFT_VERSION}

# Verify installation
/usr/local/bin/syft version

# Install grype
GRYPE_VERSION=v0.111.0
curl -sSfL https://raw.githubusercontent.com/anchore/grype/main/install.sh | sudo sh -s -- -b /usr/local/bin ${GRYPE_VERSION}

# Verify installation
/usr/local/bin/grype version
/usr/local/bin/grype db update

cat > /tmp/quarkus.sh <<'EOF'
curl -Ls https://sh.jbang.dev | bash -s - trust add https://repo1.maven.org/maven2/io/quarkus/quarkus-cli/
curl -Ls https://sh.jbang.dev | bash -s - app install --fresh --force quarkus@quarkusio
export PATH="$HOME/.jbang/bin:$PATH"
if ! grep -q '.jbang/bin' ~/.bashrc 2>/dev/null; then
    echo 'export PATH="$HOME/.jbang/bin:$PATH"' >> ~/.bashrc
fi

EOF
chmod +x /tmp/quarkus.sh
su -l rhel -c /tmp/quarkus.sh
rm /tmp/quarkus.sh

mkdir -p /home/rhel/webserver /home/rhel/flask /home/rhel/scanning /home/rhel/fips
cp ${SCRIPT_FILES}/test-fips.py /home/rhel/fips/

echo "=== Step 5: Scaffolding Quarkus project ==="
su -l rhel -c "quarkus create app com.example:sample-app \
    --extension='rest,rest-jackson' \
    --no-code"

echo "=== Updating .dockerignore ==="
cp ${SETUP_FILES}/quarkus/.dockerignore /home/rhel/sample-app/

echo "=== Fixing file permissions ==="
chmod -R a+rX /home/rhel/sample-app/.mvn/ /home/rhel/sample-app/src/
chmod a+r /home/rhel/sample-app/pom.xml
chmod a+x /home/rhel/sample-app/mvnw

echo "=== Creating GreetingResource.java ==="
mkdir -p /home/rhel/sample-app/src/main/java/com/example
cp ${SETUP_FILES}/quarkus/GreetingResource.java \
  /home/rhel/sample-app/src/main/java/com/example/

echo "=== Configuring application.properties ==="
cp ${SETUP_FILES}/quarkus/application.properties \
  /home/rhel/sample-app/src/main/resources/

echo "=== Creating UBI comparison image ==="
# Create Containerfile.ubi for comparison
cp ${SETUP_FILES}/quarkus/Containerfile.ubi /home/rhel/sample-app/

# Build UBI-only version for comparison
su -l rhel -c "podman build -f /home/rhel/sample-app/Containerfile.ubi -t hummingbird-demo:ubi /home/rhel/sample-app"
echo "✅ UBI comparison image built successfully"

echo "=== Step 4: Preparing Host Directories for Bind Mounts ==="

echo "Creating host directories for bind mounts..."
mkdir -p /opt/myapp/config /opt/myapp/logs
chown -R rhel:rhel /opt/myapp

echo "Setting SELinux context for container file access..."
semanage fcontext -a -t container_file_t "/opt/myapp/config(/.*)?" || echo "Context may already exist"
semanage fcontext -a -t container_file_t "/opt/myapp/logs(/.*)?" || echo "Context may already exist"
restorecon -Rv /opt/myapp

echo "=== Creating exercise files for improved reliability ==="

echo "Creating HTML landing page..."
cp ${SETUP_FILES}/webserver/index.html /home/rhel/webserver/

echo "Creating Flask application..."
cp ${SETUP_FILES}/flask/app.py /home/rhel/flask/

echo "Creating Caddy SSL configuration..."
cp ${SETUP_FILES}/webserver/Caddyfile /home/rhel/webserver/

echo "Creating multi-stage Quarkus Containerfile..."
cp ${SETUP_FILES}/quarkus/Containerfile /home/rhel/sample-app/

echo "Creating Flask UBI Containerfile..."
cp ${SETUP_FILES}/flask/Containerfile.ubi /home/rhel/flask/

echo "✅ Exercise files created successfully"

echo "=== Installing validation scripts ==="
mkdir -p /home/rhel/scripts
cp ${SCRIPT_FILES}/validate-module-01-01.sh /home/rhel/scripts/validate-mod-01-01.sh
cp ${SCRIPT_FILES}/validate-module-01-02.sh /home/rhel/scripts/validate-mod-01-02.sh
cp ${SCRIPT_FILES}/validate-module-01-03.sh /home/rhel/scripts/validate-mod-01-03.sh
cp ${SCRIPT_FILES}/validate-module-01-04.sh /home/rhel/scripts/validate-mod-01-04.sh
cp ${SCRIPT_FILES}/validate-module-01-05.sh /home/rhel/scripts/validate-mod-01-05.sh
chmod +x /home/rhel/scripts/validate-mod-01-*.sh

echo "=== Installing solve scripts ==="
cp ${SCRIPT_FILES}/solve-module-01-01.sh /home/rhel/scripts/solve-mod-01-01.sh
cp ${SCRIPT_FILES}/solve-module-01-02.sh /home/rhel/scripts/solve-mod-01-02.sh
cp ${SCRIPT_FILES}/solve-module-01-03.sh /home/rhel/scripts/solve-mod-01-03.sh
cp ${SCRIPT_FILES}/solve-module-01-04.sh /home/rhel/scripts/solve-mod-01-04.sh
cp ${SCRIPT_FILES}/solve-module-01-05.sh /home/rhel/scripts/solve-mod-01-05.sh
cp ${SCRIPT_FILES}/solve-module-01-06.sh /home/rhel/scripts/solve-mod-01-06.sh
cp ${SCRIPT_FILES}/solve-module-01-07.sh /home/rhel/scripts/solve-mod-01-07.sh
cp ${SCRIPT_FILES}/solve-module-01-08.sh /home/rhel/scripts/solve-mod-01-08.sh
chmod +x /home/rhel/scripts/solve-mod-01-*.sh

# Clean up temporary repository clone
echo "=== Cleaning up temporary files ==="
rm -rf ${TEMP_REPO}

chown -R rhel:rhel /home/rhel/

subscription-manager unregister && subscription-manager clean
