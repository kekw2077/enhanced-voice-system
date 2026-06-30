<#
.SYNOPSIS
  Produce the WinSparkle DSA signature (sparkle:dsaSignature) for an EVS update
  file, matching WinSparkle's own sign_update.bat exactly:

      openssl dgst -sha1 -binary < file | openssl dgst -sha1 -sign key | openssl enc -base64

.USAGE
  .\dist\sign_update.ps1 .\dist\out\EVS-Setup-1.0.0.exe
  .\dist\sign_update.ps1 <file> -PrivateKey C:\path\to\dsa_priv.pem

  Prints the base64 signature AND the file length (bytes) — paste both into the
  matching <enclosure> in dist/appcast.xml.

  The private key (dsa_priv.pem) is git-ignored; keep a secure backup. Losing it
  makes every installed copy un-upgradable.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true, Position = 0)]
  [string]$File,
  [string]$PrivateKey = (Join-Path $PSScriptRoot '..\dsa_priv.pem'),
  [string]$OpenSsl = ''
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $File))       { throw "File not found: $File" }
if (-not (Test-Path $PrivateKey)) { throw "Private key not found: $PrivateKey (generate with openssl; see dist/README.md)" }

# Locate openssl: PATH first, then Git for Windows' bundled copy.
if (-not $OpenSsl) {
  $cmd = Get-Command openssl -ErrorAction SilentlyContinue
  if ($cmd) { $OpenSsl = $cmd.Source }
  elseif (Test-Path 'C:\Program Files\Git\usr\bin\openssl.exe') { $OpenSsl = 'C:\Program Files\Git\usr\bin\openssl.exe' }
  else { throw 'openssl not found. Install it or pass -OpenSsl <path>.' }
}

$File = (Resolve-Path $File).Path
$PrivateKey = (Resolve-Path $PrivateKey).Path

# Stream the three-stage pipeline through temp files (avoids PowerShell's
# text-mangling of binary pipes).
$tmp1 = [System.IO.Path]::GetTempFileName()
$tmp2 = [System.IO.Path]::GetTempFileName()
try {
  & $OpenSsl dgst -sha1 -binary -out $tmp1 $File
  & $OpenSsl dgst -sha1 -sign $PrivateKey -out $tmp2 $tmp1
  $sig = & $OpenSsl enc -base64 -A -in $tmp2
} finally {
  Remove-Item $tmp1, $tmp2 -Force -ErrorAction SilentlyContinue
}

$len = (Get-Item $File).Length
Write-Host ''
Write-Host "File:    $File"
Write-Host "length:  $len"
Write-Host "sparkle:dsaSignature:"
Write-Host $sig
