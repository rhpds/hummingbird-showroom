# Module 1 Images

This directory contains screenshots and images for Module 1: Container Development Environment with Hummingbird.

## Images to Capture During Workshop Delivery

### Installation and Configuration
- `podman-desktop-install.png` - Podman Desktop installation/download page
- `podman-desktop-dashboard.png` - Main Podman Desktop dashboard showing connection
- `podman-desktop-registries.png` - Registry configuration screen

### Build Process
- `containerfile-example.png` - Multi-stage Containerfile in editor
- `build-logs.png` - Terminal output showing successful build
- `image-size-comparison.png` - Side-by-side comparison of UBI vs Hummingbird image sizes

### Security Tools
- `grype-scan-output.png` - Grype vulnerability scan results (showing zero/minimal CVEs)
- `syft-sbom-summary.png` - Syft SBOM generation output
- `cosign-sign-verify.png` - Cosign signing and verification process

### Application Testing
- `app-running-test.png` - curl output showing running application
- `podman-images-list.png` - Terminal showing built images

### Validation
- `validation-script-output.png` - Complete validation script showing all checks passed

## Naming Conventions

- Use descriptive kebab-case names
- Prefix with step number if relevant to specific lab step (e.g., `step-19-build-output.png`)
- Keep file sizes reasonable (< 500KB per image when possible)
- Use PNG format for screenshots for best quality

## Image References in AsciiDoc

Reference images using:
```asciidoc
image::module-01/filename.png[Alt text description, link=self, window=blank, width=100%]
```
