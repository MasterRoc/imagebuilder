#!/usr/bin/env bash
set -euo pipefail

VERSION="${VERSION:-25.12.1}"
TARGET="${TARGET:-x86/64}"
PROFILE="${PROFILE:-generic}"

IMAGEBUILDER_URL="${IMAGEBUILDER_URL:-https://downloads.immortalwrt.org/releases/25.12.1/targets/x86/64/immortalwrt-imagebuilder-25.12.1-x86-64.Linux-x86_64.tar}"

EXTRA_IMAGE_NAME="${EXTRA_IMAGE_NAME:-daede}"
OUT_DIR="${OUT_DIR:-$PWD/out}"
PREFLIGHT="${PREFLIGHT:-1}"
ROOTFS_PARTSIZE="${ROOTFS_PARTSIZE:-4096}"

# ============================================================
# Daed
# ============================================================
# 0 = 不下载、不安装 Daed
# 1 = 如果以后需要，可通过环境变量手动启用
INSTALL_DAEDE="${INSTALL_DAEDE:-0}"

# ============================================================
# Packages
# ============================================================
# 注意：
# 这里保留 Daed/dae 相关的 kmod 依赖。
# 但不会安装 luci-app-daede，也不会下载 Daed APK。
# ============================================================

EXTRA_PACKAGES="${EXTRA_PACKAGES:-\
luci \
luci-i18n-base-zh-cn \
luci-i18n-ttyd-zh-cn \
luci-theme-argon \
luci-i18n-firewall-zh-cn \
luci-i18n-ddns-zh-cn \
luci-i18n-package-manager-zh-cn \
kmod-sched-core \
kmod-sched-bpf \
kmod-veth \
kmod-xdp-sockets-diag \
curl \
nano}"

WORK_DIR="${WORK_DIR:-$PWD/work}"
IB_ARCHIVE="$WORK_DIR/imagebuilder.tar.zst"

mkdir -p "$WORK_DIR" "$OUT_DIR"


# ============================================================
# Daed download/install
# ============================================================
# 当前版本默认完全不下载、不安装 Daed。
#
# 如果以后需要恢复 Daed 下载逻辑，可以重新增加：
# resolve_daede_apk_url()
# install_daede_apk()
#
# 目前不执行任何 Daed APK 下载。
# ============================================================

install_daede_apk() {
  case "$INSTALL_DAEDE" in
    1|true|yes)
      echo "WARNING: INSTALL_DAEDE=$INSTALL_DAEDE"
      echo "Daed APK download/install is disabled in this build-image.sh."
      echo "Only Daed runtime dependencies are retained."
      ;;
    *)
      echo "Skipping luci-app-daede download/install."
      ;;
  esac
}


# ============================================================
# Download ImageBuilder
# ============================================================

if [ ! -s "$IB_ARCHIVE" ]; then
  echo "===== Downloading ImageBuilder ====="
  echo "URL: $IMAGEBUILDER_URL"

  curl -L \
    --retry 8 \
    --retry-delay 5 \
    --connect-timeout 30 \
    -o "$IB_ARCHIVE" \
    "$IMAGEBUILDER_URL"
else
  echo "===== Using cached ImageBuilder ====="
  echo "$IB_ARCHIVE"
fi


# ============================================================
# Extract ImageBuilder
# ============================================================

echo "===== Extracting ImageBuilder ====="

rm -rf "$WORK_DIR/imagebuilder"
mkdir -p "$WORK_DIR/imagebuilder"

tar \
  --use-compress-program=unzstd \
  -xf "$IB_ARCHIVE" \
  -C "$WORK_DIR/imagebuilder" \
  --strip-components=1


# ============================================================
# Copy custom files
# ============================================================

echo "===== Copying custom files ====="

cp -a files "$WORK_DIR/imagebuilder/files"


# ============================================================
# Check 99-custom.sh
# ============================================================

echo "===== Checking 99-custom.sh ====="

if [ -f "files/etc/uci-defaults/99-custom.sh" ]; then
  nl -ba files/etc/uci-defaults/99-custom.sh

  echo "===== Syntax check 99-custom.sh ====="

  sh -n files/etc/uci-defaults/99-custom.sh

  echo "99-custom.sh syntax OK."
