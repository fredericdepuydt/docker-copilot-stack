# GitHub Copilot CLI Container

A Docker container that runs the [GitHub Copilot CLI](https://www.npmjs.com/package/@github/copilot) with a host codebase mounted for editing.

## Prerequisites

- [Docker](https://docs.docker.com/get-docker/)
- [Docker Compose](https://docs.docker.com/compose/install/)
- Linux: Bash 4.4+, Perl with the core `JSON::PP` module, and `realpath`
- Windows: PowerShell

## Quick Start

Build the image:

```bash
docker-compose build
```

### Linux

Install the launcher for the current user:

```bash
./install
source ~/.bashrc
copilot
```

The installer adds a `copilot` shell function to the current shell's profile.
That function invokes the launcher in this repository while preserving the
caller's current directory for `.code-workspace` discovery. Keep the repository
at the same path after installation. Bash, Zsh, Fish, and POSIX-style profile
files are supported.

### Windows

Install the PowerShell launcher:

```powershell
.\install.ps1
. $PROFILE
copilot
```

The PowerShell installer adds the same repository-bound `copilot` function to
the current user's PowerShell profile.

Arguments are forwarded to the Copilot CLI after the required access flags:

```bash
copilot chat
copilot --help
```

The effective CLI invocation always includes `--allow-all-paths --yolo`.
The launchers add either flag only when it was not already supplied.

For direct Compose usage:

```bash
docker-compose run --rm copilot copilot --help
```

## Root and Workspace

Both launchers treat the named folders in a VS Code `.code-workspace` file as two separate concepts:

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

For this Linux layout:

```text
/home/alice/Source/Codebase
|-- Libraries
|   `-- Shared
`-- Applications
    `-- MyApplication
        |-- MyApplication.sln
        `-- MyApplication.code-workspace
```

Put the example workspace file above in `MyApplication`. Launching `copilot` there produces:

```text
Host root:          /home/alice/Source/Codebase
Host workspace:     /home/alice/Source/Codebase/Applications/MyApplication
Docker mount:       /home/alice/Source/Codebase -> /workspace
Container cwd:      /workspace/Applications/MyApplication
Copilot config:     /workspace/Applications/MyApplication/.copilot
Container user:     1000:1000
```

Copilot starts beside `MyApplication.sln` but can read and edit
`Libraries/Shared` through the complete Root mount. Paths containing spaces are
passed to Docker as individual arguments.

### Workspace discovery

The launcher searches only the current directory for `*.code-workspace`.

- One file: it is selected automatically.
- Multiple files: the launcher asks which file to use.
- No files: the launcher prompts:

```text
No VS Code workspace file was found.
Create one with Root and Workspace both pointing to "."? [Y/n]
```

Accepting creates `<foldername>.code-workspace` with both named folders pointing to `"."`. Declining uses the current directory as both Root and Workspace for that run without creating a file. Root and Workspace may resolve to the same directory.

Before Docker starts, the resolved mapping is displayed:

```text
VS Code workspace: <workspace-file>
Host root:          <resolved-root>
Host workspace:     <resolved-workspace>
Docker mount:       <resolved-root> -> /workspace
Container cwd:      <container-workspace>
Copilot config:     <container-workspace>/.copilot
Container user:     <host-uid>:<host-gid>
Container name:     copilot-<projectname>-<UTC timestamp>
Copilot mode:       YOLO, all paths allowed
```

When no workspace file is used, `VS Code workspace` displays `<current directory defaults>`.
`Container user` is shown by the Linux launcher; the PowerShell launcher uses
the Compose environment defaults.

### Workspace-scoped Copilot state and instructions

`COPILOT_CONFIG_DIR` is set to `Workspace/.copilot` inside the mounted Root. Existing project-specific Copilot configuration and session state therefore remain persistent across container runs.

The container working directory is set to Workspace, so Copilot discovers the project-specific `AGENTS.md` relative to that directory. The launcher does not copy `AGENTS.md` to Root. Instructions closer to files in shared-library directories can still apply through Copilot's normal hierarchical instruction discovery.

## Security

Both launchers always enable `--allow-all-paths` and `--yolo`. Copilot can execute tools without confirmation and can read, create, modify, or delete files anywhere under the mounted Root, including sibling projects and shared libraries.

Only launch it from a trusted codebase, review the resolved directories printed before startup, and keep Root as narrow as practical. An incorrect Root grants edit access to more host files than intended; invalid or out-of-root workspace mappings are rejected rather than silently widened.

## Configuration

### .NET SDKs

The image includes .NET 8 and .NET 10 SDKs:

```bash
docker-compose run --rm copilot dotnet --list-sdks
```

### User ID mapping

The Linux launcher automatically passes the current user's UID and GID as
`PUID` and `PGID`. Direct Compose usage defaults to `1000:1000`; override it
when needed:

```bash
PUID=$(id -u) PGID=$(id -g) docker-compose run --rm copilot copilot --help
```

### Copilot version

`COPILOT_VERSION` defaults to `latest`:

```bash
docker-compose build --build-arg COPILOT_VERSION=1.0.0
```

### Authentication and BYOK

Authentication is persistent but deliberately separate from workspace state:

| State | Host location | Container location |
| --- | --- | --- |
| Workspace sessions, instructions, trusted folders, and Copilot settings | `<selected workspace>/.copilot` | `COPILOT_CONFIG_DIR` |
| Stack authentication and BYOK settings | `config/copilot/auth.env` | `/copilot-stack-config/auth.env` |

On the first normal container start, when no `auth.env` exists, the entrypoint
opens an interactive configuration wizard. Non-interactive starts fail clearly
instead of waiting for input. Configure explicitly with either launcher:

```bash
copilot --stack-configure-auth
copilot --stack-show-auth
copilot --stack-reset-auth
```

```powershell
copilot --stack-configure-auth
copilot --stack-show-auth
copilot --stack-reset-auth
```

The equivalent direct Compose commands are:

```bash
docker compose run --rm copilot configure-auth
docker compose run --rm copilot show-auth
docker compose run --rm copilot reset-auth
docker compose run --rm copilot reset-auth --yes
```

`reset-auth` deletes only `config/copilot/auth.env`; it never deletes a
workspace `.copilot` directory. The launcher-specific arguments are consumed
by the launcher and are never passed to Copilot CLI.

The wizard supports three explicit modes:

| Mode | Inference | GitHub features | Offline |
| --- | --- | --- | --- |
| `github` | GitHub-hosted Copilot models | Enabled | Not allowed |
| `byok` | External provider | Disabled unless the CLI can work without GitHub | Optional |
| `hybrid` | External provider | Enabled with a GitHub token | Not allowed |

For `github` and `hybrid`, provide a user-owned fine-grained PAT with the
**Copilot Requests** account permission, an OAuth token, or a GitHub App
user-to-server token. Classic `ghp_` PATs are not supported by Copilot CLI.
The stack exports this only as `COPILOT_GITHUB_TOKEN`.

For BYOK, the currently supported provider types are `openai`, `azure`, and
`anthropic`. The `openai` type covers OpenAI and OpenAI Chat
Completions-compatible services, including LiteLLM, Ollama, vLLM, and Foundry
Local. Copilot requires a streaming model with tool/function-calling support.
The wizard validates the provider URL, model identifier, provider type, and
required key before saving. OpenAI-compatible local services may leave the API
key blank; Azure OpenAI and Anthropic require one.

Example values, entered through the wizard rather than placed in a tracked
file:

| Service | Type | Base URL example | API key |
| --- | --- | --- | --- |
| LiteLLM | `openai` | `https://litellm.example.com/v1` | Required by typical deployments |
| Ollama | `openai` | `http://host.docker.internal:11434` | Usually blank |
| vLLM | `openai` | `http://host.docker.internal:8000/v1` | Deployment dependent |
| Azure OpenAI | `azure` | `https://RESOURCE.openai.azure.com/openai/deployments/DEPLOYMENT` | Required |
| Anthropic | `anthropic` | `https://api.anthropic.com` | Required |

When running a provider on the Docker host, use a host address reachable from
the container. `localhost` inside the container is not the host. On Linux,
this may require adding an appropriate Docker host gateway mapping or using a
network-reachable address.

BYOK-only mode can set `COPILOT_OFFLINE=true`, which prevents GitHub
communication and telemetry. It does not make prompts air-gapped when the
provider URL is remote: prompts and code context still go to that provider.
Hybrid mode always disables offline mode so GitHub-integrated features, such
as the GitHub MCP server, code search, and `/delegate`, remain available.

`config/copilot/auth.env` is generated with owner-only permissions where the
host filesystem supports them and is ignored by Git. The tracked
`config/copilot/auth.env.example` contains placeholders only and is never
loaded automatically. The mount is configured relative to this repository, so
both direct Compose and launchers invoked from another directory use the same
stack configuration.

#### Automatic workspace trust

Automatic trust is enabled by default. The selected container working
directory is added to that workspace's `.copilot/config.json` before startup.
Existing JSON properties are preserved and updates are atomic. Invalid JSON is
reported and left untouched. Set `COPILOT_AUTO_TRUST_WORKSPACE=0` before
starting the launcher or Compose to disable it.

#### Security limitations

The generated authentication file is plaintext, not encrypted. Treat
`config/copilot/` as sensitive: secrets can potentially be read by root, users
with access to this repository directory, users with access to the Docker
daemon, and processes able to inspect the running container environment.
Do not copy `auth.env` into image build arguments, Dockerfiles, logs, issue
reports, or source control. Reconfigure or reset the stack if a credential is
exposed.

### Corporate or proxy networks

Place custom `.crt` certificate files in `build/copilot/certs/` before building. They are installed into the system trust store and configured for npm.

## Tests

```bash
./tests/copilot.Tests.sh
```

The existing PowerShell launcher tests remain available at
`tests/copilot.Tests.ps1`.
