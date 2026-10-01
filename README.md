# WirenHome bridge

Apple Home bridge for Wiren Board controllers.

[![Release](https://img.shields.io/github/v/release/andrey-lysikov/WirenHome-bridge)](https://github.com/andrey-lysikov/WirenHome-bridge/releases/latest)
[![Build](https://github.com/andrey-lysikov/WirenHome-bridge/actions/workflows/build.yml/badge.svg)](https://github.com/andrey-lysikov/WirenHome-bridge/actions/workflows/build.yml)
[![Platform](https://img.shields.io/badge/platform-Wiren%20Board%20arm64-blue)](https://github.com/andrey-lysikov/WirenHome-bridge/releases/latest)

## Features

- Lives inside the Wiren Board web UI: the device "Bridge Apple HomeKit" shows the status, the HomeKit setup code and the bridge settings, no separate app is needed
- You choose which dashboards go to Apple Home; every widget becomes one accessory
- Widget roles: Auto, Light, Outlet, Fan, Thermostat, Blinds, Valve, Leak, Motion, Contact and Info (read-only)
- Auto updates check (and update via apt)
- Save data in /mnt/data/wb-homekit

*WARNING: the bridge is not certified by Apple, so the Home app asks you to confirm adding an uncertified accessory.*

## Install

On the controller, download the package from the [latest release](https://github.com/andrey-lysikov/WirenHome-bridge/releases/latest) and install it:

```bash
apt install ./wb-homekit_*_arm64.deb
```

## Setup

1. Open the Wiren Board web UI → **Devices** → **Мост Apple HomeKit**.
2. Turn on the dashboards you want in Apple Home.
3. Under each dashboard pick a role for every widget (Auto fits most sensors and switches).
4. In the Home app on iPhone: **+** → **Add Accessory** → **More options…** → **WirenHome XXXX**, then enter the setup code shown on the device page.

Changes in dashboards are picked up automatically within about half a minute after you save them. Problems such as a missing device or a widget that does not fit its role are counted under **Warnings** and described next to the widget's role. The plugin follows the language of the Wiren Board web UI (Russian or English).

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
| Info | anything | sensors only, nothing can be switched |

Advanced Settings in /etc/wb-homekit.conf 

## Tech

Written in Swift 6, Linux arm64 builds the `.deb` package and releases are made by GitHub Actions.
