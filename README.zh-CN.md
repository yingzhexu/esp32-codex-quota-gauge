# Codex 额度指针

一个 3D 打印的桌面指针，显示 **Codex** 使用额度还剩多少：SG90 舵机转动 74 齿齿轮，齿轮推动齿条，红色箭头沿 90 mm 刻度上下移动。ESP32 控制舵机，Mac 菜单栏 App 读取额度，再通过蓝牙发给 ESP32。

[English](README.md)

## 下载入口

- [下载 Mac App 安装包（DMG）](https://github.com/yingzhexu/esp32-codex-quota-gauge/raw/refs/heads/main/release/CodexGauge.dmg)
- [可直接打印的 STL 零件](hardware/STL/) · [STEP 模型与 CAD 源码](hardware/CAD/)
- [ESP32 固件](firmware/QuotaGaugeBLE/) · [Mac App 源码](macos-app/) · [Python 辅助工具](tools/python/)
- [通信协议与改造指南](docs/protocol-and-hacking.zh-CN.md)

> 与 OpenAI 无关。App 只是读取你 Mac 上已登录的 Codex 命令行（`codex app-server`，只读），不保存账号信息，也不调用模型。

## 功能

- 90 mm 行程，实心面板只有刻度，配大箭头
- ESP32 装在背面小仓里，USB-C 从侧面露出
- 只用 **8 颗 M2 螺丝**：面板挂钩、抽拉式盖板、压入式箭头
- 所有零件**不需要支撑**
- Mac 菜单栏 App：实时显示 5 小时 / 每周额度、自动同步、测试滑块、数值校准、转速调节、开机启动、中英双语

## 目录

| 路径 | 内容 |
|---|---|
| `hardware/STL/` | 可直接打印的零件，已按打印方向摆好 |
| `hardware/CAD/` | STEP 文件、参数化建模源码 `build_v5.py`、`parameters.json` 和检查脚本 |
| `hardware/images/` | 设计总览、舵机安装示意图 |
| `hardware/verification/` | 干涉、旋转扫掠、装配路径、齿形检查结果 |
| `firmware/QuotaGaugeBLE/` | ESP32 蓝牙固件（Arduino） |
| `firmware/ServoTest/` | USB 串口舵机测试程序 |
| `macos-app/` | 菜单栏 App 源码和 `build.sh` |
| `release/CodexGauge.dmg` | 编译好的 App（通用版，macOS 13+） |
| `tools/python/` | 可选的命令行蓝牙桥接 |
| `docs/` | 通信协议、工作原理及接入其他数据源的改造指南 |
| `docs/protocol-and-hacking.zh-CN.md` | 蓝牙协议与改造成其他仪表的指南 |

## 材料

| 物品 | 数量 |
|---|---:|
| SG90 舵机（180°），带十字舵盘和螺丝 | 1 |
| ESP32 30 针 USB-C 开发板（51.85 × 28.35 mm，Ø3 孔，孔距 46.5 × 23.5） | 1 |
| 母对母杜邦线 | 3 |
| M2×6 螺丝 | 4 |
| M2×8 螺丝（或舵机附带的长螺丝） | 2 |
| M2×12 螺丝（M2×10 也可） | 2 |
| PLA 耗材；打印平台 ≥ 215 mm | |

## 打印

PLA，0.2 mm 层高；齿轮、齿条 4 道墙，其余 3 道。导入时保持 100% 比例，零件已经按打印方向摆好。

**所有零件都关闭支撑。** 悬空处都是短桥接（≤ 11 mm）或 45° 斜面。如果加了支撑，支撑会长进刻度槽、舵盘槽、齿条齿面和盖板导槽里，拆不干净就装不上。

| 文件 | 数量 | 说明 |
|---|---:|---|
| `01_plaque_back` | 1 | 98.5 × 214 mm，背面朝下 |
| `02_front` | 1 | 正面朝下（刻度在热床面） |
| `03_pinion_74T` | 1 | 舵盘槽朝下，开象脚补偿 |
| `04`～`08` | 各 1 | |
| `S_servo_ear_shim_1.0mm_print2` | 2 | 0.5 / 1.5 / 2.0 mm 备用 |
| `T5_horn_fit` | 1 | **建议先打**，约 10 分钟，试十字舵盘松紧 |
| `T1`～`T4`、`optional_horn_spacer_*` | 可选 | 试配件 |

## 接线

| SG90 线 | ESP32 |
|---|---|
| 棕（地） | **GND** |
| 橙（信号） | **D13** |
| 红（电源） | **3V3**（很多 USB-C FT232 板的 VIN 插 USB 时没有 5V 输出） |

不要把舵机 3 针插头直接插在排针上：引脚顺序对不上，会把舵机电源接反。要用 3 根杜邦线分开接。如果舵机一转板子就重启，在红棕两线之间加一个 470～1000 µF 电容。

## 装配

1. 安装座上放两片 1.0 mm 垫片，舵机从正面放入，舵机线从立柱下的出线口穿出，用 2 颗 M2×8 固定。
2. 先把 3 根杜邦线插到 **3V3、GND、D13**（都在 USB 那一端）。把背仓底座贴到后壳背面，ESP32 元件面朝外、排针朝里，USB 端的两个孔套进定位销，排针和杜邦线一起穿过长槽。2 颗 M2×12 穿过板子和背仓，拧进后壳。
3. 盖板从天线那一端推进去，"咔"一声卡住。
4. 在壳内把杜邦线接到舵机线上。
5. 在 App 里点"回中 1500"。
6. 齿条放进导轨；十字舵盘放进齿轮的槽里，盖上压盖，拧 2 颗 M2×6；然后把齿轮套到舵机轴上，拧上舵盘中心螺丝。
7. 面板：先往上错开约 3.5 mm 放下（滑槽套过指针颈，中间孔套住齿轮轴），再往下推 3.5 mm，让底部挂钩卡住，最后拧上顶部 2 颗 M2×6。
8. 把箭头压到指针颈上，松的话点一滴胶。
9. 在 App 里校准 0% 和 100%。

## 固件

用 Arduino IDE（ESP32 开发板支持包 3.x）打开 `firmware/QuotaGaugeBLE/QuotaGaugeBLE.ino`，开发板选 **ESP32 Dev Module**，并设置 **Flash Mode DIO、Flash Size 4MB、Upload Speed 115200**。用默认的 QIO / 921600，有些 FT232 板会读不到 Flash。

```bash
arduino-cli compile --upload --fqbn "esp32:esp32:esp32:FlashMode=dio,FlashSize=4M,UploadSpeed=115200" -p /dev/cu.usbserial-XXXX firmware/QuotaGaugeBLE
```

蓝牙设备名 **CodexGauge**。命令（蓝牙或 USB 串口 115200 都可以）：`STATUS`、`P <µs>`、`CAL <0%脉宽> <100%脉宽>`、`Q <百分比>`、`T <百分比>`、`SPEED <°/秒>`、`STALE`、`OFF`。校准和转速保存在 Flash 里，断电不丢。

## Mac App

打开 `release/CodexGauge.dmg`，把 **Codex Gauge** 拖进「应用程序」。App 是本地签名、没有经过苹果公证，所以第一次打开要**右键 → 打开**。系统询问时，允许它使用蓝牙。

App 需要 Mac 上已安装并登录 Codex 命令行（ChatGPT 桌面版自带）。

- 菜单栏默认只显示百分比，可以在设置里打开指针图标。
- 点开可以看到 5 小时 / 每周额度和重置时间，以及自动同步开关。
- **设置与校准**窗口：
  - **测试**：拖动百分比、全程扫描；
  - **校准**：直接填写脉宽数值，或者微调后一键记录两端位置；
  - **设置**：显示哪个额度、转速、刷新间隔、语言、菜单栏图标、开机启动；
  - **日志**：命令和板子的回应。

自己编译（只需要命令行工具，不需要 Xcode）：`cd macos-app && ./build.sh`

## 重新生成模型

```bash
cd hardware/CAD
pip install -r requirements.txt
python build_v5.py && python check_v5.py && python sweep_v5.py && python assembly_path_v5.py
```

舵机、舵盘、板子、齿轮的尺寸都在 `parameters.json` 里。

## 状态

V5 已通过全部模型检查：齿形无重叠、零干涉、旋转扫掠和装配路径都通过。上一版 V4（60 mm 行程）已经实物打印、校准、运行成功。V5 还没有完整实物打印装配过，欢迎反馈配合问题。
