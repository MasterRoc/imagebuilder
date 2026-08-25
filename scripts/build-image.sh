#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Basic configuration
# ============================================================

VERSION="${VERSION:-}"
TARGET="${TARGET:-x86/64}"
PROFILE="${PROFILE:-generic}"

IMAGEBUILDER_URL="${IMAGEBUILDER_URL:-https://downloads.immortalwrt.org/releases/25.12.1/targets/x86/64/immortalwrt-imagebuilder-25.12.1-x86-64.Linux-x86_64.tar.zst}"

EXTRA_IMAGE_NAME="${EXTRA_IMAGE_NAME:-daede}"

OUT_DIR="${OUT_DIR:-$PWD/out}"
WORK_DIR="${WORK_DIR:-$PWD/work}"

PREFLIGHT="${PREFLIGHT:-1}"
ROOTFS_PARTSIZE="${ROOTFS_PARTSIZE:-1024}"

# Daede
INSTALL_DAEDE="${INSTALL_DAEDE:-1}"
DAEDE_REPO="${DAEDE_REPO:-kenzok8/openwrt-daede}"
DAEDE_RELEASE_TAG="${DAEDE_RELEASE_TAG:-latest}"
DAEDE_ARCH="${DAEDE_ARCH:-x86_64}"
DAEDE_APK_URL="${DAEDE_APK_URL:-}"

# Network uci-defaults script

# Supported:
#  99-custom.sh


NETWORK_SCRIPT="${NETWORK_SCRIPT:－99-custom.sh}"

# Do NOT put luci-app-daede here.
# The APK is downloaded separately into ImageBuilder/packages.
EXTRA_PACKAGES="${EXTRA_PACKAGES:-luci luci-i18n-ddns-zh-cn luci-i18n-base-zh-cn luci-i18n-firewall-zh-cn luci-i18n-package-manager-zh-cn kmod-sched-core kmod-sched-bpf kmod-veth kmod-xdp-sockets-diag curl nano}"

# ============================================================
# Paths
# ============================================================

mkdir -p "$WORK_DIR" "$OUT_DIR"

IB_ARCHIVE_NAME="${IMAGEBUILDER_URL##*/}"
IB_ARCHIVE="$WORK_DIR/$IB_ARCHIVE_NAME"

IMAGEBUILDER_DIR="$WORK_DIR/imagebuilder"

# ============================================================
# Resolve ImageBuilder version from URL
# ============================================================

