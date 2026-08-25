name: Build daede image

on:
  workflow_dispatch:
    inputs:

      publish_release:
        description: 把生成的固件发布到 GitHub Release
        required: true
        default: "true"
        type: choice
        options:
          - "true"
          - "false"

      imagebuilder_url:
        description: ImmortalWrt ImageBuilder 下载地址
        required: true
        default: "https://downloads.immortalwrt.org/releases/25.12.1/targets/x86/64/immortalwrt-imagebuilder-25.12.1-x86-64.Linux-x86_64.tar.zst"

      preflight:
        description: 构建前先检查软件包清单是否齐全
        required: true
        default: "true"
        type: choice
        options:
          - "true"
          - "false"

      rootfs_partsize:
        description: 根文件系统分区大小（MB）
        required: true
        default: "4096"

      install_daede:
        description: 把 luci-app-daede 打进固件
        required: true
        default: "true"
        type: choice
        options:
          - "true"
          - "false"

      daede_release_tag:
        description: luci-app-daede 的 Release 版本
        required: true
        default: "latest"

      daede_apk_url:
        description: 可选，直接指定 luci-app-daede APK 下载地址
        required: false
        default: ""

permissions:
  contents: write

jobs:
  build:
    name: Build ImmortalWrt x86-64
    runs-on: ubuntu-22.04
    timeout-minutes: 60

    steps:

      # ======================================================
      # Checkout
      # ======================================================

      - name: Checkout
        uses: actions/checkout@v6

      # ======================================================
      # Install dependencies
      # ======================================================

      - name: Install host dependencies
        run: |
          set -e

          sudo apt-get update

          sudo apt-get install -y \
            build-essential \
            clang \
            flex \
            bison \
            gawk \
            gettext \
            git \
            libncurses-dev \
            libssl-dev \
            python3 \
            rsync \
            unzip \
            zstd \
            file \
            wget \
            curl \
            qemu-utils \
            genisoimage

      # ======================================================
      # Verify repository files
      # ======================================================

      - name: Verify repository files
        run: |
          set -e

          echo "========================================"
          echo "Checking repository"
          echo "========================================"

          echo
          echo "build-image.sh:"
          test -f scripts/build-image.sh

          echo
          echo "99-custom.sh:"
          test -f files/etc/uci-defaults/99-custom.sh

          echo
          echo "Making scripts executable..."
          chmod +x scripts/build-image.sh
          chmod +x files/etc/uci-defaults/99-custom.sh

          echo
          echo "Checking shell syntax..."
          bash -n scripts/build-image.sh

          if command -v shellcheck >/dev/null 2>&1; then
            shellcheck files/etc/uci-defaults/99-custom.sh || true
          fi

          echo
          echo "Repository files:"
          find files/etc/uci-defaults \
            -maxdepth 1 \
            -type f \
            -printf '%M %p\n' \
            | sort

      # ======================================================
      # Show configuration
      # ======================================================

      - name: Show build configuration
        env:
          IMAGEBUILDER_URL: ${{ inputs.imagebuilder_url }}
          PREFLIGHT: ${{ inputs.preflight }}
          ROOTFS_PARTSIZE: ${{ inputs.rootfs_partsize }}
          INSTALL_DAEDE: ${{ inputs.install_daede }}
          DAEDE_RELEASE_TAG: ${{ inputs.daede_release_tag }}
          DAEDE_APK_URL: ${{ inputs.daede_apk_url }}
        run: |
          echo "========================================"
          echo "Build configuration"
          echo "========================================"

          echo "ImageBuilder URL : $IMAGEBUILDER_URL"
          echo "Network script   : 99-custom.sh"
          echo "Preflight        : $PREFLIGHT"
          echo "Rootfs size      : ${ROOTFS_PARTSIZE}MB"
          echo "Install Daede    : $INSTALL_DAEDE"
          echo "Daede release    : $DAEDE_RELEASE_TAG"

          if [ -n "$DAEDE_APK_URL" ]; then
            echo "Daede APK URL    : custom"
          else
            echo "Daede APK URL    : automatic"
          fi

          echo "========================================"

      # ======================================================
      # Build
      # ======================================================

      - name: Build image
        env:
          IMAGEBUILDER_URL: ${{ inputs.imagebuilder_url }}

          # build-image.sh already forces:
          # NETWORK_SCRIPT="99-custom.sh"
          #
          # Do NOT pass inputs.network_script here.

          PREFLIGHT: ${{ inputs.preflight }}
          ROOTFS_PARTSIZE: ${{ inputs.rootfs_partsize }}
          INSTALL_DAEDE: ${{ inputs.install_daede }}
          DAEDE_RELEASE_TAG: ${{ inputs.daede_release_tag }}
          DAEDE_APK_URL: ${{ inputs.daede_apk_url }}

          GITHUB_TOKEN: ${{ github.token }}

          OUT_DIR: ${{ github.workspace }}/out
          WORK_DIR: ${{ github.workspace }}/work

        run: |
          set -e

          chmod +x scripts/build-image.sh

          ./scripts/build-image.sh

      # ======================================================
      # Verify output
      # ======================================================

      - name: Verify build output
        run: |
          set -e

          echo "========================================"
          echo "Checking build output"
          echo "========================================"

          test -d out

          echo
          echo "Output files:"
          ls -lah out

          echo
          echo "Required manifest:"
          test -s out/BUILD-MANIFEST.txt

          echo
          echo "SHA256:"
          test -s out/sha256sums

          cat out/sha256sums

          echo
          echo "Checking firmware files..."

          found=0

          for file in \
            out/daede-squashfs-efi.img.gz \
            out/daede-squashfs-efi.qcow2 \
            out/daede-squashfs-efi.vmdk
          do
            if [ -f "$file" ]; then
              echo "FOUND: $file"
              found=1
            fi
          done

          if [ "$found" -ne 1 ]; then
            echo "ERROR: No firmware image was generated."
            exit 1
          fi

          echo
          echo "Build output verification passed."

      # ======================================================
      # Upload artifact
      # ======================================================

      - name: Upload firmware artifact
        uses: actions/upload-artifact@v7
        with:
          name: immortalwrt-daede-x86-64
          path: out/*
          if-no-files-found: error
          retention-days: 30

      # ======================================================
      # Publish GitHub Release
      # ======================================================

      - name: Publish release
        if: inputs.publish_release == 'true'
        uses: ncipollo/release-action@v1
        with:
          tag: daede-${{ github.run_number }}
          name: daede 固件 ${{ github.run_number }}
          artifacts: out/*
          allowUpdates: true
          replacesArtifacts: true
          bodyFile: out/BUILD-MANIFEST.txt
