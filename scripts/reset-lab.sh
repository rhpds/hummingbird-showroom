#!/bin/bash
# reset-lab.sh - Quick reset for modules 01-01 through 01-06

echo "Resetting lab environment..."

# Stop all containers
CONTAINERS=$(podman ps -aq)
[ -n "$CONTAINERS" ] && podman stop $CONTAINERS && podman rm $CONTAINERS

# Remove lab images
podman rmi -f \
  my-website \
  my-flasksite:ubi \
  my-flasksite:hi \
  hummingbird-demo:v1 \
  caddy:ssl \
  curl:local-ca \
  fips:no \
  fips:yes \
  2>/dev/null || true

podman image prune -f

# Clean files
rm -f ~/webserver/Containerfile \
      ~/flask/Containerfile.hi \
      ~/flask/index.html \
      ~/scanning/{cosign.key,cosign.pub,*.spdx,*.json} \
      ~/{Containerfile.pem,root.key,root.crt,ca.pem} \
      ~/fips/Containerfile{,.fips} \
      ~/hummingbird_demo.cil

# Reset system state
sudo semodule -r hummingbird_demo 2>/dev/null || true
systemctl --user disable --now podman.socket 2>/dev/null || true

echo "Done."
