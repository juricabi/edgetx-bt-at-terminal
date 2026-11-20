# DX-BT24-T Bluetooth telemetry on a HelloRadioSky V12

**How we got the EdgeTX telemetry mirror flowing from a soldered-in DX-BT24-T BLE module
into the [android-taranis-smartport-telemetry](https://github.com/RomanLut/android-taranis-smartport-telemetry) app,
and everything we learned on the way.**

Written 2026-08-01 · Radio: HelloRadioSky V12 (STM32H750) · Phone: Android

This is the story behind the [BT AT terminal](../README.md) in this repository: the
one-off scripts of that day grew into it.

---

## TL;DR

The app was never broken and needed no fork. The module's UART ran at its factory
default **9600 baud** while the radio's CRSF telemetry mirror transmits at **115200**.
The app connects over BLE, listens for up to 10 s for a recognizable telemetry
protocol (FrSky S.Port / CRSF / LTM / MAVLink), and reports **"connection failed"**
if all it hears is baud-mismatched garbage. Setting the module to 115200 with
`AT+BAUD7`, sent by the radio itself from a Lua script, fixed everything.

> ⚠️ The app's README says "configure the module for 57600 baud". That is
> **S.Port-era advice**. EdgeTX mirrors CRSF telemetry at **115200**
> (`CROSSFIRE_TELEM_MIRROR_BAUDRATE` in `radio/src/telemetry/crossfire.h`,
> selected in `radio/src/serial.cpp`). FrSky S.Port radios do mirror at 57600.

---

## The setup

```
 drone (ELRS/CRSF)
   │  RF link
   ▼
 HelloRadioSky V12 ── EdgeTX, AUX1 = UART4 (PH13 TXD / PH14 RXD, 3-pin header)
   │  "Telemetry Mirror" @ 115200, raw CRSF frames
   ▼
 DX-BT24-T (DA14531, BLE 5.1) ── transparent UART↔BLE bridge
   │  BLE notify, char FFE1
   ▼
 Android app ── auto-detects protocol, shows telemetry + map
```

- The module was renamed to **HelloRadioV12**.
- AUX1 on the V12 is in EdgeTX since [PR #7761](https://github.com/EdgeTX/edgetx/pull/7761)
  (*feat(v12): add AUX1 serial port on UART4*, merged 2026-10-07).

## Module facts (DX-BT24-T)

Learned from the vendor documentation and empirically over the air:

| Fact | Value |
|---|---|
| GATT layout | service `FFE0`; `FFE1` read/write/notify (data out); `FFE2` write (data in), HM-10 compatible |
| Advertising | legacy advertising; **stops while any central is connected** (single connection) |
| Factory defaults | 9600 8N1, name `BT24-T`, transparent mode ON |
| AT command format | UPPERCASE, terminated with `\r\n`, e.g. `AT+NAMEHelloRadioV12`, `AT+BAUD7` |
| AT is parsed | **only on the UART side, only while no BLE central is connected**. The BT24 guide lists `AT+TRANSPORT0` to change that; the BT24-T answers `+ERROR=104` to it |
| AT over BLE | **not supported** by this firmware: writes to FFE1/FFE2 are forwarded to the UART as data, never parsed |
| Baud table | `AT+BAUD<n>`: 1=2400 2=4800 3=9600 4=19200 5=38400 **6=57600 7=115200**; needs `AT+RESET` to apply |
| Manual quirk | the -T manual lists BAUD/NAME as "query-only, contact sales"; **the set forms work anyway** (the manual's own examples use them) |
| Error codes | 101 param length · 102 param format · 103 param data · 104 unknown command |

## Why the app said "connection failed"

The app's BLE path (`BluetoothLeDataPoller.kt`) is very tolerant, which is why no fork was needed:

1. Connects GATT, requests MTU 67, discovers services.
2. Subscribes to **every characteristic with the notify property** (no UUID filtering at all).
3. Feeds incoming bytes to a `ProtocolDetector` (FrSky S.Port / CRSF / LTM / MAVLink v1/v2).
4. If no protocol is recognized within **10 seconds** → disconnect → **"Connection failed"**.

At 9600 vs 115200 the module forwards deterministic garbage, the detector never
fires, and the app gives up. Vendor test apps (DXSmart) happily display that
garbage as "data", which makes the module look healthier than it is.

## The debugging journey

1. **Read the app source**: there is no UUID filter and no pairing requirement,
   so "module incompatible" was ruled out early.
2. **Probed the module from the PC** (Python + WinRT, direct connect by MAC;
   the PC's Bluetooth adapter rarely heard its advertisements, but
   `BluetoothLEDevice.FromBluetoothAddressAsync` connects regardless):
   full GATT dump, subscribed to FFE1, captured the live stream.
3. **First capture (module @ 9600):** 150 bytes in 15 s of `66 fe 66 fe 24 fc …`,
   only 6 distinct byte values, no framing. Classic "UART sampling ~6× too slow".
4. **Reprogrammed via the radio itself.** The module is soldered in, so we used
   an EdgeTX Lua tool (`serialWrite` on the LUA-mode serial port) to send
   `AT+NAMEHelloRadioV12` + `AT+BAUD6` (57600, per the app README).
   *Pitfall:* the first attempt silently failed because **the phone was connected
   to the module**: a connected BT24 forwards UART bytes to the phone instead of
   parsing them as AT commands.
5. **Baud-detector trick.** With replies initially invisible, we made the radio
   cycle through 9600…115200 sending `MARKER<baud>` text lines while the PC
   captured over BLE ([`extras/bt24test.lua`](../extras/bt24test.lua)).
   `MARKER57600` arrived intact: proof the earlier `AT+BAUD6` had actually worked.
6. **Still garbled telemetry @ 57600:** a rock-stable **23-byte repeating pattern**,
   the half-rate signature of 46-byte CRSF frames at 2× the listening baud.
   Checked the EdgeTX source: CRSF mirror = **115200**. (A naive frame-sniffing
   analyzer initially called this garbage "valid CRSF": frame validation without
   CRC checking is worthless.)
7. **Final hop:** Lua tool again → `AT+BAUD7` → module confirmed `+BAUD=7`
   on-screen (two-way AT visible this time, proving UART4 RX works too).
8. **CRC-validated verification:** 20 s capture → **400/400 frames CRC-valid
   (CRC8-DVB-S2)**: link statistics `0x14`, attitude `0x1E`, battery `0x08`,
   flight mode `0x21`, ~230 B/s. App connected instantly.

## Verified working configuration

| Item | Value |
|---|---|
| EdgeTX AUX1 (UART4) mode | `Telemetry Mirror` |
| Mirror baud (CRSF, fixed in firmware) | 115200 |
| BT24-T baud | 115200 (`AT+BAUD7`) |
| BT24-T name | `HelloRadioV12` |
| Protocol detected by app | CRSF |
| App connection type | Bluetooth LE |

## The tools

- **[`btterm.lua`](../btterm.lua)**, the BT AT terminal of this repository, does today
  what the first scripts did by hand: it tests the link, sets the baud rate and the
  name, resets the module and scans for a module whose baud rate is unknown.
- **[`extras/bt24test.lua`](../extras/bt24test.lua)** is the baud detector of step 5.
  It needs no AT at all: it cycles through the baud rates sending `MARKER<baud>` lines,
  and whichever arrives intact over BLE is the module's true baud. Useful when
  everything else is uncertain and a PC or phone can show the raw BLE data.

For any AT work: set AUX1 to `LUA` mode first, make sure **no phone or PC is connected**
to the module (its LED must blink), and set the port back to `Telemetry Mirror` afterwards.

The PC-side probe scripts (Python, `bleak` / `winrt`) are not included. The essential
techniques are: connect by MAC (`FromBluetoothAddressAsync`) instead of scanning,
subscribe to FFE1, and validate CRSF frames with CRC8-DVB-S2 before trusting any capture.

## Pitfalls checklist (the ones that bit us)

- [ ] **Phone auto-reconnects** (DXSmart, nRF Connect) hold the module's single
  connection slot → it stops advertising, ignores AT, and nobody else can connect.
  Turn phone Bluetooth fully OFF while working on the module.
- [ ] Module in transparent mode + connected central = AT commands become data.
- [ ] Vendor apps showing "data" prove nothing about baud correctness.
- [ ] The -T manual's "query only" is wrong for NAME/BAUD: just try the set form.
- [ ] The app README's 57600 applies to S.Port radios only; CRSF mirrors at 115200.
- [ ] EdgeTX Lua: the baud function was `setSerialBaudrate()` on that build
  (older API name; `serialSetBaudrate` in newer docs). Support both in scripts.
- [ ] Don't trust frame-pattern "detection" without CRC validation.
- [ ] Windows caches BLE device names: a cached name is not proof the device is
  reachable *now*.
