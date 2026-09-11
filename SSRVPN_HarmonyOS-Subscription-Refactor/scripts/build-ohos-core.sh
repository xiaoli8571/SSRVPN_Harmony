#!/usr/bin/env bash
# SSRVPN HarmonyOS — Mihomo 内核交叉编译脚本
# 对应 upstream: scripts/build-android-core.sh（recipe 见 assets/libgojni-source.txt）
#
# 产物: libgojni.so (ohos arm64, c-shared, tags: with_gvisor,cmfa)
# 放入: entry/libs/arm64-v8a/ (HVigor 会打包进 HAP 的 /data/storage/el1/bundle/libs/arm64/)
#
# 依赖:
#   - Go >= 1.25 (与 upstream 一致: go1.25.11)
#   - HarmonyOS NDK (含 aarch64-unknown-linux-ohos clang 工具链)
#   - mihomo 源码: github.com/MetaCubeX/mihomo (upstream 引用 zeyugao/mihomo@7031b75, 反查同源)
#
# 用法:
#   OHOS_NDK=/path/to/ohos-sdk/native ./scripts/build-ohos-core.sh /path/to/mihomo
#
# 说明:
#   Go 官方暂无 GOOS=ohos。OHOS native 运行时为 musl libc + Linux kernel,
#   实测可行路径是 GOOS=linux GOARCH=arm64 + NDK musl 工具链做 CC:
#   若链接报 glibc 符号缺失, 用 `-tags=with_gvisor` 且确保 CGO 代码仅用 POSIX 头文件;
#   极少数情况下需要给 mihomo 打 ohos 兼容补丁(社区已有先例), 补丁放 patches/ 目录。

set -euo pipefail

if [ $# -lt 1 ]; then
  echo "usage: $0 /path/to/mihomo-src" >&2
  exit 1
fi
MIHOMO_SRC="$1"
OHOS_NDK="${OHOS_NDK:?set OHOS_NDK to the HarmonyOS NDK native/ directory}"
GO="${GO:-go}"

CC_BIN="${OHOS_NDK}/llvm/bin/aarch64-unknown-linux-ohos-clang"
if [ ! -x "$CC_BIN" ]; then
  # NDK 版本差异: 尝试通用 clang + target 参数
  CC_BIN="${OHOS_NDK}/llvm/bin/clang"
  CC_ARGS="--target=aarch64-linux-ohos --sysroot=${OHOS_NDK}/sysroot"
fi

BRIDGE_SRC="$(dirname "$0")/../entry/src/main/cpp/bridge/bridge.go"
if [ ! -f "$BRIDGE_SRC" ]; then
  echo "ERROR: bridge.go not found at $BRIDGE_SRC" >&2
  echo "请从 upstream SSRVPN_Android/native/bridge/bridge.go 复制并保持导出符号:" >&2
  echo "  SsrvpnStart(configYaml *C.char, tunFd C.int) C.int" >&2
  echo "  SsrvpnStop() C.int" >&2
  echo "  SsrvpnIsAlive() C.int" >&2
  echo "  SsrvpnVersion() *C.char" >&2
  exit 1
fi

OUT_DIR="$(dirname "$0")/../entry/libs/arm64-v8a"
mkdir -p "$OUT_DIR"

echo "==> building mihomo c-shared for ohos arm64..."
cd "$MIHOMO_SRC"

# 复制桥接层（含 Ssrvpn* 导出符号）进内核 module
cp "$BRIDGE_SRC" ./bridge_ssrvpn.go

export CGO_ENABLED=1
export GOOS=openharmony
export GOARCH=arm64
export CC="$CC_BIN ${CC_ARGS:-}"
export GOFLAGS=-trimpath

$GO build \
  -buildmode=c-shared \
  -tags "with_gvisor,cmfa" \
  -ldflags "-s -w" \
  -o "$OUT_DIR/libgojni.so" \
  .

echo "==> built: $OUT_DIR/libgojni.so"
sha256sum "$OUT_DIR/libgojni.so"

# 记录来源（对齐 upstream libgojni-source.txt 的可验证性要求）
cat > "$OUT_DIR/libgojni-source.txt" <<EOF
Target: ohos/arm64 (HarmonyOS NDK musl)
Build mode: c-shared
Build tags: with_gvisor,cmfa
Go version: $($GO version)
mihomo src: $MIHOMO_SRC
Bridge: entry/src/main/cpp/bridge/bridge.go (copied as bridge_ssrvpn.go)
Recipe: scripts/build-ohos-core.sh
EOF

echo "==> done"
