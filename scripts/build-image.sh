#!/usr/bin/env bash
set -euo pipefail

BASE_URL="https://downloads.immortalwrt.org"
TARGET="x86/64"
PROFILE="generic"
ROOTFS_PARTSIZE="${ROOTFS_PARTSIZE:-4096}"
EXTRA_PACKAGES="${EXTRA_PACKAGES:-luci luci-i18n-base-zh-cn openssh-sftp-server luci-i18n-ddns-zh-cn luci-theme-argon luci-i18n-ttyd-zh-cn luci-i18n-firewall-zh-cn luci-i18n-package-manager-zh-cn k[...]}"

# 自动获取 ImmortalWrt 官方最新正式版本
VERSION="${VERSION:-$(curl -fsSL "$BASE_URL/releases/" \
  | grep -oE '>[0-9]+\.[0-9]+\.[0-9]+/' \
  | tr -d '>/' \
  | sort -V \
  | tail -1)}"

if [ -z "$VERSION" ]; then
  echo "❌ 错误：无法获取 ImmortalWrt 版本号"
  exit 1
fi

URL="$BASE_URL/releases/$VERSION/targets/x86/64/immortalwrt-imagebuilder-$VERSION-x86-64.Linux-x86_64.tar.zst"

echo "==> ImmortalWrt: $VERSION"
echo "==> ROOTFS_PARTSIZE: ${ROOTFS_PARTSIZE} MiB"
echo "==> Download: $URL"

if ! curl -fL "$URL" -o imagebuilder.tar.zst; then
  echo "❌ 错误：下载 imagebuilder 失败"
  exit 1
fi

rm -rf imagebuilder
mkdir imagebuilder

if ! tar -xaf imagebuilder.tar.zst -C imagebuilder --strip-components=1; then
  echo "❌ 错误：解压 imagebuilder 失败"
  exit 1
fi

cd imagebuilder

echo "==> 开始构建镜像..."
if ! make image \
  PROFILE="$PROFILE" \
  ROOTFS_PARTSIZE="$ROOTFS_PARTSIZE" \
  PACKAGES="$EXTRA_PACKAGES"; then
  echo "❌ 错误：make image 构建失败"
  echo "==> 检查输出目录内容："
  ls -la bin/targets/x86/64/ 2>/dev/null || echo "目录不存在"
  exit 1
fi

# Create output directory in the repo root (not relative to imagebuilder)
mkdir -p ../output

echo "==> 复制生成的文件..."

# 检查文件是否存在并复制
if find bin/targets/x86/64 -name 'generic-squashfs-combined-efi.img.gz' -type f 2>/dev/null | head -1 | grep -q .; then
  find bin/targets/x86/64 -name 'generic-squashfs-combined-efi.img.gz' -exec cp {} ../output/squashfs-efi.img.gz \;
  echo "✓ 已复制 squashfs-efi.img.gz"
else
  echo "❌ 错误：未找到 generic-squashfs-combined-efi.img.gz"
  echo "==> bin/targets/x86/64 目录内容："
  ls -lah bin/targets/x86/64/ || true
  exit 1
fi

if find bin/targets/x86/64 -name 'generic-squashfs-combined-efi.vmdk' -type f 2>/dev/null | head -1 | grep -q .; then
  find bin/targets/x86/64 -name 'generic-squashfs-combined-efi.vmdk' -exec cp {} ../output/squashfs-efi.vmdk \;
  echo "✓ 已复制 squashfs-efi.vmdk"
else
  echo "⚠️  警告：未找到 generic-squashfs-combined-efi.vmdk"
fi

echo "==> 构建完成"
ls -lh ../output/

if [ ! -f ../output/squashfs-efi.img.gz ]; then
  echo "❌ 错误：最终输出文件缺失"
  exit 1
fi
