<#
.SYNOPSIS
    Packs this repository into an installable .rmskin package.

.DESCRIPTION
    A .rmskin is an ordinary ZIP with a 16-byte trailer appended:

        offset 0  int64   length of the ZIP data in bytes
        offset 8  byte    flags (0)
        offset 9  char[7] "RMSKIN\0"

    Rainmeter reads that trailer first and rejects anything without it with
    "Invalid package ... The Skin Packager tool must be used to create valid
    .rmskin packages." Zipping the folder by hand is therefore not enough.

    Entries are written with forward slashes and in an explicit order, because
    Compress-Archive on Windows PowerShell 5.1 can emit backslash separators
    that Rainmeter will not read.

.EXAMPLE
    .\build.ps1
    .\build.ps1 -OutFile dist\AppAudio.rmskin
#>

[CmdletBinding()]
param(
    [string]$OutFile
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem

$root = $PSScriptRoot

# Version the filename from RMSKIN.ini so the package and manifest cannot drift.
$manifest = Join-Path $root 'RMSKIN.ini'
if (-not (Test-Path $manifest)) { throw "RMSKIN.ini not found at $manifest" }
$version = (Select-String -Path $manifest -Pattern '^Version=(.+)$').Matches[0].Groups[1].Value.Trim()

if (-not $OutFile) { $OutFile = Join-Path $root "AppAudio_$version.rmskin" }
$outDir = Split-Path -Parent $OutFile
if ($outDir -and -not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }

$entries = @(
    'Skins/AppAudio/AppAudio.ini',
    'Skins/AppAudio/README.md',
    'Skins/AppAudio/@Resources/Variables.inc',
    'Skins/AppAudio/@Resources/Scripts/Get-AppAudio.ps1',
    'RMSKIN.ini'
)

foreach ($e in $entries) {
    $p = Join-Path $root ($e -replace '/', '\')
    if (-not (Test-Path $p)) { throw "Missing file: $e" }
}

if (Test-Path $OutFile) { Remove-Item $OutFile -Force }

$zip = [System.IO.Compression.ZipFile]::Open($OutFile, 'Create')
try {
    foreach ($e in $entries) {
        $src = Join-Path $root ($e -replace '/', '\')
        $entry = $zip.CreateEntry($e, [System.IO.Compression.CompressionLevel]::Optimal)
        $in = [System.IO.File]::OpenRead($src)
        try {
            $os = $entry.Open()
            try { $in.CopyTo($os) } finally { $os.Close() }
        } finally { $in.Close() }
    }
} finally {
    $zip.Dispose()
}

$zipSize = (Get-Item $OutFile).Length

$footer = New-Object byte[] 16
[BitConverter]::GetBytes([int64]$zipSize).CopyTo($footer, 0)
$footer[8] = 0
[System.Text.Encoding]::ASCII.GetBytes('RMSKIN').CopyTo($footer, 9)
$footer[15] = 0

$fs = [System.IO.File]::Open($OutFile, 'Append')
try { $fs.Write($footer, 0, 16) } finally { $fs.Close() }

Write-Host ("Built {0}" -f $OutFile)
Write-Host ("  zip payload : {0:N0} bytes" -f $zipSize)
Write-Host ("  total       : {0:N0} bytes" -f (Get-Item $OutFile).Length)
Write-Host ("  version     : {0}" -f $version)
