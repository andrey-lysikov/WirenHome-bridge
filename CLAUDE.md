# WirenHome-bridge

Мост между контроллером Wiren Board и Apple Home (HomeKit). Работает как системный плагин на самом Wiren Board: читает устройства из MQTT и панели веб-интерфейса, публикует виджеты как HomeKit-аксессуары (HAP Bridge).

## Стек и платформы

- Swift 6, `swift-tools-version: 6.2`, strict concurrency (Swift 6 language mode).
- Mac для разработки: macOS 26+, Apple Silicon.
- Swift Package Manager, исполняемый таргет `wb-homekit`.
- Разработка и запуск: Xcode на macOS (открыть `Package.swift`, Cmd+R). Проект всегда должен собираться и запускаться в Xcode.
- Продакшн: только штатная прошивка Wiren Board на Debian 13 Trixie и новее, arm64, работа внутри контроллера. Debian 11 (glibc 2.31, libstdc++ 10) не поддерживается.

## Кросс-платформенность (обязательно)

Код должен одинаково собираться на macOS и Linux arm64:

- Запрещены Apple-only фреймворки: `HomeKit`, `Combine`, `Network`, `CryptoKit`, `os.log`, `Dispatch`-специфичные API macOS, `NetService`/`Bonjour` напрямую.
- Минимум сторонних библиотек. Любую новую зависимость согласовывать явно, указав, для какой функции она нужна.
- Согласованные зависимости:
  - `apple/swift-crypto` — Ed25519, X25519, ChaCha20-Poly1305, HKDF/SHA-512 (HAP).
  - `swift-server-community/mqtt-nio` 2.x — MQTT-клиент; его SwiftNIO (`NIOCore`, `NIOPosix`, `NIOHTTP1`, подключён напрямую) используется и для TCP/HTTP-сервера HAP, и для HTTP-клиента панелей.
- SRP-6a (Pair-Setup: 3072, g=5, SHA-512, `g` в M1 без паддинга) и `BigUInt` — своя реализация, обязательно с тестовыми векторами HAP.
- В коде моста только `FoundationEssentials` на Linux (`#if canImport(FoundationEssentials)`, на macOS — Foundation): без `Process`, `FileHandle`, `NSLock`, `String(format:)`, `components(separatedBy:)`, `trimmingCharacters`, `replacingOccurrences`. Замены — `Common` (`Subprocess` на `posix_spawn`, `trimmed`, `percentDecoded`, `hex`), `Mutex` из `Synchronization`, запись лога через `write(2)`. Тесты могут импортировать полную Foundation.
- JSON — `Codable`. TLV8 — своя реализация с фрагментацией (>255 байт).
- mDNS — API `dns_sd`: на macOS системный, на Linux `libavahi-compat-libdnssd` загружается через `dlopen("libdns_sd.so.1")` при старте. Нет библиотеки → понятная ошибка с `apt install libavahi-compat-libdnssd1` и выход с ненулевым кодом; не запущен avahi-daemon → аналогично.
- Платформенные различия изолировать за протоколами, не размазывать `#if` по коду.
- Foundation — только то, что есть в swift-corelibs-foundation.

## Интеграция с Wiren Board

Плагин — страница настроек «Мост Apple HomeKit» в «Настройки → Конфигурационные файлы» (общая форма confed по JSON-схеме); своего фронтенда и устройства в «Устройствах» нет. Свою страницу, как у DALI (`"editor": "dali"`), пакет добавить не может: такие страницы зашиты в `wb-mqtt-homeui`.