else
  echo "No files/etc/uci-defaults/99-custom.sh found."
fi


# ============================================================
# Daed install hook
# ============================================================

# install_daede_apk


# ============================================================
# Enter ImageBuilder
# ============================================================

cd "$WORK_DIR/imagebuilder"


# ============================================================
# Build information
# ============================================================

echo "========================================"
echo "        ImmortalWrt ImageBuilder"
echo "========================================"
echo "Version:            $VERSION"
echo "Target:             $TARGET"
echo "Profile:            $PROFILE"
echo "Rootfs part size:   ${ROOTFS_PARTSIZE}MB"

echo ""
echo "Daed:"
echo "  APK download:     DISABLED"
echo "  Default install:  DISABLED"
echo "  Runtime kmods:    ENABLED"

echo ""
echo "Extra packages:"
echo "$EXTRA_PACKAGES" | tr ' ' '\n'

echo "========================================"


mkdir -p "$OUT_DIR"

echo "extra_packages=$EXTRA_PACKAGES" > "$OUT_DIR/.extra_packages"


# ============================================================
# Failure diagnostics
# ============================================================

diagnose_failure() {
  cat >&2 <<'EOF'

========================================
ImageBuilder failed.
========================================

Possible causes:

1. The selected ImmortalWrt ImageBuilder and package
   feeds are out of sync.

2. One or more requested packages are not available
   for the selected target/kernel combination.

3. A kmod-* package does not match the kernel version
   used by this ImageBuilder.

4. A package dependency cannot be satisfied.

Daed status:

- luci-app-daede is NOT downloaded.
- Daed is NOT installed by default.
- Daed-related kmod dependencies remain enabled.

Important:

The following packages are intentionally retained because
they may be required by dae/daed:

- kmod-sched-core
- kmod-sched-bpf
- kmod-veth
- kmod-xdp-sockets-diag

If the build fails during kmod verification, check which
specific package is reported as unavailable.

BTF:

ImmortalWrt 25.12 kernels enable CONFIG_DEBUG_INFO_BTF.
Do NOT add vmlinux-btf to EXTRA_PACKAGES.

ImageBuilder cannot compile missing kernel modules.
The kmod package must exist in the feed matching the
ImageBuilder kernel.

========================================

EOF
}


# ============================================================
# Package preflight
# ============================================================

if [ "$PREFLIGHT" = "1" ] || [ "$PREFLIGHT" = "true" ]; then

  echo "========================================"
  echo "Running package manifest preflight..."
  echo "========================================"

  echo "===== All requested packages ====="
  echo "$EXTRA_PACKAGES" | tr ' ' '\n'

  echo ""
  echo "===== Verify kmod packages ====="

  for pkg in $EXTRA_PACKAGES; do

    case "$pkg" in

      kmod-*)
        echo "----------------------------------------"
        echo "Checking package: $pkg"

        if make manifest \
            PROFILE="$PROFILE" \
            PACKAGES="$pkg"; then

          echo "OK: $pkg"

        else

          echo "::error::Package verification failed: $pkg"

          diagnose_failure

          exit 1

        fi
        ;;

    esac

  done

  echo "----------------------------------------"
  echo "===== All kmod packages verified ====="
  echo ""


  # ==========================================================
  # Verify all packages
  # ==========================================================
  #
  # 注意：
  # kmod 已经逐个检查。
  #
  # 这里再检查整个 EXTRA_PACKAGES。
  # 如果某个普通 LuCI 软件包不存在，也能在这里发现。
  # ==========================================================

  echo "===== Verify complete package list ====="

  if make manifest \
      PROFILE="$PROFILE" \
      PACKAGES="$EXTRA_PACKAGES"; then

    echo "===== Package manifest OK ====="

  else

    echo "::error::Complete package manifest verification failed."

    diagnose_failure

    exit 1

  fi

fi


# ============================================================
# Slim image formats
# ============================================================

echo "===== Configuring slim image formats ====="

