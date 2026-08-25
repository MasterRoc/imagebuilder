````bash
#!/usr/bin/env bash
set -euo pipefail

VERSION="${VERSION:-25.12.1}"
TARGET="${TARGET:-x86/64}"
PROFILE="${PROFILE:-generic}"
IMAGEBUILDER_URL="${IMAGEBUILDER_URL:-https://downloads.immortalwrt.org/releases/25.12.1/targets/x86/64/immortalwrt-imagebuilder-25.12.1-x86-64.Linux-x86_64.tar.zst}"
EXTRA_IMAGE_NAME="${EXTRA_IMAGE_NAME:-custom}"
OUT_DIR="${OUT_DIR:-$PWD/out}"
PREFLIGHT="${PREFLIGHT:-1}"
ROOTFS_PARTSIZE="${ROOTFS_PARTSIZE:-4096}"

# 保留原有依赖，不删除
EXTRA_PACKAGES="${EXTRA_PACKAGES:-luci luci-i18n-base-zh-cn openssh-sftp-server luci-i18n-ddns-zh-cn luci-theme-argon luci-i18n-ttyd-zh-cn luci-i18n-firewall-zh-cn luci-i18n-package-manager-zh-cn kmod-sched-core kmod-sched-bpf kmod-veth kmod-xdp-sockets-diag curl nano}"

WORK_DIR="${WORK_DIR:-$PWD/work}"
IB_ARCHIVE="$WORK_DIR/imagebuilder.tar.zst"

mkdir -p "$WORK_DIR" "$OUT_DIR"

if [ ! -s "$IB_ARCHIVE" ]; then
  curl -L --retry 8 --retry-delay 5 --connect-timeout 30 \
    -o "$IB_ARCHIVE" "$IMAGEBUILDER_URL"
fi

rm -rf "$WORK_DIR/imagebuilder"
mkdir -p "$WORK_DIR/imagebuilder"

tar --use-compress-program=unzstd \
  -xf "$IB_ARCHIVE" \
  -C "$WORK_DIR/imagebuilder" \
  --strip-components=1

cp -a files "$WORK_DIR/imagebuilder/files"

cd "$WORK_DIR/imagebuilder"

echo "Version: $VERSION"
echo "Target: $TARGET"
echo "Profile: $PROFILE"
echo "Rootfs part size: ${ROOTFS_PARTSIZE}MB"
echo "Extra packages: $EXTRA_PACKAGES"

mkdir -p "$OUT_DIR"
echo "extra_packages=$EXTRA_PACKAGES" > "$OUT_DIR/.extra_packages"

diagnose_failure() {
  cat >&2 <<'EOF'

ImageBuilder failed.

Common causes:
- The selected ImmortalWrt ImageBuilder and package feeds are out of sync.
- A package listed in EXTRA_PACKAGES is missing from the selected target's package feed.
- A kmod-* package does not match the kernel version used by the selected ImageBuilder.
- The ImageBuilder URL does not match the selected target/profile.

Next choices:
- Retry later after the ImmortalWrt package feeds finish syncing.
- Use an ImageBuilder URL that matches the target and kernel version.
- Remove or replace packages that are not available in the selected feed.
- Verify package availability with:

    make manifest PROFILE="$PROFILE" PACKAGES="$EXTRA_PACKAGES"
EOF
}

if [ "$PREFLIGHT" = "1" ] || [ "$PREFLIGHT" = "true" ]; then
  echo "Running package manifest preflight..."

  if ! make manifest \
      PROFILE="$PROFILE" \
      PACKAGES="$EXTRA_PACKAGES"; then
    diagnose_failure
    exit 1
  fi
fi

# Slim image formats:
# keep only squashfs EFI img.gz + qcow2 + vmdk
sed -i \
  -e 's/^CONFIG_TARGET_ROOTFS_EXT4FS=y/# CONFIG_TARGET_ROOTFS_EXT4FS is not set/' \
  -e 's/^CONFIG_TARGET_ROOTFS_TARGZ=y/# CONFIG_TARGET_ROOTFS_TARGZ is not set/' \
  -e 's/^CONFIG_VDI_IMAGES=y/# CONFIG_VDI_IMAGES is not set/' \
  -e 's/^CONFIG_VHDX_IMAGES=y/# CONFIG_VHDX_IMAGES is not set/' \
  -e 's/^CONFIG_ISO_IMAGES=y/# CONFIG_ISO_IMAGES is not set/' \
  -e 's/^CONFIG_GRUB_IMAGES=y/# CONFIG_GRUB_IMAGES is not set/' \
  .config

if ! make image \
    PROFILE="$PROFILE" \
    PACKAGES="$EXTRA_PACKAGES" \
    FILES=files \
    BIN_DIR="$OUT_DIR" \
    EXTRA_IMAGE_NAME="$EXTRA_IMAGE_NAME" \
    ROOTFS_PARTSIZE="$ROOTFS_PARTSIZE"; then
  diagnose_failure
  exit 1
fi

# Rename to short friendly names
cd "$OUT_DIR"

for f in *-squashfs-combined-efi.img.gz; do
  [ -f "$f" ] && mv "$f" squashfs-efi.img.gz
done

for f in *-squashfs-combined-efi.qcow2; do
  [ -f "$f" ] && mv "$f" squashfs-efi.qcow2
done

for f in *-squashfs-combined-efi.vmdk; do
  [ -f "$f" ] && mv "$f" squashfs-efi.vmdk
done

for f in *-kernel.bin; do
  [ -f "$f" ] && mv "$f" kernel.bin
done

for f in *-rootfs.tar.gz; do
  [ -f "$f" ] && mv "$f" rootfs.tar.gz
done

for f in *.manifest; do
  [ -f "$f" ] && mv "$f" manifest
done

for f in *.bom.cdx.json; do
  [ -f "$f" ] && mv "$f" bom.cdx.json
done

for f in *.img.gz *.qcow2 *.vmdk *.bin *.tar.gz *.manifest *.bom.cdx.json; do
  [ -f "$f" ] || continue
  sha256sum "$f"
done > sha256sums

# Build date in CST for release notes
BUILD_DATE="$(TZ='Asia/Shanghai' date '+%F %H:%M CST')"

cat > BUILD-MANIFEST.txt <<BODYEOF
## ImmortalWrt 固件 · ${EXTRA_IMAGE_NAME}

基于 ImmortalWrt 25.12.*，x86-64 通用镜像，squashfs-only。

### 推荐下载

| 格式 | 适用场景 | 文件 |
|------|----------|------|
| **img.gz** | 物理机 dd 写盘 / PVE 导入 | squashfs-efi.img.gz |
| **qcow2** | QEMU / Proxmox VE | squashfs-efi.qcow2 |
| **vmdk** | VMware ESXi / Workstation | squashfs-efi.vmdk |

> 额外：rootfs.tar.gz 裸文件系统，可用于 LXC 容器转换。

### 镜像详情

- **系统类型**：squashfs（只读根 + overlay 可写层，抗断电）
- **分区**：combined（含分区表 + 引导，直接 dd）
- **启动**：EFI
- **根分区大小**：${ROOTFS_PARTSIZE} MB
- **构建日期**：${BUILD_DATE}
- **ImageBuilder**：${IMAGEBUILDER_URL}

### 预装软件

$(cat "$OUT_DIR/.extra_packages" 2>/dev/null || echo "$EXTRA_PACKAGES")

### 校验

```bash
sha256sum -c sha256sums --ignore-missing
````

BODYEOF

ls -la "$OUT_DIR"

```
```
