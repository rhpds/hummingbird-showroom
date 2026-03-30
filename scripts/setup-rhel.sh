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
echo "=== Step 5: Scaffolding Quarkus project ==="
su -l rhel -c "quarkus create app com.example:sample-app \
    --extension='rest,rest-jackson' \
    --no-code"

echo "=== Updating .dockerignore ==="
cat > /home/rhel/sample-app/.dockerignore << 'EOF'
target/
.git/
.gitignore
README.md
*.cmd
EOF

echo "=== Fixing file permissions ==="
chmod -R a+rX /home/rhel/sample-app/.mvn/ /home/rhel/sample-app/src/
chmod a+r /home/rhel/sample-app/pom.xml
chmod a+x /home/rhel/sample-app/mvnw

echo "=== Creating GreetingResource.java ==="
mkdir -p /home/rhel/sample-app/src/main/java/com/example
cat > /home/rhel/sample-app/src/main/java/com/example/GreetingResource.java << 'EOF'
package com.example;

import jakarta.ws.rs.GET;
import jakarta.ws.rs.Path;
import jakarta.ws.rs.Produces;
import jakarta.ws.rs.core.MediaType;
import java.time.Instant;
import java.util.LinkedHashMap;
import java.util.Map;

@Path("/")
public class GreetingResource {

    @GET
    @Produces(MediaType.APPLICATION_JSON)
    public Map<String, String> hello() {
        Map<String, String> response = new LinkedHashMap<>();
        response.put("message", "Hello from Hummingbird!");
        response.put("runtime", "Java " + System.getProperty("java.version"));
        response.put("platform", System.getProperty("os.name").toLowerCase());
        response.put("timestamp", Instant.now().toString());
        return response;
    }

    @GET
    @Path("/health")
    @Produces(MediaType.APPLICATION_JSON)
    public Map<String, String> health() {
        Map<String, String> response = new LinkedHashMap<>();
        response.put("status", "healthy");
        return response;
    }
}
EOF

echo "=== Configuring application.properties ==="
cat > /home/rhel/sample-app/src/main/resources/application.properties << 'EOF'
quarkus.http.host=0.0.0.0
quarkus.http.port=8080
EOF

echo "=== Creating UBI comparison image ==="
# Create Containerfile.ubi for comparison
cat > /home/rhel/sample-app/Containerfile.ubi << EOF
FROM ${UBI_REGISTRY}/ubi9/openjdk-21:latest
USER root
RUN microdnf install -y unzip && microdnf clean all
WORKDIR /build
COPY mvnw pom.xml ./
COPY .mvn ./.mvn
RUN ./mvnw dependency:go-offline -B
COPY src ./src
RUN ./mvnw package -DskipTests -B
WORKDIR /app
RUN cp -r /build/target/quarkus-app/* /app/
EXPOSE 8080
USER 1001
ENTRYPOINT ["java", "-jar", "quarkus-run.jar"]
EOF

# Build UBI-only version for comparison
podman build -f /home/rhel/sample-app/Containerfile.ubi -t hummingbird-demo:ubi /home/rhel/sample-app
echo "✅ UBI comparison image built successfully"

echo "=== Step 4: Preparing Host Directories for Bind Mounts ==="

echo "Creating host directories for bind mounts..."
mkdir -p /opt/myapp/config /opt/myapp/logs
chown -R $(id -u):$(id -g) /opt/myapp

echo "Setting SELinux context for container file access..."
semanage fcontext -a -t container_file_t "/opt/myapp/config(/.*)?" || echo "Context may already exist"
semanage fcontext -a -t container_file_t "/opt/myapp/logs(/.*)?" || echo "Context may already exist"
restorecon -Rv /opt/myapp

chown -R rhel:rhel /home/rhel/
