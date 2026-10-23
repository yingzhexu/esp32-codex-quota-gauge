#!/usr/bin/env python3
"""Read Codex account/rateLimits/read, send only Q percent over local USB.
No scraping, stored credentials, reset-credit consumption, or paid model calls.
Default: Codex bucket, minimum remaining among available primary/secondary windows.
"""
from __future__ import annotations
import argparse, json, math, queue, shutil, subprocess, sys, threading, time
from pathlib import Path

class QuotaError(RuntimeError): pass

def select_quota(result: dict, bucket='codex', window='most-restrictive') -> dict:
    buckets=result.get('rateLimitsByLimitId')
    if buckets:
        if bucket not in buckets:
            raise QuotaError(f'Bucket {bucket!r} absent; available: {", ".join(sorted(buckets))}')
        snapshot=buckets[bucket]
    else:
        snapshot=result.get('rateLimits')
        if not isinstance(snapshot,dict) or snapshot.get('limitId') not in (None,bucket):
            raise QuotaError('No matching Codex quota snapshot')
    windows={}
    for key in ('primary','secondary'):
        item=snapshot.get(key)
        if not isinstance(item,dict): continue
        used=item.get('usedPercent')
        if isinstance(used,bool) or not isinstance(used,(int,float)) or not math.isfinite(used): continue
        windows[key]={
            'remaining_percent':max(0.,min(100.,100.-used)),
            'window_minutes':item.get('windowDurationMins'),
            'resets_at':item.get('resetsAt')
        }
    if not windows: raise QuotaError('Quota windows unavailable: keep last position, mark stale')
    if window=='most-restrictive': selected=min(windows,key=lambda k:windows[k]['remaining_percent'])
    elif window in windows: selected=window
    else: raise QuotaError(f'{window} quota window unavailable')
    return {'bucket':bucket,'mode':window,'selected_window':selected,
            'remaining_percent':round(windows[selected]['remaining_percent'],3),'windows':windows}

class AppServer:
    def __init__(self, codex=None, timeout=25):
        self.codex=codex or shutil.which('codex')
        if not self.codex:
            candidate=Path('/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex')
            if candidate.exists(): self.codex=str(candidate)
        if not self.codex: raise QuotaError('Codex CLI not found; pass --codex /absolute/path/to/codex')
        self.timeout=timeout; self.proc=None; self.inbox=queue.Queue(); self.req_id=0
    def _reader(self):
        try:
            for line in self.proc.stdout:
                try: self.inbox.put(json.loads(line))
                except (ValueError,TypeError): continue
        finally: self.inbox.put(None)
    def _send(self,msg):
        self.proc.stdin.write(json.dumps(msg,separators=(',',':'))+'\n'); self.proc.stdin.flush()
    def request(self,method,params=None):
        self.req_id+=1; ident=self.req_id
        payload={'id':ident,'method':method}
        if params is not None: payload['params']=params
        self._send(payload); deadline=time.monotonic()+self.timeout
        while True:
            wait=deadline-time.monotonic()
            if wait<=0: raise QuotaError(f'Timed out reading {method}')
            try: msg=self.inbox.get(timeout=wait)
            except queue.Empty: raise QuotaError(f'Timed out reading {method}') from None
            if msg is None: raise QuotaError('Codex app-server exited; verify local Codex sign-in')
            if msg.get('id')!=ident: continue
            if 'error' in msg: raise QuotaError(f'{method} failed: {msg["error"].get("message","server error")}')
            return msg.get('result',{})
    def __enter__(self):
        self.proc=subprocess.Popen([self.codex,'app-server','--stdio'],stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,text=True,bufsize=1)
        threading.Thread(target=self._reader,daemon=True).start()
        try:
            self.request('initialize',{'clientInfo':{'name':'local_quota_gauge','title':'Local Quota Gauge','version':'1.0.0'}})
            self._send({'method':'initialized','params':{}})
            return self
        except Exception: self.__exit__(None,None,None); raise
    def __exit__(self,*args):
        if self.proc:
            try: self.proc.stdin.close()
            except (OSError,BrokenPipeError): pass
            try: self.proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.proc.terminate()
                try: self.proc.wait(timeout=3)
                except subprocess.TimeoutExpired: self.proc.kill(); self.proc.wait()
    def read(self): return self.request('account/rateLimits/read')

def open_serial(port):
    try: import serial
    except ImportError: raise QuotaError('Install pyserial: python3 -m pip install pyserial') from None
    dev=serial.Serial(port,115200,timeout=.15,write_timeout=2)
    # ESP32 USB-UART may reset on opening. Do not transmit before setup finishes.
    time.sleep(2.2); dev.reset_input_buffer()
    return dev

def send_checked(dev,command,timeout=2.5):
    dev.write((command+'\n').encode('ascii')); dev.flush()
    deadline=time.monotonic()+timeout
    while time.monotonic()<deadline:
        line=dev.readline().decode('ascii',errors='replace').strip()
        if line.startswith('ERR'): raise QuotaError(f'ESP32: {line}')
        if line.startswith('OK') or (command=='STATUS' and line.startswith('STATUS')): return line
    raise QuotaError('ESP32 did not acknowledge serial command')

def main(argv=None):
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--codex'); ap.add_argument('--port',help='e.g. /dev/cu.usbserial-...')
    ap.add_argument('--bucket',default='codex')
    ap.add_argument('--window',choices=['most-restrictive','primary','secondary'],default='most-restrictive')
    ap.add_argument('--interval',type=float,default=30)
    ap.add_argument('--once',action='store_true',help='Read one live snapshot and exit; optional --port transmits it')
    ap.add_argument('--list-ports',action='store_true')
    ap.add_argument('--serial-command',help='Explicit manual command such as STATUS, P 1500, or CAL us0 us100')
    ap.add_argument('--snapshot',type=Path,help='Offline JSON fixture instead of live quota')
    args=ap.parse_args(argv)
    if args.list_ports:
        from serial.tools.list_ports import comports
        for p in comports(): print(f'{p.device}\t{p.description}')
        return 0
    if args.interval<5: ap.error('--interval must be at least 5 seconds')
    if args.serial_command and not args.port: ap.error('--serial-command requires --port')
    if not args.once and not args.port and not args.serial_command: ap.error('Use --once to read quota or --port for the hardware bridge')
    dev=None
    try:
        if args.port: dev=open_serial(args.port)
        if args.serial_command:
            print(send_checked(dev,args.serial_command)); return 0
        if args.snapshot:
            result=select_quota(json.loads(args.snapshot.read_text()),args.bucket,args.window)
            if dev: result['device']=send_checked(dev,f'Q {result["remaining_percent"]:.3f}')
            print(json.dumps(result,ensure_ascii=False,indent=2)); return 0
        with AppServer(args.codex) as server:
            while True:
                try:
                    result=select_quota(server.read(),args.bucket,args.window)
                    if dev: result['device']=send_checked(dev,f'Q {result["remaining_percent"]:.3f}')
                    print(json.dumps(result,ensure_ascii=False),flush=True)
                except (QuotaError,OSError) as e:
                    if dev:
                        try: send_checked(dev,'STALE')
                        except (QuotaError,OSError): pass
                    if args.once: raise
                    print(f'STALE: {e}',file=sys.stderr,flush=True)
                if args.once: break
                time.sleep(args.interval)
        return 0
    except (QuotaError,OSError,ValueError) as e:
        print(f'ERROR: {e}',file=sys.stderr); return 1
    except KeyboardInterrupt: return 0
    finally:
        if dev: dev.close()

if __name__=='__main__': raise SystemExit(main())
