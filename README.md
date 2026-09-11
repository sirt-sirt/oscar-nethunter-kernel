<div align="center">
  <h1>NetHunter Custom Kernel</h1>
  <h3>Realme 9 Pro 5G (oscar)</h3>
  
  <p>
    <a href="https://github.com/sirt-sirt/oscar-nethunter-custom_kernel/actions/workflows/build-kernel.yml">
      <img src="https://github.com/sirt-sirt/oscar-nethunter-custom_kernel/actions/workflows/build-kernel.yml/badge.svg" alt="Build Status">
    </a>
  </p>
</div>

---

## Поддерживаемые устройства
* **Устройство:** Realme 9 Pro 5G
* **Кодовое имя:** `oscar` (RMX3471 / RMX3472)
* **Процессор:** Qualcomm Snapdragon 695 5G (`sm6375` / `holi`)
* **Базовая прошивка:** LineageOS 21 (Android 14)
* **Версия ядра:** Linux 5.4.280-qgki

---

## Особенности (Патчи NetHunter)

Данное ядро было модифицировано специально для проведения аудита информационной безопасности с использованием мобильной платформы **Kali NetHunter**.

### Поддержка Kali Chroot
* **System V IPC (`SYSVIPC`)**: Включена поддержка для корректной работы баз данных PostgreSQL и Metasploit.
* **Linux Namespaces**: Активирована полная изоляция (`PID_NS`, `NET_NS`, `USER_NS`, `IPC_NS`, `UTS_NS`) для обеспечения работоспособности chroot-окружения NetHunter и выполнения операций без root-прав в рамках контейнера.

### Беспроводные сети и пакетные инъекции (Monitor Mode)
* **Wireless Extensions (`CFG80211_WEXT`)**: Включена совместимость со старыми API, необходимыми для работы утилит `airodump-ng` и `aireplay-ng`.
* **Поддержка вендора Realtek**: Активированы staging-драйверы для внешних Wi-Fi адаптеров.
* **Скомпилированные модули**: Драйверы `r8188eu.ko` (TP-Link TL-WN722N v2/v3), `rtl8xxxu.ko` и криптографические библиотеки (`lib80211`) компилируются вместе с ядром и автоматически устанавливаются в систему с помощью AnyKernel3.

### USB OTG и внешнее оборудование
* **USB Serial / ACM**: Активированы параметры `CONFIG_USB_ACM` и `CONFIG_USB_SERIAL` для работы с SDR и RFID-оборудованием (Proxmark3, HackRF One).
* **Серийные адаптеры**: Добавлена поддержка чипов `PL2303`, `FTDI_SIO`, `CH341` и `CP210X` (охватывает большинство внешних беспроводных адаптеров).
* **Bluetooth**: Параметр `CONFIG_BT_HCIBTUSB` включен для поддержки внешних USB Bluetooth-адаптеров (например, CSR8510). Параметр `BT_BNEP` активирован для сетевой инкапсуляции и Bluetooth-атак.

### Инженерные исправления
* **Удаление LTO и CFI**: Отключены параметры `CONFIG_LTO_CLANG` и `CONFIG_CFI_CLANG` для устранения критических ошибок линкера `ld.lld: R_AARCH64_ABS32` и обхода жестких проверок Control Flow Integrity, блокирующих пакетные инъекции.
* **Исправление файловой системы Windows**: Устранены конфликты регистра в подсистеме `net/netfilter` (например, `xt_dscp.c` против `xt_DSCP.c`), возникавшие при клонировании репозитория в ОС Windows, что препятствовало компиляции модуля `iptables`.
* **Proton Clang**: Ядро скомпилировано с использованием Proton Clang 13.0.0 с принудительным использованием LLVM линкера и ассемблера.

---

## Установка

Ядро упаковано с помощью **AnyKernel3** и устанавливается поверх LineageOS без изменения вендорных разделов и `ocdt`.

1. Перейдите на вкладку **[Actions](https://github.com/sirt-sirt/oscar-nethunter-custom_kernel/actions)**.
2. Выберите последний успешный запуск **Build NetHunter Kernel (oscar)**.
3. Скачайте артефакт `NetHunter-Kernel-oscar.zip` внизу страницы.
4. Распакуйте скачанный ZIP-архив **один раз**, чтобы получить внутренний установочный файл `NetHunter-Kernel-oscar.zip`.
5. Выполните прошивку:
   * **Lineage Recovery / TWRP:** `Apply Update` -> `Choose from SD card` (или `adb sideload`).
   * **Magisk:** Модули -> Установить из хранилища.
6. Перезагрузите устройство.

---

## Компиляция (GitHub Actions)

Для сборки ядра локальная Linux-машина не требуется. Процесс полностью автоматизирован через GitHub Actions.
1. Сделайте форк данного репозитория.
2. Перейдите на вкладку `Actions` и включите workflows.
3. Выберите `Build NetHunter Kernel (oscar)` и нажмите **Run workflow**.
4. Модули `.ko` и бинарный файл ядра `Image` будут автоматически собраны и упакованы в архив AnyKernel3.

> **Примечание:** Скрипт AnyKernel настроен с параметром `do.modules=1`, что обеспечивает автоматическую распаковку и установку внешних Wi-Fi модулей Realtek в системный раздел при прошивке архива.
