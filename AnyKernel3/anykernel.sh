# AnyKernel3 Ramdisk Mod Script
# osm0sis @ xda-developers

## AnyKernel setup
# begin properties
properties() { '
kernel.string=NetHunter Kernel for Realme 9 Pro 5G (oscar)
do.devicecheck=1
do.modules=0
do.systemless=1
do.cleanup=1
do.cleanuponabort=0
device.name1=oscar
device.name2=RMX3471
device.name3=RMX3472
device.name4=holi
device.name5=RE54CBL1
device.name6=RMX3472 (RE54CBL1)
'; } # end properties

# ------------------------------------------------------------------------------
# do.modules is 0 ON PURPOSE. Do not turn it back on.
#
# With do.modules=1 and do.systemless=1, AnyKernel3 builds a Magisk module and
# drops every .ko into
#     /data/adb/modules/ak3-helper/system/vendor/lib/modules/
# expecting Magisk to overlay that onto /vendor/lib/modules. On oscar that path
# does not exist as a directory:
#
#     lrw-r--r-- 1 root root 24 /vendor/lib/modules -> /vendor_dlkm/lib/modules
#     /dev/block/dm-5 /vendor_dlkm erofs ro,seclabel,relatime
#
# Magisk overlays /system and /vendor. It does not map /vendor_dlkm, and it
# cannot write through a symlink into a read-only filesystem. So the modules
# landed somewhere the kernel never looks, all 39 stock modules kept loading,
# and MODVERSIONS refused them because our task_struct differs - no camera, no
# Wi-Fi, no Bluetooth, no audio, no cellular. That is what the 61 MB zip did.
#
# The modules now travel inside vendor_dlkm.img, which write_boot() flashes via
# flash_generic. It is padded to the exact partition size so flash_generic does
# a straight in-place write and never touches lptools.
# ------------------------------------------------------------------------------

# shell variables
#
# Let AnyKernel resolve the ACTIVE slot itself.
#
# The previous version hardcoded:
#     block=/dev/block/by-name/boot_a;
#     BLOCK=/dev/block/by-name/boot_a;
#     is_slot_device=0;
#
# On an A/B device that always writes slot A. If the phone is booted from
# slot B the flash lands in the inactive slot: either nothing changes, or the
# wrong slot gets a kernel and boot breaks. BLOCK is not an AnyKernel
# variable at all and was simply ignored.
#
# "block=boot" plus "is_slot_device=1" makes AnyKernel append the current
# slot suffix on its own.
BLOCK=boot;
IS_SLOT_DEVICE=1;
RAMDISK_COMPRESSION=auto;
PATCH_VBMETA_FLAG=auto;


## AnyKernel methods (DO NOT CHANGE)
# import patching functions/variables - see for reference
. tools/ak3-core.sh;

## AnyKernel boot install
dump_boot;

# stock ramdisk is reused unchanged - only the kernel is replaced.
# write_boot() then also runs "flash_generic vendor_dlkm", which picks up the
# vendor_dlkm.img sitting next to this script.
write_boot;

## end boot install

# ------------------------------------------------------------------------------
# The dongle driver, installed outside the partition.
#
# 8188eu.ko is roughly 1-2 MB stripped, and vendor_dlkm.img has about 250 KB of
# headroom left after the 39 device modules. It also must not load at boot -
# nothing depends on it and a broken out-of-tree driver in modules.load would
# turn a Wi-Fi experiment into a bootloop. So it is copied to /data and loaded
# by hand:
#
#     su -c 'insmod /data/adb/nh/8188eu.ko'
#     iw dev            # look for the new wlanN
#     airmon-ng start wlanN
#
# Kernel Flasher runs from booted Android, so /data is decrypted and this
# works. From recovery /data is FBE-locked, the test below fails, and the only
# consequence is a warning - the kernel and vendor_dlkm still flash fine.
# ------------------------------------------------------------------------------
if [ -f $AKHOME/8188eu.ko ]; then
  if [ -d /data/adb ]; then
    mkdir -p /data/adb/nh;
    cp -f $AKHOME/8188eu.ko /data/adb/nh/8188eu.ko;
    chmod 0644 /data/adb/nh/8188eu.ko;
    ui_print " " "8188eu.ko -> /data/adb/nh/ (insmod it by hand)";
  else
    ui_print " " "warning: no /data access - 8188eu.ko was not installed";
  fi;
fi;
