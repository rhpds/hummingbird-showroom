# Module 2 Images

This directory contains screenshots and images for Module 2: Building Hummingbird Images with Shipwright on OpenShift.

## Images to Capture During Workshop Delivery

### Operator Installation
- `operatorhub-search.png` - OperatorHub search showing "Builds for Red Hat OpenShift"
- `operator-install-page.png` - Operator installation details page
- `operator-installed.png` - Operator showing "Succeeded" status in installed operators view

### Build Resources
- `clusterbuildstrategy-list.png` - CLI or web console showing ClusterBuildStrategy resources
- `build-yaml-example.png` - Sample Build resource YAML in editor
- `buildrun-yaml-example.png` - Sample BuildRun resource YAML

### Build Execution
- `buildrun-running.png` - BuildRun status showing "Running" state
- `buildrun-succeeded.png` - BuildRun status showing "Succeeded" state
- `build-logs-output.png` - Tekton TaskRun logs showing build progress
- `buildpacks-detect.png` - Buildpacks detection output showing language/runtime

### Registry Integration
- `quay-io-repository.png` - Quay.io showing pushed image
- `image-digest-output.png` - Terminal showing image digest after successful push
- `internal-registry-config.png` - OpenShift internal registry configuration

### Security Features
- `sbom-generation-logs.png` - Syft SBOM generation step in build logs
- `grype-scan-logs.png` - Grype vulnerability scanning step output
- `cosign-signing-framework.png` - Cosign signing step (demo/framework)

### Deployment
- `deployment-yaml.png` - Deployment manifest for built application
- `pods-running.png` - OpenShift web console or CLI showing running pods
- `route-output.png` - Route URL and application response
- `app-response.png` - curl or browser showing application output

### Build Strategies
- `multi-lang-strategy.png` - Custom multi-language BuildStrategy YAML
- `hummingbird-secure-build.png` - Secure build strategy with SBOM and scanning

### Verification
- `production-deployment.png` - Production namespace with deployed application
- `image-size-comparison.png` - Size comparison between UBI and Hummingbird builds

## Naming Conventions

- Use descriptive kebab-case names
- Prefix with step number if relevant to specific lab step (e.g., `step-14-buildrun-progress.png`)
- Keep file sizes reasonable (< 500KB per image when possible)
- Use PNG format for screenshots for best quality
- Use OpenShift web console screenshots where visual clarity helps
- Use CLI terminal screenshots for detailed command output

## Image References in AsciiDoc

Reference images using:
```asciidoc
image::module-02/filename.png[Alt text description, link=self, window=blank, width=100%]
```

## OpenShift Web Console Screenshots

When capturing OpenShift web console screenshots:
- Use Administrator perspective for operator installation
- Use Developer perspective for application deployments (where appropriate)
- Ensure cluster URL is visible but redact any sensitive information
- Focus on relevant UI elements, crop out unnecessary chrome
- Use consistent theme (light or dark mode) throughout module
