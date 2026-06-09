#!/usr/bin/env pwsh
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$Repo = "openai/codex"

function Fail {
    param([string] $Message)

    Write-Error $Message
    exit 1
}

function Reject-Installation {
    param(
        [string] $Reason,
        [string] $Path
    )

    Write-Error @"
Refusing to upgrade this Codex installation.
Reason: $Reason
Detected path: $Path

This script only upgrades direct GitHub binary installations.
"@
    exit 1
}

# Compatible with both Windows PowerShell 5.1 and PowerShell Core.
if ($env:OS -notlike "*Windows*") {
    Fail "This script only supports Windows."
}

switch ($env:PROCESSOR_ARCHITECTURE) {
    "AMD64" { $Target = "x86_64-pc-windows-msvc" }
    "ARM64" { $Target = "aarch64-pc-windows-msvc" }
    default {
        Fail "Unsupported architecture: $env:PROCESSOR_ARCHITECTURE"
    }
}

try {
    $CodexCommand = Get-Command codex -ErrorAction Stop
} catch {
    Fail "codex is not currently installed or not present in PATH."
}

$CodexPath = [System.IO.Path]::GetFullPath($CodexCommand.Source)
$CodexDir = Split-Path -Parent $CodexPath

if (-not (Test-Path -LiteralPath $CodexPath -PathType Leaf)) {
    Fail "Active codex is not a regular file: $CodexPath"
}

if ([System.IO.Path]::GetExtension($CodexPath).ToLowerInvariant() -ne ".exe") {
    Reject-Installation "the active codex command is not a direct .exe binary" $CodexPath
}

$RejectedFragments = @(
    "*\node_modules\*",
    "*\npm\*",
    "*\.npm\*",
    "*\nvm\*",
    "*\scoop\*",
    "*\chocolatey\*",
    "*\winget\*",
    "*\windowsapps\*",
    "*\appdata\local\microsoft\winget\*",
    "*\appdata\local\microsoft\windowsapps\*"
)

foreach ($Fragment in $RejectedFragments) {
    if ($CodexPath -like $Fragment) {
        Reject-Installation "this looks like a package-manager or wrapper installation" $CodexPath
    }
}

$VersionOutput = & $CodexPath --version 2>$null

if ($LASTEXITCODE -ne 0 -or $VersionOutput -notmatch "^codex-cli ") {
    Reject-Installation "the executable does not look like the Codex CLI binary" $CodexPath
}

Write-Host "Detected direct Codex installation:"
Write-Host "  $CodexPath"
Write-Host

$TempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("codex-update-" + [System.Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $TempDir | Out-Null

try {
    function Download-And-Install {
        param(
            [Parameter(Mandatory = $true)]
            [string] $AssetBaseName,

            [Parameter(Mandatory = $true)]
            [string] $DestinationPath
        )

        $AssetName = "$AssetBaseName-$Target.exe"
        $Url = "https://github.com/$Repo/releases/latest/download/$AssetName"
        $DownloadedExe = Join-Path $TempDir $AssetName

        Write-Host "Downloading $AssetName..."

        try {
            Invoke-WebRequest -Uri $Url -OutFile $DownloadedExe -UseBasicParsing
        } catch {
            Fail "Failed to download $AssetName from $Url"
        }

        if (-not (Test-Path -LiteralPath $DownloadedExe -PathType Leaf)) {
            Fail "Downloaded file not found: $DownloadedExe"
        }

        if ((Get-Item -LiteralPath $DownloadedExe).Length -le 0) {
            Fail "Downloaded file is empty: $DownloadedExe"
        }

        $DestinationDir = Split-Path -Parent $DestinationPath

        if (-not (Test-Path -LiteralPath $DestinationDir -PathType Container)) {
            Fail "Destination directory does not exist: $DestinationDir"
        }

        try {
            Copy-Item -LiteralPath $DownloadedExe -Destination $DestinationPath -Force
        } catch {
            Fail @"
Failed to write to:
  $DestinationPath

The file may be locked by a running Codex process, or you may not have permission to write to this folder.
Close any running Codex sessions and, if needed, run this script from an elevated Administrator PowerShell session.
"@
        }

        Write-Host "Installed $DestinationPath"
    }

    Download-And-Install "codex" $CodexPath

    $SandboxSetupPath = Join-Path $CodexDir "codex-windows-sandbox-setup.exe"

    Write-Host

    if (Test-Path -LiteralPath $SandboxSetupPath -PathType Leaf) {
        Write-Host "Detected Codex Windows sandbox setup executable:"
        Write-Host "  $SandboxSetupPath"
    } else {
        Write-Host "No codex-windows-sandbox-setup.exe found next to codex."
        Write-Host "Installing it next to codex:"
        Write-Host "  $SandboxSetupPath"
    }

    Download-And-Install "codex-windows-sandbox-setup" $SandboxSetupPath

    Write-Host
    & $CodexPath --version

    if (Test-Path -LiteralPath $SandboxSetupPath -PathType Leaf) {
        & $SandboxSetupPath --version
    }
}
finally {
    Remove-Item -LiteralPath $TempDir -Recurse -Force -ErrorAction SilentlyContinue
}
