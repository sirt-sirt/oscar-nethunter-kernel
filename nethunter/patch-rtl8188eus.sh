#!/usr/bin/env bash
# =============================================================================
# NetHunter patches for the aircrack-ng rtl8188eus fork.
#
#   bash nethunter/patch-rtl8188eus.sh <path-to-cloned-driver>
#
# Patch 1 - MODULE_IMPORT_NS(VFS_internal_...)
#
# Run 32571447245 built the driver cleanly and still ended with:
#
#   WARNING: module 8188eu uses symbol kernel_read from namespace
#   VFS_internal_I_am_really_a_filesystem_and_am_NOT_a_driver,
#   but does not import it.
#
# That is a modpost WARNING, so the build succeeds and the .ko looks fine. It
# is not fine. Since 5.4 the module loader enforces namespace imports, and
# CONFIG_MODULE_ALLOW_MISSING_NAMESPACE_IMPORTS is off on this device (checked
# against the stock config recovered from boot_backup_a.img), so insmod would
# refuse the module at runtime with no useful message.
#
# The driver calls kernel_read() from rtw_retrieve_from_file() in
# os_dep/linux/os_intfs.c, so that is where the import belongs.
#
# Guarded on the macro itself rather than on LINUX_VERSION_CODE: MODULE_IMPORT_NS
# either exists in linux/module.h or it does not, and #ifdef answers that
# question without assuming which backport a vendor tree happens to carry.
#
# Patch 2 - ndo_start_xmit signatures must return netdev_tx_t (clang CFI)
#
# oscar ships CONFIG_CFI_CLANG=y + LTO. CFI compares the canonical type hash of
# the callee against the function-pointer type at every INDIRECT call. The
# kernel's net_device_ops slot is:
#
#   netdev_tx_t (*ndo_start_xmit)(struct sk_buff *, struct net_device *);
#
# but this driver declares all four xmit handlers as plain `int` functions:
#
#   os_dep/linux/xmit_linux.c:443      int _rtw_xmit_entry(...)
#   os_dep/linux/xmit_linux.c:516      int rtw_xmit_entry(...)
#   os_dep/linux/mlme_linux.c:276      static int mgnt_xmit_entry(...)
#   os_dep/linux/ioctl_cfg80211.c:4284 static int rtw_cfg80211_monitor_if_xmit_entry(...)
#
# int (*)(...) hashes differently from enum netdev_tx (*)(...), so the first
# transmitted frame dies in __cfi_check_fail. That is exactly the observed
# crash: `ip link set wlanX up` starts IPv6 DAD/MLD, the first packet goes out
# through dev_hard_start_xmit -> ndo_start_xmit and the kernel panics with
# "Fatal exception in interrupt" (console-ramoops-0, pc = __cfi_check_fail).
#
# Fix: retype the four definitions/prototypes to netdev_tx_t
# (= typedef enum netdev_tx netdev_tx_t, include/linux/netdevice.h). Bodies are
# untouched - they only ever return 0 (== NETDEV_TX_OK) or propagate an int,
# both of which convert to/from the enum legally.
#
# Patch 3 - tasklet callbacks must take unsigned long (same CFI class)
#
# Second crash, this time in monitor mode: pc = __cfi_check_fail [8188eu],
# Call trace = tasklet_action_common -> __do_softirq. On Linux 5.4
# tasklet_init() takes void (*func)(unsigned long). The fork declares its
# three tasklet handlers as void f(void *priv) and papers over the difference
# with a cast at every tasklet_init() call site:
#
#   os_dep/linux/usb_ops_linux.c:729/867  void usb_recv_tasklet(void *priv)
#   hal/rtl8188e/usb/usb_ops_linux.c:248  void rtl8188eu_xmit_tasklet(void *priv)
#   core/mesh/rtw_mesh.c:2306             static void mpath_tx_tasklet_hdl(void *priv)
#
# A cast silences the compiler but not CFI: tasklet_action_common does an
# indirect call typed void (*)(unsigned long) while the callee's __cfi_check
# was generated for void (*)(void *). Idle managed mode never fired these
# (no RX, TX dropped as unassociated) - monitor mode floods RX beacons and
# the recv tasklet detonated instantly.
#
# Fix: declare the handlers exactly as void f(unsigned long priv) - including
# the two prototypes in include/usb_ops_linux.h and include/rtl8188e_xmit.h -
# and drop the lying casts so nothing hides future drift. Bodies stay valid:
# they only do (_adapter *)priv.
#
# Work items need nothing: _workitem is typedef'd to struct work_struct
# (osdep_service_linux.h:214) and every callback is declared with it, so their
# hashes already match INIT_WORK. Driver timers go through a self-owned
# trampoline (_init_timer / timer_hdl) whose internal pointer types agree -
# proven live by the watchdog ticking through the whole first test.
#
# Every substitution below is anchored and verified after sed; if an anchor
# does not match because upstream moved, fail loudly instead of building a
# module we cannot trust.
# =============================================================================
set -euo pipefail

