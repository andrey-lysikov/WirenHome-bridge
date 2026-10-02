# WirenHome bridge

[Русский](README.md) | **English**

Apple Home bridge for Wiren Board controllers.

[![Release](https://img.shields.io/github/v/release/andrey-lysikov/WirenHome-bridge)](https://github.com/andrey-lysikov/WirenHome-bridge/releases/latest)
[![Platform](https://img.shields.io/badge/platform-Wiren%20Board%20arm64-blue)](https://github.com/andrey-lysikov/WirenHome-bridge/releases/latest)

## Features

- Lives inside the Wiren Board web UI: **Settings** → **Configuration files** → **Apple HomeKit bridge**
- You choose which dashboards go to Apple Home; every widget becomes one accessory
- Widget roles: Auto, Light, Outlet, Fan, Thermostat, Blinds, Valve, Leak, Motion, Contact, Gate and Info (read-only)
- Save data in /mnt/data/wirenhome-bridge

*WARNING: the bridge is not certified by Apple, so the Home app asks you to confirm adding an uncertified accessory.*

## Install

Requires Wiren Board firmware based on Debian 13 or newer (arm64)

```bash
curl -fsSL https://andrey-lysikov.github.io/WirenHome-bridge/wirenhome-bridge.gpg -o /usr/share/keyrings/wirenhome-bridge.gpg
echo "deb [arch=arm64 signed-by=/usr/share/keyrings/wirenhome-bridge.gpg] https://andrey-lysikov.github.io/WirenHome-bridge stable main" > /etc/apt/sources.list.d/wirenhome-bridge.list
apt update
apt install wirenhome-bridge
```

Or install the latest package directly:

```bash
curl -fsSLO https://andrey-lysikov.github.io/WirenHome-bridge/wirenhome-bridge_latest_arm64.deb
apt install ./wirenhome-bridge_latest_arm64.deb
```

To update, run `apt update && apt upgrade`

## Setup

1. Open the Wiren Board web UI → **Settings** → **Configuration files** → **Apple HomeKit bridge**.
2. Tick the dashboards you want in Apple Home, pick a role for every widget (Auto fits most sensors and switches) and press **Save**.
3. Scan the QR code on the page with the iPhone camera, or in the Home app tap **+** → **Add Accessory** → **More options…** → **WirenHome XXXX** and enter the setup code.

Changes in dashboards are picked up automatically within about half a minute after you save them.

| Role | Widget contents | In Apple Home |
|---|---|---|
| Auto | anything | every cell on its own: switches, sensors, dimmers |
| Light | switch, optional dimmer and/or RGB | lightbulb |
| Outlet | switch | outlet |
| Fan | switch and/or speed | fan |
| Thermostat | temperature + writable setpoint, optional switch | thermostat |
| Blinds | position, or two switches (up, down) | window covering |
| Valve | switch | valve |
| Leak / Motion / Contact | input or value | sensor |
| Gate | "open" and "close" buttons (one button is an impulse input) or a switch; optional "open" and "closed" end sensors and an alarm | gate: open/close, opening/closing |
| Info | anything | sensors only, nothing can be switched |

Advanced settings are in /etc/wirenhome-bridge.conf.

## Tech

Written in Swift 6, Linux arm64 builds the `.deb` package and releases are made by GitHub Actions.
