# 蓝牙指针仪表：工作原理、通信协议与改造指南

> **写给 AI 助手：** 这是一个现成的硬件"百分比指针"。你只需要通过蓝牙或 USB 串口，发一行文本 `Q <0-100>`，箭头就会移动到对应位置。读完本文，你就能把它改造成显示任何 0–100% 数值的仪表（CPU 占用、电量、天气、股价涨跌、任务进度等），**不需要改固件，也不需要改机械结构**。
>
> 第 3 节是通信协议，第 6 节是改造方法，第 8 节是常见坑。

---

## 1. 这是什么

一块 3D 打印的竖牌，正面有 0–100% 刻度（只有刻度线，没有数字），一个红色箭头沿刻度上下移动，行程 90 mm。

| 部分 | 作用 |
|---|---|
| **机械** | SG90 舵机转动 74 齿齿轮，推动齿条直线移动，齿条上装箭头。舵机转 139.4°，箭头走 90 mm |
| **ESP32 固件** | 蓝牙设备名 `CodexGauge`，接收文本命令，控制舵机 PWM，平滑移动到目标位置 |
| **上位机（目前是 Mac 菜单栏 App）** | 读取数据源（目前是 Codex 剩余额度），换算成百分比，通过蓝牙发给 ESP32 |

**关键设计：固件对数据含义一无所知，它只认"百分比"。** 所以要改造成别的仪表，只需要换掉上位机的数据源，并按需更换面板刻度。

---

## 2. 系统结构

```
┌──────────────────────┐   BLE（或 USB 串口）   ┌──────────────────┐   PWM 50 Hz   ┌───────┐
│ 上位机                │ ─── "Q 42.5\n" ─────▶ │ ESP32 固件        │ ────────────▶ │ SG90  │──▶ 齿轮 → 齿条 → 箭头
│ （Mac App / Python / │ ◀── "OK Q 42.5" ───── │ 百分比 → 脉宽     │   GPIO13      └───────┘
│   手机 / 任何 BLE 端）│      Notify            │ 平滑移动、保存校准│
└──────────────────────┘                        └──────────────────┘
     数据源：任意                                    数据：只有 0–100%
```

**换算链路：**
1. 上位机把原始数据换算成 **0–100 的百分比**；
2. 固件按校准值线性换算成舵机脉宽：`脉宽 = empty_us + (full_us − empty_us) × 百分比 / 100`；
3. 舵机按设定速度平滑转到这个脉宽，到位后保持 0.8 秒，然后**停止输出 PWM**（舵机放松，不会一直嗡嗡响；齿条很轻，会停在原位）。

---

## 3. 通信协议（重点）

### 3.1 蓝牙 GATT

| 项目 | 值 |
|---|---|
| 设备名（广播名） | `CodexGauge` |
| 服务 UUID | `6e400001-c0de-4a11-9a5e-000000000001`（广播包里带这个 UUID，可以按 UUID 扫描） |
| **RX 特征**（上位机 → ESP32） | `6e400002-c0de-4a11-9a5e-000000000001`，属性 Write / Write Without Response |
| **TX 特征**（ESP32 → 上位机） | `6e400003-c0de-4a11-9a5e-000000000001`，属性 Notify / Read |
| 安全 | 无配对、无加密 |
| 连接数 | **同一时间只能连 1 台上位机**。连接期间设备停止广播，断开后自动恢复广播 |

**使用流程：** 扫描 → 连接 → 订阅 TX 的 Notify → 向 RX 写入命令 → 在 TX 上收到回复。

### 3.2 消息格式

- **纯 ASCII 文本，一行一条命令**，以 `\n` 结尾（`\r` 会被忽略）。通过 BLE 写入时，不带 `\n` 也会被当作一行处理。
- 每行最多 **63 字节**。BLE 默认 MTU 下单次写入最多 20 字节，所有命令都远小于这个长度。
- **每条命令都会回复一行**，前缀是 `OK`、`ERR` 或 `STATUS`。
- 回复会**同时**发到 BLE Notify 和 USB 串口（115200 波特率）。
- **建议逐条发送：** 发一条，等到回复再发下一条。固件的蓝牙接收队列只有 8 行，写得太快会丢命令。