resolve_version() {
    if [ -n "${VERSION:-}" ]; then
        printf '%s\n' "$VERSION"
        return
    fi

    local url="$IMAGEBUILDER_URL"

    # Examples:
    #
    # /releases/25.12.1/targets/x86/64/...
    # /releases/25.12-SNAPSHOT/targets/x86/64/...
    #
    if [[ "$url" =~ /releases/([^/]+)/targets/ ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
        return
    fi

    # Fallback: try filename
    if [[ "$url" =~ immortalwrt-imagebuilder-([0-9A-Za-z._-]+)-x86-64 ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
        return
    fi

    printf '%s\n' "unknown"
}

VERSION="$(resolve_version)"

# ============================================================
# Resolve Daede APK URL
# ============================================================

resolve_daede_apk_url() {
    if [ -n "$DAEDE_APK_URL" ]; then
        printf '%s\n' "$DAEDE_APK_URL"
        return
    fi

    local release_api

    if [ "$DAEDE_RELEASE_TAG" = "latest" ]; then
        release_api="https://api.github.com/repos/$DAEDE_REPO/releases/latest"
    else
        release_api="https://api.github.com/repos/$DAEDE_REPO/releases/tags/$DAEDE_RELEASE_TAG"
    fi

    python3 - "$release_api" "$DAEDE_ARCH" <<'PY'
import json
import os
import sys
import urllib.request

release_api, arch = sys.argv[1:3]

request = urllib.request.Request(
    release_api,
    headers={
        "Accept": "application/vnd.github+json",
        "User-Agent": "MasterRoc-imagebuilder",
    },
)

token = os.environ.get("GITHUB_TOKEN")
if token:
    request.add_header("Authorization", f"Bearer {token}")

with urllib.request.urlopen(request, timeout=30) as response:
    release = json.load(response)

suffix = f"-{arch}.apk"

matches = [
    asset.get("browser_download_url") or asset.get("url")
    for asset in release.get("assets", [])
    if asset.get("name", "").startswith("luci-app-daede-")
    and asset.get("name", "").endswith(suffix)
]

if not matches:
    tag = release.get("tag_name", release_api)
    raise SystemExit(
        f"luci-app-daede APK for {arch} not found in {tag}"
    )

print(matches[0])
PY
}

# ============================================================
# Download Daede APK
# ============================================================

install_daede_apk() {
    case "$INSTALL_DAEDE" in
        1|true|yes)
            ;;
        *)
            echo "Skipping luci-app-daede release APK download."
            return
            ;;
    esac

    local packages_dir="$IMAGEBUILDER_DIR/packages"
    local daede_url

    daede_url="$(resolve_daede_apk_url)"

    mkdir -p "$packages_dir"

    # ImageBuilder's package index expects the canonical APK filename.
    #
    # Example:
    #   luci-app-daede-1.0.0-x86_64.apk
    #
    # becomes:
    #   luci-app-daede-1.0.0.apk
    #
    local fname="${daede_url##*/}"

    if [[ "$fname" == *-"$DAEDE_ARCH".apk ]]; then
        fname="${fname%-${DAEDE_ARCH}.apk}.apk"
    fi

    echo "Downloading luci-app-daede APK:"
    echo "  URL : $daede_url"
    echo "  File: $fname"

    curl -fL \
        --retry 8 \
        --retry-delay 5 \
        --connect-timeout 30 \
        -o "$packages_dir/$fname" \
        "$daede_url"

    if [ ! -s "$packages_dir/$fname" ]; then
        echo "ERROR: Daede APK download failed or file is empty."
        exit 1
    fi

    echo "Daede APK installed into ImageBuilder packages:"
    ls -lh "$packages_dir/$fname"
}

# ============================================================
# Prepare selected uci-defaults script
# ============================================================

prepare_network_script() {
    local source_dir="$PWD/files/etc/uci-defaults"
    local target_dir="$IMAGEBUILDER_DIR/files/etc/uci-defaults"

    echo
    echo "========================================"
    echo "Preparing uci-defaults"
    echo "========================================"
    echo "Selected network script: $NETWORK_SCRIPT"

    mkdir -p "$target_dir"

    # Remove both selectable scripts first.
    #
    # This is important because the repository contains both files,
    # but we only want ONE of them inside the final firmware.
    rm -f \
        "$target_dir/99-custom.sh" \
        "$target_dir/99-daed-test-network"

    case "$NETWORK_SCRIPT" in
        99-custom.sh)
            if [ ! -f "$source_dir/99-custom.sh" ]; then
                echo "ERROR: files/etc/uci-defaults/99-custom.sh not found."
                exit 1
            fi

            cp -f \
                "$source_dir/99-custom.sh" \
                "$target_dir/99-custom.sh"

            chmod 0755 \
                "$target_dir/99-custom.sh"
            ;;

        99-daed-test-network)
            if [ ! -f "$source_dir/99-daed-test-network" ]; then
                echo "ERROR: files/etc/uci-defaults/99-daed-test-network not found."
                exit 1
            fi

            cp -f \
                "$source_dir/99-daed-test-network" \
                "$target_dir/99-daed-test-network"

            chmod 0755 \
                "$target_dir/99-daed-test-network"
            ;;

        none)
            echo "No selectable network uci-defaults script will be installed."
            ;;

        *)
            echo "ERROR: Unknown NETWORK_SCRIPT: $NETWORK_SCRIPT"
            echo
            echo "Supported values:"
            echo "  99-custom.sh"
            echo "  99-daed-test-network"
            echo "  none"
            exit 1
            ;;
    esac

    echo
    echo "Final uci-defaults files:"
    if [ -d "$target_dir" ]; then
        find "$target_dir" \
            -maxdepth 1 \
            -type f \
            -printf '%f %m\n' \
            | sort
    fi

    echo "========================================"
}

# ============================================================
# Prepare files directory
# ============================================================