SRC="${1:?usage: patch-rtl8188eus.sh <driver-source-dir>}"
status=0

ok()  { echo "  ok      $*"; }
bad() { echo "::error::$*"; status=1; }

# -----------------------------------------------------------------------------
# Patch 1: symbol namespace import
# -----------------------------------------------------------------------------
F="$SRC/os_dep/linux/os_intfs.c"
if [ ! -f "$F" ]; then
  bad "$F not found - the driver layout changed"
elif grep -q 'MODULE_IMPORT_NS' "$F"; then
  ok "MODULE_IMPORT_NS already present in os_intfs.c"
else
  {
    printf '\n'
    printf '/* NetHunter: rtw_retrieve_from_file() calls kernel_read(), which lives in\n'
    printf ' * the VFS symbol namespace since Linux 5.4. Without this import modpost\n'
    printf ' * only warns, and the module is then REFUSED at insmod time because\n'
    printf ' * CONFIG_MODULE_ALLOW_MISSING_NAMESPACE_IMPORTS is not set on oscar. */\n'
    printf '#ifdef MODULE_IMPORT_NS\n'
    printf 'MODULE_IMPORT_NS(VFS_internal_I_am_really_a_filesystem_and_am_NOT_a_driver);\n'
    printf '#endif\n'
  } >> "$F"
  if grep -q 'MODULE_IMPORT_NS' "$F"; then
    ok "appended MODULE_IMPORT_NS to os_intfs.c"
  else
    bad "failed to append MODULE_IMPORT_NS to $F"
  fi
fi

# -----------------------------------------------------------------------------
# Patch 2: CFI-correct ndo_start_xmit signatures
# -----------------------------------------------------------------------------

# Prototypes shared by every caller of the xmit entries. The PLATFORM_LINUX
# section is what matters; the identical FreeBSD-section lines also match the
# sed and get retyped too - that section never compiles on Linux, harmless.
F="$SRC/include/xmit_osdep.h"
if [ ! -f "$F" ]; then
  bad "$F not found - the driver layout changed"
elif grep -q 'extern netdev_tx_t rtw_xmit_entry' "$F"; then
  ok "xmit_osdep.h already retyped"
else
  sed -i \
    -e 's/^extern int _rtw_xmit_entry(_pkt \*pkt, _nic_hdl pnetdev);$/extern netdev_tx_t _rtw_xmit_entry(_pkt *pkt, _nic_hdl pnetdev);/' \
    -e 's/^extern int rtw_xmit_entry(_pkt \*pkt, _nic_hdl pnetdev);$/extern netdev_tx_t rtw_xmit_entry(_pkt *pkt, _nic_hdl pnetdev);/' \
    "$F"
  if grep -q '^extern netdev_tx_t _rtw_xmit_entry(_pkt \*pkt, _nic_hdl pnetdev);$' "$F" && \
     grep -q '^extern netdev_tx_t rtw_xmit_entry(_pkt \*pkt, _nic_hdl pnetdev);$' "$F"; then
    ok "retyped _rtw_xmit_entry/rtw_xmit_entry prototypes in xmit_osdep.h"
  else
    bad "xmit_osdep.h anchors not found - upstream prototype changed"
  fi
fi

F="$SRC/os_dep/linux/xmit_linux.c"
if [ ! -f "$F" ]; then
  bad "$F not found - the driver layout changed"
elif grep -q '^netdev_tx_t rtw_xmit_entry' "$F"; then
  ok "xmit_linux.c already retyped"
