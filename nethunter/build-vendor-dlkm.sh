#!/usr/bin/env bash
# =============================================================================
# Build a drop-in replacement for oscar's vendor_dlkm partition.
#
#   bash nethunter/build-vendor-dlkm.sh <module-dir> <out.img> <release> [System.map]
#
# WHY THIS EXISTS
#
# /vendor/lib/modules on this phone is not a directory. It is a 24-byte symlink:
#     lrw-r--r-- 1 root root 24 /vendor/lib/modules -> /vendor_dlkm/lib/modules
# and /vendor_dlkm is a separate read-only erofs logical partition:
#     /dev/block/dm-5 /vendor_dlkm erofs ro,seclabel,relatime
#
# Magisk overlays /system and /vendor. It does not map /vendor_dlkm, and it
# cannot write through a symlink into a read-only filesystem. So every module
# the old packaging pushed to
#     /data/adb/modules/ak3-helper/system/vendor/lib/modules/
# landed on a path the kernel never reads. All 39 stock modules kept loading,
# and MODVERSIONS refused them because our task_struct differs. Camera, Wi-Fi,
# Bluetooth, audio and cellular all die together. Replacing the partition is
# the only delivery mechanism that actually reaches the loader.
#
# THE SIZE TRICK
#
# AnyKernel3's flash_generic() does this:
#     imgsz=$(wc -c < $img)
#     if [ "$imgsz" != "$(wc -c < $imgblock)" ]; then   # lptools surgery
# Every dangerous path in that function - lptools_static remove / create /
# unmap / map / replace, snapshotupdater, resizing a live logical partition on
# a virtual-A/B device - hangs off that one inequality. Pad the image to the
# exact partition size and the whole branch is skipped; all that is left is
#     blockdev --setrw $imgblock
#     cat $img /dev/zero > $imgblock
# which is a plain in-place write. Hence PART_SIZE below, and hence the hard
# failure if the image does not fit.
#
# 20960 sectors * 512 = 10731520 bytes, from lpdump on the device.
# =============================================================================
set -euo pipefail

MODSRC="${1:?usage: build-vendor-dlkm.sh <module-dir> <out.img> <release> [System.map]}"
OUTIMG="${2:?missing output image path}"
REL="${3:?missing kernel release string}"
SYSMAP="${4:-}"

HERE="$(cd "$(dirname "$0")" && pwd)"
REF="$HERE/vendor_dlkm"
PART_SIZE=10731520

# Reproduce the stock superblock where it is free to do so. Neither of these
# changes behaviour; they just make a diff against the stock image readable.
STOCK_UUID=b78554f6-0fa7-5a25-8089-7c4c24e6d4e8
STOCK_TIME=1230768000

STAGE="$(mktemp -d)"
DEPROOT="$(mktemp -d)"
trap 'rm -rf "$STAGE" "$DEPROOT"' EXIT

# -----------------------------------------------------------------------------
echo "=== 1. stage the 39 device modules ==="
# -----------------------------------------------------------------------------
mkdir -p "$STAGE/lib/modules" "$STAGE/etc"

missing=0
staged=0
while IFS= read -r m; do
  case "$m" in ''|'#'*) continue;; esac
  if [ -f "$MODSRC/$m.ko" ]; then
    cp -f "$MODSRC/$m.ko" "$STAGE/lib/modules/$m.ko"
    staged=$((staged + 1))
  else
    echo "::error::$m.ko was not built - vendor_dlkm would ship without it"
    missing=1
  fi
done < "$REF/stock-manifest.txt"

[ "$missing" = 0 ] || exit 1
if [ "$staged" != 39 ]; then
  echo "::error::staged $staged modules, the device has exactly 39"
  exit 1
fi
echo "  ok      $staged of 39 modules staged"

# -----------------------------------------------------------------------------
echo "=== 2. depmod ==="
# -----------------------------------------------------------------------------
# depmod insists on a lib/modules/<release>/ layout, so it gets its own tree.
# The modules sit FLAT in it on purpose: with no kernel/drivers/... hierarchy
# depmod emits bare filenames, which is the format Android's libmodprobe reads
# from /vendor_dlkm/lib/modules/modules.dep. A modules.dep full of
# "kernel/drivers/..." paths resolves to nothing and every dependent module
# silently fails to load.
mkdir -p "$DEPROOT/lib/modules/$REL"
cp "$STAGE/lib/modules/"*.ko "$DEPROOT/lib/modules/$REL/"

if [ -n "$SYSMAP" ] && [ -f "$SYSMAP" ]; then
  echo "  using System.map: $SYSMAP"
  depmod -b "$DEPROOT" -F "$SYSMAP" "$REL" || true
else
  echo "  no System.map - unresolved-symbol warnings below are expected"
  depmod -b "$DEPROOT" "$REL" || true
fi

for f in modules.dep modules.alias; do
  if [ ! -f "$DEPROOT/lib/modules/$REL/$f" ]; then
    echo "::error::depmod produced no $f"
    exit 1
  fi
  cp "$DEPROOT/lib/modules/$REL/$f" "$STAGE/lib/modules/$f"
