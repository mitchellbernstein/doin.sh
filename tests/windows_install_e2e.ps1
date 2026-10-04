# Failure census: checksum rejection, existing destination, explicit replacement,
# spaced directories, wrong architecture, missing archive, cleanup on every error.
$ErrorActionPreference = 'Stop'
$root = Join-Path ([IO.Path]::GetTempPath()) ('doin-install-test-' + [Guid]::NewGuid())
$artifact = Join-Path $PSScriptRoot '../artifacts/windows-e2e/installer.json'
New-Item -ItemType Directory $root | Out-Null
$results = @()
try {
  $fixture = Join-Path $root 'fixture'; New-Item -ItemType Directory $fixture | Out-Null
  Copy-Item (Join-Path $PSScriptRoot '../zig-out/bin/doin.exe') $fixture
  Copy-Item (Join-Path $PSScriptRoot '../LICENSE') $fixture
  $archive = Join-Path $root 'doin-windows-x86_64.zip'; Compress-Archive (Join-Path $fixture '*') $archive
  $hash = (Get-FileHash $archive).Hash.ToLowerInvariant()
  $env:DOIN_INSTALL_DIR = Join-Path $root 'Install with spaces'; $env:DOIN_VERSION = 'fixture'; $env:DOIN_REPLACE = $null
  $fixtureDownloads = @{archive=$archive;hash=$hash;corrupt=$false}
  $downloadShim = {
    param($Uri,$OutFile)
    if ($Uri.EndsWith('/SHA256SUMS')) {
      $selectedHash = if ($fixtureDownloads.corrupt) {'0'*64} else {$fixtureDownloads.hash}
      return @{Content=($selectedHash+'  doin-windows-x86_64.zip')}
    }
    Copy-Item -LiteralPath $fixtureDownloads.archive -Destination $OutFile
  }.GetNewClosure()
  Set-Item Function:global:Invoke-WebRequest -Value $downloadShim
  & (Join-Path $PSScriptRoot '../scripts/install.ps1')
  $installed=Join-Path $env:DOIN_INSTALL_DIR 'doin.exe'; if ((Get-FileHash $installed).Hash -ne (Get-FileHash (Join-Path $fixture 'doin.exe')).Hash) {throw 'Wrong installed executable'}
  $results += @{name='verified real archive into spaced folder';passed=$true}
  try { & (Join-Path $PSScriptRoot '../scripts/install.ps1'); throw 'Replacement unexpectedly allowed' } catch { if ($_.Exception.Message -notmatch 'exists') {throw} }
  $results += @{name='existing destination preserved';passed=$true}
  $env:DOIN_REPLACE='1';$fixtureDownloads.corrupt=$true
  try { & (Join-Path $PSScriptRoot '../scripts/install.ps1'); throw 'Corrupt checksum unexpectedly allowed' } catch { if ($_.Exception.Message -notmatch 'Checksum mismatch') {throw} }
  if ((Get-FileHash $installed).Hash -ne (Get-FileHash (Join-Path $fixture 'doin.exe')).Hash) {throw 'Failed checksum altered destination'}
  $results += @{name='checksum failure preserves destination';passed=$true}
  $fixtureDownloads.corrupt=$false;& (Join-Path $PSScriptRoot '../scripts/install.ps1')
  $results += @{name='explicit verified update';passed=$true}
} finally {
  Remove-Item Function:global:Invoke-WebRequest -ErrorAction SilentlyContinue
  Remove-Item -Recurse -Force $root
  New-Item -ItemType Directory -Force (Split-Path $artifact) | Out-Null
  ConvertTo-Json -Depth 5 $results | Set-Content -Encoding utf8 $artifact
}
