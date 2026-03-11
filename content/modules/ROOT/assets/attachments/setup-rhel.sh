#! /bin/bash
# --- Core Container Tools ---
sudo dnf install -y podman buildah skopeo container-tools java-21-openjdk-devel python3-pip

# --- Quarkus CLI via JBang ---
curl -Ls https://sh.jbang.dev | bash -s - trust add https://repo1.maven.org/maven2/io/quarkus/quarkus-cli/
curl -Ls https://sh.jbang.dev | bash -s - app install --fresh --force quarkus@quarkusio
export PATH="$HOME/.jbang/bin:$PATH"
if ! grep -q '.jbang/bin' ~/.bashrc 2>/dev/null; then
    echo 'export PATH="$HOME/.jbang/bin:$PATH"' >> ~/.bashrc
fi
# Download Flask packages locally
mkdir -p /var/pypi-cache
pip download  --python-version=3.14 --only-binary=:all: flask -d /var/pypi-cache/
podman run -d -p 8000:8080 -v /var/pypi-cache:/data/packages:z pypiserver/pypiserver:latest

# Install cosign from GitHub releases
COSIGN_VERSION=v2.4.1
curl -LO https://github.com/sigstore/cosign/releases/download/${COSIGN_VERSION}/cosign-linux-amd64
sudo install -m 755 cosign-linux-amd64 /usr/local/bin/cosign
rm cosign-linux-amd64

# Verify installation
cosign version

# Install syft
SYFT_VERSION=v1.17.0
curl -sSfL https://raw.githubusercontent.com/anchore/syft/main/install.sh | sudo sh -s -- -b /usr/local/bin ${SYFT_VERSION}

# Verify installation
syft version

# Install grype
GRYPE_VERSION=v0.88.0
curl -sSfL https://raw.githubusercontent.com/anchore/grype/main/install.sh | sudo sh -s -- -b /usr/local/bin ${GRYPE_VERSION}

# Verify installation
grype version

mkdir -p ~/hummingbird-lab
cd ~/hummingbird-lab
quarkus create app com.example:sample-app \
    --extension='rest,rest-jackson' \
    --no-code

mkdir -p sample-ap/psrc/main/java/com/example
cat > sample-app/src/main/java/com/example/GreetingResource.java << 'EOF'
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

cat > sample-ap/psrc/main/resources/application.properties << 'EOF'
quarkus.http.host=0.0.0.0
quarkus.http.port=8080
EOF

