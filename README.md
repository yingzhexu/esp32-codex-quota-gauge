# Mechanical Gauge

A 3D-printed mechanical desk gauge. An SG90 servo turns a 74-tooth gear, the gear drives a rack, and a red arrow moves along a 90 mm tick scale. An ESP32 drives the servo; a macOS menu bar app turns your data into 0–100 % and sends it over Bluetooth LE.

One gauge and one firmware, two uses you switch between in the app:

- **Codex quota**: how much of your Codex 5-hour or weekly quota is left.
- **Game gauge**: reads a game's on-screen instruments in real time and shows them on the physical needle.
  - Racing: speedometer, tachometer (simulated from a gear table), manual tachometer (reads the game's rpm bar and lit gear).
  - Flight: speedometer, altimeter (reads drum counters).

[简体中文说明](README.zh-CN.md)

![Front, back and section views](hardware/images/V5_views.png)

## Downloads

- [macOS app (DMG)](release/MechanicalGauge.dmg)
- [Print-ready STL parts](hardware/STL/) · [STEP models and CAD source](hardware/CAD/)
- [ESP32 firmware](firmware/MechanicalGaugeBLE/) · [macOS app source](macos-app/) · [Python command-line tool](tools/python/)
- [Communication protocol and modification guide (Chinese)](docs/protocol-and-hacking.zh-CN.md)

> Not affiliated with OpenAI or any game publisher. Codex mode reads the quota from the Codex CLI already signed in on your Mac (`codex app-server`, read-only); no credentials are stored and no model calls are made. Game mode only captures the small screen area you select and recognises it on your Mac. It does not read game memory, inject anything or go online.

## Features

- 90 mm pointer stroke, tick-only solid faceplate, large arrow
- ESP32 sits in a pod on the back, USB-C exposed on the side
- Only **8 M2 screws**: faceplate hooks, slide-in pod lid, press-fit arrow
- Every part prints **without supports**
- macOS menu bar app: Codex quota and game gauge modes, test slider, numeric calibration, servo speed, launch at login, English and Chinese

## Game gauge

In the app, choose **Settings → Mode → Game gauge**, then open the **Game** tab:

1. **Pick the game and dial**

   | Game | Dial | Reads |
   |---|---|---|
   | Racing | Speedometer | The speed number on screen |
   | Racing | Tachometer (simulated) | The speed number, turned into engine rpm with a five-speed shift table |
   | Racing | Manual tachometer | The game's own rpm bar and the lit gear label |
   | Flight | Speedometer | The speed drum counter (e.g. `00897`) |
   | Flight | Altimeter | The altitude drum counter (e.g. `00049`) |

2. **Pick the region**: press **Pick region (in 3 s)**, switch to the game and drag a box around the number.
   - Box the digits only: not the gear (N/D), and not the scale labels beside a counter.
   - The manual tachometer needs two boxes: the rpm bar from end to end, and the gear row from the first label to the last.
   - Each dial keeps its own region.
   - In a full-screen game you can pick from the menu bar icon without leaving the game.

3. **Set the full scale**: speed, rpm, altitude, or the rpm at the right end of the bar, to match the game.

The first time, allow **机械指针 (Mechanical Gauge)** under System Settings → Privacy & Security → Screen & System Audio Recording, then reopen the app.

### How the recognition works

- **Capture**: ScreenCaptureKit captures only the selected area, at 30 frames per second.
- **Numbers**: read with Apple's Vision OCR in fast mode, 4–8 ms per frame.
  - The app counts the glyphs in the number. If the reading has fewer digits than that (e.g. `117` read as `7`), it reads the same frame again in accurate mode (about 20 ms).
  - Readings that jump too far from the current value are re-checked the same way. A confirmed real drop, such as a crash, is followed immediately.
- **Flight counters**: the app remembers the counter's fixed digit count and adds a 3-frame median plus adaptive One-Euro smoothing, so the needle ignores the rolling digits but still keeps up with climbs and dives.
- **Rpm bar and gear**: read straight from pixels (no OCR), about 1 ms per frame. While the bar flashes white and red at the redline, the needle holds full scale.
- **Sending**: up to 40 updates per second with Write Without Response.
- **Simulated tachometer**: idle wobble, clutch launch, late shifts under hard acceleration and early shifts when cruising, upshift dip, downshift blip, engine vibration and a rev limiter.

Frames where the fast and accurate readers disagree are saved to `~/Library/Application Support/MechanicalGauge/ocr-samples/` for diagnosis. The Game tab has a button to open the folder.

## Repository layout

| Path | Contents |
|---|---|
| `hardware/STL/` | Print-ready parts, already oriented for printing |
| `hardware/CAD/` | STEP files, the parametric CadQuery source (`build_v5.py`), `parameters.json` and check scripts |
| `hardware/images/` | Design overview and servo mounting images |
| `hardware/verification/` | Interference, rotation sweep, assembly path and gear mesh results |
| `firmware/MechanicalGaugeBLE/` | ESP32 BLE firmware (Arduino) |
| `firmware/ServoTest/` | USB-serial servo test sketch |
| `macos-app/` | Menu bar app source (`Sources/main.swift`, `Sources/game.swift`) and `build.sh` |
| `release/MechanicalGauge.dmg` | Prebuilt app (universal, macOS 14+) |
| `tools/python/` | Command-line BLE tool for Codex mode (`gauge_ble.py`) |
| `docs/protocol-and-hacking.zh-CN.md` | BLE protocol and how to repurpose the gauge (Chinese) |

## Bill of materials

| Item | Qty |
|---|---:|
| SG90 servo (180°) with its cross horn and screws | 1 |
| ESP32 DevKit, 30-pin, USB-C (51.85 × 28.35 mm, Ø3 holes 46.5 × 23.5 mm) | 1 |
| Female-female Dupont jumpers | 3 |
| M2×6 screws | 4 |
| M2×8 screws (or the long screws supplied with the SG90) | 2 |
| M2×12 screws (M2×10 also works) | 2 |
| PLA filament; printer bed ≥ 215 mm | |
| Optional: 470–1000 µF electrolytic capacitor | 1 |

## Printing

PLA at 0.2 mm layers; 4 walls for the gear and rack, 3 for everything else. Import at 100 % scale. The files are already oriented for printing.

**Turn supports off for every part.** Overhangs are short bridges (≤ 11 mm) or 45° slopes. Supports would grow into the tick grooves, the horn pocket, the rack teeth and the lid grooves, and you would not be able to assemble the parts.

| File | Qty | Notes |
|---|---:|---|
| `01_plaque_back` | 1 | 98.5 × 214 mm, back face down |
| `02_front` | 1 | Face down (ticks on the bed) |
| `03_pinion_74T` | 1 | Horn pocket down; enable elephant-foot compensation |
| `04_horn_keeper`, `05_rack_slider`, `06_arrow`, `07_pod_base`, `08_pod_lid` | 1 each | |
| `S_servo_ear_shim_1.0mm_print2` | 2 | Use the 0.5 / 1.5 / 2.0 mm shims only if needed |
| `T5_horn_fit` | 1 | Print first: about 10 min, checks the SG90 cross horn fit |
| `T1`–`T4`, `optional_horn_spacer_*` | optional | Fit test pieces |

## Wiring and power

| SG90 wire | ESP32 pin |
|---|---|
| Brown (GND) | **GND** |
| Orange (signal) | **D13** |
| Red (+) | **5V / VIN** if that pin carries 5 V from USB on your board; otherwise **3V3** |

- Do not plug the servo's 3-pin connector straight onto the header. The pin order does not match the board, and the servo would get reversed power. Use three separate jumpers.
- **Give it enough current.** The servo draws a lot when it starts and moves fast, and a Mac's USB port may not keep up. When it can't, the servo only hums, the arrow stays put and the ESP32 stops responding. A USB charger or a power bank fixes it; a 470–1000 µF capacitor across red and brown also helps.
- On a power bank the Mac controls the gauge over Bluetooth. Connect it to the computer only when flashing firmware.

## Assembly

1. Put two 1.0 mm shims on the ear posts. Drop the servo in from the front and route its lead through the tunnel under a post. Fix it with 2 × M2×8.
2. Plug the 3 jumpers onto the ESP32 (all at the USB end). Place the pod base on the back of the case. Seat the ESP32 component side out, pins in, so its USB-end holes go over the locating pins and the pins and jumpers pass through the two slots. Drive 2 × M2×12 through the board and pod into the case.
3. Slide the pod lid in from the antenna end until it clicks.
4. Inside the case, connect the jumpers to the servo lead.
5. In the app, press **Center 1500**.
6. Put the rack in the rail. Seat the cross horn in the gear pocket, fit the keeper with 2 × M2×6, then push the gear onto the servo spline and fit the horn's centre screw.
7. Faceplate: place it about 3.5 mm high, lower it over the arrow neck and gear hub, slide it down 3.5 mm so the bottom hooks engage, then fit 2 × M2×6 at the top.
8. Press the arrow onto the neck. If it is loose, add a drop of glue.
9. Calibrate 0 % and 100 % on the app's Calibration tab.

## Firmware

Open `firmware/MechanicalGaugeBLE/MechanicalGaugeBLE.ino` in the Arduino IDE with the ESP32 core 3.x installed. Select **ESP32 Dev Module** with **Flash Mode DIO, Flash Size 4MB, Upload Speed 115200**. With the default QIO / 921600 settings, some FT232 boards fail to read the flash.

```bash
arduino-cli compile --upload --fqbn "esp32:esp32:esp32:FlashMode=dio,FlashSize=4M,UploadSpeed=115200" -p /dev/cu.usbserial-XXXX firmware/MechanicalGaugeBLE
```

The firmware only understands percentages, so Codex and game modes share it; switching modes never needs a reflash. To stay compatible with boards already in use, it still advertises as **CodexGauge**. It accepts text commands over BLE (Nordic-style RX/TX characteristics) or USB serial at 115200 baud:

| Command | Action |
|---|---|
| `STATUS` | Report calibration, pulse and speed |
| `P <µs>` | Move to a raw pulse width (500–2500) |
| `CAL <µs0> <µs100>` | Save the 0 % / 100 % pulses |
| `Q <percent>` | Show a value (needs CAL) |
| `T <percent>` | Test position (needs CAL; not counted as data) |
| `SPEED <°/s>` | Servo speed 10–1000, saved (firmware V5; V4 stops at 400) |
| `STALE` / `OFF` | Mark data stale / release the servo |

The servo is released shortly after it reaches each target, so it does not buzz. Calibration and speed are kept in flash across power cycles and firmware updates.

## macOS app

Open `release/MechanicalGauge.dmg` and drag **机械指针 (Mechanical Gauge)** to Applications. The app is ad-hoc signed and not notarized, so the first time you open it, right-click the app and choose **Open**. Allow Bluetooth when macOS asks, and Screen Recording for the game gauge.

- **Menu bar**: the remaining percentage in Codex mode; speed, rpm or altitude in game mode. The gauge icon can be turned on in Settings.
- **Menu panel**: the 5-hour and weekly windows with reset times in Codex mode; the reading, gear and recognition status in game mode. It also holds the auto sync / live follow switch.
- **Settings & Calibration** has five tabs:
  - **Game**: game, dial, full scale, regions and a live preview.
  - **Test**: percentage slider and full sweep.
  - **Calibration**: type the pulse values, or jog the servo and capture each end.
  - **Settings**: mode (Codex quota or game gauge), quota shown, servo speed, refresh interval, language, menu bar icon, launch at login.
  - **Log**: commands and replies.

Testing or calibrating pauses sync; turn **auto sync / live follow** back on in the menu afterwards. Codex mode needs the Codex CLI, which comes with the ChatGPT desktop app, or a `codex` binary in `/opt/homebrew/bin`, `/usr/local/bin` or `~/.local/bin`, already signed in.

To build the app yourself (only the Command Line Tools are needed, not Xcode):

```bash
cd macos-app && ./build.sh
```

Every local build has a new ad-hoc signature, so macOS may silently drop the Screen Recording permission. If capture stops, remove 机械指针 from the Screen Recording list and allow it again.

## Python command-line tool

`tools/python/gauge_ble.py` is a command-line version of Codex mode: scan, calibrate, send raw commands and sync the quota on a timer (`pip install bleak`). On macOS, run it from a terminal that has Bluetooth permission.

## Regenerating the models

```bash
cd hardware/CAD
pip install -r requirements.txt
python build_v5.py          # STEP + STL + gear mesh check
python check_v5.py          # static interference at 0/25/50/75/100 %
python sweep_v5.py          # rotation sweep of gear, horn and screws
python assembly_path_v5.py  # straight-line insertion of every part
```

Servo, horn, board and gear dimensions live in `parameters.json`.

## Status

- **Hardware**: the V5 design passes all model checks (no tooth overlap, zero interference, rotation sweep and assembly path clear). The previous version (V4, 60 mm stroke) was built and calibrated successfully. V5 itself has not yet been fully printed and assembled. Please report fit issues.
- **Game gauge**: tested in Roblox racing and flight games. Fonts and instrument styles vary a lot between games. If recognition is off, please open an issue with a few images from `ocr-samples`.
