#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# ImmortalWrt ImageBuilder 自动构建脚本
###############################################################################

# 官方下载站
BASE_URL="${BASE_URL:-https://downloads.immortalwrt.org}"

# 目标平台
TARGET="${TARGET:-x86/64}"

# Profile
PROFILE="${PROFILE:-generic}"

# ROOTFS 分区大小，单位 MB
ROOTFS_PARTSIZE="${ROOTFS_PARTSIZE:-4096}"

# 如果手动指定 VERSION，则使用指定版本
# 留空则自动获取官方最新正式版本
VERSION="${VERSION:-}"

# 如果手动指定 IMAGEBUILDER_URL，则直接使用
# 留空则自动生成官方 ImageBuilder 地址
IMAGEBUILDER_URL="${IMAGEBUILDER_URL:-}"

# 工作目录
WORKDIR="${WORKDIR:-$(pwd)}"

# curl
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
# 检查基础依赖
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

    # zstd 解压工具
    if ! command -v unzstd >/dev/null 2>&1; then
        if ! command -v zstd >/dev/null 2>&1; then
            die "缺少 zstd/unzstd，请先安装 zstd"
        fi
    fi

    log "依赖检查完成"
}

###############################################################################
# 获取 ImmortalWrt 官方最新正式版本
###############################################################################

get_latest_version() {

    if [ -n "$VERSION" ]; then
        log "使用指定 ImmortalWrt 版本：$VERSION"
        return 0
    fi

    log "正在获取 ImmortalWrt 官方最新正式版本..."

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
    )" || die "无法访问 ImmortalWrt 官方下载站"

    VERSION="$(
        printf '%s\n' "$data" |
        grep -Eo 'href="[0-9]+\.[0-9]+\.[0-9]+/"' |
        sed -E 's/href="([0-9]+\.[0-9]+\.[0-9]+)/\1/' |
        sort -V |
        tail -n 1
    )"

    if [ -z "$VERSION" ]; then
        die "无法获取 ImmortalWrt 最新正式版本"
    fi

    log "最新 ImmortalWrt 正式版本：$VERSION"
}

###############################################################################
# 自动生成 ImageBuilder URL
###############################################################################

get_imagebuilder_url() {

    # 用户手动指定 URL
    if [ -n "$IMAGEBUILDER_URL" ]; then
        log "使用手动指定的 IMAGEBUILDER_URL"
        return 0
    fi

    # 自动获取版本
    get_latest_version

    IMAGEBUILDER_URL="${BASE_URL}/releases/${VERSION}/targets/x86/64/immortalwrt-imagebuilder-${VERSION}-x86-64.Linux-x86_64.tar.zst"

    log "自动生成 ImageBuilder URL："
    log "$IMAGEBUILDER_URL"
}

###############################################################################
# 检查 ImageBuilder
###############################################################################

check_imagebuilder_url() {

    log "检查 ImageBuilder 地址..."

    if ! "$CURL" \
        -fsSI \
        --retry 3 \
        --connect-timeout 15 \
        --max-time 60 \
        "$IMAGEBUILDER_URL" >/dev/null 2>&1; then

        die "ImageBuilder 不存在或无法访问：$IMAGEBUILDER_URL"
    fi

    log "ImageBuilder 地址检查通过"
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

    IMAGEBUILDER_ARCHIVE="$WORKDIR/$filename"

    log "ImageBuilder 文件：$filename"

    if [ -s "$IMAGEBUILDER_ARCHIVE" ]; then
        log "检测到已有 ImageBuilder，跳过下载"
    else
        log "开始下载 ImageBuilder..."

        "$CURL" \
            -fL \
            --retry 5 \
            --retry-delay 3 \
            --connect-timeout 30 \
            --max-time 1800 \
            -o "$IMAGEBUILDER_ARCHIVE" \
            "$IMAGEBUILDER_URL" || die "ImageBuilder 下载失败"
    fi

    if [ ! -s "$IMAGEBUILDER_ARCHIVE" ]; then
        die "ImageBuilder 文件不存在或为空"
    fi

    log "ImageBuilder 下载完成"
}

###############################################################################
# 解压 ImageBuilder
###############################################################################

extract_imagebuilder() {

    log "开始解压 ImageBuilder..."

    rm -rf "$WORKDIR/imagebuilder"

    mkdir -p "$WORKDIR/imagebuilder"

    if command -v unzstd >/dev/null 2>&1; then

        tar \
            --use-compress-program=unzstd \
            -xf "$IMAGEBUILDER_ARCHIVE" \
            -C "$WORKDIR/imagebuilder" \
            --strip-components=1

    else

        tar \
            --use-compress-program=zstd \
            -xf "$IMAGEBUILDER_ARCHIVE" \
            -C "$WORKDIR/imagebuilder" \
            --strip-components=1

    fi

    if [ ! -f "$WORKDIR/imagebuilder/Makefile" ]; then
        die "ImageBuilder 解压失败：找不到 Makefile"
    fi

    log "ImageBuilder 解压完成"
}

###############################################################################
# 显示构建信息
###############################################################################

show_build_info() {

    echo
    echo "============================================================"
    echo " ImmortalWrt ImageBuilder"
    echo "============================================================"
    echo " Version         : $VERSION"
    echo " Target          : $TARGET"
    echo " Profile         : $PROFILE"
    echo " ROOTFS_PARTSIZE : $ROOTFS_PARTSIZE MB"
    echo " ImageBuilder    : $IMAGEBUILDER_URL"
    echo "============================================================"
    echo " Extra Packages:"
    echo "$EXTRA_PACKAGES"
    echo "============================================================"
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

    log "ImmortalWrt 固件构建完成"
}

###############################################################################
# 显示输出文件
###############################################################################

show_output() {

    cd "$WORKDIR/imagebuilder"

    echo
    echo "============================================================"
    echo " 构建完成，生成文件："
    echo "============================================================"

    if [ -d "bin/targets" ]; then

        find bin/targets \
            -type f \
            -print |
            sort

    else

        warn "没有找到 bin/targets 输出目录"

    fi

    echo "============================================================"
}

###############################################################################
# 主程序
###############################################################################

main() {

    log "开始 ImmortalWrt ImageBuilder 构建"

    check_dependencies

    prepare_workdir

    get_imagebuilder_url

    check_imagebuilder_url

    download_imagebuilder

    extract_imagebuilder

    show_build_info

    build_image

    show_output

    log "全部任务完成"
}

main "$@"