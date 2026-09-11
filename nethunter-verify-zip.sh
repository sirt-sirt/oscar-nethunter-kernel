#!/usr/bin/env bash
# =============================================================================
# Pre-flash verification for the NetHunter oscar kernel zip.
#
#   bash nethunter-verify-zip.sh NetHunter-Kernel-oscar-YYYYmmdd-HHMM.zip
#
# Reads the artifact and nothing else. No phone, no root, no flashing.
# Exit 0 = every hard requirement met.  Non-zero = DO NOT FLASH.
#
# Run it from a checkout of this repository: it uses nethunter/verify-erofs.py
# and nethunter/vendor_dlkm/stock-manifest.txt to look inside vendor_dlkm.img.
# Needs unzip, python3, grep, find. On Windows use WSL.
#
# REWRITTEN for build 10. The previous version checked
#     modules/vendor/lib/modules/*.ko
# inside the zip, and every one of those checks passed on the build-9 artifact.
# That is the problem: the modules were all present, all correctly versioned,
# and on a path this phone never reads. /vendor/lib/modules is a symlink into
# the read-only erofs vendor_dlkm partition, which Magisk does not map, so the
# whole overlay was inert. A verifier that says PASS on an inert zip is worse
# than no verifier. The modules now live inside vendor_dlkm.img and that is
# what gets checked.
# =============================================================================
set -u

ZIP="${1:-}"
HERE="$(cd "$(dirname "$0")" && pwd)"
WANT_REL='5.4.280-qgki-ge408f03a5c42'
PART_SIZE=10731520
MANIFEST="$HERE/nethunter/vendor_dlkm/stock-manifest.txt"
EROFS_TOOL="$HERE/nethunter/verify-erofs.py"

# Absence of any of these is immediately visible to the user.
CRITICAL='camera qca_cld3_wlan btpower bt_fm_slim rmnet_core rmnet_ctl rmnet_offload rmnet_shs'

hard=0; soft=0
ok()   { printf '  ok    %s\n' "$*"; }
warn() { printf '  WARN  %s\n' "$*"; soft=$((soft+1)); }
die()  { printf '  FAIL  %s\n' "$*"; hard=$((hard+1)); }
hdr()  { printf '\n== %s\n' "$*"; }

