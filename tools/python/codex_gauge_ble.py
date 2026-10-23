#!/usr/bin/env python3
"""Codex 额度指针 · Mac 蓝牙桥接

Reads the local Codex quota (codex app-server, read-only) and sends the
remaining percent to the ESP32 over Bluetooth LE.

  python3 codex_gauge_ble.py                 run: update the gauge every 60 s
  python3 codex_gauge_ble.py scan            list nearby gauges
  python3 codex_gauge_ble.py center          move servo to 1500 us (assembly)
  python3 codex_gauge_ble.py calibrate       guided 0% / 100% calibration
  python3 codex_gauge_ble.py cmd "STATUS"    send one raw command
  python3 codex_gauge_ble.py quota           print quota only, no Bluetooth
"""
from __future__ import annotations
import argparse, asyncio, json, sys, time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from quota_bridge import AppServer, QuotaError, select_quota  # noqa: E402

try:
    from bleak import BleakClient, BleakScanner
except ImportError:
    print('缺少 bleak：python3 -m pip install bleak', file=sys.stderr); raise SystemExit(1)

DEVICE_NAME = 'CodexGauge'
SERVICE_UUID = '6e400001-c0de-4a11-9a5e-000000000001'
RX_UUID = '6e400002-c0de-4a11-9a5e-000000000001'
TX_UUID = '6e400003-c0de-4a11-9a5e-000000000001'


class Gauge:
    """One BLE connection; send() waits for the firmware's OK/ERR reply."""
    def __init__(self, address=None, timeout=15):
        self.address = address; self.timeout = timeout
        self.client = None; self.replies: asyncio.Queue[str] = asyncio.Queue()

    async def find(self):
        if self.address: return self.address
        dev = await BleakScanner.find_device_by_filter(
            lambda d, ad: (d.name or ad.local_name) == DEVICE_NAME
            or SERVICE_UUID in [u.lower() for u in ad.service_uuids],
            timeout=self.timeout)
        if not dev: raise QuotaError(f'没找到蓝牙设备 {DEVICE_NAME}：确认 ESP32 已上电、在附近')
        return dev

    async def connect(self):
        target = await self.find()
        self.client = BleakClient(target, timeout=self.timeout)
        await self.client.connect()
        await self.client.start_notify(TX_UUID, lambda _, data: self.replies.put_nowait(
            data.decode('utf-8', errors='replace').strip()))
        return self

    @property
    def connected(self): return bool(self.client and self.client.is_connected)

    async def send(self, command, timeout=5.0):
        while not self.replies.empty(): self.replies.get_nowait()
        await self.client.write_gatt_char(RX_UUID, (command + '\n').encode('ascii'), response=True)
        deadline = time.monotonic() + timeout
        while (left := deadline - time.monotonic()) > 0:
            try: line = await asyncio.wait_for(self.replies.get(), left)
            except asyncio.TimeoutError: break
            if line.startswith('ERR'): raise QuotaError(f'ESP32: {line}')
            if line.startswith(('OK', 'STATUS')): return line
        raise QuotaError('ESP32 没有回应')

    async def close(self):
        if self.connected: await self.client.disconnect()


async def scan(_args):
    found = await BleakScanner.discover(timeout=6, return_adv=True)
    hits = [(d, ad) for d, ad in found.values()
            if (d.name or ad.local_name) == DEVICE_NAME or SERVICE_UUID in [u.lower() for u in ad.service_uuids]]
    for d, ad in hits: print(f'{d.address}\t{d.name or ad.local_name}\tRSSI {ad.rssi}')
    if not hits: print('没有找到 CodexGauge')


async def one_command(args, command):
    g = await Gauge(args.address).connect()
    try: print(await g.send(command))
    finally: await g.close()


