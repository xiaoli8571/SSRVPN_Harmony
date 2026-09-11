# Third-Party Notices

本工程为 SSRVPN 的 HarmonyOS 移植。upstream 项目的第三方声明（`SSRVPN-upstream/third_party/THIRD_PARTY_NOTICES.md`）在此整体适用，包括其中登记的 Mihomo 内核与 GeoIP 数据的 GPL-3.0 许可、来源 tag/commit 与 SHA-256 记录。

鸿蒙移植新增的第三方来源：

- **Mihomo 内核 (libgojni.so)**
  - 上游模块：github.com/metacubex/mihomo（upstream 构建引用 zeyugao/mihomo@7031b7569831677a8d89ad8a8a3347db116ba1a8，见 upstream `SSRVPN_Android/assets/libgojni-source.txt`）
  - 许可：GPL-3.0
  - **鸿蒙构建（已验证，2026-09-06）**：
    - 方式：`scripts/build-ohos-core.ps1`（c-shared，GOOS=linux GOARCH=arm64 + OHOS NDK musl clang，
      `-tags with_gvisor,cmfa`，Go 1.27，GOPROXY=goproxy.cn）
    - 产物：`entry/libs/arm64-v8a/libgojni.so`（ELF64 AArch64，约 46.5MB）
    - SHA-256：`9BFF5455A626FE6C218D2C1860B8CBB167A393CEB10C32B8F5A89317F024C0FF`（另见 libgojni.sha256）
    - 包装层：mihomo 源码树内 `cshared_main.go`（导出 SsrvpnInit/SsrvpnStart/SsrvpnStop/SsrvpnIsRunning/
      SsrvpnVersion/SsrvpnLastError，protect 自动应答守护），bridge 包为 upstream 原文件
      `SSRVPN_Android/native/bridge/bridge.go`（含 bridge_test.go）
    - 与 upstream Android 的差异：upstream 经 gomobile bind（bionic libc，android 目标）；鸿蒙为
      musl libc，改用 c-shared 直连方案，ABI 见 `entry/src/main/cpp/ssrvpn_core_napi.cpp` 的 dlsym
  - 对应源码获取方式：按 GPL-3.0 要求，任何分发的 HAP 须同时提供（或指明获取途径）libgojni.so 的
    对应源码（mihomo 源码 @7031b75 + bridge.go + cshared_main.go + 构建脚本）。
