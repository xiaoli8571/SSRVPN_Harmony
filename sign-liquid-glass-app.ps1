$ErrorActionPreference = 'Stop'

$repo = Split-Path -Parent $MyInvocation.MyCommand.Path
$project = Join-Path $repo 'SSRVPN_HarmonyOS_liquid_glass'
$deveco = 'C:\Program Files\Huawei\DevEco Studio'
$hvigor = Join-Path $deveco 'tools\hvigor\bin\hvigorw.js'
$java = Join-Path $deveco 'jbr\bin\java.exe'
$signTool = Join-Path $deveco 'sdk\default\openharmony\toolchains\lib\hap-sign-tool.jar'
$keyStore = Join-Path $repo 'SSRVPN.p12'
$cert = Join-Path $repo 'SSRVPN.cer'
$profile = Join-Path $repo 'SSRVPNRelease.p7b'
$unsignedApp = Join-Path $project 'build\outputs\default\SSRVPN_HarmonyOS_liquid_glass-default-unsigned.app'
$dist = Join-Path $project 'dist'
$signedApp = Join-Path $dist 'SSRVPN-liquid-glass-release-signed.app'

if (-not $env:SSRVPN_KEY_PASSWORD) { throw 'SSRVPN_KEY_PASSWORD is empty' }
foreach ($required in @($hvigor, $java, $signTool, $keyStore, $cert, $profile)) {
  if (-not (Test-Path -LiteralPath $required)) { throw "Missing required file: $required" }
}

$env:DEVECO_SDK_HOME = Join-Path $deveco 'sdk'
$env:JAVA_HOME = Join-Path $deveco 'jbr'
$env:Path = (Join-Path $env:JAVA_HOME 'bin') + ';' + $env:Path
Push-Location $project
try {
  & node $hvigor --mode project -p product=default -p buildMode=release assembleApp --no-daemon
  if ($LASTEXITCODE -ne 0) { throw 'Release APP build failed' }
} finally { Pop-Location }
if (-not (Test-Path -LiteralPath $unsignedApp)) { throw "Missing unsigned APP: $unsignedApp" }

$work = Join-Path $env:TEMP ('ssrvpn-liquid-sign-' + (Get-Date -Format 'yyyyMMddHHmmss'))
$payload = Join-Path $work 'payload'
New-Item -ItemType Directory -Path $payload -Force | Out-Null
New-Item -ItemType Directory -Path $dist -Force | Out-Null
Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [System.IO.Compression.ZipFile]::OpenRead($unsignedApp)
try {
  foreach ($metadataName in @('pac.json', 'pack.info')) {
    $entry = $archive.Entries | Where-Object { $_.FullName -eq $metadataName } | Select-Object -First 1
    if ($null -eq $entry) { throw "Missing APP metadata: $metadataName" }
    [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, (Join-Path $payload $metadataName), $true)
  }
  $hapEntry = $archive.Entries | Where-Object { $_.FullName -like '*.hap' } | Select-Object -First 1
  if ($null -eq $hapEntry) { throw 'Missing inner HAP' }
  $unsignedHap = Join-Path $work 'entry-default-unsigned.hap'
  [System.IO.Compression.ZipFileExtensions]::ExtractToFile($hapEntry, $unsignedHap, $true)
} finally { $archive.Dispose() }

$signedHap = Join-Path $payload 'entry-default.hap'
& $java -jar $signTool sign-app -mode localSign -keyAlias ssrvpn -keyPwd $env:SSRVPN_KEY_PASSWORD -keystorePwd $env:SSRVPN_KEY_PASSWORD -signAlg SHA256withECDSA -appCertFile $cert -profileFile $profile -keystoreFile $keyStore -inFile $unsignedHap -outFile $signedHap
if ($LASTEXITCODE -ne 0) { throw 'Inner HAP signing failed' }
$repackedApp = Join-Path $work 'SSRVPN-liquid-glass-repacked.app'
[System.IO.Compression.ZipFile]::CreateFromDirectory($payload, $repackedApp, [System.IO.Compression.CompressionLevel]::Optimal, $false)
if (Test-Path -LiteralPath $signedApp) { Remove-Item -LiteralPath $signedApp -Force }
& $java -jar $signTool sign-app -mode localSign -keyAlias ssrvpn -keyPwd $env:SSRVPN_KEY_PASSWORD -keystorePwd $env:SSRVPN_KEY_PASSWORD -signAlg SHA256withECDSA -appCertFile $cert -profileFile $profile -keystoreFile $keyStore -inFile $repackedApp -outFile $signedApp
if ($LASTEXITCODE -ne 0) { throw 'APP shell signing failed' }
& $java -jar $signTool verify-app -inFile $signedApp -outCertChain (Join-Path $dist 'SSRVPN-liquid-glass-app-verified-cert-chain.cer') -outProfile (Join-Path $dist 'SSRVPN-liquid-glass-app-verified-profile.p7b')
if ($LASTEXITCODE -ne 0) { throw 'Signed APP verification failed' }
Write-Output 'SIGNED_APP_READY'
Get-Item -LiteralPath $signedApp | Select-Object FullName, Length, LastWriteTime
Get-FileHash -LiteralPath $signedApp -Algorithm SHA256 | Select-Object Algorithm, Hash, Path
