#!/bin/sh
# Buildroot post-build script: puts the LightOS stage 1 tree (out/stage1.tar
# from tools/build_initramfs.sh: the static busybox in /lightos/bin and
# /lightos/init) into the root file system, so both stages run the same
# script with the same tools, and marks the tree as stage 2.
set -e
target=$1
stage1=$BR2_EXTERNAL_LIGHTOS_PATH/../out/stage1.tar
[ -f "$stage1" ] || { echo "No $stage1: run tools/build_initramfs.sh first" >&2; exit 1; }
rm -rf "$target/lightos"
tar -xf "$stage1" -C "$target"
mkdir -p "$target/flash"
# slot writes /data/slot-card.log and /data/slot-repair.result; the root is
# read-only, so /data is a link to a folder init makes in /tmp.
ln -sfn /tmp/data "$target/data"
echo "LightOS stage 2: Buildroot root file system (version in /etc/os-release)" > "$target/lightos/stage2"
