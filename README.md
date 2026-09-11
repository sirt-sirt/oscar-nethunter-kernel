<div align="center">

# NetHunter Kernel · Realme 9 Pro 5G (`oscar`)

**Кастомное ядро Linux 5.4.280-qgki с поддержкой Kali NetHunter**

[![Build](https://github.com/sirt-sirt/oscar-nethunter-kernel/actions/workflows/build-kernel.yml/badge.svg)](https://github.com/sirt-sirt/oscar-nethunter-kernel/actions/workflows/build-kernel.yml)
[![License](https://img.shields.io/badge/license-GPL--2.0-blue)](LICENSE)
![Kernel](https://img.shields.io/badge/kernel-5.4.280--qgki-green)
![CFI](https://img.shields.io/badge/CFI-strict%20·%20passing-success)

</div>

---

## Что это

Патченное ядро для **Realme 9 Pro 5G** (кодовое имя `oscar`, SoC Qualcomm Snapdragon 695 5G / `sm6375` / `holi`, база LineageOS 21 / Android 14), добавляющее поддержку окружения **Kali NetHunter**:

- полноценный chroot: Linux-namespaces и SysVIPC;
- внешнее USB-железо по OTG (Wi-Fi адаптеры, serial-устройства, Bluetooth-донглы).

Телефон при этом остаётся телефоном: Wi-Fi, Bluetooth, камера, звук и сотовая сеть работают штатно.

## Ключевые особенности

### Совместимость Kali chroot
`CONFIG_SYSVIPC=y`, полная изоляция namespace'ами (`PID_NS`, `NET_NS`, `USER_NS`, `IPC_NS`, `UTS_NS`) — chroot NetHunter работает без ограничений.

### Внешние USB-устройства
- USB Serial / ACM (`CONFIG_USB_ACM`, `CONFIG_USB_SERIAL`, чипы `PL2303`, `FTDI_SIO`, `CH341`, `CP210X`);
- внешние USB Bluetooth-адаптеры (`CONFIG_BT_HCIBTUSB`, `BT_BNEP`);
- `CFG80211_WEXT` — совместимость с классическими wireless-утилитами.

> ⚠️ **Некоторые внешние Wi-Fi-свистки могут крашить систему.** Драйверы out-of-tree на этом ядре (strict CFI + LTO) при несовпадении сигнатур колбэков приводят к kernel panic. Поэтому драйвер внешнего адаптера грузится **только вручную** и живёт вне всех загрузочных путей — на загрузку телефона он повлиять не может в принципе. Свисток подключайте осознанно.

Для TP-Link TL-WN722N v2 (чип Realtek RTL8188EUS, USB ID `2357:010c`) в репозитории есть патч-скрипт, приводящий драйвер к строгому CFI — он собирается в CI и кладётся в архив отдельным модулем.

### Строгий CFI + LTO сохранены
`CONFIG_CFI_CLANG=y + LTO` включены, как у стока Qualcomm, и проходят без послаблений — `CONFIG_CFI_PERMISSIVE` не нужен. Все правки типизированы честно, касты, глушащие компилятор, удалены.

### Инженерная доставка модулей (главное отличие)
`/vendor/lib/modules` на этом устройстве — **симлинк на read-only раздел `vendor_dlkm` (EROFS)**, поэтому systemless-оверлеи Magisk туда не добивают. Решение:

1. **Все 39 вендорных модулей пересобираются из этого же дерева** (включая Wi-Fi встройки `qcacld-3.0` → `qca_cld3_wlan.ko`) и пакуются в `vendor_dlkm.img` с SELinux-метками (патченный `erofs-utils`).
2. CI **фатально падает**, если хоть один стоковый модуль остался «стоковым» — с включёнными SYSVIPC/USER_NS сдвигаются CRC `task_struct`, и стоковый модуль не загрузится даже при совпадающем vermagic.
3. AnyKernel3 трогает только `boot` (подмена ядра, Magisk переживает прошивку), `do.modules=0`.

## Сборка (GitHub Actions)

Локальная Linux-машина не нужна — всё собирает CI (~26 минут), с гейтами на каждом шаге: проверка release-строки и критичных символов **до** сборки, vermagic каждого `.ko` **после**, сверка с инвентарём 39 модулей устройства, двойная верификация EROFS-образа и готового зипа.

1. Форкните репозиторий.
2. Вкладка **Actions** → включить workflows.
3. **Build NetHunter Kernel (oscar)** → *Run workflow*.
4. Скачать артефакт `NetHunter-Kernel-oscar`.

## Установка

> Требуется разблокированный загрузчик и root (Magisk). Всё, что вы делаете, — на ваш риск.

1. Скачать артефакт из Actions (или [Releases](../../releases)) и **распаковать один раз** — внутри настоящий `NetHunter-Kernel-oscar-*.zip`.
2. Сделать бэкап текущего `boot`:
   ```bash
   su -c 'dd if=/dev/block/by-name/boot$(getprop ro.boot.slot_suffix) of=/sdcard/boot-backup.img'
   ```
3. Прошить внутренний zip через **Kernel Flasher** (capntrips) из загруженного Android. Шить **только в активный слот**.

**Откат:** `fastboot set_active b` (в слоте B остаётся копия рабочего загрузчика) либо `fastboot flash boot boot-backup.img` из fastbootd.

### После OTA LineageOS
OTA перезаписывает `boot` — ядро нужно прошить заново (Magisk → *Install to Inactive Slot (After OTA)* → ребут → Kernel Flasher).

## Структура репозитория

| Путь | Что это |
|---|---|
| `arch/arm64/configs/vendor/nethunter_oscar.config` | конфиг-фрагмент NetHunter поверх `holi-qgki_defconfig` |
| `nethunter/patch-rtl8188eus.sh` | патч драйвера RTL8188EUS под строгий CFI (идемпотентный, loud-fail) |
| `nethunter/build-vendor-dlkm.sh` | сборка `vendor_dlkm.img` (EROFS + SELinux-метки) |
| `nethunter/verify-erofs.py` | независимый верификатор EROFS-образа |
| `nethunter/vendor_dlkm/` | манифест 39 стоковых модулей, `modules.load/softdep/blocklist`, `file_contexts`, `build.prop` |
| `nethunter/ci/build-kernel.yml` | CI-конвейер |
| `AnyKernel3/` | упаковка и прошивка |

## Версии

Смотри [Releases](../../releases) — каждый релиз соответствует проверенной на устройстве сборке.

## Лицензия

GPL-2.0 — унаследована от ядра Linux.