### 3.3 命令表

| 命令 | 作用 | 成功回复 | 失败回复 |
|---|---|---|---|
| `Q <百分比>` | **显示数据**（0–100，可以带小数）。会标记为"新鲜数据" | `OK Q 42.5` | `ERR Q_RANGE`；未校准时为 `ERR NOT_CALIBRATED` |
| `T <百分比>` | **测试位置**。移动方式和 `Q` 一样，但不算作真实数据 | `OK T 50.0` | `ERR T_RANGE` / `ERR NOT_CALIBRATED` |
| `P <微秒>` | 直接设定舵机脉宽（500–2500），用于校准和居中。同时把数据标记为过期 | `OK P 1500` | `ERR P_RANGE` |
| `CAL <0%脉宽> <100%脉宽>` | 保存校准值。两个值都在 500–2500 之间、至少相差 200，顺序可以反过来（用来反转方向） | `OK CAL 730 2270` | `ERR CAL_RANGE` |
| `SPEED <°/秒>` | 舵机转动速度，10–400，默认 90 | `OK SPEED 120` | `ERR SPEED_RANGE` |
| `STATUS` | 查询状态 | 见 3.4 | — |
| `STALE` | 主动标记"数据源不可用"（LED 改为慢闪，箭头不动） | `OK STALE` | — |
| `OFF` | 立即停止 PWM，放松舵机 | `OK OFF` | — |
| 其他 | — | — | `ERR COMMAND` |

`CAL` 和 `SPEED` 保存在 ESP32 的 Flash 里，**断电不丢**。

### 3.4 STATUS 回复

```
STATUS cal=1 fresh=1 empty_us=730 full_us=2270 pct=42.5 us=1384 speed=90
```

| 字段 | 含义 |
|---|---|
| `cal` | 1 = 已校准，0 = 未校准（未校准时 `Q`、`T` 会被拒绝） |
| `fresh` | 1 = 最近 10 分钟内收到过 `Q` |
| `empty_us` / `full_us` | 0% / 100% 对应的脉宽 |
| `pct` | 最后一次 `Q` 的百分比（从未收到过时为 `nan`） |
| `us` | 舵机当前脉宽 |
| `speed` | 当前转速（°/秒） |

解析方法：按空格分割，再按 `=` 拆成键值对。

### 3.5 数据新鲜度和 LED

- 固件在收到 `Q` 后的 **10 分钟**内认为数据是新鲜的。**上位机即使数值没变，也应该每隔不超过 5 分钟重发一次 `Q`**（Mac App 就是这样做的）。
- 板载 LED（GPIO2）：**快闪** = 未校准；**常亮** = 数据新鲜；**慢闪**（1 秒）= 数据过期，或者收到了 `STALE`。
- 数据过期时箭头**停在原位不动**，只有 LED 提示。

---

## 4. 最小示例

### 4.1 Python（bleak，跨平台）

```python
# pip install bleak
import asyncio
from bleak import BleakClient, BleakScanner

SERVICE = "6e400001-c0de-4a11-9a5e-000000000001"
RX = "6e400002-c0de-4a11-9a5e-000000000001"
TX = "6e400003-c0de-4a11-9a5e-000000000001"

async def main():
    dev = await BleakScanner.find_device_by_filter(
        lambda d, ad: SERVICE in [u.lower() for u in ad.service_uuids], timeout=10)
    replies = asyncio.Queue()
    async with BleakClient(dev) as c:
        await c.start_notify(TX, lambda _, data: replies.put_nowait(data.decode().strip()))
        async def send(cmd):
            await c.write_gatt_char(RX, (cmd + "\n").encode(), response=True)
            return await asyncio.wait_for(replies.get(), 5)
        print(await send("STATUS"))
        print(await send("Q 42.5"))     # 箭头移动到 42.5%

asyncio.run(main())
```

### 4.2 USB 串口（不用蓝牙，插着 USB 线就能用）

