# copilot.ps1
# Run from any folder to launch the Copilot CLI container with that folder as the workspace.
# Usage: /path/to/copilot.ps1 [copilot arguments...]
# Example: /path/to/copilot.ps1 chat
#          /path/to/copilot.ps1 --help

param(
    [Parameter(ValueFromRemainingArguments)]
    [string[]]$CopilotArgs = @("--banner")
)

$ErrorActionPreference = "Stop"

$ComposeFile = Join-Path $PSScriptRoot "docker-compose.yaml"
$Workspace = (Get-Location).Path

$dockerArgs = @(
    "-f", $ComposeFile,
    "run", "--rm", "-it",
    "-v", "${Workspace}:/workspace",
    "copilot"
)
$dockerArgs += $CopilotArgs

& docker-compose @dockerArgs