[ -n "$ZIP" ] || { echo "usage: bash $0 <NetHunter-Kernel-oscar-*.zip>"; exit 2; }
[ -f "$ZIP" ] || { echo "no such file: $ZIP"; exit 2; }
command -v unzip >/dev/null || { echo 'install unzip first'; exit 2; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
unzip -q -o "$ZIP" -d "$tmp" || { echo 'zip will not extract - it is corrupt'; exit 2; }

hdr '1. kernel image'
if [ -s "$tmp/Image" ]; then
  ok "Image present, $(wc -c < "$tmp/Image" | tr -d ' ') bytes"
  if strings -a "$tmp/Image" 2>/dev/null | grep -q -F "Linux version $WANT_REL"; then
    ok "Image banner says $WANT_REL"
  elif command -v strings >/dev/null 2>&1; then
    die "Image does not carry 'Linux version $WANT_REL'"
  else
    warn 'no strings(1) here - could not read the Image banner'
  fi
else
  die 'Image missing or empty - this zip cannot boot the phone'
fi

hdr '2. AnyKernel3 flags'
ak="$tmp/anykernel.sh"
if [ -f "$ak" ]; then
  # do.modules MUST be 0. With 1 it builds an ak3-helper Magisk module that
  # writes to a path nothing reads, and it would also pull a modules/ directory
  # into the zip.
  if grep -q '^do.modules=0' "$ak"; then
    ok 'do.modules=0 - the dead Magisk overlay path is off'
  else
    die 'do.modules is not 0 - modules would be written where nothing reads them'
  fi
  for f in do.devicecheck=1 is_slot_device=1; do
    if grep -q "^$f" "$ak"; then ok "$f"; else die "$f is not set"; fi
  done
  if grep -q '^block=boot;' "$ak"; then
    ok 'block=boot; - slot resolved at runtime'
  else
    die 'block= is not plain boot; - a hardcoded slot can overwrite the wrong partition'
  fi
  if grep -q '^device.name1=oscar' "$ak"; then
    ok 'device check pinned to oscar'
  else
    warn 'device.name1 is not oscar'
  fi
else
  die 'anykernel.sh missing'
fi

hdr '3. nothing left over from the old packaging'
if [ -d "$tmp/modules" ]; then
  die "a modules/ directory is still in the zip ($(find "$tmp/modules" -name '*.ko' | wc -l | tr -d ' ') .ko) - that is the inert path"
else
  ok 'no modules/ directory - nothing goes through the Magisk overlay'
fi
if [ -f "$tmp/nethunter_oscar_defconfig" ]; then
  warn 'nethunter_oscar_defconfig is inside the zip - harmless, but it belongs in the artifact only'
else
  ok 'no stray defconfig in the zip'
fi

hdr '4. vendor_dlkm.img - this is where the modules actually live'
img="$tmp/vendor_dlkm.img"
if [ ! -f "$img" ]; then
  die 'vendor_dlkm.img MISSING - without it the kernel changes and the modules do not'
else
  sz=$(wc -c < "$img" | tr -d ' ')
  if [ "$sz" = "$PART_SIZE" ]; then
    ok "exactly $PART_SIZE bytes - AnyKernel3 writes it in place"
  else
    die "$sz bytes, expected exactly $PART_SIZE. AnyKernel3 would try to resize a live logical partition"
  fi

  # EROFS magic 0xE0F5E1E2 little-endian at offset 1024.
  magic=$(od -An -tx1 -j 1024 -N 4 "$img" 2>/dev/null | tr -d ' \n')
  if [ "$magic" = "e2e1f5e0" ]; then
    ok 'EROFS superblock magic is correct'
  else
    die "no EROFS magic at offset 1024 (read: ${magic:-nothing})"
  fi
fi

hdr '5. inside vendor_dlkm.img'
if [ ! -f "$img" ]; then
  die 'skipped - no image to look inside'
elif ! command -v python3 >/dev/null 2>&1; then
  warn 'no python3 - cannot read the image contents'
elif [ ! -f "$EROFS_TOOL" ]; then
  warn "$EROFS_TOOL not found - run this script from a checkout of the repo"
else
  if python3 "$EROFS_TOOL" assert "$img" "$PART_SIZE" "$MANIFEST" > "$tmp/erofs.txt" 2>&1; then
    ok 'file list, SELinux labels and size all match the stock partition'
  else
    die 'the image does not match the stock partition - details below'
    cat "$tmp/erofs.txt"
  fi

  python3 "$EROFS_TOOL" dump "$img" > "$tmp/dump.txt" 2>&1 || true

  n=$(grep -c '\.ko ' "$tmp/dump.txt" 2>/dev/null || echo 0)
  if [ "$n" = 39 ]; then
    ok '39 modules in the image'
  else
    die "$n modules in the image, the device has 39"
  fi

  for m in $CRITICAL; do
    if grep -q "/lib/modules/$m\.ko " "$tmp/dump.txt"; then
      ok "$m.ko"
    else
      die "$m.ko MISSING from vendor_dlkm.img"
    fi
  done

  # The files that are copied verbatim from the stock partition rather than
  # regenerated. modules.load carries a real load ORDER the audio stack depends
  # on, and modules.blocklist is what keeps qca_cld3_wlan out of the boot
  # sequence so the Wi-Fi HAL can insmod it after cold-boot calibration.
  for f in modules.load modules.dep modules.alias modules.softdep modules.blocklist; do
    if grep -q "/lib/modules/$f " "$tmp/dump.txt"; then
      ok "$f present"
    else
      die "$f MISSING - without it init does not know what to load, or in what order"
    fi
  done

  if grep -q '/etc/build.prop ' "$tmp/dump.txt"; then
    ok '/etc/build.prop present'
  else
    warn '/etc/build.prop absent - cosmetic, but stock has it'
  fi

  if grep -q 'NOTICE.xml.gz' "$tmp/dump.txt"; then
    ok 'NOTICE.xml.gz present'
  else
    warn 'NOTICE.xml.gz dropped on purpose - Settings > Legal information loses one section, nothing else'
  fi

  if grep -q '(none)' "$tmp/dump.txt"; then
    die 'some files are UNLABELLED - init could not read them; expect no camera, audio, Wi-Fi or Bluetooth'
  else
    ok 'every entry carries an SELinux label'
  fi
fi

hdr '6. Wi-Fi dongle driver'
if [ -f "$tmp/8188eu.ko" ]; then
  ok "8188eu.ko at the zip root, $(wc -c < "$tmp/8188eu.ko" | tr -d ' ') bytes"
  if strings -a "$tmp/8188eu.ko" 2>/dev/null | grep -q '^import_ns='; then
    ok 'it imports a symbol namespace - insmod will not refuse it'
  else
    warn 'no import_ns - insmod may refuse it over kernel_read'
  fi
  if strings -a "$tmp/8188eu.ko" 2>/dev/null | grep -q cfg80211; then
    ok 'cfg80211 symbols present - real monitor mode'
  else
    warn 'no cfg80211 - monitor mode would be wireless-extensions only'
  fi
  echo "        install: su -c 'insmod /data/adb/nh/8188eu.ko'"
else
  warn '8188eu.ko absent - internal Wi-Fi unaffected, but no monitor mode on the dongle'
fi

hdr 'verdict'
if [ "$hard" = 0 ]; then
  printf '  PASS - 0 hard failures, %d warnings.\n\n' "$soft"
  echo '  Before flashing, keep these two on the PC:'
  echo "    adb shell su -c 'dd if=/dev/block/by-name/boot_a of=/data/local/tmp/boot_a.img'"
  echo "    adb shell su -c 'dd if=/dev/block/dm-5 of=/data/local/tmp/vendor_dlkm.img'"
  echo '    adb pull /data/local/tmp/boot_a.img'
  echo '    adb pull /data/local/tmp/vendor_dlkm.img'
  echo ''
  echo '  Rollback: the boot slot is a plain reflash, but vendor_dlkm is a'
  echo '  LOGICAL partition and the classic bootloader cannot see it. Use'
  echo '  fastbootd, and rehearse getting into it BEFORE you flash anything:'
  echo '    adb reboot fastboot'
  echo '    fastboot flash vendor_dlkm vendor_dlkm.img'
  exit 0
else
  printf '  DO NOT FLASH - %d hard failures, %d warnings.\n' "$hard" "$soft"
  exit 1
fi
