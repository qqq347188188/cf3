#!/bin/bash
# CFPatchLoader 热补丁方案打包（一次安装，之后改剪贴板/配置文件即可换补丁）
# 用法: bash build_and_package.sh /path/to/222.ipa
# 环境: macOS + Theos(export THEOS=~/theos) + insert_dylib + ldid
set -euo pipefail

IPA="${1:-222.ipa}"
SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK="${SRC_DIR}/build_hotpatch"
OUT="${SRC_DIR}/222-hotpatch.ipa"
APP_NAME="cf"
DYLIB_NAME="CFPatchLoader.dylib"

echo "[*] 清理"
rm -rf "$WORK"; mkdir -p "$WORK"

echo "[*] 1/7 解压 IPA"
unzip -q "$IPA" -d "$WORK"
APP="$WORK/Payload/${APP_NAME}.app"

echo "[*] 2/7 Theos 编译 CFPatchLoader.dylib"
export THEOS="${THEOS:-$HOME/theos}"
make -C "$SRC_DIR" clean >/dev/null 2>&1 || true
make -C "$SRC_DIR" -j2
DYLIB="$(find "$SRC_DIR/packages" -name 'CFPatchLoader.dylib' 2>/dev/null | head -n1)"
[ -z "$DYLIB" ] && DYLIB="$(find "$SRC_DIR" -name 'CFPatchLoader.dylib' 2>/dev/null | head -n1)"
if [ -z "$DYLIB" ]; then echo "[-] 找不到 CFPatchLoader.dylib"; exit 1; fi

echo "[*] 3/7 注入 dylib 到主程序"
mkdir -p "$APP/Frameworks"
cp "$DYLIB" "$APP/Frameworks/${DYLIB_NAME}"
insert_dylib --strip-codesig --all-yes \
    "@executable_path/Frameworks/${DYLIB_NAME}" \
    "$APP/${APP_NAME}" "$APP/${APP_NAME}_patched" >/dev/null
mv "$APP/${APP_NAME}_patched" "$APP/${APP_NAME}"
chmod +x "$APP/${APP_NAME}"

echo "[*] 4/7 预置默认配置文件到 App bundle"
# loader 首次启动会把它复制到 Documents；用户之后改 Documents/cfpatch.txt 即可
cp "$SRC_DIR/cfpatch.txt" "$APP/cfpatch.txt"

echo "[*] 5/7 用 ldid ad-hoc 重签（macOS 标准工具，非自制签名器）"
if command -v ldid >/dev/null 2>&1; then
    ldid -S "$APP/Frameworks/${DYLIB_NAME}"
    ldid -S "$APP/${APP_NAME}"
else
    codesign --force --sign - "$APP/Frameworks/${DYLIB_NAME}"
    codesign --force --sign - "$APP/${APP_NAME}"
fi

echo "[*] 6/7 删除 SC_Info（App Store DRM 残留）"
rm -rf "$APP/SC_Info" 2>/dev/null || true

echo "[*] 7/7 打包"
(cd "$WORK" && zip -qry "$OUT" Payload)

echo "[+] 完成: $OUT"
echo "[+] TrollStore 安装。之后换补丁只需：复制数字 0/1/2 到剪贴板 → 重启游戏"
ls -lh "$OUT"
