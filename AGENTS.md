# AGENTS.md

This repository builds and runs the GitHub Copilot CLI in Docker. Use this file as the working guide for automated or human agents making changes here.

## Project intent

- Package `@github/copilot` in a `node:20-slim` image.
- Run Copilot as a non-root user created from `PUID`/`PGID`.
- Support corporate/custom CA certificates during image build.
- Provide .NET SDKs (`8.0`, `10.0`) through the optional `dotnet` image target; default to `base`.
- Provide equivalent Linux and Windows host launchers and installers.

## Source of truth

- `docker-compose.yaml`: service definition, runtime env vars, mounted config path.
- `build/copilot/Dockerfile`: base image, apt dependencies, cert install, Copilot install.
- `build/copilot/entrypoint.sh`: UID/GID mapping, user/group creation, `.copilot` symlink setup, `gosu` handoff.
- `build/copilot/certs/`: additional CA certificates (`.crt`) installed into trust store.
- `copilot` and `install`: Linux launcher and user-local installer.
- `copilot.ps1` and `install.ps1`: PowerShell launcher and installer.
- `README.md`: operator-facing usage and examples.

## Change rules

- Keep changes surgical and directly related to the request.
- Preserve non-root execution flow (`entrypoint.sh` should continue to `exec gosu "$USER_NAME" "$@"`).
- Preserve UID/GID mapping semantics (`PUID`, `PGID`) and existing fallback behavior.
- Preserve workspace-scoped `COPILOT_CONFIG_DIR` state and the central `config/copilot/config.json` login/settings symlink target.
- If Docker/runtime behavior changes, update `README.md` in the same change.
- Do not commit secrets, tokens, or private certificates.

## Validation commands

Run the smallest relevant set based on files changed:

```bash
# Rebuild after Dockerfile/entrypoint/compose changes
docker-compose build

# Basic CLI smoke test
docker-compose run --rm copilot copilot --help

# Verify SDK availability when toolchain layers changed
COPILOT_BUILD_TARGET=dotnet docker-compose build
COPILOT_BUILD_TARGET=dotnet docker-compose run --rm copilot dotnet --list-sdks

# Linux launcher and installer behavior
./tests/copilot.Tests.sh
```

## Notes for agents

- Match existing shell style in `entrypoint.sh` (simple bash, explicit checks, no broad error swallowing).
- Prefer explicit, predictable behavior over hidden defaults.
- If you find conflicting documentation vs. implementation, align docs to actual behavior in this repo.
