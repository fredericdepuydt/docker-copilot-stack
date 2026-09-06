# copilot.ps1
# Launch Copilot in the project workspace while mounting the complete codebase root.
# Usage: /path/to/copilot.ps1 [copilot arguments...]

param(
    [Parameter(ValueFromRemainingArguments)]
    [string[]]$CopilotArgs = @("--banner")
)

$ErrorActionPreference = "Stop"

function ConvertFrom-Jsonc {
    param(
        [Parameter(Mandatory)]
        [string]$Content,

        [Parameter(Mandatory)]
        [string]$Source
    )

    $withoutComments = [System.Text.StringBuilder]::new()
    $inString = $false
    $escaped = $false
    $inLineComment = $false
    $inBlockComment = $false

    for ($index = 0; $index -lt $Content.Length; $index++) {
        $character = $Content[$index]
        $nextCharacter = if ($index + 1 -lt $Content.Length) { $Content[$index + 1] } else { [char]0 }

        if ($inLineComment) {
            if ($character -eq "`r" -or $character -eq "`n") {
                $inLineComment = $false
                [void]$withoutComments.Append($character)
            }
            continue
        }

        if ($inBlockComment) {
            if ($character -eq "*" -and $nextCharacter -eq "/") {
                $inBlockComment = $false
                $index++
            } elseif ($character -eq "`r" -or $character -eq "`n") {
                [void]$withoutComments.Append($character)
            }
            continue
        }

        if ($inString) {
            [void]$withoutComments.Append($character)
            if ($escaped) {
                $escaped = $false
            } elseif ($character -eq [char]92) {
                $escaped = $true
            } elseif ($character -eq '"') {
                $inString = $false
            }
            continue
        }

        if ($character -eq '"') {
            $inString = $true
            [void]$withoutComments.Append($character)
        } elseif ($character -eq "/" -and $nextCharacter -eq "/") {
            $inLineComment = $true
            $index++
        } elseif ($character -eq "/" -and $nextCharacter -eq "*") {
            $inBlockComment = $true
            $index++
        } else {
            [void]$withoutComments.Append($character)
        }
    }

    if ($inBlockComment) {
        throw "Invalid workspace JSON in '$Source': unterminated block comment."
    }

    $json = $withoutComments.ToString()
    $withoutTrailingCommas = [System.Text.StringBuilder]::new()
    $inString = $false
    $escaped = $false

    for ($index = 0; $index -lt $json.Length; $index++) {
        $character = $json[$index]

        if ($inString) {
            [void]$withoutTrailingCommas.Append($character)
            if ($escaped) {
                $escaped = $false
            } elseif ($character -eq [char]92) {
                $escaped = $true
            } elseif ($character -eq '"') {
                $inString = $false
            }
            continue
        }

        if ($character -eq '"') {
            $inString = $true
            [void]$withoutTrailingCommas.Append($character)
            continue
        }

        if ($character -eq ",") {
            $lookAhead = $index + 1
            while ($lookAhead -lt $json.Length -and [char]::IsWhiteSpace($json[$lookAhead])) {
                $lookAhead++
            }

            if ($lookAhead -lt $json.Length -and ($json[$lookAhead] -eq "}" -or $json[$lookAhead] -eq "]")) {
                continue
            }
        }

        [void]$withoutTrailingCommas.Append($character)
    }

    try {
        return $withoutTrailingCommas.ToString() | ConvertFrom-Json -ErrorAction Stop
    } catch {
        throw "Invalid or unreadable workspace JSON in '$Source': $($_.Exception.Message)"
    }
}

function Get-NamedWorkspaceFolder {
    param(
        [Parameter(Mandatory)]
        [object]$WorkspaceData,

        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [string]$WorkspaceFile
    )

    $matches = @(
        @($WorkspaceData.folders) | Where-Object {
            [string]::Equals([string]$_.name, $Name, [System.StringComparison]::OrdinalIgnoreCase)
        }
    )

    if ($matches.Count -eq 0) {
        throw "Workspace file '$WorkspaceFile' is missing a named '$Name' folder entry."
    }

    if ($matches.Count -gt 1) {
        throw "Workspace file '$WorkspaceFile' contains multiple named '$Name' folder entries."
    }

    if ([string]::IsNullOrWhiteSpace([string]$matches[0].path)) {
        throw "The '$Name' folder entry in '$WorkspaceFile' is missing its path."
    }

    return $matches[0]
}