- Схему генерирует мост: `/var/lib/wb-mqtt-confed/schemas/wb-homekit.schema.json` (confed следит за каталогом через inotify, перезапуск не нужен); `configFile.validate: false`, без `service`. Переписывается только при изменении содержимого.
- Вверху (описание корня, HTML через DOMPurify формы): статус (загрузка, ожидание сопряжения, работает, остановлен), число аксессуаров, предупреждений, «Версия приложения», PIN, QR-код (SVG от `qrencode`, зависимость пакета) и строка `X-HM://…`.
- Поля формы: `dashboards.<id>.enabled` (публиковать панель), `dashboards.<id>.roles.<widgetId>` (код роли, `enum_titles`), `reset_pairing` (галочка: при сохранении сбросить сопряжение, новый PIN и Setup ID, мост снимает её сам), `mqtt`. Виджет, показанный на нескольких панелях, — только под первой.
- Тексты — ключи и английские подписи в `title`/`enum_titles`/`description`, переводы в `translations.ru`/`translations.en` схемы. Предупреждения виджета — `description` поля роли (`warning-<widgetId>`).
- `/etc/wb-homekit.conf` пишет форма; мост читает его раз в 2 с и применяет без перезапуска; смена `mqtt` → выход, systemd перезапускает. Источник истины — `state.json` в `/mnt/data`; при первом запуске после обновления (в файле нет `dashboards`) выбор переносится из `state.json` в файл. Файл `0600` (пароль MQTT).
- Устройство `/devices/wb-homekit` из версий до 0.3 мост удаляет: на любой retained-топик под ним публикует пустой retained.
- Устройства и контролы — из `/devices/+/controls/+` и JSON в `.../meta` (`type`, `readonly`, `units`, `max`, `title`, `error`). Комнат в MQTT нет.
- Панели (рабочие столы) — `GET http://<хост MQTT>/api/dashboards` (бэкенд веб-интерфейса за nginx; в MQTT и confed их нет); при ошибке HTTP (например, нужен вход) — чтение `/etc/wb-webui.conf`. Ответ без массива `dashboards` — ошибка, не пустой список. `widgets` панели — список или колонки (`[[…]]`). Опрос раз в 10 с, правки применяются, когда два опроса совпали.
- Выбор панелей и ролей — на странице настроек; хранится в `state.json` и `/etc/wb-homekit.conf`.
- Виджет панели = один HAP-аксессуар, ячейка `device/control` = сервис. Дубли ячеек, несуществующие устройства, виджеты и ячейки с пустым именем пропускаются.
- Имена: аксессуар — имя виджета, сервис — имя ячейки; автоматически приводятся к правилам iOS (буквы, цифры, пробел, `-`, `'`; `₂` → `2`).
- Ячейки-разделители `separatorN` при переводе пропускаются.
- Роль виджета (код в `AccessoryRole.code`, не перенумеровывать): Авто, Свет, Розетка, Вентилятор, Термостат, Шторы, Кран, Протечка, Движение, Открытие, Ворота, Инфо (только чтение: все ячейки — датчики, записи из HomeKit не принимаются). Ячейки раскладываются по типу из MQTT, при неоднозначности — по порядку в виджете; не подошло → «Авто» + предупреждение у роли.
- Тип сервиса определяется по `meta` из MQTT, а не по `type` ячейки виджета. Мощность (`power`, `W`) — характеристика Eve на основном сервисе аксессуара. События из WB в HomeKit — не чаще раза в секунду на характеристику.
- Перевод: `CellKind` (классификация контрола) → `AccessoryMapper` (сервисы по роли, стабильные `aid`/`iid` в `state.json`) → `Source` (чтение/запись одной характеристики). Значения читаются из реестра WB на лету; запись публикуется в `/on` и сразу применяется к реестру оптимистично.
- HomeKit-сервер стартует только после первой сборки аксессуаров (иначе iOS увидит пустой мост и удалит устройства). Исчезнувший контрол сохраняет последний известный тип.
- Язык формы выбирает браузер (контроллер его не знает): все тексты — через `translations` схемы с `ru`/`en`, значения в файле — коды, числа, флаги. Предупреждения — `MappingIssue`; в логе — на английском.
- Сервер HAP слушает все интерфейсы, только IPv4 (`0.0.0.0`); ограничение сети — средствами Wiren Board.
- Поток двусторонний: запись из HomeKit → `/devices/<d>/controls/<c>/on`; изменение `/devices/<d>/controls/<c>` → `EVENT` подписанным сессиям (кроме автора записи, без событий при неизменном значении).
- Репозиторий: https://github.com/andrey-lysikov/WirenHome-bridge (apt-репозиторий будет на https://andrey-lysikov.github.io/WirenHome-bridge).
- Тестовый контроллер в сети: `172.30.212.48` (WB 8.5, `wb-2606`), MQTT `1883` без авторизации.
- MQTT: на контроллере только `localhost:1883`, при запуске из Xcode — IP контроллера (`--mqtt-host`). Поддержка логина/пароля MQTT.
- PIN и Setup ID генерируются случайно при первом запуске (тривиальные коды запрещены HomeKit). QR-код: `HAPSetupPayload.uri` (`X-HM://`, категория «мост», IP), в mDNS — `sh` (SHA-512 от Setup ID + id моста).

## Архитектура