else
  sed -i \
    -e 's/^int _rtw_xmit_entry(_pkt \*pkt, _nic_hdl pnetdev)$/netdev_tx_t _rtw_xmit_entry(_pkt *pkt, _nic_hdl pnetdev)/' \
    -e 's/^int rtw_xmit_entry(_pkt \*pkt, _nic_hdl pnetdev)$/netdev_tx_t rtw_xmit_entry(_pkt *pkt, _nic_hdl pnetdev)/' \
    "$F"
  if grep -q '^netdev_tx_t _rtw_xmit_entry(_pkt \*pkt, _nic_hdl pnetdev)$' "$F" && \
     grep -q '^netdev_tx_t rtw_xmit_entry(_pkt \*pkt, _nic_hdl pnetdev)$' "$F"; then
    ok "retyped _rtw_xmit_entry/rtw_xmit_entry definitions in xmit_linux.c"
  else
    bad "xmit_linux.c anchors not found - upstream definition changed"
  fi
fi

F="$SRC/os_dep/linux/mlme_linux.c"
if [ ! -f "$F" ]; then
  bad "$F not found - the driver layout changed"
elif grep -q '^static netdev_tx_t mgnt_xmit_entry' "$F"; then
  ok "mlme_linux.c already retyped"
else
  sed -i \
    -e 's/^static int mgnt_xmit_entry(struct sk_buff \*skb, struct net_device \*pnetdev)$/static netdev_tx_t mgnt_xmit_entry(struct sk_buff *skb, struct net_device *pnetdev)/' \
    "$F"
  if grep -q '^static netdev_tx_t mgnt_xmit_entry(struct sk_buff \*skb, struct net_device \*pnetdev)$' "$F"; then
    ok "retyped mgnt_xmit_entry in mlme_linux.c"
  else
    bad "mgnt_xmit_entry anchor not found - upstream definition changed"
  fi
fi

F="$SRC/os_dep/linux/ioctl_cfg80211.c"
if [ ! -f "$F" ]; then
  bad "$F not found - the driver layout changed"
elif grep -q '^static netdev_tx_t rtw_cfg80211_monitor_if_xmit_entry' "$F"; then
  ok "ioctl_cfg80211.c already retyped"
else
  sed -i \
    -e 's/^static int rtw_cfg80211_monitor_if_xmit_entry(struct sk_buff \*skb, struct net_device \*ndev)$/static netdev_tx_t rtw_cfg80211_monitor_if_xmit_entry(struct sk_buff *skb, struct net_device *ndev)/' \
    "$F"
  if grep -q '^static netdev_tx_t rtw_cfg80211_monitor_if_xmit_entry(struct sk_buff \*skb, struct net_device \*ndev)$' "$F"; then
    ok "retyped rtw_cfg80211_monitor_if_xmit_entry in ioctl_cfg80211.c"
  else
    bad "rtw_cfg80211_monitor_if_xmit_entry anchor not found - upstream definition changed"
  fi
fi

# -----------------------------------------------------------------------------
# Patch 3: CFI-correct tasklet callbacks (unsigned long, no casts)
# -----------------------------------------------------------------------------

# Two identical definitions in this file (CONFIG_USE_USB_BUFFER_ALLOC_RX
# variants) plus the shared prototype in include/usb_ops_linux.h.
F="$SRC/os_dep/linux/usb_ops_linux.c"
if [ ! -f "$F" ]; then
  bad "$F not found - the driver layout changed"
elif grep -q '^void usb_recv_tasklet(unsigned long priv)$' "$F"; then
  ok "usb_ops_linux.c already retyped"
else
  sed -i \
    -e 's/^void usb_recv_tasklet(void \*priv)$/void usb_recv_tasklet(unsigned long priv)/' \
    "$F"
  n=$(grep -c '^void usb_recv_tasklet(unsigned long priv)$' "$F")
  if [ "$n" -eq 2 ]; then
    ok "retyped both usb_recv_tasklet definitions in usb_ops_linux.c"
  else
    bad "expected 2 usb_recv_tasklet definitions after sed, found $n"
  fi
fi

F="$SRC/include/usb_ops_linux.h"
if [ ! -f "$F" ]; then
  bad "$F not found - the driver layout changed"
elif grep -q '^void usb_recv_tasklet(unsigned long priv);$' "$F"; then
  ok "usb_ops_linux.h already retyped"
else
  sed -i \
    -e 's/^void usb_recv_tasklet(void \*priv);$/void usb_recv_tasklet(unsigned long priv);/' \
    "$F"
  if grep -q '^void usb_recv_tasklet(unsigned long priv);$' "$F"; then
    ok "retyped usb_recv_tasklet prototype in usb_ops_linux.h"
  else
    bad "usb_recv_tasklet prototype anchor not found in usb_ops_linux.h"
  fi
