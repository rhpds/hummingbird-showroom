# Product Requirements Document: sample-nodejs-hummingbird

## Purpose

A sample Node.js HTTP application built on Red Hat Hummingbird container images,
used as the Node.js test case for Module 2.2 (Custom Build Strategies) in the
Zero-CVE Hummingbird Workshop.

Demonstrates that Hummingbird images can run production Node.js applications
(Express) while maintaining a zero-CVE posture at the OS layer.

## Repository

- **Owner**: tosin2013 (Tosin Akinosho, takinosh@redhat.com)
- **Name**: `sample-nodejs-hummingbird`
- **Visibility**: Public

## Application Requirements

| Requirement            | Detail                                                |
|------------------------|-------------------------------------------------------|
| Language               | Node.js 20                                            |
| Framework              | Express 4.x                                           |
| Port                   | 8080                                                  |
| Endpoints              | `GET /` (info), `GET /health`, `POST /transform`, `GET /transform/sample` |
| Container user         | 65532 (non-root)                                      |
| Builder image          | `registry.access.redhat.com/ubi9/nodejs-20:latest`    |
| Runtime image          | `quay.io/hummingbird-hatchling/nodejs:20`             |
| Build pattern          | Multi-stage Containerfile (npm install in builder, copy to runtime) |

## Endpoints

- `GET /` -- Returns JSON with runtime info: Node.js version, Express version, V8 version, platform, architecture
- `GET /health` -- Returns `{"status": "healthy"}`
- `POST /transform` -- Text transformation: accepts `{"text": "hello world", "operation": "uppercase"}`, returns `{"input": "hello world", "operation": "uppercase", "result": "HELLO WORLD"}`
  - Supported operations: `uppercase`, `lowercase`, `reverse`, `wordcount`, `base64encode`, `base64decode`
- `GET /transform/sample` -- Runs a transformation on hardcoded sample data for quick testing

## Project Structure

```
sample-nodejs-hummingbird/
├── .github/
│   └── workflows/
│       └── ci.yml
├── .gitignore
├── Containerfile
├── PRD.md
├── README.md
├── package.json
├── package-lock.json
└── server.js
```

## Key Implementation Notes

- Use Express for routing
- The `package.json` file is the trigger for auto-detection by the `hummingbird-multi-lang` strategy
- All responses should be JSON with appropriate Content-Type headers
- Use `npm ci --only=production` in the builder stage for reproducible builds
- Graceful shutdown on SIGTERM/SIGINT

## Containerfile

```dockerfile
ARG BUILDER_IMAGE=registry.access.redhat.com/ubi9/nodejs-20:latest
ARG RUNTIME_IMAGE=quay.io/hummingbird-hatchling/nodejs:20

# Stage 1: Install dependencies with UBI Node.js
FROM ${BUILDER_IMAGE} AS builder

WORKDIR /build
COPY package*.json ./
RUN npm ci --only=production
COPY . .

# Stage 2: Runtime on Hummingbird Node.js
FROM ${RUNTIME_IMAGE}

WORKDIR /app
COPY --from=builder /build ./

USER 65532

EXPOSE 8080

CMD ["node", "server.js"]
```

## CI/CD

- **GitHub Actions**: Build, container build validation, grype security scan (fails on High/Critical), SBOM generation
- **Dependabot**: Weekly npm and GitHub Actions updates

## Verification

```bash
# Local test
curl http://localhost:8080/
curl http://localhost:8080/health
curl http://localhost:8080/transform/sample
curl -X POST http://localhost:8080/transform -H "Content-Type: application/json" \
  -d '{"text": "hello world", "operation": "uppercase"}'
```