done

if grep -q '/' "$STAGE/lib/modules/modules.dep"; then
  echo "::error::modules.dep contains paths, Android expects bare filenames:"
  grep -m 5 '/' "$STAGE/lib/modules/modules.dep"
  exit 1
fi
echo "  ok      modules.dep $(wc -l < "$STAGE/lib/modules/modules.dep") lines, modules.alias $(wc -l < "$STAGE/lib/modules/modules.alias") lines, no paths"

# -----------------------------------------------------------------------------
echo "=== 3. copy the stock metadata verbatim ==="
# -----------------------------------------------------------------------------
# These three are NOT regenerated. modules.load encodes a real load ORDER that
# the audio stack depends on; modules.blocklist is what keeps qca_cld3_wlan out
# of the boot sequence so the Wi-Fi HAL can insmod it after cold-boot
# calibration; modules.softdep pulls bt_fm_slim in before machine_dlkm. An
# alphabetical replacement for any of them breaks boot or breaks Wi-Fi.
cp "$REF/modules.load"      "$STAGE/lib/modules/modules.load"
cp "$REF/modules.softdep"   "$STAGE/lib/modules/modules.softdep"
cp "$REF/modules.blocklist" "$STAGE/lib/modules/modules.blocklist"
cp "$REF/build.prop"        "$STAGE/etc/build.prop"

# Present and empty on the stock partition. Recreated so the file list matches.
: > "$STAGE/etc/fs_config_dirs"
: > "$STAGE/etc/fs_config_files"

# /etc/NOTICE.xml.gz is deliberately NOT reproduced. It is 36693 bytes of
# gzipped licence text read only by Settings > Legal information, nothing in
# the boot path touches it, and dropping it hands back 36 KB of headroom.

while IFS= read -r line; do
  case "$line" in ''|'#'*) continue;; esac
  b="${line%.ko}"
  if [ ! -f "$STAGE/lib/modules/$b.ko" ]; then
    echo "::error::modules.load asks for $line, which is not staged"
    exit 1
  fi
done < "$REF/modules.load"
echo "  ok      every entry in modules.load resolves to a staged module"

# Stock is 0644 for files, 0755 for directories, root:root throughout.
find "$STAGE" -type d -exec chmod 0755 {} +
find "$STAGE" -type f -exec chmod 0644 {} +

echo "  staged payload: $(find "$STAGE" -type f | wc -l) files, $(du -sb "$STAGE" | cut -f1) bytes"

# -----------------------------------------------------------------------------
echo "=== 4. mkfs.erofs ==="
# -----------------------------------------------------------------------------
if ! command -v mkfs.erofs >/dev/null 2>&1; then
  echo "::error::mkfs.erofs is not installed"
  exit 1
fi
mkfs.erofs -V 2>&1 | head -3 || true
HELP="$(mkfs.erofs --help 2>&1 || true)"

if ! printf '%s' "$HELP" | grep -q -- '--file-contexts'; then
  echo "::error::this mkfs.erofs has no --file-contexts; every file would be"
  echo "::error::unlabelled, init could not read the modules, and the phone would"
  echo "::error::boot with no camera, audio, Wi-Fi or Bluetooth."
  exit 1
fi
echo "  ok      --file-contexts is supported"

# LZ4 is not a preference, it is the only legal choice. erofs on Linux 5.4
# supports LZ4 only; LZMA needs 5.16, DEFLATE 6.6, zstd 6.10. An image built
# with any of those mounts on the build host and fails on the phone.
BASE="-zlz4hc --all-root --file-contexts=$REF/file_contexts"
EXTRA="-U $STOCK_UUID -T $STOCK_TIME"

rm -f "$OUTIMG"
if mkfs.erofs $BASE $EXTRA "$OUTIMG" "$STAGE"; then
  echo "  ok      built with the stock UUID and timestamp"
else
  echo "  note    -U/-T rejected by this build, retrying without them"
  rm -f "$OUTIMG"
  mkfs.erofs $BASE "$OUTIMG" "$STAGE"
fi

# -----------------------------------------------------------------------------
echo "=== 5. size and padding ==="
# -----------------------------------------------------------------------------
sz=$(stat -c %s "$OUTIMG")
echo "  filesystem : $sz bytes"
echo "  partition  : $PART_SIZE bytes"
if [ "$sz" -gt "$PART_SIZE" ]; then
  echo "::error::the image is $((sz - PART_SIZE)) bytes too large for vendor_dlkm."
  echo "::error::Do NOT work around this by letting AnyKernel3 resize the logical"
  echo "::error::partition - shrink the payload instead (start with the DVB tuners)."
  exit 1
fi
truncate -s "$PART_SIZE" "$OUTIMG"
echo "  ok      padded to exactly $PART_SIZE bytes, headroom was $((PART_SIZE - sz))"

# -----------------------------------------------------------------------------
echo "=== 6. read the finished image back and compare it to the staging tree ==="
# -----------------------------------------------------------------------------
python3 "$HERE/verify-erofs.py" check "$OUTIMG" "$STAGE" "$PART_SIZE"