fi

F="$SRC/hal/rtl8188e/usb/usb_ops_linux.c"
if [ ! -f "$F" ]; then
  bad "$F not found - the driver layout changed"
elif grep -q '^void rtl8188eu_xmit_tasklet(unsigned long priv)$' "$F"; then
  ok "rtl8188e xmit tasklet already retyped"
else
  sed -i \
    -e 's/^void rtl8188eu_xmit_tasklet(void \*priv)$/void rtl8188eu_xmit_tasklet(unsigned long priv)/' \
    "$F"
  if grep -q '^void rtl8188eu_xmit_tasklet(unsigned long priv)$' "$F"; then
    ok "retyped rtl8188eu_xmit_tasklet definition"
  else
    bad "rtl8188eu_xmit_tasklet anchor not found"
  fi
fi

F="$SRC/include/rtl8188e_xmit.h"
if [ ! -f "$F" ]; then
  bad "$F not found - the driver layout changed"
elif grep -q 'void rtl8188eu_xmit_tasklet(unsigned long priv);' "$F"; then
  ok "rtl8188e_xmit.h already retyped"
else
  sed -i \
    -e 's/\tvoid rtl8188eu_xmit_tasklet(void \*priv);$/\tvoid rtl8188eu_xmit_tasklet(unsigned long priv);/' \
    "$F"
  if grep -q 'void rtl8188eu_xmit_tasklet(unsigned long priv);' "$F"; then
    ok "retyped rtl8188eu_xmit_tasklet prototype in rtl8188e_xmit.h"
  else
    bad "rtl8188eu_xmit_tasklet prototype anchor not found in rtl8188e_xmit.h"
  fi
fi

F="$SRC/core/mesh/rtw_mesh.c"
if [ ! -f "$F" ]; then
  bad "$F not found - the driver layout changed"
elif grep -q '^static void mpath_tx_tasklet_hdl(unsigned long priv)$' "$F"; then
  ok "rtw_mesh.c already retyped"
else
  sed -i \
    -e 's/^static void mpath_tx_tasklet_hdl(void \*priv)$/static void mpath_tx_tasklet_hdl(unsigned long priv)/' \
    "$F"
  if grep -q '^static void mpath_tx_tasklet_hdl(unsigned long priv)$' "$F"; then
    ok "retyped mpath_tx_tasklet_hdl in rtw_mesh.c"
  else
    bad "mpath_tx_tasklet_hdl anchor not found"
  fi
fi

# Drop the three lying casts. A cast hides type drift from the compiler; with
# correct prototypes it is pure noise, and its absence is what makes a future
# upstream signature change fail the build instead of passing CFI runtime.
for pair in \
  "$SRC/hal/hal_hci/hal_usb.c|usb_recv_tasklet," \
  "$SRC/hal/rtl8188e/usb/rtl8188eu_xmit.c|rtl8188eu_xmit_tasklet," ; do
  F="${pair%|*}"; FN="${pair#*|}"
  if [ ! -f "$F" ]; then
    bad "$F not found - the driver layout changed"
  elif ! grep -q "(void(\*)(unsigned long))$FN" "$F"; then
    ok "cast already gone: $FN"
  else
    sed -i -E "s/\(void\(\*\)\(unsigned long\)\)$FN/$FN/" "$F"
    if ! grep -q "(void(\*)(unsigned long))$FN" "$F" && grep -Eq "^[[:space:]]*$FN\$" "$F"; then
      ok "dropped stale cast for $FN"
    else
      bad "failed to remove cast for $FN in $F"
    fi
  fi
done

F="$SRC/core/mesh/rtw_mesh.c"
if [ -f "$F" ] && grep -q '(void(\*)(unsigned long))mpath_tx_tasklet_hdl' "$F"; then
  sed -i -E 's/, \(void\(\*\)\(unsigned long\)\)mpath_tx_tasklet_hdl/, mpath_tx_tasklet_hdl/' "$F"
  if grep -q ', mpath_tx_tasklet_hdl$' "$F"; then
    ok "dropped stale cast for mpath_tx_tasklet_hdl"
  else
    bad "failed to remove cast for mpath_tx_tasklet_hdl"
  fi
fi

if [ "$status" -eq 0 ]; then
  echo "=== all rtl8188eus patches applied ==="
else
  echo "=== one or more patches FAILED - do not ship this build ==="
fi
exit "$status"