prepare_files() {
    echo
    echo "========================================"
    echo "Preparing ImageBuilder files/"
    echo "========================================"

    rm -rf "$IMAGEBUILDER_DIR/files"

    mkdir -p "$IMAGEBUILDER_DIR/files"

    # Copy all repository files first.
    #
    # We use files/. rather than copying the directory itself so
    # the final ImageBuilder structure is:
    #
    # imagebuilder/files/...
    #
    if [ -d "$PWD/files" ]; then
        cp -a "$PWD/files/." "$IMAGEBUILDER_DIR/files/"
    fi

    # Then select exactly one network uci-defaults script.
    prepare_network_script

    echo
    echo "ImageBuilder files tree:"
    find "$IMAGEBUILDER_DIR/files" \
        -maxdepth 5 \
        -type f \
        -print \
        | sort || true

    echo "========================================"
}

# ============================================================
# Download ImageBuilder
# ============================================================

download_imagebuilder() {
    echo
    echo "========================================"
    echo "ImageBuilder"
    echo "========================================"
    echo "URL:"
    echo "$IMAGEBUILDER_URL"
    echo
    echo "Archive:"
    echo "$IB_ARCHIVE"

    if [ ! -s "$IB_ARCHIVE" ]; then
        echo "Downloading ImageBuilder..."

        curl -fL \
            --retry 8 \
            --retry-delay 5 \
            --connect-timeout 30 \
            -o "$IB_ARCHIVE" \
            "$IMAGEBUILDER_URL"
    else
        echo "Using cached ImageBuilder archive:"
        ls -lh "$IB_ARCHIVE"
    fi

    if [ ! -s "$IB_ARCHIVE" ]; then
        echo "ERROR: ImageBuilder archive is missing or empty."
        exit 1
    fi

    echo "ImageBuilder archive:"
    file "$IB_ARCHIVE"
    echo "========================================"
}

# ============================================================
# Extract ImageBuilder
# ============================================================

extract_imagebuilder() {
    echo
    echo "========================================"
    echo "Extracting ImageBuilder"
    echo "========================================"

    rm -rf "$IMAGEBUILDER_DIR"
    mkdir -p "$IMAGEBUILDER_DIR"

    case "$IB_ARCHIVE" in
        *.tar.zst|*.tzst)
            echo "Detected zstd-compressed tar archive."

            tar \
                --use-compress-program=unzstd \
                -xf "$IB_ARCHIVE" \
                -C "$IMAGEBUILDER_DIR" \
                --strip-components=1
            ;;

        *.tar)
            echo "Detected uncompressed tar archive."

            tar \
                -xf "$IB_ARCHIVE" \
                -C "$IMAGEBUILDER_DIR" \
                --strip-components=1
            ;;

        *)
            echo "ERROR: Unsupported ImageBuilder archive format:"
            echo "$IB_ARCHIVE"
            echo
            echo "Supported:"
            echo "  .tar"
            echo "  .tar.zst"
            exit 1
            ;;
    esac

    if [ ! -f "$IMAGEBUILDER_DIR/Makefile" ]; then
        echo "ERROR: ImageBuilder extraction failed."
        echo "Makefile not found in:"
        echo "$IMAGEBUILDER_DIR"
        exit 1
    fi

    echo "ImageBuilder extracted successfully."
    echo "========================================"
}

# ============================================================
# Diagnose failure
# ============================================================

diagnose_failure() {
    cat >&2 <<'EOF'

============================================================
ImageBuilder failed.
============================================================

Common causes:

1. The selected ImmortalWrt SNAPSHOT ImageBuilder and
   package feeds are out of sync.

2. One of the required kmod packages is missing for the
   selected kernel version:

   kmod-sched-core
   kmod-sched-bpf
   kmod-veth
   kmod-xdp-sockets-diag

3. luci-app-daede APK was not copied into:
   ImageBuilder/packages/

4. luci-app-daede APK architecture does not match:
   x86_64

5. The selected Daede release was built for another
   ImmortalWrt/OpenWrt package ABI.

6. A SNAPSHOT feed changed after the ImageBuilder was
   released.

About BTF:

ImmortalWrt 25.12 kernels enable CONFIG_DEBUG_INFO_BTF
by default.

dae/daed reads:

    /sys/kernel/btf/vmlinux

directly at runtime.

Do NOT add:

    vmlinux-btf

to EXTRA_PACKAGES.

ImageBuilder cannot compile that package and it is not
required for ImmortalWrt 25.12.

============================================================
EOF
}

