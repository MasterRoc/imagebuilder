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

URL="$BASE_URL/releases/$VERSION/targets/x86/64/immortalwrt-imagebuilder-$VERSION-x86-64.Linux-x86_64.tar.zst"

echo "==> ImmortalWrt: $VERSION"
echo "==> ROOTFS_PARTSIZE: ${ROOTFS_PARTSIZE} MiB"
echo "==> Download: $URL"

curl -fL "$URL" -o imagebuilder.tar.zst

rm -rf imagebuilder
mkdir imagebuilder
tar -xaf imagebuilder.tar.zst -C imagebuilder --strip-components=1

cd imagebuilder

make image \
  PROFILE="$PROFILE" \
  ROOTFS_PARTSIZE="$ROOTFS_PARTSIZE" \
  PACKAGES="$EXTRA_PACKAGES"

# Create output directory in the repo root (not relative to imagebuilder)
mkdir -p ../output

find bin/targets/x86/64 -name 'generic-squashfs-combined-efi.img.gz' \
  -exec cp {} ../output/squashfs-efi.img.gz \;

find bin/targets/x86/64 -name 'generic-squashfs-combined-efi.vmdk' \
  -exec cp {} ../output/squashfs-efi.vmdk \;

echo "==> Build complete"
ls -lh ../output/