async def calibrate(args):
    print('标定：箭头对准刻度 0 和 100。每次输入一个脉宽数值（微秒），回车移动。')
    print('从 1500（中间）开始，每次改 10～20，慢慢靠近；不要顶到上下止挡。')
    print('命令：数字=移动  e=当前位置记为 0%  f=当前位置记为 100%  s=保存  q=退出')
    g = await Gauge(args.address).connect()
    us, empty, full = 1500, None, None
    loop = asyncio.get_running_loop()
    try:
        print(await g.send(f'P {us}'))
        while True:
            text = (await loop.run_in_executor(None, input, f'[当前 {us} us] > ')).strip().lower()
            if text == 'q': break
            if text == 'e': empty = us; print(f'0% = {us} us')
            elif text == 'f': full = us; print(f'100% = {us} us')
            elif text == 's':
                if empty is None or full is None: print('先用 e 和 f 记下两端'); continue
                print(await g.send(f'CAL {empty} {full}'))
                for q in (0, 50, 100, 50):
                    print(await g.send(f'Q {q}')); await asyncio.sleep(4)
                print('完成。若 50% 偏离刻度中线较多，重新标定。'); break
            elif text.lstrip('-').isdigit():
                us = max(500, min(2500, int(text))); print(await g.send(f'P {us}'))
            else: print('输入数字、e、f、s 或 q')
    finally:
        await g.send('OFF'); await g.close()


def read_quota(server, args):
    return select_quota(server.read(), args.bucket, args.window)


async def run(args):
    gauge = None; last_sent = None; last_sent_at = 0.0
    with AppServer(args.codex) as server:
        while True:
            try:
                result = read_quota(server, args)
                pct = result['remaining_percent']
            except QuotaError as e:
                print(f'{time.strftime("%H:%M:%S")} 读取额度失败：{e}', file=sys.stderr, flush=True)
                result = None
            try:
                if not (gauge and gauge.connected):
                    gauge = await Gauge(args.address).connect()
                    print(f'{time.strftime("%H:%M:%S")} 已连接 {DEVICE_NAME}', flush=True)
                    last_sent = None
                if result is None:
                    await gauge.send('STALE')
                # Resend after 5 min even if unchanged, so the firmware stays "fresh".
                elif last_sent is None or abs(pct - last_sent) >= 0.5 or time.monotonic() - last_sent_at > 300:
                    await gauge.send(f'Q {pct:.1f}')
                    last_sent, last_sent_at = pct, time.monotonic()
                    w = result['windows']
                    print(f'{time.strftime("%H:%M:%S")} 剩余 {pct:.1f}%（{result["selected_window"]}；'
                          + '，'.join(f'{k} {v["remaining_percent"]:.0f}%' for k, v in w.items()) + '）', flush=True)
            except Exception as e:  # BLE errors vary by stack
                print(f'{time.strftime("%H:%M:%S")} 蓝牙：{e}；稍后重连', file=sys.stderr, flush=True)
                if gauge:
                    try: await gauge.close()
                    except Exception: pass
                gauge = None
            await asyncio.sleep(args.interval)


def main(argv=None):
    ap = argparse.ArgumentParser(description='Codex 额度指针 Mac 蓝牙桥接')
    ap.add_argument('action', nargs='?', default='run',
                    choices=['run', 'scan', 'center', 'calibrate', 'cmd', 'quota'])
    ap.add_argument('command', nargs='?', help='cmd 时要发送的命令，例如 "STATUS"')
    ap.add_argument('--address', help='指定蓝牙设备 (scan 显示的 UUID)')
    ap.add_argument('--codex', help='codex 可执行文件路径')
    ap.add_argument('--bucket', default='codex')
    ap.add_argument('--window', default='most-restrictive',
                    choices=['most-restrictive', 'primary', 'secondary'],
                    help='primary=5小时窗口, secondary=每周, most-restrictive=两者取小')
    ap.add_argument('--interval', type=float, default=60, help='刷新间隔秒，默认 60')
    args = ap.parse_args(argv)
    if args.interval < 10: ap.error('--interval 至少 10 秒')
    try:
        if args.action == 'quota':
            with AppServer(args.codex) as s: print(json.dumps(read_quota(s, args), ensure_ascii=False, indent=2))
        elif args.action == 'scan': asyncio.run(scan(args))
        elif args.action == 'center': asyncio.run(one_command(args, 'P 1500'))
        elif args.action == 'calibrate': asyncio.run(calibrate(args))
        elif args.action == 'cmd':
            if not args.command: ap.error('cmd 需要命令，例如 cmd "STATUS"')
            asyncio.run(one_command(args, args.command))
        else: asyncio.run(run(args))
        return 0
    except QuotaError as e:
        print(f'错误：{e}', file=sys.stderr); return 1
    except KeyboardInterrupt:
        return 0


if __name__ == '__main__':
    raise SystemExit(main())
