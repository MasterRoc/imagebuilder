#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# ImmortalWrt ImageBuilder 自动构建脚本
#
# 功能：
#   1. 自动检测 ImmortalWrt 官方最新正式版
#   2. 自动生成 x86/64 ImageBuilder 下载地址
#   3. 使用 generic EFI profile
#   4. ROOTFS_PARTSIZE 默认 4096 MB
#   5. 保留原有 EXTRA_PACKAGES，不删除任何依赖
#   6. 支持 IMAGEBUILDER_URL 手动指定
###############################################################################

###############################################################################
# 基础配置
###############################################################################

BASE_URL="${BASE_URL:-https://downloads.immortalwrt.org}"

TARGET="${TARGET:-x86/64}"

PROFILE="${PROFILE:-generic}"

ROOTFS_PARTSIZE="${ROOTFS_PARTSIZE:-4096}"

# ImmortalWrt 官方最新正式版
VERSION="${VERSION:-}"

# 如果为空，则自动从官方 releases 获取最新正式版本
IMAGEBUILDER_URL="${IMAGEBUILDER_URL:-}"

# 工作目录
WORKDIR="${WORKDIR:-$(pwd)}"

# 下载工具
CURL="${CURL:-curl}"

###############################################################################
# 保留原有依赖，不删除
###############################################################################

EXTRA_PACKAGES="${EXTRA_PACKAGES:-luci luci-i18n-base-zh-cn openssh-sftp-server luci-i18n-ddns-zh-cn luci-theme-argon luci-i18n-ttyd-zh-cn luci-i18n-firewall-zh-cn luci-i18n-package-manager-zh-cn kmod-sched-core kmod-sched-bpf kmod-veth kmod-xdp-sockets-diag curl nano}"

###############################################################################
# 日志
###############################################################################

log() {
    echo "[INFO] $*"
}

warn() {
    echo "[WARN] $*" >&2
}

error() {
    echo "[ERROR] $*" >&2
}

die() {
    error "$*"
    exit 1
}

###############################################################################
# 检查依赖
###############################################################################

check_dependencies() {
    local deps=(
        curl
        grep
        sed
        sort
        tail
        head
        tar
    )

    for cmd in "${deps[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            die "缺少依赖：$cmd"
        fi
    done

    log "依赖检查完成"
}

###############################################################################
# 获取 ImmortalWrt 最新正式版本
#
# 官方：
# https://downloads.immortalwrt.org/releases/
#
# 只匹配：
#   25.12.1
#   25.12.0
#   24.10.6
#
# 不匹配：
#   snapshots
#   25.12-SNAPSHOT
#   24.10-SNAPSHOT
###############################################################################

get_latest_version() {

    if [ -n "$VERSION" ]; then
        log "使用指定 ImmortalWrt 版本：$VERSION"
        return 0
    fi

    log "正在从 ImmortalWrt 官方下载站获取最新正式版本..."

    local releases_url
    releases_url="${BASE_URL}/releases/"

    local data

    data="$(
        "$CURL" \
            -fsSL \
            --retry 3 \
            --connect-timeout 15 \
            --max-time 60 \
            "$releases_url"
    )" || die "无法访问 ImmortalWrt 官方下载站：$releases_url"

    VERSION="$(
        printf '%s\n' "$data" |
        grep -Eo 'href="[0-9]+\.[0-9]+\.[0-9]+/"' |
        sed -E 's/href="([0-9]+\.[0-9]+\.[0-9]+)/\1/' |
        sort -V |
        tail -n1
    )"

    if [ -z "$VERSION" ]; then
        die "无法从 ImmortalWrt 官方下载站获取最新正式版本"
    fi

    log "检测到最新 ImmortalWrt 正式版本：$VERSION"
}

###############################################################################
# 生成 ImageBuilder URL
###############################################################################

get_imagebuilder_url() {

    if [ -n "$IMAGEBUILDER_URL" ]; then
        log "使用手动指定的 IMAGEBUILDER_URL"
        return 0
    fi

    get_latest_version

    IMAGEBUILDER_URL="${BASE_URL}/releases/${VERSION}/targets/x86/64/immortalwrt-imagebuilder-${VERSION}-x86-64.Linux-x86_64.tar.zst"

    log "自动生成 ImageBuilder URL："
    log "$IMAGEBUILDER_URL"
}

###############################################################################
# 检查 ImageBuilder URL
###############################################################################

