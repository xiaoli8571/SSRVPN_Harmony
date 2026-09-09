# =====================================================================
# SSRVPN v5.0.4 one-shot: build -> sign release .app -> publish GitHub
# Run in a normal PowerShell window (Windows PowerShell 5.1 compatible):
#   powershell -ExecutionPolicy Bypass -File build-sign-publish.ps1
# It will prompt for your GitHub PAT (not stored anywhere).
# =====================================================================
$ErrorActionPreference = 'Stop'

$repo   = 'C:\Users\xiaoli\Downloads\Agent-WorkerSpaces\SSRVPN-HarmonyOS'
$proj   = "$repo\SSRVPN_HarmonyOS"
$ver    = 'v5.0.4'
$dl     = "$env:USERPROFILE\Downloads"

$deveco = 'C:\Program Files\Huawei\DevEco Studio'
$hvigor = "$deveco\tools\hvigor\bin\hvigorw.js"
$tool   = "$deveco\sdk\default\openharmony\toolchains\lib\hap-sign-tool.jar"

$cer    = "$repo\SSRVPN.cer"
$p7b    = "$repo\SSRVPNRelease.p7b"
$p12    = "$repo\SSRVPN.p12"
$kAlias = 'ssrvpn'
$kPwd   = 'Lijx.820115'

function Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }

# ---------- 0. sanity ----------
foreach ($f in @($hvigor, $tool, $cer, $p7b, $p12)) {
  if (-not (Test-Path $f)) { throw "missing file: $f" }
}
if (-not (Get-Command node -ErrorAction SilentlyContinue)) { throw 'node not on PATH (DevEco terminal works)' }
$env:DEVECO_SDK_HOME = "$deveco\sdk"
$env:JAVA_HOME = "$deveco\jbr"
$env:Path = "$env:JAVA_HOME\bin;$env:Path"

# ---------- 1. debug hap (for sideload testing) ----------
Step 'build debug hap'
Push-Location $proj
node $hvigor --mode module -p product=default -p module=entry@default -p buildMode=debug assembleHap --no-daemon | Select-String 'BUILD'
if ($LASTEXITCODE -ne 0) { Pop-Location; throw 'debug hap build FAILED' }

# ---------- 2. release app pack (unsigned) ----------
Step 'build release app pack'
node $hvigor --mode project -p product=default -p buildMode=release assembleApp --no-daemon | Select-String 'BUILD'
if ($LASTEXITCODE -ne 0) { Pop-Location; throw 'release app build FAILED' }
Pop-Location

$unsignedApp = "$proj\build\outputs\default\SSRVPN_HarmonyOS-default-unsigned.app"
$debugHap    = "$proj\entry\build\default\outputs\default\entry-default-signed.hap"
$unsignedHap = "$proj\entry\build\default\outputs\default\entry-default-unsigned.hap"
foreach ($f in @($unsignedApp, $debugHap, $unsignedHap)) {
  if (-not (Test-Path $f)) { throw "build artifact missing: $f" }
}

# ---------- 3. double-layer release signing ----------
Add-Type -AssemblyName System.IO.Compression.FileSystem
$work = Join-Path $env:TEMP 'ssrvpn_sign_work'
Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force "$work\payload" | Out-Null

Step 'extract inner hap + metadata from unsigned app'
$zip = [System.IO.Compression.ZipFile]::OpenRead($unsignedApp)
foreach ($n in @('pac.json', 'pack.info')) {
  $en = $zip.Entries | Where-Object { $_.FullName -eq $n } | Select-Object -First 1
  [System.IO.Compression.ZipFileExtensions]::ExtractToFile($en, "$work\payload\$n", $true)
}
$hp = $zip.Entries | Where-Object { $_.FullName -like '*.hap' } | Select-Object -First 1
[System.IO.Compression.ZipFileExtensions]::ExtractToFile($hp, "$work\inner-unsigned.hap", $true)
$zip.Dispose()

Step 'sign inner hap (release cert)'
java -jar $tool sign-app -mode "localSign" -keyAlias $kAlias -keyPwd $kPwd -keystorePwd $kPwd `
  -signAlg "SHA256withECDSA" -appCertFile $cer -profileFile $p7b -keystoreFile $p12 `
  -inFile "$work\inner-unsigned.hap" -outFile "$work\payload\entry-default.hap"
if ($LASTEXITCODE -ne 0) { throw 'inner hap sign FAILED' }

Step 'repack app shell'
[System.IO.Compression.ZipFile]::CreateFromDirectory("$work\payload", "$work\repack.app",
  [System.IO.Compression.CompressionLevel]::Optimal, $false)

