# GitHub Copilot CLI Container

A Docker container that runs the [GitHub Copilot CLI](https://www.npmjs.com/package/@github/copilot) with a host codebase mounted for editing.

## Prerequisites

- [Docker](https://docs.docker.com/get-docker/)
- [Docker Compose](https://docs.docker.com/compose/install/)
- PowerShell for the `copilot` launcher

## Quick Start

Build the image:

```bash
docker-compose build
```

Install the PowerShell launcher:

```powershell
.\install.ps1
. $PROFILE
copilot
```

Arguments are forwarded to the Copilot CLI after the required access flags:

```powershell
copilot chat
copilot --help
```

The effective CLI invocation always includes `--allow-all-paths --yolo`.

For direct Compose usage:

```bash
docker-compose run --rm -it copilot copilot --help
```

## Root and Workspace

The PowerShell launcher treats the named folders in a VS Code `.code-workspace` file as two separate concepts:

- `Root`: the complete codebase bind-mounted at `/workspace`.
- `Workspace`: the project or solution directory where Copilot starts.

The names are matched case-insensitively. `Workspace` must be equal to or contained inside `Root`. Both paths are resolved relative to the `.code-workspace` file and must exist.

```jsonc
{
  "folders": [
    {
      "name": "Root",
      "path": "../.."
    },
    {
      "name": "Workspace",
      "path": "."
    }
  ],
  "settings": {
    "terminal.integrated.cwd": "${workspaceFolder:Workspace}"
  }
}
```

Comments and trailing commas in normal VS Code JSONC files are supported.

### .NET solution with shared libraries

For this layout:

```text
C:\Source\Codebase
|-- Libraries
|   `-- Shared
`-- Applications
    `-- MyApplication
        |-- MyApplication.sln
        `-- MyApplication.code-workspace
```

Put the example workspace file above in `MyApplication`. Launching `copilot` there produces:

```text
Host Root       C:\Source\Codebase
Host Workspace  C:\Source\Codebase\Applications\MyApplication
Docker mount    C:\Source\Codebase -> /workspace
Container cwd   /workspace/Applications/MyApplication
Copilot config  /workspace/Applications/MyApplication/.copilot
```

Copilot starts beside `MyApplication.sln` but can read and edit `Libraries\Shared` through the complete Root mount. Paths containing spaces are passed to Docker as individual PowerShell arguments.

### Workspace discovery

The launcher searches only the current directory for `*.code-workspace`.

- One file: it is selected automatically.
- Multiple files: the launcher asks which file to use.
- No files: the launcher prompts:

```text
No VS Code workspace file was found.
Create one with Root and Workspace both pointing to "."? [Y/n]
```

Accepting creates `workspace.code-workspace` with both named folders pointing to `"."`. Declining uses the current directory as both Root and Workspace for that run without creating a file. Root and Workspace may resolve to the same directory.

Before Docker starts, the resolved mapping is displayed:

```text
VS Code workspace: <workspace-file>
Host root:          <resolved-root>
Host workspace:     <resolved-workspace>
Docker mount:       <resolved-root> -> /workspace
Container cwd:      <container-workspace>
Copilot config:     <container-workspace>/.copilot
Copilot mode:       YOLO, all paths allowed
```

When no workspace file is used, `VS Code workspace` displays `<current directory defaults>`.

### Workspace-scoped Copilot state and instructions

`COPILOT_CONFIG_DIR` is set to `Workspace/.copilot` inside the mounted Root. Existing project-specific Copilot configuration and session state therefore remain persistent across container runs.

The container working directory is set to Workspace, so Copilot discovers the project-specific `AGENTS.md` relative to that directory. The launcher does not copy `AGENTS.md` to Root. Instructions closer to files in shared-library directories can still apply through Copilot's normal hierarchical instruction discovery.

## Security

The PowerShell launcher always enables both `--allow-all-paths` and `--yolo`. Copilot can execute tools without confirmation and can read, create, modify, or delete files anywhere under the mounted Root, including sibling projects and shared libraries.

Only launch it from a trusted codebase, review the resolved directories printed before startup, and keep Root as narrow as practical. An incorrect Root grants edit access to more host files than intended; invalid or out-of-root workspace mappings are rejected rather than silently widened.

## Configuration

### .NET SDKs

The image includes .NET 8 and .NET 10 SDKs:

```bash
docker-compose run --rm copilot dotnet --list-sdks
```

### User ID mapping

The container uses UID/GID `1000:1000` by default. Set `PUID` and `PGID` to match the host user when needed:

```bash
PUID=$(id -u) PGID=$(id -g) docker-compose run --rm copilot copilot --help
```

### Copilot version

`COPILOT_VERSION` defaults to `latest`:

```bash
docker-compose build --build-arg COPILOT_VERSION=1.0.0
```

### Corporate or proxy networks

Place custom `.crt` certificate files in `build/copilot/certs/` before building. They are installed into the system trust store and configured for npm.