# ============================================================
# Build configuration
# ============================================================

echo
echo "============================================================"
echo "MasterRoc ImageBuilder"
echo "============================================================"
echo "Version           : $VERSION"
echo "Target            : $TARGET"
echo "Profile           : $PROFILE"
echo "ImageBuilder URL  : $IMAGEBUILDER_URL"
echo "Network script    : $NETWORK_SCRIPT"
echo "Rootfs part size  : ${ROOTFS_PARTSIZE}MB"
echo "Extra packages    : $EXTRA_PACKAGES"
echo "Install Daede APK : $INSTALL_DAEDE"
echo "Daede repository  : $DAEDE_REPO"
echo "Daede release     : $DAEDE_RELEASE_TAG"
echo "Daede architecture: $DAEDE_ARCH"
echo "============================================================"
echo

# ============================================================
# Main preparation
# ============================================================

download_imagebuilder
extract_imagebuilder
prepare_files
install_daede_apk

cd "$IMAGEBUILDER_DIR"

echo
echo "============================================================"
echo "Final build configuration"
echo "============================================================"
echo "Version           : $VERSION"
echo "Target            : $TARGET"
echo "Profile           : $PROFILE"
echo "Rootfs part size  : ${ROOTFS_PARTSIZE}MB"
echo "Network script    : $NETWORK_SCRIPT"
echo "Extra packages    : $EXTRA_PACKAGES"
echo "Install Daede APK : $INSTALL_DAEDE"
echo "Daede release     : $DAEDE_REPO@$DAEDE_RELEASE_TAG ($DAEDE_ARCH)"
echo "============================================================"

mkdir -p "$OUT_DIR"

echo "extra_packages=$EXTRA_PACKAGES" \
    > "$OUT_DIR/.extra_packages"

echo "imagebuilder_version=$VERSION" \
    > "$OUT_DIR/.imagebuilder_version"

echo "imagebuilder_url=$IMAGEBUILDER_URL" \
    >> "$OUT_DIR/.imagebuilder_version"

echo "network_script=$NETWORK_SCRIPT" \
    > "$OUT_DIR/.network_script"

# ============================================================
# Show selected files before build
# ============================================================

echo
echo "============================================================"
echo "Checking uci-defaults before build"
echo "============================================================"

if [ -d "files/etc/uci-defaults" ]; then
    find files/etc/uci-defaults \
        -maxdepth 1 \
        -type f \
        -printf '%M %f\n' \
        | sort
else
    echo "No files/etc/uci-defaults directory."
fi

echo "============================================================"

# ============================================================
# Check Daede APK
# ============================================================

case "$INSTALL_DAEDE" in
    1|true|yes)
        echo
        echo "Checking local ImageBuilder packages for Daede..."

        if ! find packages \
            -maxdepth 1 \
            -type f \
            -name 'luci-app-daede-*.apk' \
            -print \
            | grep -q .; then

            echo "ERROR: luci-app-daede APK was requested but was not found."
            echo
            echo "Current packages directory:"
            ls -lah packages || true
            exit 1
        fi

        find packages \
            -maxdepth 1 \
            -type f \
            -name 'luci-app-daede-*.apk' \
            -print
        ;;
esac

# ============================================================
# Package manifest preflight
# ============================================================

if [ "$PREFLIGHT" = "1" ] || [ "$PREFLIGHT" = "true" ]; then

    echo
    echo "============================================================"
    echo "Running package manifest preflight..."
    echo "============================================================"

    if ! make manifest \
        PROFILE="$PROFILE" \
        PACKAGES="$EXTRA_PACKAGES"; then

        diagnose_failure
        exit 1
    fi
fi

# ============================================================
# Slim image formats
#
# Keep:
#   squashfs combined EFI img.gz
#   qcow2
#   vmdk
# ============================================================

echo
echo "============================================================"
echo "Configuring image formats"
echo "============================================================"

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

echo
echo "============================================================"
echo "Building firmware..."
echo "============================================================"

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

echo
echo "============================================================"
echo "Renaming output files"
echo "============================================================"

cd "$OUT_DIR"

for f in *-squashfs-combined-efi.img.gz; do
    [ -f "$f" ] || continue
    mv "$f" daede-squashfs-efi.img.gz
