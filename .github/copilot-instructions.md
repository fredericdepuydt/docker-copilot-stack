# Copilot Instructions

## Project Overview

This is a Docker container setup that runs the GitHub Copilot CLI (`@github/copilot` npm package) inside a Node.js 20-slim container. The container mounts a host `/workspace` directory and runs Copilot as a non-root user.

## Build & Run

```bash
# Build and start the container
docker-compose up -d

# Run with custom user/group IDs (default: 1000:1000)
PUID=1001 PGID=1001 docker-compose up -d

# View logs
docker-compose logs copilot

# Stop
docker-compose down
```

## Architecture

```
build/
  copilot/
    Dockerfile       # node:20-slim image, installs @github/copilot via npm
    entrypoint.sh    # Creates non-root `appuser`, drops privileges via gosu
    certs/           # Corporate CA certs (AMB PKI) installed into system trust
workspace/           # Bind-mounted from host; working directory inside container
docker-compose.yaml  # Defines the `copilot` service
```

**Entrypoint flow:** The container starts as root, creates `appuser` with the specified `PUID`/`PGID`, sets ownership on `/home/appuser/.copilot`, then uses `gosu` to drop to `appuser` before running the Copilot CLI.

## Key Conventions

- **User mapping:** Always configure `PUID`/`PGID` environment variables to match the host user to avoid file permission issues on the mounted `/workspace` volume.
- **CA certificates:** Place corporate/custom CA certs in `build/copilot/certs/` as `.crt` files. The Dockerfile installs them into the system trust store and configures npm to use them — this is required for proxied/corporate networks.
- **No root execution:** The entrypoint falls back to running as root only if `appuser` creation fails; this should not happen in normal use.
- **Copilot config storage:** The CLI stores tokens and config in `/home/appuser/.copilot` inside the container (not persisted across container recreations unless a volume is added).