```python
# pip install pyserial
import serial, time
s = serial.Serial("/dev/cu.usbserial-XXXX", 115200, timeout=1)   # Windows 是 COM3 之类
time.sleep(2.5); s.reset_input_buffer()     # 打开串口会让 ESP32 重启，等它启动完
s.write(b"Q 42.5\n"); print(s.readline().decode().strip())
```

注意：同一时间只用一种方式控制。蓝牙和串口都能收命令，但同时混用会互相覆盖位置。

### 4.3 其他平台

任何支持 BLE 的环境都可以：Swift CoreBluetooth（参考仓库里的 `macos-app/Sources/main.swift`）、Android、Node.js（`@abandonware/noble`）、Web Bluetooth（Chrome 浏览器）、树莓派、另一块 ESP32 都行。流程都是：按服务 UUID 扫描 → 连接 → 订阅 TX → 写 RX。

---

## 5. 校准

箭头的机械行程是固定的，但舵盘装到舵机轴上的角度每次都不一样，所以**每次装配后都要校准一次**：

1. 发送 `P 1500`（舵机居中），然后每次 ±10 µs 微调 `P`，直到箭头对准 **0** 刻度，记下这个脉宽；
2. 同样找到对准 **100** 刻度的脉宽；
3. 发送 `CAL <0%脉宽> <100%脉宽>` 保存。

V5（74 齿齿轮）的参考值约为 `CAL 730 2270`。

**安全提醒：** 刻度两端外只留了约 1.2 mm 余量，再往外就是机械止挡。**不要用 `P` 把箭头推到止挡上。** 舵机顶住止挡时会持续嗡嗡响、发热，时间长了会损坏。

**想让方向反过来**（比如数值越大箭头越低）：把两个值对调，比如 `CAL 2270 730`。

---

## 6. 改造成其他仪表

### 6.1 只需要做两件事

1. **写一个上位机程序：** 读取数据 → 换算成 0–100 → 发 `Q`；
2. **（可选）换面板刻度：** 改 `hardware/CAD/build_v5.py` 里的 `faceplate()` 函数，或者直接在面板上贴自己的刻度贴纸。

### 6.2 百分比换算（常见映射方法）

| 类型 | 公式 | 例子 |
|---|---|---|
| 线性范围 | `pct = (x − min) / (max − min) × 100`，再限制在 0–100 | 温度 −10～40 °C |
| 中心为零 | `pct = 50 + x / 满量程 × 50` | 股价涨跌 ±10% → 50% 是平盘 |
| 对数 | `pct = log10(x / min) / log10(max / min) × 100` | 网速 1 kbps～1 Gbps |
| 分档 | 取固定几个值，比如 0 / 25 / 50 / 75 / 100 | 空气质量等级 |
| 倒数（剩余量） | `pct = 100 − 已用比例` | 额度、磁盘剩余空间 |

### 6.3 改造示例思路

| 用途 | 数据来源 | 换算 |
|---|---|---|
| CPU / 内存占用 | `psutil.cpu_percent()` | 直接用 |
| 笔记本电量 | `psutil.sensors_battery().percent` | 直接用 |
| 室外温度 | 天气 API | −10～40 °C 线性映射 |
| 股票 / 加密货币涨跌 | 行情 API | 中心为零，±5% 满量程 |
| GitHub Actions 构建进度 | GitHub API | 已完成步骤 / 总步骤 |
| 番茄钟倒计时 | 本地计时 | 剩余时间 / 25 分钟 |
| 下一班公交 | 公交 API | 0～30 分钟线性映射 |
| 某个 AI 服务的剩余额度 | 各服务的用量 API | 100 − 已用% |

### 6.4 上位机推荐写法

```text
每隔 N 秒（15 秒～5 分钟）：
    读取数据；失败 → 发送 "STALE"，保持箭头不动
    pct = 换算并限制在 0–100
    如果 |pct − 上次发送值| ≥ 0.5，或者距离上次发送超过 5 分钟：
        发送 "Q <pct 保留 1 位小数>"
蓝牙断开 → 每 3 秒重新扫描连接；重连后先发 STATUS，检查 cal=1
```