check_imagebuilder_url() {

    log "检查 ImageBuilder 是否存在..."

    if ! "$CURL" \
        -fsSI \
        --retry 3 \
        --connect-timeout 15 \
        --max-time 60 \
        "$IMAGEBUILDER_URL" >/dev/null; then

        die "ImageBuilder 不存在或无法访问：$IMAGEBUILDER_URL"
    fi

    log "ImageBuilder URL 检查通过"
}

###############################################################################
# 创建工作目录
###############################################################################

prepare_workdir() {

    mkdir -p "$WORKDIR"

    cd "$WORKDIR"

    log "工作目录：$WORKDIR"
}

###############################################################################
# 下载 ImageBuilder
###############################################################################

download_imagebuilder() {

    local filename

    filename="$(basename "$IMAGEBUILDER_URL")"

    log "ImageBuilder 文件：$filename"

    if [ -f "$filename" ]; then
        log "检测到已有 ImageBuilder，跳过下载"
    else
        log "开始下载 ImageBuilder..."

        "$CURL" \
            -fL \
            --retry 5 \
            --retry-delay 3 \
            --connect-timeout 30 \
            --max-time 1800 \
            -o "$filename" \
            "$IMAGEBUILDER_URL" ||
            die "ImageBuilder 下载失败"
    fi

    if [ ! -s "$filename" ]; then
        die "ImageBuilder 文件为空：$filename"
    fi

    IMAGEBUILDER_ARCHIVE="$filename"

    log "ImageBuilder 下载完成"
}

###############################################################################
# 解压 ImageBuilder
###############################################################################

extract_imagebuilder() {

    log "解压 ImageBuilder..."

    rm -rf imagebuilder

    mkdir -p imagebuilder

    tar \
        --use-compress-program=unzstd \
        -xf "$IMAGEBUILDER_ARCHIVE" \
        -C imagebuilder \
        --strip-components=1

    if [ ! -f "imagebuilder/Makefile" ]; then
        die "ImageBuilder 解压失败：找不到 Makefile"
    fi

    log "ImageBuilder 解压完成"
}

###############################################################################
# 显示版本信息
###############################################################################

show_build_info() {

    echo
    echo "=============================================="
    echo " ImmortalWrt ImageBuilder"
    echo "=============================================="
    echo " Version        : $VERSION"
    echo " Target         : $TARGET"
    echo " Profile        : $PROFILE"
    echo " ROOTFS_PARTSIZE: $ROOTFS_PARTSIZE"
    echo " ImageBuilder   : $IMAGEBUILDER_URL"
    echo "=============================================="
    echo " Extra Packages :"
    echo "$EXTRA_PACKAGES"
    echo "=============================================="
    echo
}

###############################################################################
# 构建固件
###############################################################################

build_image() {

    cd "$WORKDIR/imagebuilder"

    log "开始构建 ImmortalWrt 固件..."

    make image \
        PROFILE="$PROFILE" \
        ROOTFS_PARTSIZE="$ROOTFS_PARTSIZE" \
        PACKAGES="$EXTRA_PACKAGES"

    log "固件构建完成"
}

###############################################################################
# 查找输出文件
###############################################################################

show_output() {

    cd "$WORKDIR/imagebuilder"

    echo
    echo "=============================================="
    echo " 构建完成"
    echo "=============================================="

    if [ -d "bin/targets" ]; then
        find bin/targets \
            -maxdepth 3 \
            -type f \
            -printf '%p\n' |
            sort
    else
        warn "没有找到 bin/targets 输出目录"
    fi

    echo "=============================================="
}

###############################################################################
# 主程序
###############################################################################

main() {

    log "开始 ImmortalWrt ImageBuilder 构建"

    check_dependencies

    prepare_workdir

    get_imagebuilder_url

    # 如果用户手动指定 IMAGEBUILDER_URL，
    # 仍然尝试从 URL 中提取版本号
    if [ -z "$VERSION" ]; then
        VERSION="$(
            printf '%s\n' "$IMAGEBUILDER_URL" |
            grep -Eo 'immortalwrt-imagebuilder-[0-9]+\.[0-9]+\.[0-9]+' |
            sed 's/immortalwrt-imagebuilder-//' |
            head -n1 ||
            true
        )
    fi

    check_imagebuilder_url

    download_imagebuilder

    extract_imagebuilder

    show_build_info

    build_image

    show_output

    log "全部任务完成"
}

main "$@"