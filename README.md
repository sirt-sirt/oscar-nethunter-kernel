<div align="center">

# NetHunter Kernel · Realme 9 Pro 5G (`oscar`)

**Кастомное ядро Linux 5.4.280-qgki для Kali NetHunter — прошито и проверено на живом железе**

[![Build](https://github.com/sirt-sirt/oscar-nethunter-kernel/actions/workflows/build-kernel.yml/badge.svg)](https://github.com/sirt-sirt/oscar-nethunter-kernel/actions/workflows/build-kernel.yml)
[![License](https://img.shields.io/badge/license-GPL--2.0-blue)](LICENSE)
![Kernel](https://img.shields.io/badge/kernel-5.4.280--qgki-green)
![CFI](https://img.shields.io/badge/CFI-strict%20·%20passing-success)

</div>

---

## Что это

Кастомное ядро для **Realme 9 Pro 5G** (кодовое имя `oscar`, SoC Qualcomm Snapdragon 695 5G / `sm6375` / `holi`, база LineageOS 21 / Android 14), превращающее телефон в полноценную платформу **Kali NetHunter**:

- полноценный Kali chroot (namespaces, SysVIPC);
- хакерское железо по USB OTG;
- **monitor mode + packet injection** через внешний Wi-Fi-свисток.

Телефон при этом остаётся телефоном: Wi-Fi, Bluetooth, камера, звук и сотовая сеть работают штатно.

## Ключевые особенности

### Совместимость Kali chroot
`CONFIG_SYSVIPC=y`, полная изоляция namespace'ами (`PID_NS`, `NET_NS`, `USER_NS`, `IPC_NS`, `UTS_NS`) — chroot NetHunter работает без ограничений.

### Monitor mode и инжекция
- Свисток **TP-Link TL-WN722N v2** (чип Realtek **RTL8188EUS**, USB ID `2357:010c`), драйвер — форк aircrack-ng `rtl8188eus`.
- Драйвер **пропатчен под строгий clang CFI** (xmit-хендлеры → `netdev_tx_t`, tasklet-колбэки → `void f(unsigned long)`, `MODULE_IMPORT_NS`): `CONFIG_CFI_PERMISSIVE` **не нужен**.
- Живая валидация: инжекция **30/30 = 100 %**, полный WPA-пентест-цикл (monitor → deauth → handshake) без единого CFI-фейла в dmesg.

### Строгий CFI + LTO сохранены
В отличие от «простых» кастомов, здесь `CONFIG_CFI_CLANG=y + LTO` включены и **проходят** — как у стока Qualcomm. Все out-of-tree правки типизированы честно, касты, глушащие компилятор, удалены.

### Инженерная доставка модулей (главное отличие)
`/vendor/lib/modules` на этом устройстве — **симлинк на read-only раздел `vendor_dlkm` (EROFS)**, поэтому systemless-оверлеи Magisk туда не добивают. Решение:

1. **Все 39 вендорных модулей пересобираются из этого же дерева** (включая Wi-Fi встройки `qcacld-3.0` → `qca_cld3_wlan.ko`) и пакуются в `vendor_dlkm.img` с SELinux-метками (патченный `erofs-utils`).
2. CI **фатально падает**, если хоть один стоковый модуль остался «стоковым» — с включёнными SYSVIPC/USER_NS сдвигаются CRC `task_struct`, и стоковый модуль не загрузится даже при совпадающем vermagic.
3. AnyKernel3 трогает только `boot` (подмена ядра, Magisk переживает прошивку), `do.modules=0`.
4. Драйвер свистка живёт отдельно в `/data/adb/nh/8188eu.ko` и грузится вручную (`insmod` / меню `nh-wifi`) — кривой out-of-tree драйвер по построению не может уронить бут.

## Сборка (GitHub Actions)

Локальная Linux-машина не нужна — всё собирает CI (~26 минут), с гейтами на каждом шаге: проверка release-строки и критичных символов **до** сборки, vermagic каждого `.ko` **после**, сверка с инвентарём 39 модулей устройства, двойная верификация EROFS-образа и готового зипа.

1. Форкните репозиторий.
2. Вкладка **Actions** → включить workflows.
3. **Build NetHunter Kernel (oscar)** → *Run workflow*.
4. Скачать артефакт `NetHunter-Kernel-oscar`.

## Установка

> Требуется разблокированный загрузчик и root (Magisk). Всё, что вы делаете, — на ваш риск.

1. Скачать артефакт из Actions и **распаковать один раз** — внутри настоящий `NetHunter-Kernel-oscar-*.zip`.
2. Сделать бэкап текущего `boot`:
   ```bash
   su -c 'dd if=/dev/block/by-name/boot$(getprop ro.boot.slot_suffix) of=/sdcard/boot-backup.img'
   ```
3. Прошить внутренний zip через **Kernel Flasher** (capntrips) из загруженного Android. Шить **только в активный слот**.
4. Свисток: скопировать `8188eu.ko` в `/data/adb/nh/`, затем `su -c 'insmod /data/adb/nh/8188eu.ko'`.

**Откат:** `fastboot set_active b` (в слоте B остаётся копия рабочего загрузчика) либо `fastboot flash boot boot-backup.img` из fastbootd.

### После OTA LineageOS
OTA перезаписывает `boot` — ядро нужно прошить заново (Magisk → *Install to Inactive Slot (After OTA)* → ребут → Kernel Flasher).

## Использование свистка (в Kali chroot)

```bash
nh-wifi                       # меню: вкл/выкл/монитор
airmon-ng start wlan1         # монитоp (в chroot стоит шим против wext-мины ядра 5.4)
airodump-ng wlan1             # скан
aireplay-ng -9 -a <BSSID> wlan1   # тест инжекции с явной целью
```

## Структура репозитория

| Путь | Что это |
|---|---|
| `arch/arm64/configs/vendor/nethunter_oscar.config` | конфиг-фрагмент NetHunter поверх `holi-qgki_defconfig` |
| `nethunter/patch-rtl8188eus.sh` | патчи драйвера свистка под строгий CFI (идемпотентный, loud-fail) |
| `nethunter/build-vendor-dlkm.sh` | сборка `vendor_dlkm.img` (EROFS + SELinux-метки) |
| `nethunter/verify-erofs.py` | независимый верификатор EROFS-образа |
| `nethunter/vendor_dlkm/` | манифест 39 стоковых модулей, `modules.load/softdep/blocklist`, `file_contexts`, `build.prop` |
| `nethunter/ci/build-kernel.yml` | CI-конвейер |
| `AnyKernel3/` | упаковка и прошивка |

## Версии

Смотри [Releases](../../releases) — каждый релиз соответствует проверенной на устройстве сборке.

## Лицензия

GPL-2.0 — унаследована от ядра Linux. Проект — для аудита информационной безопасности собственных устройств и сетей.
