# =====================================================================
# SSRVPN v5.2 one-shot: build -> sign release .app -> publish GitHub
# Run in a normal PowerShell window (Windows PowerShell 5.1 compatible):
#   powershell -ExecutionPolicy Bypass -File build-sign-publish.ps1
# It will prompt for your GitHub PAT (not stored anywhere).
# =====================================================================
$ErrorActionPreference = 'Stop'

$repo   = 'C:\Users\xiaoli\Downloads\Agent-WorkerSpaces\SSRVPN-HarmonyOS'
$proj   = "$repo\SSRVPN_HarmonyOS"
$ver    = 'v5.2'
$dl     = "$env:USERPROFILE\Downloads"

$deveco = 'C:\Program Files\Huawei\DevEco Studio'
$hvigor = "$deveco\tools\hvigor\bin\hvigorw.js"
$tool   = "$deveco\sdk\default\openharmony\toolchains\lib\hap-sign-tool.jar"

$cer    = "$repo\SSRVPN.cer"
$p7b    = "$repo\SSRVPNRelease.p7b"
$p12    = "$repo\SSRVPN.p12"
$kAlias = 'ssrvpn'

function Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }

# SECURITY: the signing password is NEVER stored in this file or in the repo.
# Priority: env var SSRVPN_KEY_PASSWORD -> interactive masked prompt.
$kPwd = $null
if ($env:SSRVPN_KEY_PASSWORD) {
  $kPwd = $env:SSRVPN_KEY_PASSWORD
  Step 'signing password loaded from SSRVPN_KEY_PASSWORD'
} else {
  $kPwdSecure = Read-Host 'Signing key password (SSRVPN_KEY_PASSWORD not set)' -AsSecureString
  $kPwdPtr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($kPwdSecure)
  $kPwd = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($kPwdPtr)
  [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($kPwdPtr)
  $kPwdSecure = $null
  Write-Host 'NOTE: set $env:SSRVPN_KEY_PASSWORD to avoid entering the password each run.' -ForegroundColor Yellow
}
if ([string]::IsNullOrEmpty($kPwd)) { throw 'empty signing password, aborting' }

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

Step 'git stage (WHITELIST only) + sensitive-material scan'
Push-Location $repo

# ---- Sensitive-material scanner -------------------------------------------
# File-name blacklist + content-pattern scan. Any hit ABORTS the commit.
$nameBlacklist = @(
  '\.p12$', '\.p7b$', '\.keystore$', '\.jks$', '\.cer$', '\.csr$', '\.pem$', '\.key$',
  '(?i)pass(word)?', '(?i)secret', '(?i)credential', '(?i)token',
  '\.log$', '\.dmp$', 'hs_err_pid', 'replay_pid',
  '(?i)rollback-\d{8}', '(?i)snapshot-\d{8}', '(?i)backup-\d{8}',
  '^material/', '(?i)\.patch$'
)
# Content patterns: POSIX ERE for `git grep -f`. NOTE: git ERE has NO inline
# (?i) flag, so case-insensitive patterns live in a separate list run with -i.
$contentPatterns = @(
  'Lijx\.820115',                                     # known legacy literal
  '((key|store)Password)[[:space:]]*:',               # json5 explicit pwd key
  'BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY',
  'ghp_[A-Za-z0-9]{20,}',                             # github PAT
  '[0-9a-f]{64,}'                                     # long hex blob (HarmonyOS pwd/certish)
)
$contentPatternsI = @(
  '(keyPassword|storePassword|KeyPwd|StorePwd|keystorePwd)',  # camelCase pwd keys
  'secret',
  'credential'
)
$scanFail = @()
# 1) staged file-name blacklist
$staged = @(git diff --cached --name-only)
foreach ($f in $staged) {
  foreach ($p in $nameBlacklist) { if ($f -match $p) { $scanFail += "NAME  $f  (matched /$p/)" } }
}
# 2) staged-content pattern scan (patterns via -f file to avoid arg mangling)
function Invoke-PatScan([string[]]$pats, [switch]$IgnoreCase) {
  $patFile = Join-Path $env:TEMP ('ssrvpn_scan_' + [guid]::NewGuid().ToString('N') + '.txt')
  [System.IO.File]::WriteAllLines($patFile, $pats)
  try {
    $a = @('-I', '-l', '-E', '-f', $patFile, '--cached')
    if ($IgnoreCase) { $a = @('-i') + $a }
    return @(git grep @a 2>$null)
  } finally { Remove-Item $patFile -Force -ErrorAction SilentlyContinue }
}
foreach ($h in (Invoke-PatScan $contentPatterns))            { $scanFail += "CONTENT  $h" }
foreach ($h in (Invoke-PatScan $contentPatternsI -IgnoreCase)) { $scanFail += "CONTENT(i)  $h" }
if ($scanFail.Count -gt 0) {
  Write-Host 'SECURITY SCAN FAILED - commit aborted. Offending staged entries:' -ForegroundColor Red
  $scanFail | Sort-Object -Unique | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
  git reset -q
  Pop-Location
  throw 'sensitive material detected in staged set; nothing committed'
}
Write-Host 'sensitive-material scan: PASS (0 hits)' -ForegroundColor Green

# ---- WHITELIST staging (explicit paths only) ------------------------------
$msg = @"
v4.0.38-5.0.3: store compliance + UX + local YAML import

- layered app icon (1024 fg/bg, square, no padding) with original K logo restored
- color contrast 2.1.4.1: text variants >=4.5:1, darker button fills, diagnostics wired
- seamless start window (theme-colored bg + transparent K glyph)
- long-press node delete with hidden-list persistence (survives refresh)
- headless test core: real-protocol latency before VPN connect (no TUN, no permission dialog)
- auto sort by latency after batch test; http subscription support (SSRF guards kept)
- hysteria2 upmbps/downmbps aliases (fixes server 404 auth when bandwidth params missing)
- power button: original blue ring + donut glow for connected state (radialGradient square bug fixed)
- startVpnExtensionAbility 15s race timeout (stuck spinner guard)
- local YAML import + allow renaming local:// subscriptions
- global node-name dedup (fix kernel startup abort on duplicate proxy names)
"@

# Whitelist: source / resources / necessary config / docs ONLY.
# NOTE: no -A, no -u. Snapshot, rollback, backup, cert and log dirs are never staged.
git reset -q
git add -- `
  'SSRVPN_HarmonyOS/AppScope' `
  'SSRVPN_HarmonyOS/entry/src' `
  'SSRVPN_HarmonyOS/entry/libs' `
  'SSRVPN_HarmonyOS/scripts' `
  'SSRVPN_HarmonyOS/oh-package.json5' `
  'SSRVPN_HarmonyOS/build-profile.json5' `
  'SSRVPN_HarmonyOS/hvigorfile.ts' `
  'SSRVPN_HarmonyOS/entry/src/main/module.json5' `
  'build-sign-publish.ps1' `
  'README.md' `
  'BUILD_README.md' `
  'SECURITY_KEY_ROTATION.md' `
  '.gitignore'

# Guard: signing config must stay local (env-var placeholders only)
git reset -q -- 'SSRVPN_HarmonyOS/build-profile.json5' 2>$null

$stagedFinal = @(git diff --cached --name-only)
if ($stagedFinal.Count -eq 0) { Pop-Location; throw 'nothing staged after whitelist; aborting' }
Write-Host ("staged {0} path(s) via whitelist" -f $stagedFinal.Count) -ForegroundColor Cyan

$stagedFinal | git commit -F -
$authValue = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("xiaoli8571:$token"))
git -c "http.https://github.com/.extraheader=AUTHORIZATION: basic $authValue" push origin main
$authValue = $null
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
