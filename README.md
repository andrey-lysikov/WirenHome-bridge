# WirenHome bridge

**Русский** | [English](README.en.md)

Мост Apple Home для контроллеров Wiren Board.

[![Release](https://img.shields.io/github/v/release/andrey-lysikov/WirenHome-bridge)](https://github.com/andrey-lysikov/WirenHome-bridge/releases/latest)
[![Platform](https://img.shields.io/badge/platform-Wiren%20Board%20arm64-blue)](https://github.com/andrey-lysikov/WirenHome-bridge/releases/latest)

## Возможности

- Работает внутри веб-интерфейса Wiren Board: **Настройки** → **Конфигурационные файлы** → **Мост Apple HomeKit**.
- Вы сами выбираете, какие панели попадут в Apple Home; каждый виджет становится одним аксессуаром
- Роли виджетов: Авто, Свет, Розетка, Вентилятор, Термостат, Шторы, Кран, Протечка, Движение, Открытие, Ворота и Инфо (только чтение)
- Данные хранятся в /mnt/data/wirenhome-bridge

*ВНИМАНИЕ: мост не сертифицирован Apple, поэтому приложение «Дом» попросит подтвердить добавление несертифицированного аксессуара.*

## Установка

Нужна прошивка Wiren Board на Debian 13 или новее (arm64)

```bash
curl -fsSL https://andrey-lysikov.github.io/WirenHome-bridge/wirenhome-bridge.gpg -o /usr/share/keyrings/wirenhome-bridge.gpg
echo "deb [arch=arm64 signed-by=/usr/share/keyrings/wirenhome-bridge.gpg] https://andrey-lysikov.github.io/WirenHome-bridge stable main" > /etc/apt/sources.list.d/wirenhome-bridge.list
apt update
apt install wirenhome-bridge
```

Или установите последний пакет напрямую — он сам подключит репозиторий:

```bash
curl -fsSLO https://andrey-lysikov.github.io/WirenHome-bridge/wirenhome-bridge_latest_arm64.deb
apt install ./wirenhome-bridge_latest_arm64.deb
```

Обновление — обычным `apt update && apt upgrade`

## Настройка

1. Откройте веб-интерфейс Wiren Board → **Настройки** → **Конфигурационные файлы** → **Мост Apple HomeKit**.
2. Отметьте панели, которые нужны в Apple Home, и выберите роль для каждого виджета (Авто подходит для большинства датчиков и выключателей), затем нажмите **Сохранить**.
3. Отсканируйте QR-код со страницы камерой iPhone или в приложении «Дом»: **+** → **Добавить аксессуар** → **Другие параметры…** → **WirenHome XXXX** и введите код сопряжения.

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

Дополнительные настройки — в /etc/wirenhome-bridge.conf.

## Технологии

Написан на Swift 6; сборка `.deb` для Linux arm64 и релизы выполняются в GitHub Actions.