sed -i \
  -e 's/^CONFIG_TARGET_ROOTFS_EXT4FS=y/# CONFIG_TARGET_ROOTFS_EXT4FS is not set/' \
  -e 's/^CONFIG_TARGET_ROOTFS_TARGZ=y/# CONFIG_TARGET_ROOTFS_TARGZ is not set/' \
  -e 's/^CONFIG_VDI_IMAGES=y/# CONFIG_VDI_IMAGES is not set/' \
  -e 's/^CONFIG_VHDX_IMAGES=y/# CONFIG_VHDX_IMAGES is not set/' \
  -e 's/^CONFIG_ISO_IMAGES=y/# CONFIG_ISO_IMAGES is not set/' \
  -e 's/^CONFIG_GRUB_IMAGES=y/# CONFIG_GRUB_IMAGES is not set/' \
  .config


# ============================================================
# Build image
# ============================================================

echo "========================================"
echo "Starting ImageBuilder..."
echo "========================================"

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


# ============================================================
# Rename output files
# ============================================================

echo "===== Renaming output files ====="

cd "$OUT_DIR"


for f in *-squashfs-combined-efi.img.gz; do
  [ -f "$f" ] && mv "$f" daede-squashfs-efi.img.gz
done



for f in *-kernel.bin; do
  [ -f "$f" ] && mv "$f" daede-kernel.bin
done


for f in *.manifest; do
  [ -f "$f" ] && mv "$f" daede.manifest
done


for f in *.bom.cdx.json; do
  [ -f "$f" ] && mv "$f" daede.bom.cdx.json
done


# ============================================================
# SHA256
# ============================================================

echo "===== Generating SHA256 checksums ====="

for f in \
  *.img.gz \
  *.bin \
  *.tar.gz \
  *.manifest \
  *.bom.cdx.json; do

  [ -f "$f" ] || continue

  sha256sum "$f"

done > sha256sums


# ============================================================
# Build manifest
# ============================================================

BUILD_DATE="$(TZ='Asia/Shanghai' date '+%F %H:%M CST')"


cat > BUILD-MANIFEST.txt <<BODYEOF
## daede 固件 · ${EXTRA_IMAGE_NAME}

基于 ImmortalWrt 25.12.1，x86-64 通用镜像，squashfs-only。

### 推荐下载

| 格式 | 适用场景 | 文件 |
|------|----------|------|
| **img.gz** | 物理机 dd 写盘 / PVE 导入 | daede-squashfs-efi.img.gz |
| **qcow2** | QEMU / Proxmox VE | daede-squashfs-efi.qcow2 |
| **vmdk** | VMware ESXi / Workstation | daede-squashfs-efi.vmdk |

> 额外：\`daede-rootfs.tar.gz\` 裸文件系统，可用于 LXC 容器转换。

### 镜像详情

- **系统类型**：squashfs（只读根 + overlay 可写层，抗断电）
- **分区**：combined（含分区表 + 引导，直接 dd）
- **启动**：EFI
- **根分区大小**：${ROOTFS_PARTSIZE} MB
- **构建日期**：${BUILD_DATE}
- **ImageBuilder**：${IMAGEBUILDER_URL}

### Daed

- **Daed APK 下载**：禁用
- **Daed 默认安装**：禁用
- **Daed 相关 kmod 依赖**：保留

### 预装软件

\`$(cat "$OUT_DIR/.extra_packages" 2>/dev/null || echo "$EXTRA_PACKAGES")\`

### 校验

\`\`\`bash
sha256sum -c sha256sums --ignore-missing
\`\`\`
BODYEOF


# ============================================================
# Final output
# ============================================================

echo ""
echo "========================================"
echo "         BUILD SUCCESS"
echo "========================================"
echo ""

ls -lah "$OUT_DIR"

echo ""
echo "===== SHA256 ====="
cat "$OUT_DIR/sha256sums"

echo ""
echo "===== Build manifest ====="
cat "$OUT_DIR/BUILD-MANIFEST.txt"

echo ""
echo "========================================"
echo "Daed APK download: DISABLED"
echo "Daed default installation: DISABLED"
echo "Daed dependencies: RETAINED"
echo "========================================"
