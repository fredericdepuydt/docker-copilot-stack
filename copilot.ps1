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

    $workspaceFile = Join-Path $CurrentDirectory "workspace.code-workspace"
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

    return @{
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

    $workspaceFiles = @(
        Get-ChildItem -LiteralPath $currentDirectory -Filter "*.code-workspace" -ErrorAction Stop |
            Where-Object { -not $_.PSIsContainer } |
            Sort-Object Name
    )

    $workspaceFile = $null
    $workspaceDisplay = "<current directory defaults>"

    if ($workspaceFiles.Count -gt 0) {
        $workspaceFile = Select-WorkspaceFile -WorkspaceFiles $workspaceFiles
    } elseif (Confirm-WorkspaceFileCreation) {
        $workspaceFile = New-DefaultWorkspaceFile -CurrentDirectory $currentDirectory
    }

    if ($null -ne $workspaceFile) {
        $configuration = Read-WorkspaceConfiguration -WorkspaceFile $workspaceFile
        $root = $configuration.Root
        $workspace = $configuration.Workspace
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

    Write-Host ("VS Code workspace: {0}" -f $workspaceDisplay)
    Write-Host ("Host root:          {0}" -f $root)
    Write-Host ("Host workspace:     {0}" -f $workspace)
    Write-Host ("Docker mount:       {0} -> /workspace" -f $root)
    Write-Host ("Container cwd:      {0}" -f $containerWorkspace)
    Write-Host ("Copilot config:     {0}" -f $containerConfig)
    Write-Host "Copilot mode:       YOLO, all paths allowed"

    if ($null -eq (Get-Command "docker-compose" -ErrorAction SilentlyContinue)) {
        throw "Docker Compose startup failed: 'docker-compose' was not found in PATH."
    }

    $dockerArgs = @(
        "-f", $composeFile,
        "run", "--rm",
        "-v", "${root}:/workspace",
        "--workdir", $containerWorkspace,
        "-e", "COPILOT_CONFIG_DIR=$containerConfig",
        "copilot",
        "copilot",
        "--allow-all-paths",
        "--yolo"
    )
    $dockerArgs += $Arguments

    try {
        & docker-compose @dockerArgs
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
