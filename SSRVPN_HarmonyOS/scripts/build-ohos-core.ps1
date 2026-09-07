# SSRVPN HarmonyOS - Mihomo core cross-compile script (PowerShell, ASCII-only)
# NOTE: keep this file ASCII-only. PS5.1 reads UTF-8-no-BOM as ANSI/GBK and a
#       Chinese comment with odd UTF-8 byte count eats the trailing CR and
#       merges the next line into the comment.
# Output: entry\libs\arm64-v8a\libgojni.so (ohos arm64, musl, c-shared, tags: with_gvisor,cmfa)
$ErrorActionPreference = 'Stop'

# Repo layout (this script lives at SSRVPN_HarmonyOS/scripts/):
#   <repoRoot>/SSRVPN_HarmonyOS        <- this app project ($ProjRoot)
#   <repoRoot>/mihomo-build/mihomo-*   <- patched mihomo source ($SrcDir)
#   <repoRoot>/mihomo-build/gvisor-patched  <- referenced by go.mod replace
# All paths can be overridden via environment variables.
$RepoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$SrcDir = if ($env:MIHOMO_SRC) { $env:MIHOMO_SRC } else { Join-Path $RepoRoot 'mihomo-build\mihomo-7031b7569831677a8d89ad8a8a3347db116ba1a8' }
# DevEco native SDK (clang + sysroot). Override with DEVECO_NATIVE_SDK if yours differs.
$NativeSdk = if ($env:DEVECO_NATIVE_SDK) { $env:DEVECO_NATIVE_SDK } else { 'C:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony\native' }
# 8.3 short paths avoid quoting issues in CC command lines.
$NdkClang = Join-Path $NativeSdk 'llvm\bin\clang.exe'
$NdkSysroot = Join-Path $NativeSdk 'sysroot'
# OpenHarmony-flavored Go toolchain (GOOS=openharmony support), NOT stock Go.
# Get it from https://gitee.com/openharmony-sig/ohos_golang_go (build per its README).
$GoRoot = if ($env:OHOS_GO_ROOT) { $env:OHOS_GO_ROOT } else { Join-Path $env:USERPROFILE 'ohos-go-build\ohos_golang_go' }
$GoExe = Join-Path $GoRoot 'bin\go.exe'
$ProjRoot = if ($env:PROJ_ROOT) { $env:PROJ_ROOT } else { Join-Path $RepoRoot 'SSRVPN_HarmonyOS' }
$OutDir = Join-Path $ProjRoot 'entry\libs\arm64-v8a'
$LogDir = if ($env:BUILD_LOG_DIR) { $env:BUILD_LOG_DIR } else { $RepoRoot }

if (-not (Test-Path $NdkClang)) { Write-Error "NDK clang not found: $NdkClang (set DEVECO_NATIVE_SDK)"; exit 1 }
if (-not (Test-Path $GoExe)) { Write-Error "OpenHarmony Go not found: $GoExe (set OHOS_GO_ROOT)"; exit 1 }
New-Item -ItemType Directory -Force $OutDir | Out-Null

$env:GOROOT = $GoRoot
$env:GOTOOLCHAIN = 'local'
$env:Path = "$GoRoot\bin;$(Join-Path $NativeSdk 'llvm\bin');$env:Path"
$env:GOPROXY = 'https://goproxy.cn,https://proxy.golang.org,direct'
$env:CGO_ENABLED = '1'
$env:GOOS = 'openharmony'
$env:GOARCH = 'arm64'
$env:GOFLAGS = '-trimpath'
$env:GOMAXPROCS = '1'
# CC/CXX go through go's env parsing where spaces break quoting -> use 8.3 short paths.
function ToShortPath([string]$p) {
  try { return (New-Object -ComObject Scripting.FileSystemObject).GetFolder($p).ShortPath } catch { return $p }
}
$NdkClangShort = ToShortPath $NdkClang
$NdkClangxxShort = ToShortPath (Join-Path $NativeSdk 'llvm\bin\clang++.exe')
$NdkSysrootShort = ToShortPath $NdkSysroot
$env:CC = "$NdkClangShort --target=aarch64-linux-ohos --sysroot=$NdkSysrootShort"
$env:CXX = "$NdkClangxxShort --target=aarch64-linux-ohos --sysroot=$NdkSysrootShort"
$env:CGO_CFLAGS = "--target=aarch64-linux-ohos --sysroot=$NdkSysrootShort -ftls-model=global-dynamic"
$env:CGO_CPPFLAGS = $env:CGO_CFLAGS
$env:CGO_CXXFLAGS = $env:CGO_CFLAGS

Set-Location $SrcDir
Write-Host '==> building mihomo c-shared for ohos arm64...'
$outLog = Join-Path $LogDir 'ssrvpn_go_build_out.log'
$errLog = Join-Path $LogDir 'ssrvpn_go_build_err.log'
$argLine = 'build -p 1 -buildmode=c-shared -tags with_gvisor,cmfa -ldflags "-s -w" -o "' + "$OutDir\libgojni.so" + '" .'
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
