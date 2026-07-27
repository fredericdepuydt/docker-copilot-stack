# GitHub Copilot CLI Container

A Docker container that runs the [GitHub Copilot CLI](https://www.npmjs.com/package/@github/copilot) in an isolated environment, with your local workspace mounted inside.

## Prerequisites

- [Docker](https://docs.docker.com/get-docker/)
- [Docker Compose](https://docs.docker.com/compose/install/)

## Quick Start

### Build the image

```bash
docker-compose build
```

### Run once and destroy

Run a command, then automatically remove the container when it exits:

```bash
docker-compose run --rm copilot copilot --help
```

This is the recommended way to use the container for one-off tasks — a single command that starts a fresh container, runs Copilot, and cleans up afterwards.

### Interactive session

For interactive use (e.g., guided conversations with Copilot), enable a TTY:

```bash
docker-compose run --rm -it copilot copilot chat
```

### PowerShell launcher

Run `install.ps1` to add a `copilot` function to your PowerShell profile. The function runs `copilot.ps1`, which mounts your current directory as `/workspace` and starts an interactive Copilot session in the container:

```powershell
.\install.ps1
. $PROFILE
copilot
```

Pass arguments straight through to the CLI when needed:

```powershell
copilot chat
copilot --help
```

### Long-running / background

To start the container in the background (it will exit immediately unless given a persistent command):

```bash
docker-compose up -d
docker-compose down   # stop and remove
```

## Configuration

### .NET SDKs in the container

The image now installs both `.NET 8` and `.NET 10` SDKs so mixed-version solutions can build in the same container.

After rebuilding, verify inside the container:

```bash
docker-compose run --rm copilot dotnet --list-sdks
```

### User ID mapping

By default the container runs as `appuser` with UID/GID `1000:1000`. If your host user has a different ID, set `PUID` and `PGID` so that files written to `/workspace` are owned by you:

```bash
PUID=$(id -u) PGID=$(id -g) docker-compose run --rm copilot copilot --help
```

Or export them in your shell profile so you never have to think about it:

```bash
export PUID=$(id -u)
export PGID=$(id -g)
```

### Copilot version

The Copilot CLI version is controlled by the `COPILOT_VERSION` build argument (defaults to `latest`):

```bash
docker-compose build --build-arg COPILOT_VERSION=1.0.0
```

### Corporate / proxy networks

If you are behind a corporate proxy with a custom CA, place your `.crt` certificate files in `build/copilot/certs/` before building. They are automatically installed into the system trust store and configured for npm.

## Workspace

When you start Copilot through `copilot.ps1` or the installed `copilot` PowerShell function, your current directory is mounted to `/workspace` inside the container, which is also the working directory. Any files Copilot reads or writes will go there.

If you want to point the container at a specific directory when running `docker-compose` directly, pass an explicit bind mount on the command line:

```bash
docker-compose run --rm -it -v /path/to/your/project:/workspace copilot copilot chat
```

### Workspace-scoped Copilot session state

Copilot config/session state is now stored in `./.copilot` (inside your mounted workspace) by default.
This keeps session resume scoped to that project directory.

- Default inside container: `/workspace/.copilot`
- Override location (optional): set `COPILOT_CONFIG_DIR`

## Authentication

Copilot stores its token and session data in the workspace-scoped `.copilot` directory.
Because that path is inside the bind-mounted workspace, it persists across container runs for that workspace only.

```yaml
volumes:
  - ./:/workspace
```


### Optional: auto-run `/allow-all` at chat startup

If you want interactive sessions to automatically execute `/allow-all` once at startup, this repo includes an opt-in wrapper based on `expect`.

Enable it only for a trusted environment:

```bash
COPILOT_AUTO_ALLOW_ALL=1 docker-compose run --rm -it copilot copilot chat
```

Disable (default behavior):

```bash
COPILOT_AUTO_ALLOW_ALL=0 docker-compose run --rm -it copilot copilot chat
```

Notes:

- This only applies to the exact command `copilot chat`.
- Non-interactive commands such as `copilot --help` are unaffected.
- `expect` sends `/allow-all` once and then hands control back to your terminal.
