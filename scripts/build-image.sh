```bash
#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# ImmortalWrt ImageBuilder 自动构建脚本
#
# VERSION:
#   留空   -> 自动获取 ImmortalWrt 最新正式稳定版
#   指定值 -> 使用指定版本
#
# GitHub Actions:
#
#   VERSION=""        -> 最新版本
#   VERSION="25.12.0" -> 指定旧版本
###############################################################################

###############################################################################
# 基本配置
###############################################################################

DOWNLOAD_BASE="${DOWNLOAD_BASE:-https://downloads.immortalwrt.org}"

VERSION="${VERSION:-}"

TARGET="${TARGET:-x86/64}"
PROFILE="${PROFILE:-generic}"

EXTRA_IMAGE_NAME="${EXTRA_IMAGE_NAME:-custom}"

OUT_DIR="${OUT_DIR:-$PWD/out}"
WORK_DIR="${WORK_DIR:-$PWD/work}"

PREFLIGHT="${PREFLIGHT:-1}"

ROOTFS_PARTSIZE="${ROOTFS_PARTSIZE:-4096}"

###############################################################################
# 保留原有依赖
###############################################################################

EXTRA_PACKAGES="${EXTRA_PACKAGES:-luci luci-i18n-base-zh-cn openssh-sftp-server luci-i18n-ddns-zh-cn luci-theme-argon luci-i18n-ttyd-zh-cn luci-i18n-firewall-zh-cn luci-i18n-package-manager-zh-cn kmod-sched-core kmod-sched-bpf kmod-veth kmod-xdp-sockets-diag curl nano}"

###############################################################################
# 依赖检查
###############################################################################

for cmd in curl sed tar unzstd sha256sum date grep awk sort head; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "ERROR: missing required command: $cmd" >&2
        exit 1
    fi
done

###############################################################################
# 获取最新正式版
#
# ImmortalWrt 官方下载首页会明确标记：
#
#   ImmortalWrt XX.XX.X
#
# 当前 Stable Release。
#
# 优先从官方首页读取，而不是猜 releases 目录。
###############################################################################

get_latest_version() {

    echo "Detecting latest ImmortalWrt stable release..." >&2

    local homepage
    local latest

    homepage="$(
        curl -fLsS \
            --retry 8 \
            --retry-delay 5 \
            --connect-timeout 30 \
            --max-time 60 \
            "${DOWNLOAD_BASE}/"
    )"

    latest="$(
        printf '%s\n' "$homepage" |
        grep -oE 'ImmortalWrt [0-9]+\.[0-9]+(\.[0-9]+)?' |
        sed -E 's/^ImmortalWrt //' |
        sort -V |
        tail -n 1
    )"

    if [ -z "$latest" ]; then
        echo "ERROR: unable to detect latest ImmortalWrt stable release." >&2
        echo "Source: ${DOWNLOAD_BASE}/" >&2
        exit 1
    fi

    printf '%s\n' "$latest"
}

###############################################################################
# 确定版本
###############################################################################

if [ -z "$VERSION" ]; then

    AUTO_VERSION=1

    VERSION="$(get_latest_version)"

else

    AUTO_VERSION=0

fi

###############################################################################
# 检查版本格式
###############################################################################

if ! printf '%s\n' "$VERSION" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then

    echo "ERROR: invalid ImmortalWrt version: $VERSION" >&2
    echo "Expected format: X.Y.Z" >&2

    exit 1

fi

###############################################################################
# 检查指定版本是否存在
###############################################################################

VERSION_URL="${DOWNLOAD_BASE}/releases/${VERSION}/"

echo
echo "Checking ImmortalWrt version..."
echo "Version URL: ${VERSION_URL}"

if ! curl -fLsS \
    --retry 5 \
    --retry-delay 3 \
    --connect-timeout 30 \
    --max-time 60 \
    -o /dev/null \
    "$VERSION_URL"; then

    echo
    echo "ERROR: ImmortalWrt version does not exist:"
    echo "  $VERSION"
    echo
    echo "URL:"
    echo "  $VERSION_URL"
    echo

    exit 1

fi

###############################################################################
# 自动生成 ImageBuilder URL
###############################################################################

if [ -n "${IMAGEBUILDER_URL:-}" ]; then

    echo
    echo "Using manually specified ImageBuilder URL:"
    echo "$IMAGEBUILDER_URL"

else

    IMAGEBUILDER_URL="${DOWNLOAD_BASE}/releases/${VERSION}/targets/${TARGET}/immortalwrt-imagebuilder-${VERSION}-x86-64.Linux-x86_64.tar.zst"

fi

###############################################################################
# 显示构建信息
###############################################################################

echo
echo "========================================"
echo "ImmortalWrt Build"
echo "========================================"
echo "Version          : $VERSION"
echo "Target           : $TARGET"
echo "Profile          : $PROFILE"
echo "Auto version     : $AUTO_VERSION"
echo "Rootfs part size : ${ROOTFS_PARTSIZE}MB"
echo
echo "ImageBuilder:"
echo "$IMAGEBUILDER_URL"
echo "========================================"
echo

###############################################################################
# 工作目录
###############################################################################

mkdir -p "$WORK_DIR"
mkdir -p "$OUT_DIR"

IB_ARCHIVE="$WORK_DIR/imagebuilder.tar.zst"

###############################################################################
# 验证 ImageBuilder URL
###############################################################################

echo "Checking ImageBuilder..."

if ! curl -fILsS \
    --retry 5 \
    --retry-delay 3 \
    --connect-timeout 30 \
    --max-time 60 \
    "$IMAGEBUILDER_URL" >/dev/null; then

    echo
    echo "ERROR: ImageBuilder not found."
    echo
    echo "ImmortalWrt version:"
    echo "  $VERSION"
    echo
    echo "Target:"
    echo "  $TARGET"
    echo
    echo "ImageBuilder:"
    echo "  $IMAGEBUILDER_URL"
    echo

    exit 1

fi

###############################################################################
# 下载 ImageBuilder
###############################################################################

if [ ! -s "$IB_ARCHIVE" ]; then

    echo
    echo "Downloading ImageBuilder..."
    echo

    curl -fL \
        --retry 8 \
        --retry-delay 5 \
        --connect-timeout 30 \
        --max-time 3600 \
        --progress-bar \
        -o "$IB_ARCHIVE" \
        "$IMAGEBUILDER_URL"

fi

###############################################################################
# 验证缓存的 ImageBuilder
###############################################################################

if ! tar \
    --use-compress-program=unzstd \
    -tf "$IB_ARCHIVE" >/dev/null 2>&1; then

    echo
    echo "Cached ImageBuilder is invalid."
    echo "Removing cache and downloading again..."
    echo

    rm -f "$IB_ARCHIVE"

    curl -fL \
        --retry 8 \
        --retry-delay 5 \
        --connect-timeout 30 \
        --max-time 3600 \
        --progress-bar \
        -o "$IB_ARCHIVE" \
        "$IMAGEBUILDER_URL"

fi

###############################################################################
# 解压 ImageBuilder
###############################################################################

rm -rf "$WORK_DIR/imagebuilder"

mkdir -p "$WORK_DIR/imagebuilder"

echo
echo "Extracting ImageBuilder..."

tar \
    --use-compress-program=unzstd \
    -xf "$IB_ARCHIVE" \
    -C "$WORK_DIR/imagebuilder" \
    --strip-components=1

###############################################################################
# 检查 ImageBuilder
###############################################################################

if [ ! -f "$WORK_DIR/imagebuilder/Makefile" ]; then

    echo
    echo "ERROR: Invalid ImageBuilder archive."
    echo "URL: $IMAGEBUILDER_URL"
    echo

    exit 1

fi

###############################################################################
# 检查 files
###############################################################################

if [ ! -d "$PWD/files" ]; then

    echo
    echo "ERROR: files directory not found."
    echo
    echo "Expected:"
    echo "  $PWD/files"
    echo

    exit 1

fi

###############################################################################
# 注入 files
###############################################################################

rm -rf "$WORK_DIR/imagebuilder/files"

cp -a "$PWD/files" "$WORK_DIR/imagebuilder/files"

###############################################################################
# 进入 ImageBuilder
###############################################################################

cd "$WORK_DIR/imagebuilder"

###############################################################################
# 构建信息
###############################################################################

echo
echo "========================================"
echo "Build configuration"
echo "========================================"
echo "ImmortalWrt       : $VERSION"
echo "Target            : $TARGET"
echo "Profile           : $PROFILE"
echo "Rootfs part size  : ${ROOTFS_PARTSIZE}MB"
echo "ImageBuilder      : $IMAGEBUILDER_URL"
echo
echo "Extra packages:"
echo "$EXTRA_PACKAGES"
echo "========================================"
echo

mkdir -p "$OUT_DIR"

###############################################################################
# 保存构建信息
###############################################################################

cat > "$OUT_DIR/.build_info" <<EOF
version=$VERSION
target=$TARGET
profile=$PROFILE
imagebuilder_url=$IMAGEBUILDER_URL
auto_version=$AUTO_VERSION
EOF

echo "extra_packages=$EXTRA_PACKAGES" > "$OUT_DIR/.extra_packages"

###############################################################################
# 构建失败诊断
###############################################################################

diagnose_failure() {

    cat >&2 <<EOF

========================================
ImageBuilder failed
========================================

ImmortalWrt version:
  $VERSION

Target:
  $TARGET

Profile:
  $PROFILE

ImageBuilder:
  $IMAGEBUILDER_URL

Common causes:

1. ImmortalWrt package feeds are temporarily out of sync.

2. A package listed in EXTRA_PACKAGES does not exist
   in this ImmortalWrt release.

3. A kmod-* package does not match the kernel version
   used by this ImageBuilder.

4. The selected ImageBuilder does not match the
   selected ImmortalWrt version.

5. ImmortalWrt package repositories are temporarily
   unavailable.

You can test package availability with:

    make manifest PROFILE="$PROFILE" PACKAGES="$EXTRA_PACKAGES"

========================================

EOF
}

###############################################################################
# Package preflight
###############################################################################

if [ "$PREFLIGHT" = "1" ] || [ "$PREFLIGHT" = "true" ]; then

    echo
    echo "========================================"
    echo "Running package manifest preflight..."
    echo "========================================"
    echo

    if ! make manifest \
        PROFILE="$PROFILE" \
        PACKAGES="$EXTRA_PACKAGES"; then

        diagnose_failure
        exit 1

    fi

fi

###############################################################################
# 精简镜像格式
###############################################################################

echo
echo "Configuring squashfs-only image formats..."

sed -i \
    -e 's/^CONFIG_TARGET_ROOTFS_EXT4FS=y/# CONFIG_TARGET_ROOTFS_EXT4FS is not set/' \
    -e 's/^CONFIG_TARGET_ROOTFS_TARGZ=y/# CONFIG_TARGET_ROOTFS_TARGZ is not set/' \
    -e 's/^CONFIG_VDI_IMAGES=y/# CONFIG_VDI_IMAGES is not set/' \
    -e 's/^CONFIG_VHDX_IMAGES=y/# CONFIG_VHDX_IMAGES is not set/' \
    -e 's/^CONFIG_ISO_IMAGES=y/# CONFIG_ISO_IMAGES is not set/' \
    -e 's/^CONFIG_GRUB_IMAGES=y/# CONFIG_GRUB_IMAGES is not set/' \
    .config

###############################################################################
# 构建镜像
###############################################################################

echo
echo "========================================"
echo "Building ImmortalWrt..."
echo "========================================"
echo

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

###############################################################################
# 重命名输出
###############################################################################

cd "$OUT_DIR"

echo
echo "Renaming output files..."

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

###############################################################################
# SHA256
###############################################################################

echo
echo "Generating SHA256 checksums..."

rm -f sha256sums

for f in \
    squashfs-efi.img.gz \
    squashfs-efi.qcow2 \
    squashfs-efi.vmdk \
    kernel.bin \
    rootfs.tar.gz \
    manifest \
    bom.cdx.json
do

    [ -f "$f" ] || continue

    sha256sum "$f"

done > sha256sums

###############################################################################
# 构建日期
###############################################################################

BUILD_DATE="$(TZ='Asia/Shanghai' date '+%F %H:%M CST')"

###############################################################################
# BUILD-MANIFEST
###############################################################################

cat > BUILD-MANIFEST.txt <<BODYEOF
## ImmortalWrt 固件 · ${EXTRA_IMAGE_NAME}

基于 ImmortalWrt ${VERSION}。

x86-64 通用镜像，squashfs-only。

### 上游版本

- **ImmortalWrt 版本**：${VERSION}
- **Target**：${TARGET}
- **Profile**：${PROFILE}
- **ImageBuilder**：${IMAGEBUILDER_URL}
- **自动检测版本**：$([ "$AUTO_VERSION" = "1" ] && echo "是" || echo "否，手动指定版本")

### 推荐下载

| 格式 | 适用场景 | 文件 |
|------|----------|------|
| **img.gz** | 物理机 dd 写盘 / PVE 导入 | squashfs-efi.img.gz |
| **qcow2** | QEMU / Proxmox VE | squashfs-efi.qcow2 |
| **vmdk** | VMware ESXi / Workstation | squashfs-efi.vmdk |

> 额外：rootfs.tar.gz 裸文件系统，可用于 LXC 容器转换。

### 镜像详情

- **系统类型**：squashfs
- **分区**：combined
- **启动方式**：EFI
- **架构**：x86-64
- **根分区大小**：${ROOTFS_PARTSIZE} MB
- **构建日期**：${BUILD_DATE}

### 预装软件

$(cat "$OUT_DIR/.extra_packages" 2>/dev/null || echo "$EXTRA_PACKAGES")

### 校验

\`\`\`bash
sha256sum -c sha256sums --ignore-missing
\`\`\`

### 构建说明

本固件默认自动检测 ImmortalWrt 最新正式稳定版本。

如果 GitHub Actions 手动指定 VERSION，则使用指定版本。

例如：

\`\`\`bash
VERSION=25.12.0 ./build-image.sh
\`\`\`
BODYEOF

###############################################################################
# 输出结果
###############################################################################

echo
echo "========================================"
echo "Build completed successfully"
echo "========================================"
echo
echo "ImmortalWrt version : $VERSION"
echo "Target              : $TARGET"
echo "Profile             : $PROFILE"
echo "Build date          : $BUILD_DATE"
echo
echo "Output directory:"
echo "  $OUT_DIR"
echo

ls -lah "$OUT_DIR"
```
