<div align="center">

# NetHunter Kernel · Realme 9 Pro 5G (`oscar`)

Кастомное ядро Linux 5.4.280-qgki, добавляющее телефону поддержку **Kali NetHunter** —
без потери ничего из того, что нужно каждый день.

[![Build](https://github.com/sirt-sirt/oscar-nethunter-kernel/actions/workflows/build-kernel.yml/badge.svg)](https://github.com/sirt-sirt/oscar-nethunter-kernel/actions/workflows/build-kernel.yml)
[![License](https://img.shields.io/badge/license-GPL--2.0-blue)](LICENSE)
![Kernel](https://img.shields.io/badge/kernel-5.4.280--qgki-green)
![CFI](https://img.shields.io/badge/CFI-strict%20·%20passing-success)

[English](README.md) · **Русский**

</div>

---

## Что это?

Realme 9 Pro 5G (Snapdragon 695 5G, `sm6375` / `holi`, LineageOS 21 / Android 14) поставляется
со стоковым ядром Qualcomm, в котором `CONFIG_SYSVIPC` и user namespace **выключены** —
на таком ядре chroot Kali NetHunter не работает в принципе.

Этот проект — пропатченное ядро, включающее нужное NetHunter'у, плюс инструментарий сборки,
который держит остальную систему ровно такой, как на стоке:

| | Стоковое ядро | Это ядро |
|---|---|---|
| Kali chroot (namespaces, SysVIPC) | ✗ | ✓ |
| Wi-Fi, Bluetooth, камера, звук, сотовая связь | ✓ | ✓ (без изменений) |
| Строгий clang CFI + LTO | ✓ | ✓ (сохранены, без PERMISSIVE) |
| USB OTG: serial/ACM, Bluetooth-донглы | частично | ✓ |

## Что внутри

- **Конфиг-фрагмент ядра** — `arch/arm64/configs/vendor/nethunter_oscar.config`,
  ~80 изменений `CONFIG_` поверх стокового `holi-qgki_defconfig`.
- **Полная пересборка вендорных модулей.** Тонкое место этого устройства: `/vendor/lib/modules`
  — симлинк на **read-only раздел `vendor_dlkm` (EROFS)**, до которого Magisk-оверлеи
  не добираются. Включение `SYSVIPC`/`USER_NS` меняет `task_struct`, из-за чего сдвигаются
  CRC символов — стоковые модули откажутся грузиться даже при совпадающем vermagic.
  Поэтому все **39 вендорных модулей пересобираются из того же дерева**, что и ядро,
  и пакуются в свежий `vendor_dlkm.img` с корректными SELinux-метками. Vermagic и CRC
  совпадают по построению.
- **CI с гейтами** (~26 минут): release-строка и критичные символы проверяются *до* сборки,
  vermagic каждого модуля — *после*, сверка с инвентарём 39 модулей устройства, двойная
  верификация EROFS-образа. Оставшийся стоковым модуль — фатальная ошибка, а не предупреждение.

## Сборка (GitHub Actions)

Локальный Linux не нужен — всё собирает CI:

1. Сделайте форк репозитория.
2. Вкладка **Actions** → включите workflows.
3. **Build NetHunter Kernel (oscar)** → *Run workflow*.
4. Скачайте артефакт `NetHunter-Kernel-oscar` (внутри AnyKernel3-зип и standalone-конфиг).

## Установка

> Требуются разблокированный загрузчик и root (Magisk). Всё, что вы делаете, — на ваш риск.

1. Скачайте артефакт и **распакуйте один раз** — внутри настоящий `NetHunter-Kernel-oscar-*.zip`.
2. Сделайте бэкап текущего `boot`:
   ```bash
   su -c 'dd if=/dev/block/by-name/boot$(getprop ro.boot.slot_suffix) of=/sdcard/boot-backup.img'
   ```
3. Прошейте внутренний зип через **Kernel Flasher** (capntrips) из загруженного Android,
   только в активный слот. AnyKernel3 подменяет только ядро внутри `boot` —
   Magisk и рекавери переживают прошивку.

**Откат:** `fastboot set_active b` (в слоте B лежит копия рабочего загрузчика)
или `fastboot flash boot boot-backup.img` из fastbootd.

**После OTA-обновления:** OTA перезаписывает `boot` — ядро нужно прошить заново
(Magisk → *Install to Inactive Slot (After OTA)* → ребут → Kernel Flasher).

## Известные ограничения

- Внешние USB Wi-Fi адаптеры могут крашить систему: out-of-tree драйверы под строгим CFI
  паникуют при несовпадении сигнатур колбэков. Такие драйверы, если собираются, едут
  отдельными модулями и грузятся **вручную** — они лежат вне всех загрузочных путей
  и не могут повлиять на загрузку телефона. Подключайте внешние адаптеры осознанно.
- После каждого OTA LineageOS ядро нужно прошивать заново (см. выше).

## Структура репозитория

| Путь | Что это |
|---|---|
| `arch/arm64/configs/vendor/nethunter_oscar.config` | конфиг-фрагмент NetHunter |
| `nethunter/` | CI-инструментарий: сборщик `vendor_dlkm.img`, верификатор EROFS, CFI-патчи out-of-tree драйверов |
| `nethunter/vendor_dlkm/` | манифест модулей устройства, списки load/softdep/block, SELinux `file_contexts` |
| `nethunter/ci/build-kernel.yml` | CI-конвейер |
| `AnyKernel3/` | упаковка и прошивка |

## Релизы

Смотри [Releases](../../releases) — каждый релиз соответствует сборке, проверенной на живом железе.

## Лицензия

GPL-2.0, унаследована от ядра Linux.
