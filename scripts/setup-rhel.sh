#! /bin/bash
# dnf install -y container-tools java-21-openjdk-devel python3-pip vim-enhanced cloud-init git-all

# Download Flask packages locally
mkdir -p /var/pypi-cache
pip download  --python-version=3.14 --only-binary=:all: flask -d /var/pypi-cache/
pip download  --python-version=3.12 --only-binary=:all: flask -d /var/pypi-cache/

cat > /etc/containers/systemd/pypiserver.container << 'EOF'
[Unit]
Description=PyPi Local service

[Container]
Image=docker.io/pypiserver/pypiserver:latest
ContainerName=pypiserver
PublishPort=8000:8080
Volume=/var/pypi-cache:/data/packages:z

[Service]
Restart=on-failure

[Install]
WantedBy=default.target
EOF
systemctl daemon-reload
systemctl start pypiserver

# Install cosign from GitHub releases
COSIGN_VERSION=v2.4.1
curl -LO https://github.com/sigstore/cosign/releases/download/${COSIGN_VERSION}/cosign-linux-amd64
sudo install -m 755 cosign-linux-amd64 /usr/local/bin/cosign
rm cosign-linux-amd64

# Verify installation
cosign version

# Install syft
SYFT_VERSION=v1.42.2
curl -sSfL https://raw.githubusercontent.com/anchore/syft/main/install.sh | sudo sh -s -- -b /usr/local/bin ${SYFT_VERSION}

# Verify installation
syft version

# Install grype
GRYPE_VERSION=v0.109.1
curl -sSfL https://raw.githubusercontent.com/anchore/grype/main/install.sh | sudo sh -s -- -b /usr/local/bin ${GRYPE_VERSION}

# Verify installation
grype version
grype db update

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
curl -o /home/rhel/fips/test-fips.py -L https://raw.githubusercontent.com/rhpds/zero-cve-hummingbird-showroom/refs/heads/mod1-review/scripts/test-fips.py

chown -R rhel:rhel /home/rhel/
