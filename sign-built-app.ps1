$ErrorActionPreference = 'Stop'

$repo = Split-Path -Parent $MyInvocation.MyCommand.Path
$project = Join-Path $repo 'SSRVPN_HarmonyOS'
$deveco = 'C:\Program Files\Huawei\DevEco Studio'
$java = Join-Path $deveco 'jbr\bin\java.exe'
$signTool = Join-Path $deveco 'sdk\default\openharmony\toolchains\lib\hap-sign-tool.jar'
$unsignedApp = Join-Path $project 'build\outputs\default\SSRVPN_HarmonyOS-default-unsigned.app'
$keyStore = Join-Path $repo 'SSRVPN.p12'
$cert = Join-Path $repo 'SSRVPN.cer'
$profile = Join-Path $repo 'SSRVPNRelease.p7b'
$dist = Join-Path $repo 'dist'
$signedApp = Join-Path $dist 'SSRVPN_HarmonyOS-release-signed.app'

foreach ($required in @($java, $signTool, $unsignedApp, $keyStore, $cert, $profile)) {
  if (-not (Test-Path -LiteralPath $required)) {
    throw "Missing required file: $required"
  }
}
if (-not $env:SSRVPN_KEY_PASSWORD) {
  throw 'SSRVPN_KEY_PASSWORD is empty'
}

$work = Join-Path $env:TEMP ('ssrvpn-sign-' + (Get-Date -Format 'yyyyMMddHHmmss'))
$payload = Join-Path $work 'payload'
New-Item -ItemType Directory -Path $payload -Force | Out-Null
New-Item -ItemType Directory -Path $dist -Force | Out-Null
Add-Type -AssemblyName System.IO.Compression.FileSystem

$archive = [System.IO.Compression.ZipFile]::OpenRead($unsignedApp)
try {
  foreach ($metadataName in @('pac.json', 'pack.info')) {
    $metadata = $archive.Entries | Where-Object { $_.FullName -eq $metadataName } | Select-Object -First 1
    if ($null -eq $metadata) {
      throw "Missing APP metadata: $metadataName"
    }
    $metadataPath = Join-Path $payload $metadataName
    [System.IO.Compression.ZipFileExtensions]::ExtractToFile($metadata, $metadataPath, $true)
  }
  $hapEntry = $archive.Entries | Where-Object { $_.FullName -like '*.hap' } | Select-Object -First 1
  if ($null -eq $hapEntry) {
    throw 'Missing inner HAP in unsigned APP'
  }
  $unsignedHap = Join-Path $work 'entry-default-unsigned.hap'
  [System.IO.Compression.ZipFileExtensions]::ExtractToFile($hapEntry, $unsignedHap, $true)
} finally {
  $archive.Dispose()
}

$signedHap = Join-Path $payload 'entry-default.hap'
& $java -jar $signTool sign-app -mode localSign -keyAlias ssrvpn -keyPwd $env:SSRVPN_KEY_PASSWORD -keystorePwd $env:SSRVPN_KEY_PASSWORD -signAlg SHA256withECDSA -appCertFile $cert -profileFile $profile -keystoreFile $keyStore -inFile $unsignedHap -outFile $signedHap
if ($LASTEXITCODE -ne 0) {
  throw 'Inner HAP signing failed'
}

$repackedApp = Join-Path $work 'SSRVPN_HarmonyOS-repacked.app'
[System.IO.Compression.ZipFile]::CreateFromDirectory($payload, $repackedApp, [System.IO.Compression.CompressionLevel]::Optimal, $false)
if (Test-Path -LiteralPath $signedApp) {
  Remove-Item -LiteralPath $signedApp -Force
}

& $java -jar $signTool sign-app -mode localSign -keyAlias ssrvpn -keyPwd $env:SSRVPN_KEY_PASSWORD -keystorePwd $env:SSRVPN_KEY_PASSWORD -signAlg SHA256withECDSA -appCertFile $cert -profileFile $profile -keystoreFile $keyStore -inFile $repackedApp -outFile $signedApp
if ($LASTEXITCODE -ne 0) {
  throw 'APP shell signing failed'
}

$verifiedCert = Join-Path $dist 'SSRVPN_HarmonyOS-app-verified-cert-chain.cer'
$verifiedProfile = Join-Path $dist 'SSRVPN_HarmonyOS-app-verified-profile.p7b'
& $java -jar $signTool verify-app -inFile $signedApp -outCertChain $verifiedCert -outProfile $verifiedProfile
if ($LASTEXITCODE -ne 0) {
  throw 'Signed APP verification failed'
}

Write-Output 'SIGNED_APP_READY'
Get-Item -LiteralPath $signedApp | Select-Object FullName, Length, LastWriteTime
Get-FileHash -LiteralPath $signedApp -Algorithm SHA256 | Select-Object Algorithm, Hash, Path