### 6.5 改造 Mac App

App 源码是单文件 `macos-app/Sources/main.swift`：
- **数据源**在 `QuotaService` 类里（目前通过 `codex app-server --stdio` 的 JSON-RPC 方法 `account/rateLimits/read` 读取 Codex 额度）。把它替换成你的数据源，返回 0–100 的数值即可；
- 蓝牙部分 `BLELink` 和界面部分可以原样复用；
- 编译：`cd macos-app && ./build.sh`（只需要 Xcode 命令行工具）。

### 6.6 需要改固件的情况（一般不需要）

固件在 `firmware/QuotaGaugeBLE/QuotaGaugeBLE.ino`：
- **同时用多个指针：** 修改 `DEVICE_NAME`，比如 `Gauge-CPU`、`Gauge-Temp`，上位机按名字区分（每个板子服务 UUID 相同也没关系）；
- **舵机换到别的引脚：** 修改 `SERVO_PIN`（避开 GPIO 0/2/12/15 这些启动引脚，以及 34–39 这些只能输入的引脚）；
- **需要防止别人连接：** 目前没有配对和加密，附近任何设备都能连。如果在意，可以在固件里加 BLE 配对，或者加一个简单的口令命令。

---

## 7. 硬件参数速查

| 项目 | 值 |
|---|---|
| 主控 | ESP32-D0WD-V3，30 针 USB-C 开发板（FT232 串口芯片） |
| 舵机 | SG90，180°，信号线接 GPIO13（D13） |
| 舵机供电 | **3V3**（这种板子的 VIN 插 USB 时没有 5V 输出），GND 共地 |
| PWM | 50 Hz，16 位分辨率，脉宽 500–2500 µs 对应 0–180° |
| 行程 | 0–100% 对应舵机 139.4°，箭头直线移动 90 mm |
| 转速 | 默认 90°/秒，0→100% 约 1.5 秒，可调 10–400 |
| 精度 | 约 ±1 mm（齿隙 + 舵机死区），满量程的 1% 左右 |
| 烧录设置 | ESP32 Dev Module，**Flash Mode DIO、4MB、115200** |

---

## 8. 常见坑（给 AI 的提醒）

1. **未校准时 `Q` 会返回 `ERR NOT_CALIBRATED`。** 新烧录的板子要先 `CAL`。
2. **打开 USB 串口会让 ESP32 重启**（DTR/RTS 自动复位），打开后要等 2～3 秒再发命令。
3. **蓝牙只能连 1 台上位机。** 搜不到设备时，先检查是不是别的程序（旧的 App、Python 脚本、手机）已经连着了。
4. **macOS 需要蓝牙权限。** 从终端运行时授权给"终端"，打包成 App 时 Info.plist 里要有 `NSBluetoothAlwaysUsageDescription`，否则程序一访问蓝牙就会被系统终止。
5. **不要把舵机 3 针插头直接插在开发板排针上。** 引脚顺序是 VIN-GND-D13，和舵机的棕-红-橙对不上，会把舵机电源接反。要用 3 根杜邦线分开接。
6. **烧录失败、提示 `invalid header` 或读不到 Flash** → 改用 DIO 模式、115200 波特率重新烧录。
7. **箭头不要贴着止挡工作**，校准时 0% 和 100% 都留在刻度线上，不要推到底。
8. **发送频率不用太高。** 1 秒一次已经很平滑了；舵机移动本身就有限速，发太快没有意义，还会把蓝牙队列塞满。

---

## 9. 文件位置

GitHub 项目文件夹（桌面 `codex-quota-gauge`）：
- 固件：`firmware/QuotaGaugeBLE/QuotaGaugeBLE.ino`
- Mac App：`macos-app/Sources/main.swift`
- Python 示例 / 命令行桥接：`tools/python/codex_gauge_ble.py`
- 3D 模型：`hardware/STL/`、`hardware/CAD/`（`parameters.json` 里有全部尺寸）
