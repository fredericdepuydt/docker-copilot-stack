param(
    [string]$LauncherPath = (Join-Path (Split-Path -Parent $PSScriptRoot) "copilot.ps1")
)

$ErrorActionPreference = "Stop"
. $LauncherPath

$global:CopilotTestDockerArgs = @()
$global:CopilotTestDockerExitCode = 0
$global:CopilotTestPromptResponses = @()

function global:docker-compose {
    $global:CopilotTestDockerArgs = @($args)
    $global:LASTEXITCODE = $global:CopilotTestDockerExitCode
}

function global:Read-Host {
    param([string]$Prompt)

    if ($global:CopilotTestPromptResponses.Count -eq 0) {
        throw "Unexpected prompt: $Prompt"
    }

    $response = $global:CopilotTestPromptResponses[0]
    if ($global:CopilotTestPromptResponses.Count -eq 1) {
        $global:CopilotTestPromptResponses = @()
    } else {
        $global:CopilotTestPromptResponses = @($global:CopilotTestPromptResponses[1..($global:CopilotTestPromptResponses.Count - 1)])
    }
    return $response
}

function Assert-Equal {
    param(
        [Parameter(Mandatory)]
        $Expected,

        [Parameter(Mandatory)]
        $Actual,

        [Parameter(Mandatory)]
        [string]$Message
    )

    if ($Expected -ne $Actual) {
        throw "$Message Expected '$Expected', got '$Actual'."
    }
}

