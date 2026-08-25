#!/usr/bin/env bash
# 下载并使用 ImmortalWrt ImageBuilder 构建仅针对 x86-64 EFI 的镜像（简洁版）
# - 只匹配 x86-64 EFI/UEFI 的 ImageBuilder release asset
# - 保留并允许覆盖默认 EXTRA_PACKAGES 与 ROOTFS_PARTSIZE
# - 可通过环境变量 IMAGEBUILDER_URL 或 PROFILE 等控制行为
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# ---------- 可由环境覆盖的默认值（保留你指定的默认包与分区大小） ----------
: "${GITHUB_REPO:=immortalwrt/immortalwrt}" 
: "${IMAGEBUILDER_URL:=}"   # 若已知可直接设置以跳过自动解析
# 匹配 x86-64 且包含 efi/uefi 的 ImageBuilder asset（不匹配其它架构）
: "${IMAGEBUILDER_FILTER:=ImageBuilder.*(x86[_-]?64|x86-64).*(efi|uefi).*\.tar\.(xz|gz)$}"
: "${EXTRA_PACKAGES:=luci luci-i18n-base-zh-cn openssh-sftp-server luci-i18n-ddns-zh-cn luci-theme-argon luci-i18n-ttyd-zh-cn luci-i18n-firewall-zh-cn luci-i18n-package-manager-zh-cn kmod-sched-core kmod-sched-bpf kmod-veth kmod-xdp-sockets-diag curl nano}"
: "${EXTRA_PACKAGES_EXTRA:=}"    # 额外追加包
: "${ROOTFS_PARTSIZE:=4096}"
: "${PROFILE:=}"                  # ImageBuilder 中的 PROFILE（可不设置，使用 imagebuilder 默认）
: "${OUTPUT_DIR:=$ROOT/output}"
: "${WORKDIR:=$(mktemp -d)}"
: "${CURL:=curl}"                 # 可替换为 wget wrapper
: "${QUIET:=0}"                   # 1 = 精简日志输出

PACKAGES="${EXTRA_PACKAGES} ${EXTRA_PACKAGES_EXTRA}"

usage() {
  cat <<EOF
Usage: PROFILE=<profile> $0
Environment examples:
  IMAGEBUILDER_URL=...         # 指定完整下载 URL，优先
  PROFILE=xxx                  # ImageBuilder 的目标 profile（可选）
  EXTRA_PACKAGES_EXTRA='vim'   # 追加包
  ROOTFS_PARTSIZE=8192         # 覆盖 rootfs 分区大小
EOF
  exit 1
}

log() { [ "$QUIET" -eq 0 ] && printf '%s\n' "$*"; }

cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

# 如果未指定 IMAGEBUILDER_URL，则从 GitHub latest release 中取匹配 asset
if [ -z "$IMAGEBUILDER_URL" ]; then
  log "查找 $GITHUB_REPO 最新 release 中匹配 x86-64 EFI 的 ImageBuilder..."
  api="https://api.github.com/repos/${GITHUB_REPO}/releases/latest"
  data="$($CURL -sL "$api")" || { log "无法访问 GitHub API"; exit 1; }

  # 提取所有 browser_download_url 并根据 IMAGEBUILDER_FILTER 筛选（不依赖 jq）
  urls=$(printf '%s\n' "$data" | grep -Eo '"browser_download_url":\s*"[^"]+"' | sed -E 's/.*"([^"]+)".*/\1/')
  IMAGEBUILDER_URL=$(printf '%s\n' "$urls" | grep -iE "$IMAGEBUILDER_FILTER" | head -n1 || true)

  if [ -z "$IMAGEBUILDER_URL" ]; then
    log "未在最新 release 的 assets 中找到符合条件的 ImageBuilder。候选 assets（前 30 行）:"
    printf '%s\n' "$urls" | sed -n '1,30p'
    log "你可以手动设置 IMAGEBUILDER_URL 指向 x86-64 EFI 的 ImageBuilder。"
    exit 1
  fi
  log "找到 ImageBuilder: $IMAGEBUILDER_URL"
else
  log "使用用户指定的 IMAGEBUILDER_URL: $IMAGEBUILDER_URL"
fi

# 下载 ImageBuilder
dl="$WORKDIR/$(basename "$IMAGEBUILDER_URL")"
log "下载到：$dl"
$CURL -L --fail -o "$dl" "$IMAGEBUILDER_URL"

# 解压支持 xz/gz/tgz/zip
case "$dl" in
  *.tar.xz)  tar -xJf "$dl" -C "$WORKDIR" ;;
  *.tar.gz|*.tgz) tar -xzf "$dl" -C "$WORKDIR" ;;
  *.zip) unzip -q "$dl" -d "$WORKDIR" ;;
  *) tar -xf "$dl" -C "$WORKDIR" ;;
esac

# 查找解压后的 ImageBuilder 目录（通常名为 ImageBuilder-* 或 包含 Makefile）
IMGDIR=$(find "$WORKDIR" -maxdepth 2 -type d -name 'ImageBuilder*' -print -quit || true)
if [ -z "$IMGDIR" ]; then
  IMGDIR=$(find "$WORKDIR" -maxdepth 3 -type f -name 'Makefile' -printf '%h\n' | head -n1 || true)
fi
if [ -z "$IMGDIR" ]; then
  log "未找到 ImageBuilder 目录，请检查解压内容：$WORKDIR"
  exit 1
fi
log "使用 ImageBuilder 目录: $IMGDIR"

cd "$IMGDIR"

# 可选清理（ImageBuilder 内部）
# make clean 在 imagebuilder 中并非总是必需且有时无此目标，谨慎调用
if [ "${CLEAN:-0}" -ne 0 ]; then
  log "运行 make clean (忽略错误)..."
  make clean || true
fi

# 构建参数
MAKE_ARGS=(PACKAGES="$PACKAGES" ROOTFS_PARTSIZE="$ROOTFS_PARTSIZE")
if [ -n "$PROFILE" ]; then
  MAKE_ARGS+=(PROFILE="$PROFILE")
fi

mkdir -p "$OUTPUT_DIR"
log "开始构建（针对 x86-64 EFI）:"
log "  PROFILE=${PROFILE:-<imagebuilder 默认>}"
log "  ROOTFS_PARTSIZE=$ROOTFS_PARTSIZE"
log "  PACKAGES=$PACKAGES"
log

# 运行 make image
set -x
make image "${MAKE_ARGS[@]}"
set +x

# 收集输出到 OUTPUT_DIR（ImageBuilder 通常输出在 bin/targets 下）
log "收集输出到 $OUTPUT_DIR"
find bin -type f \( -name '*.efi' -o -name '*.img' -o -name '*.bin' -o -name '*.tar.gz' -o -name '*.iso' -o -name '*.rootfs*' \) -maxdepth 4 -print0 \
  | while IFS= read -r -d '' f; do
      cp -a "$f" "$OUTPUT_DIR"/
      log " -> $(basename "$f")"
    done

log "完成。输出目录：$OUTPUT_DIR"
exit 0
