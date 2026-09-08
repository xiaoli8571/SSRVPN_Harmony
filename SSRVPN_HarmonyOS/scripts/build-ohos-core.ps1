# SSRVPN HarmonyOS - Mihomo core cross-compile script (PowerShell, ASCII-only)
# NOTE: keep this file ASCII-only. PS5.1 reads UTF-8-no-BOM as ANSI/GBK and a
#       Chinese comment with odd UTF-8 byte count eats the trailing CR and
#       merges the next line into the comment.
# Output: entry\libs\arm64-v8a\libgojni.so (ohos arm64, musl, c-shared, tags: with_gvisor,cmfa)
$ErrorActionPreference = 'Stop'

$SrcDir = 'C:\Users\xiaoli\Downloads\SSRVPN-HarmonyOS-full-20260907-0851\SSRVPN-HarmonyOS-full\mihomo-build\mihomo-7031b7569831677a8d89ad8a8a3347db116ba1a8'
$NdkClang = 'C:\PROGRA~1\Huawei\DEVECO~1\sdk\default\openharmony\native\llvm\bin\clang.exe'
$NdkSysroot = 'C:\PROGRA~1\Huawei\DEVECO~1\sdk\default\openharmony\native\sysroot'
$GoRoot = 'C:\Users\xiaoli\ohos-go-build\ohos_golang_go'
$GoExe = Join-Path $GoRoot 'bin\go.exe'
$ProjRoot = 'C:\Users\xiaoli\Downloads\SSRVPN-HarmonyOS-full-20260907-0851\SSRVPN-HarmonyOS-full\SSRVPN_HarmonyOS'
$OutDir = Join-Path $ProjRoot 'entry\libs\arm64-v8a'
$LogDir = 'C:\Users\xiaoli\Downloads\SSRVPN-HarmonyOS-full-20260907-0851\SSRVPN-HarmonyOS-full'

if (-not (Test-Path $NdkClang)) { Write-Error "NDK clang not found: $NdkClang"; exit 1 }
if (-not (Test-Path $GoExe)) { Write-Error "OpenHarmony Go not found: $GoExe"; exit 1 }
New-Item -ItemType Directory -Force $OutDir | Out-Null

$env:GOROOT = $GoRoot
$env:GOTOOLCHAIN = 'local'
$env:Path = "$GoRoot\bin;C:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony\native\llvm\bin;$env:Path"
$env:GOPROXY = 'https://goproxy.cn,https://proxy.golang.org,direct'
$env:CGO_ENABLED = '1'
$env:GOOS = 'openharmony'
$env:GOARCH = 'arm64'
$env:GOFLAGS = '-trimpath'
$env:GOMAXPROCS = '1'
$env:CC = "$NdkClang --target=aarch64-linux-ohos --sysroot=$NdkSysroot"
$env:CXX = "C:\PROGRA~1\Huawei\DEVECO~1\sdk\default\openharmony\native\llvm\bin\clang++.exe --target=aarch64-linux-ohos --sysroot=$NdkSysroot"
$env:CGO_CFLAGS = "--target=aarch64-linux-ohos --sysroot=$NdkSysroot -ftls-model=global-dynamic"
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