function Assert-True {
    param(
        [Parameter(Mandatory)]
        [bool]$Condition,

        [Parameter(Mandatory)]
        [string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Assert-ThrowsLike {
    param(
        [Parameter(Mandatory)]
        [scriptblock]$Action,

        [Parameter(Mandatory)]
        [string]$Pattern,

        [Parameter(Mandatory)]
        [string]$Message
    )

    try {
        & $Action
    } catch {
        if ($_.Exception.Message -like $Pattern) {
            return
        }
        throw "$Message Wrong error: $($_.Exception.Message)"
    }

    throw "$Message Expected an error matching '$Pattern'."
}

function Set-WorkspaceFile {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$RootPath,

        [Parameter(Mandatory)]
        [string]$WorkspacePath
    )

    $content = @"
{
  // Names are intentionally mixed-case to verify case-insensitive matching.
  "folders": [
    {
      "name": "rOoT",
      "path": "$($RootPath.Replace("\", "\\"))",
    },
    {
      "name": "WORKSPACE",
      "path": "$($WorkspacePath.Replace("\", "\\"))",
    },
  ],
  "settings": {
    "url": "https://example.test/path"
  },
}
"@
    Set-Content -LiteralPath $Path -Value $content -Encoding UTF8
}

function Get-DockerArgumentAfter {
    param([string]$Name)

    $index = [array]::IndexOf($global:CopilotTestDockerArgs, $Name)
    if ($index -lt 0 -or $index + 1 -ge $global:CopilotTestDockerArgs.Count) {
        throw "Docker argument '$Name' was not followed by a value."
    }
    return $global:CopilotTestDockerArgs[$index + 1]
}

function Invoke-TestLauncher {
    param(
        [Parameter(Mandatory)]
        [string]$WorkingDirectory,

        [string[]]$Arguments = @("--banner"),

        [string[]]$PromptResponses = @()
    )

    $global:CopilotTestDockerArgs = @()
    $global:CopilotTestDockerExitCode = 0
    $global:CopilotTestPromptResponses = @($PromptResponses)

    Push-Location $WorkingDirectory
    try {
        return @(Invoke-CopilotLauncher -Arguments $Arguments 6>&1)
    } finally {
        Pop-Location
    }
}

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) "docker copilot workspace tests $([guid]::NewGuid())"
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null

try {
    $equalDirectory = Join-Path $testRoot "equal"
    New-Item -ItemType Directory -Path $equalDirectory | Out-Null
    Set-WorkspaceFile -Path (Join-Path $equalDirectory "equal.code-workspace") -RootPath "." -WorkspacePath "."
    Invoke-TestLauncher -WorkingDirectory $equalDirectory -Arguments @("--help") | Out-Null
    Assert-Equal -Expected "/workspace" -Actual (Get-DockerArgumentAfter "--workdir") -Message "Equal Root/Workspace cwd."
    Assert-Equal -Expected "/workspace/.copilot" -Actual ((Get-DockerArgumentAfter "-e") -replace "^COPILOT_CONFIG_DIR=", "") -Message "Equal Root/Workspace config path."

    $rootWithSpaces = Join-Path $testRoot "Root With Spaces"
    $nestedWorkspace = Join-Path $rootWithSpaces "Applications/Area/My Application"
    New-Item -ItemType Directory -Path $nestedWorkspace -Force | Out-Null
    $persistentConfig = Join-Path $nestedWorkspace ".copilot"
    New-Item -ItemType Directory -Path $persistentConfig | Out-Null
    Set-Content -LiteralPath (Join-Path $persistentConfig "existing-state") -Value "keep" -Encoding UTF8
    Set-WorkspaceFile -Path (Join-Path $nestedWorkspace "nested.code-workspace") -RootPath "../../.." -WorkspacePath "."
    Invoke-TestLauncher -WorkingDirectory $nestedWorkspace -Arguments @("chat", "--model", "test-model") | Out-Null
    Assert-Equal -Expected "/workspace/Applications/Area/My Application" -Actual (Get-DockerArgumentAfter "--workdir") -Message "Nested workspace cwd."
    Assert-Equal -Expected "${rootWithSpaces}:/workspace" -Actual (Get-DockerArgumentAfter "-v") -Message "Root mount with spaces."
    Assert-Equal -Expected "--name" -Actual (Get-DockerArgumentAfter "--name") -Message "Container name option."
    Assert-True -Condition ((Get-DockerArgumentAfter "--name") -match "^copilot-nested-\d{8}-\d{6}$") -Message "Unexpected workspace container name."
    Assert-Equal -Expected "COPILOT_CONFIG_DIR=/workspace/Applications/Area/My Application/.copilot" -Actual (Get-DockerArgumentAfter "-e") -Message "Nested workspace config path."
    Assert-True -Condition (Test-Path -LiteralPath (Join-Path $persistentConfig "existing-state")) -Message "Existing .copilot state was not preserved."

    $allowIndex = [array]::IndexOf($global:CopilotTestDockerArgs, "--allow-all-paths")
    Assert-True -Condition ($allowIndex -ge 0) -Message "--allow-all-paths was not forwarded."
    Assert-Equal -Expected "--yolo" -Actual $global:CopilotTestDockerArgs[$allowIndex + 1] -Message "--yolo order."
    Assert-Equal -Expected "chat" -Actual $global:CopilotTestDockerArgs[$allowIndex + 2] -Message "First user argument order."
    Assert-Equal -Expected "--model" -Actual $global:CopilotTestDockerArgs[$allowIndex + 3] -Message "Second user argument order."
    Assert-Equal -Expected "test-model" -Actual $global:CopilotTestDockerArgs[$allowIndex + 4] -Message "Third user argument order."
    Assert-True -Condition ($global:CopilotTestDockerArgs -notcontains "-it") -Message "Unsupported Compose -it flag was forwarded."

    Invoke-TestLauncher -WorkingDirectory $nestedWorkspace -Arguments @("chat", "--allow-all-paths", "--yolo") | Out-Null
    Assert-Equal `
        -Expected 1 `
        -Actual @($global:CopilotTestDockerArgs | Where-Object { $_ -eq "--allow-all-paths" }).Count `
        -Message "--allow-all-paths was duplicated."
    Assert-Equal `
        -Expected 1 `
        -Actual @($global:CopilotTestDockerArgs | Where-Object { $_ -eq "--yolo" }).Count `
        -Message "--yolo was duplicated."

    Invoke-TestLauncher -WorkingDirectory $nestedWorkspace -Arguments @("--stack-show-auth") | Out-Null
    Assert-Equal -Expected "show-auth" -Actual $global:CopilotTestDockerArgs[-1] -Message "Stack management command."
    Assert-Equal -Expected "copilot" -Actual $global:CopilotTestDockerArgs[-2] -Message "Stack management service."

    $composeContent = Get-Content -LiteralPath (Join-Path (Split-Path -Parent $PSScriptRoot) "docker-compose.yaml") -Raw
    Assert-True `
        -Condition ($composeContent -match "(?s)config/copilot:/copilot-stack-config") `
        -Message "Stack configuration mount was missing."

    $windowsRelative = Get-RelativeWorkspacePath `
        -Root "C:\Source\Codebase" `
        -Workspace "c:\source\codebase\Applications\MyApplication"
    Assert-Equal -Expected "Applications\MyApplication" -Actual $windowsRelative -Message "Windows drive relative path."

    $createDirectory = Join-Path $testRoot "creation accepted"
    New-Item -ItemType Directory -Path $createDirectory | Out-Null
    Invoke-TestLauncher -WorkingDirectory $createDirectory -PromptResponses @("") | Out-Null
    $createdWorkspaceFile = Join-Path $createDirectory "$((Split-Path -Leaf $createDirectory)).code-workspace"
    Assert-True -Condition (Test-Path -LiteralPath $createdWorkspaceFile -PathType Leaf) -Message "Default workspace file was not created."
    $createdData = Read-WorkspaceConfiguration -WorkspaceFile (Get-Item -LiteralPath $createdWorkspaceFile)
    Assert-Equal -Expected $createDirectory -Actual $createdData.Root -Message "Created Root path."
    Assert-Equal -Expected $createDirectory -Actual $createdData.Workspace -Message "Created Workspace path."

    $declineDirectory = Join-Path $testRoot "creation declined"
    New-Item -ItemType Directory -Path $declineDirectory | Out-Null
    $declineOutput = Invoke-TestLauncher -WorkingDirectory $declineDirectory -PromptResponses @("n")
    Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path $declineDirectory "$((Split-Path -Leaf $declineDirectory)).code-workspace"))) -Message "Declining creation still created a file."
    Assert-True -Condition (($declineOutput | Out-String) -like "*<current directory defaults>*") -Message "Default workspace display was missing."

    $multipleDirectory = Join-Path $testRoot "multiple"
    $selectedWorkspace = Join-Path $multipleDirectory "selected"
    New-Item -ItemType Directory -Path $selectedWorkspace -Force | Out-Null
    Set-WorkspaceFile -Path (Join-Path $multipleDirectory "a.code-workspace") -RootPath "." -WorkspacePath "."
    Set-WorkspaceFile -Path (Join-Path $multipleDirectory "b.code-workspace") -RootPath "." -WorkspacePath "selected"
    Invoke-TestLauncher -WorkingDirectory $multipleDirectory -PromptResponses @("2") | Out-Null
    Assert-Equal -Expected "/workspace/selected" -Actual (Get-DockerArgumentAfter "--workdir") -Message "Multiple-file selection."

    $missingDirectory = Join-Path $testRoot "missing named folder"
    New-Item -ItemType Directory -Path $missingDirectory | Out-Null
    Set-Content -LiteralPath (Join-Path $missingDirectory "missing.code-workspace") -Encoding UTF8 -Value @'
{
  "folders": [
    {
      "name": "Root",
      "path": "."
    }
  ]
}
'@
    Assert-ThrowsLike `
        -Action { Invoke-TestLauncher -WorkingDirectory $missingDirectory | Out-Null } `
        -Pattern "*missing a named 'Workspace' folder entry*" `
        -Message "Missing named Workspace entry."

    $outsideDirectory = Join-Path $testRoot "outside validation"
    $outsideRoot = Join-Path $outsideDirectory "root"
    $outsideWorkspace = Join-Path $outsideDirectory "sibling"
    New-Item -ItemType Directory -Path $outsideRoot, $outsideWorkspace -Force | Out-Null
    Set-WorkspaceFile -Path (Join-Path $outsideDirectory "outside.code-workspace") -RootPath "root" -WorkspacePath "sibling"
    Assert-ThrowsLike `
        -Action { Invoke-TestLauncher -WorkingDirectory $outsideDirectory | Out-Null } `
        -Pattern "*is outside Root*" `
        -Message "Workspace outside Root."

    $invalidDirectory = Join-Path $testRoot "invalid json"
    New-Item -ItemType Directory -Path $invalidDirectory | Out-Null
    Set-Content -LiteralPath (Join-Path $invalidDirectory "invalid.code-workspace") -Value '{ "folders": [ }' -Encoding UTF8
    Assert-ThrowsLike `
        -Action { Invoke-TestLauncher -WorkingDirectory $invalidDirectory | Out-Null } `
        -Pattern "*Invalid or unreadable workspace JSON*" `
        -Message "Invalid workspace JSON."

    $missingPathDirectory = Join-Path $testRoot "missing path"
    New-Item -ItemType Directory -Path $missingPathDirectory | Out-Null
    Set-WorkspaceFile -Path (Join-Path $missingPathDirectory "missing-path.code-workspace") -RootPath "." -WorkspacePath "not-there"
    Assert-ThrowsLike `
        -Action { Invoke-TestLauncher -WorkingDirectory $missingPathDirectory | Out-Null } `
        -Pattern "*'Workspace' directory does not exist*" `
        -Message "Missing Workspace directory."

    $global:CopilotTestDockerExitCode = 17
    Push-Location $equalDirectory
    try {
        Assert-ThrowsLike `
            -Action { Invoke-CopilotLauncher -Arguments @("--help") | Out-Null } `
            -Pattern "*exited with code 17*" `
            -Message "Docker Compose failure."
    } finally {
        Pop-Location
        $global:CopilotTestDockerExitCode = 0
    }

    Write-Host "All Copilot launcher tests passed."
} finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item Function:\global:docker-compose -ErrorAction SilentlyContinue
    Remove-Item Function:\global:Read-Host -ErrorAction SilentlyContinue
    Remove-Variable CopilotTestDockerArgs -Scope Global -ErrorAction SilentlyContinue
    Remove-Variable CopilotTestDockerExitCode -Scope Global -ErrorAction SilentlyContinue
    Remove-Variable CopilotTestPromptResponses -Scope Global -ErrorAction SilentlyContinue
}
