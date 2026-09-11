<div align="center">

# NetHunter Kernel · Realme 9 Pro 5G (`oscar`)

A custom Linux 5.4.280-qgki kernel that adds **Kali NetHunter** support
to the phone — without breaking anything a daily driver needs.

[![Build](https://github.com/sirt-sirt/oscar-nethunter-kernel/actions/workflows/build-kernel.yml/badge.svg)](https://github.com/sirt-sirt/oscar-nethunter-kernel/actions/workflows/build-kernel.yml)
[![License](https://img.shields.io/badge/license-GPL--2.0-blue)](LICENSE)
![Kernel](https://img.shields.io/badge/kernel-5.4.280--qgki-green)
![CFI](https://img.shields.io/badge/CFI-strict%20·%20passing-success)

**English** · [Русский](README.ru.md)

</div>

---

## What is this?

Realme 9 Pro 5G (Snapdragon 695 5G, `sm6375` / `holi`, LineageOS 21 / Android 14)
ships with a Qualcomm stock kernel that has `CONFIG_SYSVIPC` and user namespaces
**disabled** — with that kernel, a Kali NetHunter chroot simply cannot work.

This project is a patched kernel that enables what NetHunter needs, plus the
build tooling to keep the rest of the system exactly as stock:

| | Stock kernel | This kernel |
|---|---|---|
| Kali chroot (namespaces, SysVIPC) | ✗ | ✓ |
| Wi-Fi, Bluetooth, camera, sound, cellular | ✓ | ✓ (unchanged) |
| Strict clang CFI + LTO | ✓ | ✓ (preserved, no PERMISSIVE) |
| USB OTG: serial/ACM, Bluetooth dongles | partial | ✓ |

## What's inside

- **Kernel config fragment** — `arch/arm64/configs/vendor/nethunter_oscar.config`,
  ~80 `CONFIG_` changes over the stock `holi-qgki_defconfig`.
- **Full vendor module rebuild.** The subtle part of this device: `/vendor/lib/modules`
  is a symlink to a **read-only `vendor_dlkm` (EROFS) partition**, so Magisk systemless
  overlays can't reach it. Enabling `SYSVIPC`/`USER_NS` changes `task_struct`, which shifts
  symbol CRCs — stock modules would refuse to load even with a matching vermagic.
  So all **39 vendor modules are rebuilt from the same tree** as the kernel and packed
  into a fresh `vendor_dlkm.img` with proper SELinux labels. Vermagic and CRCs match
  by construction.
- **Gated CI pipeline** (~26 min): release string and critical symbols checked *before*
  the build, per-module vermagic *after*, cross-check against the 39-module device
  inventory, double EROFS image verification. A leftover stock module is a hard failure,
  not a warning.

## Build (GitHub Actions)

No local Linux needed — everything builds in CI:

1. Fork the repository.
2. **Actions** tab → enable workflows.
3. **Build NetHunter Kernel (oscar)** → *Run workflow*.
4. Download the `NetHunter-Kernel-oscar` artifact (contains the AnyKernel3 zip
   and the standalone defconfig).

## Install

> Requires an unlocked bootloader and root (Magisk). You do this at your own risk.

1. Download the artifact and **unpack it once** — inside is the real
   `NetHunter-Kernel-oscar-*.zip`.
2. Back up the current `boot`:
   ```bash
   su -c 'dd if=/dev/block/by-name/boot$(getprop ro.boot.slot_suffix) of=/sdcard/boot-backup.img'
   ```
3. Flash the inner zip with **Kernel Flasher** (capntrips) from booted Android,
   active slot only. AnyKernel3 replaces only the kernel inside `boot` —
   Magisk and recovery survive.

**Rollback:** `fastboot set_active b` (slot B holds a copy of the working bootloader)
or `fastboot flash boot boot-backup.img` from fastbootd.

**After an OTA update:** OTA overwrites `boot` — re-flash the kernel
(Magisk → *Install to Inactive Slot (After OTA)* → reboot → Kernel Flasher).

## Known limitations

- External USB Wi-Fi adapters may crash the system: out-of-tree drivers under
  strict CFI panic on callback signature mismatch. Such drivers, if built at all,
  ship as separate modules loaded **manually** — they live outside all boot paths
  and cannot affect boot. Plug external adapters deliberately.
- After every LineageOS OTA the kernel must be re-flashed (see above).

## Repository layout

| Path | What |
|---|---|
| `arch/arm64/configs/vendor/nethunter_oscar.config` | NetHunter config fragment |
| `nethunter/` | CI tooling: `vendor_dlkm.img` builder, EROFS verifier, out-of-tree driver CFI patches |
| `nethunter/vendor_dlkm/` | device module manifest, load/softdep/block lists, SELinux `file_contexts` |
| `nethunter/ci/build-kernel.yml` | CI pipeline |
| `AnyKernel3/` | packaging and flashing |

## Releases

See [Releases](../../releases) — each release corresponds to a build validated on real hardware.

## License

GPL-2.0, inherited from the Linux kernel.