done

for f in *-squashfs-combined-efi.qcow2; do
    [ -f "$f" ] || continue
    mv "$f" daede-squashfs-efi.qcow2
done

for f in *-squashfs-combined-efi.vmdk; do
    [ -f "$f" ] || continue
    mv "$f" daede-squashfs-efi.vmdk
done

for f in *-kernel.bin; do
    [ -f "$f" ] || continue
    mv "$f" daede-kernel.bin
done

for f in *-rootfs.tar.gz; do
    [ -f "$f" ] || continue
    mv "$f" daede-rootfs.tar.gz
done

for f in *.manifest; do
    [ -f "$f" ] || continue
    mv "$f" daede.manifest
done

for f in *.bom.cdx.json; do
    [ -f "$f" ] || continue
    mv "$f" daede.bom.cdx.json
done

# ============================================================
# SHA256
# ============================================================

echo
echo "Generating SHA256..."

rm -f sha256sums

for f in \
    *.img.gz \
    *.qcow2 \
    *.vmdk \
    *.bin \
    *.tar.gz \
    *.manifest \
    *.bom.cdx.json
do
    [ -f "$f" ] || continue
    sha256sum "$f"
done > sha256sums

# ============================================================
# Build manifest
# ============================================================

BUILD_DATE="$(TZ='Asia/Shanghai' date '+%F %H:%M CST')"

cat > BUILD-MANIFEST.txt <<BODYEOF
## daede 固件 · ${EXTRA_IMAGE_NAME}

基于 ImmortalWrt ${VERSION}，x86-64 通用镜像，squashfs-only。

### 网络初始化

- 脚本：${NETWORK_SCRIPT}

### 推荐下载

| 格式 | 适用场景 | 文件 |
|------|----------|------|
| **img.gz** | 物理机 dd 写盘 / PVE 导入 | daede-squashfs-efi.img.gz |
| **qcow2** | QEMU / Proxmox VE | daede-squashfs-efi.qcow2 |
| **vmdk** | VMware ESXi / Workstation | daede-squashfs-efi.vmdk |

> 额外：\`daede-rootfs.tar.gz\` 裸文件系统，可用于 LXC 容器转换。

### 镜像详情

- **ImmortalWrt**：${VERSION}
- **Target**：${TARGET}
- **Profile**：${PROFILE}
- **系统类型**：squashfs（只读根 + overlay 可写层）
- **分区**：combined（含分区表 + 引导）
- **启动**：EFI
- **根分区大小**：${ROOTFS_PARTSIZE} MB
- **构建日期**：${BUILD_DATE}
- **ImageBuilder**：${IMAGEBUILDER_URL}

### Daede

- **安装 luci-app-daede**：${INSTALL_DAEDE}
- **Daede Release**：${DAEDE_REPO}@${DAEDE_RELEASE_TAG}
- **架构**：${DAEDE_ARCH}

### 预装软件

\`$(cat "$OUT_DIR/.extra_packages" 2>/dev/null || echo "$EXTRA_PACKAGES")\`

### 校验

\`\`\`bash
sha256sum -c sha256sums --ignore-missing
\`\`\`
BODYEOF

# ============================================================
# Final information
# ============================================================

echo
echo "============================================================"
echo "BUILD SUCCESS"
echo "============================================================"
echo "ImmortalWrt version : $VERSION"
echo "Target              : $TARGET"
echo "Profile             : $PROFILE"
echo "Network script      : $NETWORK_SCRIPT"
echo "Rootfs part size    : ${ROOTFS_PARTSIZE}MB"
echo "Install Daede       : $INSTALL_DAEDE"
echo
echo "Output directory:"
echo "$OUT_DIR"
echo
ls -lah "$OUT_DIR"

echo
echo "============================================================"
echo "SHA256"
echo "============================================================"

cat "$OUT_DIR/sha256sums"

echo
echo "============================================================"
echo "uci-defaults used by this build"
echo "============================================================"

if [ -d "$IMAGEBUILDER_DIR/files/etc/uci-defaults" ]; then
    find "$IMAGEBUILDER_DIR/files/etc/uci-defaults" \
        -maxdepth 1 \
        -type f \
        -printf '%M %f\n' \
        | sort
fi

echo
echo "Build completed successfully."