- Состояние устройств и моста — в `actor`; типы между акторами — `Sendable`.
- Без глобального изменяемого состояния, без `@unchecked Sendable` без крайней необходимости.
- Слои: MQTT-клиент → модель Wiren Board (устройства, панели) → маппинг в HAP-аксессуары → HAP-сервер.
- Модули: `Common` (лог), `WBKit` (MQTT, топики/meta WB, реестр устройств, HTTP-клиент и источник панелей, виртуальное устройство), `HAPKit` (TLV8, `BigUInt`, SRP, шифрование сессии, HTTP, `HAPController` — логика HAP без сети, `HAPServer` — TCP на NIO), `Discovery` (mDNS через `dns_sd`), `Bridge` (настройки, состояние, плагин, аксессуары, `BridgeApp`/`BridgeRunner`), `WirenHome` (точка входа).
- Файлы в каталоге данных: `state.json` (PIN, Setup ID, панели, роли), `homekit.json` (id моста, Ed25519-ключ, сопряжения, `c#`); оба `0600`.
- SRP как в fast-srp-hap (homebridge): `B` и `S` дополняются до 384 байт, `g` в M1 без дополнения, `A` берётся как пришёл; эталонные значения в `Tests/HAPKitTests/SRPVectors.swift`.
- Имя моста в HomeKit и mDNS: `WirenHome XXXX` (хвост id), производитель `WirenHome`. Мост слушает случайный порт, порт объявляется через mDNS.
- Запуск из Xcode: в схеме `WirenHome` → Run → Arguments: `--mqtt-host 172.30.212.48`; данные на macOS — `~/Library/Application Support/WirenHome`. MQTT client id на macOS `wb-homekit-dev`, не запускать одновременно со службой на контроллере.
- `aid`/`iid` стабильны: ключи виджетов и ячеек сохраняются в файле состояния.
- Состояние (ключи, сопряжения, PIN, таблица `aid`/`iid`, `c#`, выбор панелей) — в каталоге данных, всегда `/mnt/data/wb-homekit` (энергонезависимый раздел WB, переживает перепрошивку); не настраивается, `--data-dir` только для разработки. `/etc/wb-homekit.conf` — форма настроек (MQTT, панели, роли).
- Удаление аксессуаров — только по явному изменению панелей; при старте список аксессуаров отдаётся после синхронизации retained MQTT; правки панелей применяются после паузы.

## Сборка и деплой

- Локально (macOS): только разработка и тесты — Xcode (схема `WirenHome`), `swift build`, `swift test`, запуск против тестового контроллера.
- Проект лежит в `~/Documents` (iCloud): из CLI собирать с `--scratch-path ~/Library/Caches/WirenHome-build`, иначе codesign тестов падает на xattr. Xcode (DerivedData) не затронут.
- Сборка arm64 и `.deb` — только в GitHub Actions (раннер `ubuntu-26.04-arm`, сборка в контейнере `swift:6.4.0-bookworm` ради glibc 2.36; версия закреплена, с ней меняется ключ кэша); локально пакеты не собираем.
  - `build.yml` — тесты, сборка, `.deb` в артефакт запуска (только вручную; также вызывается из `release.yml`); `.build` кэшируется по `Package.resolved`/`Package.swift`.
  - `release.yml` вызывает `build.yml` со `strip: true` (бинарник без отладочной информации) — релиз `v<версия>` с `.deb`, если версия выше последнего тега и в `changelog.md` есть непустой раздел `## <версия>`.
- Версия — две цифры (`0.1`), единственный источник `Sources/WirenHome/Version.swift`; читает `packaging/version.sh`.
- Пакет собирает `packaging/build-deb.sh`; `Depends` на libc считает `dpkg-shlibdeps`. В пакете: бинарник, служба, источник apt и ключ `packaging/wb-homekit.gpg` (без ключа пакет собирается, но без обновлений); `Depends` также на `qrencode`. `/etc/wb-homekit.conf` и схему confed создаёт мост; `postrm` удаляет схему при remove и конфиг при purge.
- `release.yml` кладёт `.deb` в `gh-pages` (`pool/main`, `dists/stable`, последние 5 версий) и подписывает `InRelease`/`Release.gpg` ключом из `APT_SIGNING_KEY` (без пароля).
- Linux arm64: glibc-сборка с `--build-system native --static-swift-stdlib` (Swift Build в 6.4.0 теряет статические зависимости Foundation, swiftlang/swift-build#1764; флаг убрать после перехода на 6.4.2) в Debian 12 Bookworm (glibc вперёд-совместима, пакет требует glibc ≥ 2.35 и libstdc++ gcc 11+, работает на Debian 13); musl не подходит из-за `dlopen`.
- Поставка: `.deb` с `/usr/bin/wb-homekit` и службой systemd `wb-homekit.service` (`After=mosquitto.service`, `Restart=always`); `Depends:` на `libavahi-compat-libdnssd1` и `libc6` по факту сборки.
- Логи на контроллере: `journalctl -u wb-homekit -f`.
- Обновления — свой apt-репозиторий на GitHub Pages (ветка `gh-pages`), индексы подписаны GPG (секрет `APT_SIGNING_KEY`); `release.yml` публикует туда `.deb`.
  - Пакет ставит `/etc/apt/sources.list.d/wb-homekit.list` и `/usr/share/keyrings/wb-homekit.gpg`; дальше обновление обычным `apt update && apt upgrade`.
  - Мост обновления не проверяет и не ставит, в плагине только контрол «Версия приложения»; обновляет пользователь сам через apt.

## Правила кода

- Каждый исходник (Swift, shell) начинается с заголовка (в `Package.swift` — сразу после `swift-tools-version`):
  ```swift
  //  Copyright © AndreyLysikov
  //  SPDX-License-Identifier: Apache-2.0
  ```
- Комментарии только в коде, на английском, не больше 2 строк, коротко и по сути.
- Не добавлять документацию/markdown-файлы без запроса (есть `README.md` — русский, `README.en.md` — английский, держать в синхроне; `changelog.md`, `CLAUDE.md`).
- После изменений проверять `swift build` и `swift test` локально; Linux-сборку проверяет CI.
