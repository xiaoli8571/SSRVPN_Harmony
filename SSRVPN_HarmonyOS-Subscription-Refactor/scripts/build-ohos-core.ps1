# SSRVPN HarmonyOS - Mihomo core cross-compile script (PowerShell, ASCII-only)
# NOTE: keep this file ASCII-only. PS5.1 reads UTF-8-no-BOM as ANSI/GBK and a
#       Chinese comment with odd UTF-8 byte count eats the trailing CR and
#       merges the next line into the comment.
# Output: entry\libs\arm64-v8a\libgojni.so (ohos arm64, musl, c-shared, tags: with_gvisor,cmfa)
$ErrorActionPreference = 'Stop'

# Resolve project-relative paths so the recipe remains reproducible after moving
# or cloning the repository. Environment variables allow CI/local overrides.
$ProjRoot = Split-Path -Parent $PSScriptRoot
$RepoRoot = Split-Path -Parent $ProjRoot
$SrcDir = $env:MIHOMO_SRC
if (-not $SrcDir) {
  $candidate = Get-ChildItem -LiteralPath (Join-Path $RepoRoot 'mihomo-build') -Directory -Filter 'mihomo-*' -ErrorAction SilentlyContinue |
    Where-Object { Test-Path (Join-Path $_.FullName 'go.mod') } |
    Select-Object -First 1
  if ($null -eq $candidate) {
    Write-Error 'Mihomo source not found. Set MIHOMO_SRC to a source directory containing go.mod.'
    exit 1
  }
  $SrcDir = $candidate.FullName
}

$SdkNative = $env:OHOS_NDK
if (-not $SdkNative) {
  $SdkNative = Join-Path $env:LOCALAPPDATA 'OpenHarmony\Sdk\23\native'
}
$NdkClang = Join-Path $SdkNative 'llvm\bin\clang.exe'
$NdkClangxx = Join-Path $SdkNative 'llvm\bin\clang++.exe'
$NdkSysroot = Join-Path $SdkNative 'sysroot'
$GoRoot = $env:OHOS_GOROOT
if (-not $GoRoot) {
  $GoRoot = Join-Path $env:USERPROFILE 'ohos-go-build\ohos_golang_go'
}
$GoExe = Join-Path $GoRoot 'bin\go.exe'
$OutDir = Join-Path $ProjRoot 'entry\libs\arm64-v8a'
$LogDir = $ProjRoot

if (-not (Test-Path $NdkClang)) { Write-Error "NDK clang not found: $NdkClang"; exit 1 }
if (-not (Test-Path $GoExe)) { Write-Error "OpenHarmony Go not found: $GoExe"; exit 1 }
New-Item -ItemType Directory -Force $OutDir | Out-Null

$env:GOROOT = $GoRoot
$env:GOTOOLCHAIN = 'local'
$env:Path = "$GoRoot\bin;$(Join-Path $SdkNative 'llvm\bin');$env:Path"
$env:GOPROXY = 'https://goproxy.cn,https://proxy.golang.org,direct'
$env:CGO_ENABLED = '1'
$env:GOOS = 'openharmony'
$env:GOARCH = 'arm64'
$env:GOFLAGS = '-trimpath'
$env:GOMAXPROCS = '1'
$env:CC = "$NdkClang --target=aarch64-linux-ohos --sysroot=$NdkSysroot"
$env:CXX = "$NdkClangxx --target=aarch64-linux-ohos --sysroot=$NdkSysroot"
$env:CGO_CFLAGS = "--target=aarch64-linux-ohos --sysroot=$NdkSysroot -ftls-model=global-dynamic"
$env:CGO_CPPFLAGS = $env:CGO_CFLAGS
$env:CGO_CXXFLAGS = $env:CGO_CFLAGS

Set-Location $SrcDir
Write-Host '==> building mihomo c-shared for ohos arm64...'
$outLog = Join-Path $LogDir 'ssrvpn_go_build_out.log'
$errLog = Join-Path $LogDir 'ssrvpn_go_build_err.log'
$argLine = 'build -p 1 -buildmode=c-shared -tags with_gvisor,cmfa -ldflags "-s -w -buildid=" -o "' + "$OutDir\libgojni.so" + '" .'
$p = Start-Process -FilePath $GoExe `
  -ArgumentList $argLine `
  -WorkingDirectory $SrcDir -NoNewWindow -PassThru -Wait `
  -RedirectStandardOutput $outLog -RedirectStandardError $errLog
if ($p.ExitCode -ne 0) {
  Write-Host "--- go build failed (exit $($p.ExitCode)), stderr tail: ---"
  Get-Content $errLog -Tail 30
  exit $p.ExitCode
}
Write-Host '--- build stderr (last lines) ---'
Get-Content $errLog -Tail 5

Write-Host "==> built: $OutDir\libgojni.so"
Get-Item "$OutDir\libgojni.so" | ForEach-Object { "{0} bytes" -f $_.Length }
(Get-FileHash "$OutDir\libgojni.so" -Algorithm SHA256).Hash | Out-File "$OutDir\libgojni.sha256"
Write-Host '==> done'
