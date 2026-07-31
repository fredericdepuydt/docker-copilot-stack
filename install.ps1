$ErrorActionPreference = "Stop"

$copilotScriptPath = Join-Path $PSScriptRoot "copilot.ps1"

if (-not (Test-Path -LiteralPath $copilotScriptPath)) {
    throw "Expected script not found: $copilotScriptPath"
}
$copilotScriptPath = (Resolve-Path -LiteralPath $copilotScriptPath).Path

$profilePath = $PROFILE.CurrentUserCurrentHost
$profileDir = Split-Path -Parent $profilePath

if (-not (Test-Path -LiteralPath $profileDir)) {
    New-Item -ItemType Directory -Path $profileDir -Force | Out-Null
}

if (-not (Test-Path -LiteralPath $profilePath)) {
    New-Item -ItemType File -Path $profilePath -Force | Out-Null
}

$escapedPath = $copilotScriptPath.Replace("'", "''")
$startMarker = "# >>> copilot alias >>>"
$endMarker = "# <<< copilot alias <<<"
$aliasBlock = @"
$startMarker
function copilot {
    & '$escapedPath' @args
}
$endMarker
"@

$profileContent = Get-Content -LiteralPath $profilePath -Raw

if ($profileContent -match [regex]::Escape($startMarker)) {
    $pattern = [regex]::Escape($startMarker) + ".*?" + [regex]::Escape($endMarker)
    $updatedContent = [regex]::Replace($profileContent, $pattern, $aliasBlock, [System.Text.RegularExpressions.RegexOptions]::Singleline)
} else {
    if ($profileContent -and -not $profileContent.EndsWith("`n")) {
        $profileContent += "`r`n"
    }
    $updatedContent = $profileContent + "`r`n" + $aliasBlock + "`r`n"
}

Set-Content -LiteralPath $profilePath -Value $updatedContent

Write-Host "Added copilot function to $profilePath"
Write-Host "Run '. `$PROFILE' (or restart PowerShell), then use: copilot"