function Resolve-WorkspaceDirectory {
    param(
        [Parameter(Mandatory)]
        [string]$WorkspaceFileDirectory,

        [Parameter(Mandatory)]
        [string]$FolderPath,

        [Parameter(Mandatory)]
        [string]$FolderName,

        [Parameter(Mandatory)]
        [string]$WorkspaceFile
    )

    try {
        $candidatePath = if ([System.IO.Path]::IsPathRooted($FolderPath)) {
            [System.IO.Path]::GetFullPath($FolderPath)
        } else {
            [System.IO.Path]::GetFullPath((Join-Path $WorkspaceFileDirectory $FolderPath))
        }
    } catch {
        throw "The '$FolderName' path '$FolderPath' in '$WorkspaceFile' is invalid: $($_.Exception.Message)"
    }

    if (-not (Test-Path -LiteralPath $candidatePath -PathType Container)) {
        throw "The '$FolderName' directory does not exist: $candidatePath"
    }

    try {
        return (Get-Item -LiteralPath $candidatePath -ErrorAction Stop).FullName
    } catch {
        throw "The '$FolderName' directory cannot be read: $candidatePath. $($_.Exception.Message)"
    }
}

function Get-RelativeWorkspacePath {
    param(
        [Parameter(Mandatory)]
        [string]$Root,

        [Parameter(Mandatory)]
        [string]$Workspace
    )

    $windowsStyle = ($Root -match "^(?:[A-Za-z]:[\\/]|[\\/]{2})") -and
        ($Workspace -match "^(?:[A-Za-z]:[\\/]|[\\/]{2})")
    $comparison = if ($windowsStyle -or [System.IO.Path]::DirectorySeparatorChar -eq [char]92) {
        [System.StringComparison]::OrdinalIgnoreCase
    } else {
        [System.StringComparison]::Ordinal
    }
    $separator = if ($windowsStyle) { [char]92 } else { [System.IO.Path]::DirectorySeparatorChar }
    $rootForComparison = if ($windowsStyle) { $Root.Replace("/", "\") } else { $Root }
    $workspaceForComparison = if ($windowsStyle) { $Workspace.Replace("/", "\") } else { $Workspace }

    if ([string]::Equals($rootForComparison, $workspaceForComparison, $comparison)) {
        return ""
    }

    $rootPrefix = $rootForComparison
    if (-not $rootPrefix.EndsWith([string]$separator)) {
        $rootPrefix += $separator
    }

    if (-not $workspaceForComparison.StartsWith($rootPrefix, $comparison)) {
        throw "Workspace '$Workspace' is outside Root '$Root'. Workspace must be equal to or contained inside Root."
    }

    try {
        return $workspaceForComparison.Substring($rootPrefix.Length)
    } catch {
        throw "Failed to calculate the relative container path from Root '$Root' to Workspace '$Workspace': $($_.Exception.Message)"
    }
}

function Select-WorkspaceFile {
    param(
        [Parameter(Mandatory)]
        [System.IO.FileInfo[]]$WorkspaceFiles
    )

    if ($WorkspaceFiles.Count -eq 1) {
        return $WorkspaceFiles[0]
    }

    Write-Host "Multiple VS Code workspace files were found:"
    for ($index = 0; $index -lt $WorkspaceFiles.Count; $index++) {
        Write-Host ("  {0}. {1}" -f ($index + 1), $WorkspaceFiles[$index].Name)
    }

    while ($true) {
        $selection = Read-Host "Select a workspace file [1-$($WorkspaceFiles.Count)]"
        $selectedNumber = 0
        if ([int]::TryParse($selection, [ref]$selectedNumber) -and
            $selectedNumber -ge 1 -and
            $selectedNumber -le $WorkspaceFiles.Count) {
            return $WorkspaceFiles[$selectedNumber - 1]
        }
        Write-Host "Please enter a number between 1 and $($WorkspaceFiles.Count)."
    }
}

function Confirm-WorkspaceFileCreation {
    Write-Host "No VS Code workspace file was found."

    while ($true) {
        $response = Read-Host 'Create one with Root and Workspace both pointing to "."? [Y/n]'
        if ([string]::IsNullOrWhiteSpace($response) -or $response -match "^(?i:y|yes)$") {
            return $true
        }
        if ($response -match "^(?i:n|no)$") {
            return $false
        }
        Write-Host "Please answer Y or N."
    }
}

function New-DefaultWorkspaceFile {
    param(
        [Parameter(Mandatory)]
        [string]$CurrentDirectory
    )

    $directoryName = Split-Path -Leaf $CurrentDirectory
    $workspaceFile = Join-Path $CurrentDirectory "$directoryName.code-workspace"
    $content = @'
{
  "folders": [
    {
      "name": "Root",
      "path": "."
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
'@

    try {
        Set-Content -LiteralPath $workspaceFile -Value $content -Encoding UTF8 -ErrorAction Stop
        return Get-Item -LiteralPath $workspaceFile -ErrorAction Stop
    } catch {
        throw "Failed to create VS Code workspace file '$workspaceFile': $($_.Exception.Message)"
    }
}

function ConvertTo-ProjectName {
    param([Parameter(Mandatory)][string]$ProjectName)

    $sanitized = ($ProjectName.ToLowerInvariant() -replace "[^a-z0-9]+", "-").Trim("-")
    if ([string]::IsNullOrWhiteSpace($sanitized)) { return "project" }
    return $sanitized
}

function New-ContainerName {
    param([Parameter(Mandatory)][string]$ProjectName)

    return "copilot-{0}-{1}" -f (ConvertTo-ProjectName $ProjectName), (Get-Date).ToUniversalTime().ToString("yyyyMMdd-HHmmss")
}

function Invoke-Compose {
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments,

        [ValidateSet("base", "dotnet")]
        [string]$BuildTarget = "base"
    )

    $previousBuildTarget = $env:COPILOT_BUILD_TARGET
    try {
        $env:COPILOT_BUILD_TARGET = $BuildTarget
        if ($null -ne (Get-Command "docker-compose" -ErrorAction SilentlyContinue)) {
            & docker-compose @Arguments
            return
        }
        if ($null -ne (Get-Command "docker" -ErrorAction SilentlyContinue)) {
            & docker compose @Arguments
            return
        }
        throw "Docker Compose startup failed: neither 'docker-compose' nor 'docker' was found in PATH."
    } finally {
        $env:COPILOT_BUILD_TARGET = $previousBuildTarget
    }
}

function Read-WorkspaceConfiguration {
    param(
        [Parameter(Mandatory)]
        [System.IO.FileInfo]$WorkspaceFile
    )

    try {
        $content = Get-Content -LiteralPath $WorkspaceFile.FullName -Raw -ErrorAction Stop
    } catch {
        throw "Unable to read workspace file '$($WorkspaceFile.FullName)': $($_.Exception.Message)"
    }

    $workspaceData = ConvertFrom-Jsonc -Content $content -Source $WorkspaceFile.FullName
    $rootEntry = Get-NamedWorkspaceFolder -WorkspaceData $workspaceData -Name "Root" -WorkspaceFile $WorkspaceFile.FullName
    $workspaceEntry = Get-NamedWorkspaceFolder -WorkspaceData $workspaceData -Name "Workspace" -WorkspaceFile $WorkspaceFile.FullName
    $workspaceFileDirectory = $WorkspaceFile.Directory.FullName

    $buildTarget = $workspaceData.settings.'copilot.dockerBuildTarget'
    if ($null -eq $buildTarget -or ($buildTarget -is [string] -and [string]::IsNullOrWhiteSpace($buildTarget))) {
        $buildTarget = "base"
    }
    if ($buildTarget -isnot [string] -or $buildTarget -cnotin @("base", "dotnet")) {
        throw "Invalid copilot.dockerBuildTarget in '$($WorkspaceFile.FullName)': expected 'base' or 'dotnet'."
    }

    return @{
        BuildTarget = $buildTarget
        Root = Resolve-WorkspaceDirectory `
            -WorkspaceFileDirectory $workspaceFileDirectory `
            -FolderPath ([string]$rootEntry.path) `
            -FolderName "Root" `
            -WorkspaceFile $WorkspaceFile.FullName
        Workspace = Resolve-WorkspaceDirectory `
            -WorkspaceFileDirectory $workspaceFileDirectory `
            -FolderPath ([string]$workspaceEntry.path) `
            -FolderName "Workspace" `
            -WorkspaceFile $WorkspaceFile.FullName
    }
}

function Invoke-CopilotLauncher {
    param(
        [string[]]$Arguments = @("--banner")
    )

    $location = Get-Location
    if ($location.Provider.Name -ne "FileSystem") {
        throw "Copilot must be launched from a filesystem directory."
    }

    $currentDirectory = $location.Path
    $composeFile = Join-Path $PSScriptRoot "docker-compose.yaml"
    if (-not (Test-Path -LiteralPath $composeFile -PathType Leaf)) {
        throw "Docker Compose file not found: $composeFile"
    }

    $stackCommand = switch ($Arguments[0]) {
        "--stack-configure-auth" { "configure-auth"; break }
        "--stack-show-auth" { "show-auth"; break }
        "--stack-reset-auth" { "reset-auth"; break }
        default { $null }
    }
    if ($null -ne $stackCommand) {
        if ($Arguments.Count -ne 1) {
            throw "$($Arguments[0]) does not accept additional arguments."
        }
        Invoke-Compose -Arguments @(
            "-f", $composeFile,
            "run", "--rm",
            "copilot", $stackCommand
        )
        if ($LASTEXITCODE -ne 0) {
            throw "Docker Compose or Copilot exited with code $LASTEXITCODE."
        }
        return
    }

    $workspaceFiles = @(
        Get-ChildItem -LiteralPath $currentDirectory -Filter "*.code-workspace" -ErrorAction Stop |
            Where-Object { -not $_.PSIsContainer } |
            Sort-Object Name
    )

    $workspaceFile = $null
    $workspaceDisplay = "<current directory defaults>"
    $buildTarget = "base"

    if ($workspaceFiles.Count -gt 0) {
        $workspaceFile = Select-WorkspaceFile -WorkspaceFiles $workspaceFiles
    } elseif (Confirm-WorkspaceFileCreation) {
        $workspaceFile = New-DefaultWorkspaceFile -CurrentDirectory $currentDirectory
    }

    if ($null -ne $workspaceFile) {
        $configuration = Read-WorkspaceConfiguration -WorkspaceFile $workspaceFile
        $root = $configuration.Root
        $workspace = $configuration.Workspace
        $buildTarget = $configuration.BuildTarget
        $workspaceDisplay = $workspaceFile.FullName
    } else {
        $root = (Get-Item -LiteralPath $currentDirectory -ErrorAction Stop).FullName
        $workspace = $root
    }

    $relativeWorkspacePath = Get-RelativeWorkspacePath -Root $root -Workspace $workspace
    $containerRelativePath = $relativeWorkspacePath -replace "\\", "/"
    $containerWorkspace = if ([string]::IsNullOrEmpty($containerRelativePath)) {
        "/workspace"
    } else {
        "/workspace/$containerRelativePath"
    }
    $containerConfig = "$containerWorkspace/.copilot"
    $projectName = Split-Path -Leaf $workspace
    if ($null -ne $workspaceFile) {
        $projectName = [System.IO.Path]::GetFileNameWithoutExtension($workspaceFile.Name)
    }
    $containerName = New-ContainerName -ProjectName $projectName

    Write-Host ("VS Code workspace: {0}" -f $workspaceDisplay)
    Write-Host ("Docker build target: {0}" -f $buildTarget)
    Write-Host ("Host root:          {0}" -f $root)
    Write-Host ("Host workspace:     {0}" -f $workspace)
    Write-Host ("Docker mount:       {0} -> /workspace" -f $root)
    Write-Host ("Container cwd:      {0}" -f $containerWorkspace)
    Write-Host ("Copilot workspace state: {0}" -f $containerConfig)
    Write-Host ("Container name:     {0}" -f $containerName)
    Write-Host "Copilot mode:       YOLO, all paths allowed"

    $mandatoryCopilotArgs = @()
    if ($Arguments -notcontains "--allow-all-paths") {
        $mandatoryCopilotArgs += "--allow-all-paths"
    }
    if ($Arguments -notcontains "--yolo") {
        $mandatoryCopilotArgs += "--yolo"
    }
    $dockerArgs = @(
        "-f", $composeFile,
        "run", "--rm",
        "--name", $containerName,
        "-v", "${root}:/workspace",
        "--workdir", $containerWorkspace,
        "-e", "COPILOT_CONFIG_DIR=$containerConfig",
        "copilot",
        "copilot"
    )
    $dockerArgs += $mandatoryCopilotArgs
    $dockerArgs += $Arguments

    try {
        Invoke-Compose -Arguments $dockerArgs -BuildTarget $buildTarget
    } catch {
        throw "Docker Compose startup failed: $($_.Exception.Message)"
    }

    if ($LASTEXITCODE -ne 0) {
        throw "Docker Compose or Copilot exited with code $LASTEXITCODE."
    }
}

if ($MyInvocation.InvocationName -ne ".") {
    Invoke-CopilotLauncher -Arguments $CopilotArgs
}
