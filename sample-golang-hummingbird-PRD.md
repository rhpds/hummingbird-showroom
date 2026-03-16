# Product Requirements Document: sample-golang-hummingbird

## Purpose

A sample Go HTTP application built on Red Hat Hummingbird container images,
used as the Go test case for Module 2.2 (Custom Build Strategies) in the
Zero-CVE Hummingbird Workshop.

Demonstrates that Hummingbird images can run statically compiled Go binaries
while maintaining a zero-CVE posture at the OS layer.

## Repository

- **Owner**: tosin2013 (Tosin Akinosho, takinosh@redhat.com)
- **Name**: `sample-golang-hummingbird`
- **Visibility**: Public

## Application Requirements

| Requirement            | Detail                                              |
|------------------------|-----------------------------------------------------|
| Language               | Go 1.22+                                            |
| Framework              | net/http (standard library only)                    |
| Port                   | 8080                                                |
| Endpoints              | `GET /` (info), `GET /health`, `POST /compute`, `GET /compute/sample` |
| Container user         | 65532 (non-root)                                    |
| Builder image          | `registry.access.redhat.com/ubi9/go-toolset:latest` |
| Runtime image          | `quay.io/hummingbird-hatchling/core-runtime:2`      |
| Build pattern          | Multi-stage Containerfile (compile in builder, copy static binary to runtime) |
| Binary                 | Statically linked (`CGO_ENABLED=0`)                 |

## Endpoints

- `GET /` -- Returns JSON with runtime info: Go version, GOOS, GOARCH, number of CPUs
- `GET /health` -- Returns `{"status": "healthy"}`
- `POST /compute` -- Fibonacci computation: accepts `{"n": 10}`, returns `{"input": 10, "result": 55, "algorithm": "iterative"}`
- `GET /compute/sample` -- Runs computation on a hardcoded sample (`n=20`) for quick testing

## Project Structure

```
sample-golang-hummingbird/
├── .github/
│   └── workflows/
│       └── ci.yml
├── .gitignore
├── Containerfile
├── PRD.md
├── README.md
├── go.mod
├── go.sum
└── main.go
```

## Key Implementation Notes

- Use only the Go standard library (`net/http`, `encoding/json`, `runtime`)
- The binary must be statically compiled: `CGO_ENABLED=0 go build -o app .`
- The `go.mod` file is the trigger for auto-detection by the `hummingbird-multi-lang` strategy
- All responses should be JSON with appropriate Content-Type headers
- Graceful shutdown on SIGTERM/SIGINT

## Containerfile

```dockerfile
ARG BUILDER_IMAGE=registry.access.redhat.com/ubi9/go-toolset:latest
ARG RUNTIME_IMAGE=quay.io/hummingbird-hatchling/core-runtime:2

# Stage 1: Build static binary with UBI Go toolset
FROM ${BUILDER_IMAGE} AS builder

WORKDIR /build
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -a -installsuffix cgo -o app .

# Stage 2: Runtime on Hummingbird core-runtime
FROM ${RUNTIME_IMAGE}

WORKDIR /app
COPY --from=builder /build/app ./

USER 65532

EXPOSE 8080

ENTRYPOINT ["./app"]
```

## CI/CD

- **GitHub Actions**: Build, container build validation, grype security scan (fails on High/Critical), SBOM generation
- **Dependabot**: Weekly Go module and GitHub Actions updates

## Verification

```bash
# Local test
curl http://localhost:8080/
curl http://localhost:8080/health
curl http://localhost:8080/compute/sample
curl -X POST http://localhost:8080/compute -H "Content-Type: application/json" \
  -d '{"n": 10}'
```