Step 'sign app shell (release cert)'
$signedApp = "$work\SSRVPN_HarmonyOS-$ver-release-signed.app"
Remove-Item $signedApp -Force -ErrorAction SilentlyContinue
java -jar $tool sign-app -mode "localSign" -keyAlias $kAlias -keyPwd $kPwd -keystorePwd $kPwd `
  -signAlg "SHA256withECDSA" -appCertFile $cer -profileFile $p7b -keystoreFile $p12 `
  -inFile "$work\repack.app" -outFile $signedApp
if ($LASTEXITCODE -ne 0) { throw 'app shell sign FAILED' }

# ---------- 4. stage artifacts to Downloads ----------
Step 'copy artifacts to Downloads'
Copy-Item $signedApp  "$dl\SSRVPN_HarmonyOS-$ver-release-signed.app" -Force
Copy-Item $debugHap   "$dl\SSRVPN_HarmonyOS-$ver-debug-signed.hap" -Force
Copy-Item $unsignedHap "$dl\SSRVPN_HarmonyOS-$ver-unsigned.hap" -Force
Get-ChildItem "$dl\SSRVPN_HarmonyOS-$ver-*" | Select-Object Name, Length, LastWriteTime | Format-Table -AutoSize

# ---------- 5. git commit + push ----------
$token = Read-Host 'Paste GitHub PAT (not saved)'
if ([string]::IsNullOrWhiteSpace($token)) { throw 'empty PAT, aborting publish (artifacts are ready in Downloads)' }

Step 'git commit + push'
Push-Location $repo
git add -A
git reset -q -- SSRVPN_HarmonyOS/build-profile.json5   # keep local signing config out of the repo
$msg = "v4.0.38-5.0.3: store compliance + UX + local YAML import`n`n" +
"- layered app icon (1024 fg/bg, square, no padding) with original K logo restored`n" +
"- color contrast 2.1.4.1: text variants >=4.5:1, darker button fills, diagnostics wired`n" +
"- seamless start window (theme-colored bg + transparent K glyph)`n" +
"- long-press node delete with hidden-list persistence (survives refresh)`n" +
"- headless test core: real-protocol latency before VPN connect (no TUN, no permission dialog)`n" +
"- auto sort by latency after batch test; http subscription support (SSRF guards kept)`n" +
"- hysteria2 upmbps/downmbps aliases (fixes server 404 auth when bandwidth params missing)`n" +
"- power button: original blue ring + donut glow for connected state (radialGradient square bug fixed)`n" +
"- startVpnExtensionAbility 15s race timeout (stuck spinner guard)`n" +
"- local YAML import + allow renaming local:// subscriptions; version 5.0.4"
$msg | git commit -F -
git push "https://xiaoli8571:$token@github.com/xiaoli8571/SSRVPN_Harmony.git" main
if ($LASTEXITCODE -ne 0) { Pop-Location; throw 'git push FAILED' }
Pop-Location

# ---------- 6. GitHub release with unsigned hap ----------
Step 'create GitHub release + upload unsigned hap'
$hdr = @{ 'Authorization' = "token $token"; 'User-Agent' = 'ssrvpn-publish'; 'Accept' = 'application/vnd.github+json' }
$body = @{
  tag_name = $ver; target_commitish = 'main'
  name = "SSRVPN for HarmonyOS NEXT $ver"
  body = "$ver - local YAML subscription file import (+ rename support for local subs); previous batch: store compliance (layered icon, contrast, splash), node delete, headless latency test, http subs, hysteria2 bandwidth aliases, blue power ring."
  draft = $false; prerelease = $false
} | ConvertTo-Json
$rel = Invoke-RestMethod -Uri 'https://api.github.com/repos/xiaoli8571/SSRVPN_Harmony/releases' `
  -Method Post -Headers $hdr -Body $body -ContentType 'application/json; charset=utf-8' -TimeoutSec 60
Invoke-RestMethod -Uri "https://uploads.github.com/repos/xiaoli8571/SSRVPN_Harmony/releases/$($rel.id)/assets?name=SSRVPN_HarmonyOS-$ver-unsigned.hap" `
  -Method Post -Headers $hdr -InFile "$dl\SSRVPN_HarmonyOS-$ver-unsigned.hap" `
  -ContentType 'application/octet-stream' -TimeoutSec 600 | Out-Null

Step 'ALL DONE'
Write-Host "release : $($rel.html_url)"
Write-Host "app     : $dl\SSRVPN_HarmonyOS-$ver-release-signed.app  (upload to AGC)"
Write-Host "debug   : $dl\SSRVPN_HarmonyOS-$ver-debug-signed.hap    (sideload test)"
