$ErrorActionPreference = 'Stop'
$version = if ($env:DOIN_VERSION) { $env:DOIN_VERSION } else { 'latest' }
$repo = if ($env:DOIN_REPO) { $env:DOIN_REPO } else { 'mitchellbernstein/doin.sh' }
$destination = if ($env:DOIN_INSTALL_DIR) { $env:DOIN_INSTALL_DIR } else { Join-Path $env:LOCALAPPDATA 'doin\bin' }
if ([Runtime.InteropServices.RuntimeInformation]::OSArchitecture -ne [Runtime.InteropServices.Architecture]::X64) { throw 'This Windows download requires x64.' }
$target = Join-Path $destination 'doin.exe'
if ((Test-Path $target) -and $env:DOIN_REPLACE -ne '1') { throw 'doin.exe exists. Set DOIN_REPLACE=1 to update.' }
$base = if ($version -eq 'latest') { "https://github.com/$repo/releases/latest/download" } else { "https://github.com/$repo/releases/download/$version" }
$temporary = Join-Path ([IO.Path]::GetTempPath()) ('doin-install-' + [Guid]::NewGuid())
New-Item -ItemType Directory $temporary | Out-Null
try {
  $archive = Join-Path $temporary 'doin-windows-x86_64.zip'
  Invoke-WebRequest "$base/doin-windows-x86_64.zip" -OutFile $archive
  $checksums = (Invoke-WebRequest "$base/SHA256SUMS").Content
  $matches = @($checksums -split "`n" | Where-Object { $_ -match '^([a-fA-F0-9]{64})\s+\*?doin-windows-x86_64\.zip\s*$' })
  if ($matches.Count -ne 1) { throw 'Missing or ambiguous Windows checksum.' }
  $expected = ($matches[0] -split '\s+')[0]
  if ((Get-FileHash $archive -Algorithm SHA256).Hash -ne $expected) { throw 'Checksum mismatch; existing installation preserved.' }
  Expand-Archive $archive (Join-Path $temporary 'archive')
  $binary = Join-Path $temporary 'archive\doin.exe'
  if (-not (Test-Path $binary)) { throw 'Archive has no doin.exe.' }
  New-Item -ItemType Directory -Force $destination | Out-Null
  $staging = Join-Path $destination ('doin-' + [Guid]::NewGuid() + '.tmp')
  try { Copy-Item $binary $staging; if (Test-Path $target) { [IO.File]::Replace($staging, $target, [System.Management.Automation.Language.NullString]::Value) } else { [IO.File]::Move($staging, $target) } } finally { Remove-Item -Force -ErrorAction SilentlyContinue $staging }
  Write-Output "Installed $target"
  Write-Output "Add $destination to your user PATH, then run doin."
} finally { Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $temporary }
