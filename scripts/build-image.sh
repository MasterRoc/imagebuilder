```bash
#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# ImmortalWrt ImageBuilder 自动构建脚本
#
# 默认行为：
#   - 自动获取 ImmortalWrt 最新正式稳定版
#   - 自动匹配对应 x86/64 ImageBuilder
#   - 自动匹配对应 package feeds / kernel
#
# 可通过环境变量覆盖：
#   VERSION=25.12.1
#   IMAGEBUILDER_URL=...
#   TARGET=x86/64
#   PROFILE=generic
###############################################################################

###############################################################################
# 基本配置
###############################################################################

# ImmortalWrt 官方下载站
DOWNLOAD_BASE="${DOWNLOAD_BASE:-https://downloads.immortalwrt.org}"

# 默认自动检测最新正式版
# 如果手动指定 VERSION，则跳过自动检测
VERSION="${VERSION:-}"

TARGET="${TARGET:-x86/64}"
PROFILE="${PROFILE:-generic}"

EXTRA_IMAGE_NAME="${EXTRA_IMAGE_NAME:-custom}"
OUT_DIR="${OUT_DIR:-$PWD/out}"
WORK_DIR="${WORK_DIR:-$PWD/work}"

PREFLIGHT="${PREFLIGHT:-1}"
ROOTFS_PARTSIZE="${ROOTFS_PARTSIZE:-4096}"

# 保留原有依赖，不删除
EXTRA_PACKAGES="${EXTRA_PACKAGES:-luci luci-i18n-base-zh-cn openssh-sftp-server luci-i18n-ddns-zh-cn luci-theme-argon luci-i18n-ttyd-zh-cn luci-i18n-firewall-zh-cn luci-i18n-package-manager-zh-cn kmod-sched-core kmod-sched-bpf kmod-veth kmod-xdp-sockets-diag curl nano}"

###############################################################################
# 检查依赖
###############################################################################

for cmd in curl sed tar unzstd sha256sum date awk grep sort head; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "ERROR: missing required command: $cmd" >&2
        exit 1
    fi
done

###############################################################################
# 自动获取最新 ImmortalWrt 正式版本
###############################################################################

get_latest_version() {
    echo "Detecting latest ImmortalWrt stable release..." >&2

    local releases_url
    releases_url="${DOWNLOAD_BASE}/releases/"

    local latest

    latest="$(
        curl -fsSL \
            --retry 8 \
            --retry-delay 5 \
            --connect-timeout 30 \
            "$releases_url" |
        grep -oE 'href="[0-9]+\.[0-9]+(\.[0-9]+)?/"' |
        sed -E 's/^href="//; s#/$##' |
        sort -V |
        tail -n 1
    )"

    if [ -z "$latest" ]; then
        echo "ERROR: unable to detect latest ImmortalWrt release." >&2
        echo "URL: $releases_url" >&2
        exit 1
    fi

    echo "$latest"
}

###############################################################################
# 确定 VERSION
###############################################################################

if [ -z "$VERSION" ]; then
    VERSION="$(get_latest_version)"
    AUTO_VERSION=1
else
    AUTO_VERSION=0
fi

echo "========================================"
echo "ImmortalWrt Build"
echo "========================================"
echo "Version : $VERSION"
echo "Target  : $TARGET"
echo "Profile : $PROFILE"
echo "========================================"

###############################################################################
# 自动生成 ImageBuilder URL
###############################################################################

if [ -z "${IMAGEBUILDER_URL:-}" ]; then

    # x86/64 对应官方目录：
    #
    # releases/<VERSION>/targets/x86/64/
    #
    # 文件名：
    # immortalwrt-imagebuilder-<VERSION>-x86-64.Linux-x86_64.tar.zst

    IMAGEBUILDER_URL="${DOWNLOAD_BASE}/releases/${VERSION}/targets/${TARGET}/immortalwrt-imagebuilder-${VERSION}-x86-64.Linux-x86_64.tar.zst"

    echo "ImageBuilder URL:"
    echo "$IMAGEBUILDER_URL"
else
    echo "Using custom ImageBuilder URL:"
    echo "$IMAGEBUILDER_URL"
fi

###############################################################################
# 工作目录
###############################################################################

mkdir -p "$WORK_DIR" "$OUT_DIR"

IB_ARCHIVE="$WORK_DIR/imagebuilder.tar.zst"

###############################################################################
# 下载 ImageBuilder
###############################################################################

download_imagebuilder() {

    echo
    echo "Downloading ImmortalWrt ImageBuilder..."
    echo

    curl -fL \
        --retry 8 \
        --retry-delay 5 \
        --connect-timeout 30 \
        --progress-bar \
        -o "$IB_ARCHIVE" \
        "$IMAGEBUILDER_URL"
}

###############################################################################
# 如果 ImageBuilder 不存在，则下载
###############################################################################

if [ ! -s "$IB_ARCHIVE" ]; then
    download_imagebuilder
fi

###############################################################################
# 验证 ImageBuilder 是否可以解压
#
# 如果之前缓存的是旧版本，而 VERSION 已经变化，
# 自动删除旧缓存重新下载。
###############################################################################

if ! tar --use-compress-program=unzstd -tf "$IB_ARCHIVE" >/dev/null 2>&1; then

    echo
    echo "Cached ImageBuilder archive is invalid."
    echo "Removing cached archive and downloading again..."
    echo

    rm -f "$IB_ARCHIVE"

    download_imagebuilder
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
    echo "ERROR: Invalid ImmortalWrt ImageBuilder." >&2
    echo "URL: $IMAGEBUILDER_URL" >&2
    exit 1
fi

###############################################################################
# 注入自定义 files
###############################################################################

if [ ! -d "$PWD/files" ]; then
    echo "ERROR: files directory not found." >&2
    echo "Please create ./files before running the build." >&2
    exit 1
fi

rm -rf "$WORK_DIR/imagebuilder/files"

cp -a "$PWD/files" "$WORK_DIR/imagebuilder/files"

###############################################################################
# 进入 ImageBuilder
###############################################################################

cd "$WORK_DIR/imagebuilder"

###############################################################################
# 输出构建信息
###############################################################################

echo
echo "========================================"
echo "Build configuration"
echo "========================================"
echo "Version           : $VERSION"
echo "Target            : $TARGET"
echo "Profile           : $PROFILE"
echo "Rootfs part size  : ${ROOTFS_PARTSIZE}MB"
echo "Auto detected     : $AUTO_VERSION"
echo "ImageBuilder      : $IMAGEBUILDER_URL"
echo "Extra packages    : $EXTRA_PACKAGES"
echo "========================================"
echo

mkdir -p "$OUT_DIR"

echo "version=$VERSION" > "$OUT_DIR/.build_info"
echo "target=$TARGET" >> "$OUT_DIR/.build_info"
echo "profile=$PROFILE" >> "$OUT_DIR/.build_info"
echo "imagebuilder_url=$IMAGEBUILDER_URL" >> "$OUT_DIR/.build_info"
echo "extra_packages=$EXTRA_PACKAGES" > "$OUT_DIR/.extra_packages"

###############################################################################
# 构建失败诊断
###############################################################################

diagnose_failure() {

    cat >&2 <<EOF

========================================
ImageBuilder failed
========================================

Version:
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

4. The ImageBuilder URL does not match the selected
   target/version.

5. The upstream package repository is temporarily
   unavailable.

Try:

    make manifest PROFILE="$PROFILE" PACKAGES="$EXTRA_PACKAGES"

If the error is related to a kmod-* package,
make sure the package comes from the same ImmortalWrt
release as this ImageBuilder.

========================================

EOF
}

###############################################################################
# Package manifest preflight
###############################################################################

if [ "$PREFLIGHT" = "1" ] || [ "$PREFLIGHT" = "true" ]; then

    echo
    echo "Running package manifest preflight..."
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
#
# 保留：
#   squashfs combined EFI
#   img.gz
#   qcow2
#   vmdk
#
# 禁用：
#   ext4
#   targz
#   vdi
#   vhdx
#   iso
#   grub
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
# 开始构建
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
# 重命名输出文件
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
- **版本来源**：ImmortalWrt 官方 releases
- **自动跟随上游**：$([ "$AUTO_VERSION" = "1" ] && echo "是" || echo "否，手动指定 VERSION")

### 推荐下载

| 格式 | 适用场景 | 文件 |
|------|----------|------|
| **img.gz** | 物理机 dd 写盘 / PVE 导入 | squashfs-efi.img.gz |
| **qcow2** | QEMU / Proxmox VE | squashfs-efi.qcow2 |
| **vmdk** | VMware ESXi / Workstation | squashfs-efi.vmdk |

> 额外：rootfs.tar.gz 裸文件系统，可用于 LXC 容器转换。

### 镜像详情

- **系统类型**：squashfs（只读根 + overlay 可写层）
- **分区**：combined（含分区表 + 引导）
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

如果需要固定版本，可以：

\`\`\`bash
VERSION=25.12.1 ./build-image.sh
\`\`\`

如果不设置 VERSION，则自动使用 ImmortalWrt 官方最新正式版本。
BODYEOF

###############################################################################
# 清理内部文件
###############################################################################

rm -f "$OUT_DIR/.extra_packages"

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
