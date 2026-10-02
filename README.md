# WirenHome bridge

**Русский** | [English](README.en.md)

Мост Apple Home для контроллеров Wiren Board.

[![Release](https://img.shields.io/github/v/release/andrey-lysikov/WirenHome-bridge)](https://github.com/andrey-lysikov/WirenHome-bridge/releases/latest)
[![Platform](https://img.shields.io/badge/platform-Wiren%20Board%20arm64-blue)](https://github.com/andrey-lysikov/WirenHome-bridge/releases/latest)

## Возможности

- Работает внутри веб-интерфейса Wiren Board: устройство «Мост Apple HomeKit» показывает статус, код сопряжения HomeKit и настройки моста, отдельное приложение не нужно
- Вы сами выбираете, какие панели попадут в Apple Home; каждый виджет становится одним аксессуаром
- Роли виджетов: Авто, Свет, Розетка, Вентилятор, Термостат, Шторы, Кран, Протечка, Движение, Открытие, Ворота и Инфо (только чтение)
- Данные хранятся в /mnt/data/wb-homekit

*ВНИМАНИЕ: мост не сертифицирован Apple, поэтому приложение «Дом» попросит подтвердить добавление несертифицированного аксессуара.*

## Установка

```bash
curl -fsSL https://andrey-lysikov.github.io/WirenHome-bridge/wb-homekit.gpg -o /usr/share/keyrings/wb-homekit.gpg
echo "deb [signed-by=/usr/share/keyrings/wb-homekit.gpg] https://andrey-lysikov.github.io/WirenHome-bridge stable main" > /etc/apt/sources.list.d/wb-homekit.list
apt update
apt install wb-homekit
```

Или установите последний пакет напрямую — он сам подключит репозиторий:

```bash
curl -fsSLO https://andrey-lysikov.github.io/WirenHome-bridge/wb-homekit_latest_arm64.deb
apt install ./wb-homekit_latest_arm64.deb
```

Обновление — обычным `apt update && apt upgrade`

## Настройка

1. Откройте веб-интерфейс Wiren Board → **Устройства** → **Мост Apple HomeKit**.
2. Включите панели, которые нужны в Apple Home.
3. Под каждой панелью выберите роль для каждого виджета (Авто подходит для большинства датчиков и выключателей).
4. В приложении «Дом» на iPhone: **+** → **Добавить аксессуар** → **Другие параметры…** → **WirenHome XXXX**, затем введите код сопряжения со страницы устройства.

Изменения панелей подхватываются автоматически примерно через полминуты после сохранения.

| Роль | Содержимое виджета | В Apple Home |
|---|---|---|
| Авто | что угодно | каждая ячейка отдельно: выключатели, датчики, диммеры |
| Свет | выключатель, по желанию диммер и/или RGB | лампа |
| Розетка | выключатель | розетка |
| Вентилятор | выключатель и/или скорость | вентилятор |
| Термостат | температура + записываемая уставка, по желанию выключатель | термостат |
| Шторы | положение или два выключателя (вверх, вниз) | шторы |
| Кран | выключатель | кран |
| Протечка / Движение / Открытие | вход или значение | датчик |
| Ворота | кнопки «открыть», «закрыть» (одна кнопка — импульсный вход) или выключатель; по желанию концевики «открыто», «закрыто» и авария | ворота: открыть/закрыть, открываются/закрываются |
| Инфо | что угодно | только датчики, ничего нельзя переключить |

Дополнительные настройки — в /etc/wb-homekit.conf.

## Технологии

Написан на Swift 6; сборка `.deb` для Linux arm64 и релизы выполняются в GitHub Actions.
