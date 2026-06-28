# ESP32 UPS Power Monitor & Automation System (V5 Decoupled)

---
 
## Changelog — V4.2 → V5.2
 
### Architecture
 
| Type | Change |
|---|---|
| NEW | **Decoupled control plane — Pi becomes the brain.** V4 ran Telegram long-polling, command handling, and state logic entirely on the ESP32. V5 offloads all of that to a new `ups-monitor.py` service on the Pi (192.168.0.169), leaving the ESP32 as a pure sensor and actuator. |
| NEW | **ESP32 JSON state API — `/state` and `/command`.** ESP32 now exposes `GET /state` (full telemetry JSON) and `POST /command` (accepts `wake` / `shutdown`). Pi polls `/state` every 15 seconds and writes commands via `/command`. |
| NEW | **Pi notification webhook server — port 9997.** ESP32 fires `GET /notify?event=...` to the Pi immediately on state transitions (mains drop, WAN loss, shutdown, WOL, boot). Replaces the previous polling-only model — events are now instant instead of waiting up to 15 seconds. |
| NEW | **Deferred command execution pattern.** Commands received via `POST /command` are stored in a `pendingCommand` flag and executed from the main loop, not from inside the HTTP handler. Prevents stack re-entrancy crashes when `executeShutdownProxmox()` or `executeWakeProxmox()` are triggered remotely. |
 
### Firmware (ESP32)
 
| Type | Change |
|---|---|
| NEW | **BSSID lock to main router.** Wi-Fi now binds explicitly to the Asus main router BSSID (`CC:28:AA:C0:A2:70`) at connect time. Prevents the ESP32 from roaming to the DIR-825 extender, which would cause false mains-down readings. |
| FIX | **BSSID preserved on Wi-Fi reconnect (V5.1).** Reconnect path in `loop()` now passes `MAIN_ROUTER_BSSID` to `WiFi.begin()`. Previously the disconnect/reconnect path dropped the BSSID, allowing extender association after a drop. |
| FIX | **Cached mains/WAN state in `/state` handler (V5.1).** `handleGetState()` now reads `cachedMainsUp` / `cachedWanUp` instead of calling `isMainsUp()` and `isWANUp()` live. Eliminates up to 4 seconds of blocking TCP inside the web server thread during a `/status` request. |
| CHANGE | **Notifications now fire to Pi, not Telegram directly.** V4 sent Telegram messages straight from the ESP32. V5 ESP32 calls `notifyPi(event)` — a lightweight local HTTP call to `192.168.0.169:9997` — and the Pi handles all Telegram formatting and delivery. |
| REMOVED | **Telegram long-polling removed from firmware.** ESP32 no longer polls `getUpdates` or handles `/on`, `/off`, `/status` commands. All Telegram interaction is now handled by the Pi brain service. |
| REMOVED | **ElegantOTA dependency dropped.** Replaced by the native `ArduinoOTA` library (part of the ESP32 Arduino core). `platformio.ini` now only declares `ArduinoJson` as an external dependency. |
 
### Pi Brain Service (new in V5)
 
| Type | Change |
|---|---|
| NEW | **`ups-monitor.py` — main control service.** Runs on Pi as `ups-monitor.service`. Manages Telegram long-polling, command dispatch (`/on`, `/off`, `/status`), ESP32 background polling, liveness alerting, and real-time state assembly. |
| NEW | **Independent Proxmox and extender uptime in `/status`.** Pi queries the Proxmox API (`192.168.0.50:8006`) and the extender uptime bridge (`127.0.0.1:9998`) directly. `/status` remains useful even if the ESP32 is unreachable. |
| NEW | **ESP32 liveness alerting.** After 3 consecutive failed polls (~45 seconds), Pi sends a Telegram alert that the hardware sensor is offline. Sends a recovery message when polling resumes. ESP32 autonomous shutdown logic continues regardless. |
| NEW | **Real-time state overrides on webhook events.** When the Pi receives an event like `mains_down_countdown_start`, it immediately patches its cached ESP32 state so a `/status` response during the polling gap reflects the actual situation. |
| NEW | **Countdown timers in `/status`.** While mains or WAN is down, `/status` shows a live countdown to shutdown (e.g. `⏳ Shutting down in 4m 47s...`) calculated from `mainsFailSinceMs` / `wanFailSinceMs` in the ESP32 state JSON. |
| NEW | **Compact `/status` card (V5.2 UI).** Status redesigned — mains/WAN/Proxmox only, extender uptime inline, countdown dominant. ESP32 diagnostics moved to new `/diag` command. |
| NEW | **Optional SOCKS5 proxy for Telegram (`TG_PROXY`).** Pi brain supports a configurable SOCKS5 proxy for Telegram API calls. Set `TG_PROXY = "socks5h://..."` to enable; `None` uses direct connection. |

---

This document outlines the complete setup for the decentralized V5 ESP32-based UPS monitor. The system relies on four decoupled components to maximize Snappiness and Failsafe Autonomy:

1. **The Shutdown Webhook** (Running on the Proxmox host to execute local node cut commands).
2. **The Extender Uptime Bridge** (Running on the Pi to grab hardware logs from the ASUS/DIR router).
3. **The ESP32 Firmware** (The autonomous, lightweight hardware sensor and absolute fallback executioner).
4. **The Raspberry Pi Main Brain Service** (The control plane managing Telegram long-polling, SOCKS5 proxies, formatting, and live state compilation).
5. **The ESP32 Builder LXC** (CI/CD automated compilation and OTA delivery container).

---

## Part 1: Proxmox Shutdown Webhook

This lightweight Python HTTP server runs directly on the Proxmox host (`prox` - `192.168.0.50`). It listens on port `9999` for plain HTTP webhook calls from the ESP32 to trigger an instant graceful shutdown of the node.

* **Path:** `/usr/local/bin/shutdown-webhook.py`

```python
#!/usr/bin/env python3
from http.server import HTTPServer, BaseHTTPRequestHandler
import subprocess

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/shutdown':
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b'Shutting down...')
            subprocess.Popen(['shutdown', '-h', 'now'])
        elif self.path == '/reboot':
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b'Rebooting...')
            subprocess.Popen(['reboot'])
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, format, *args):
        pass

HTTPServer(('0.0.0.0', 9999), Handler).serve_forever()

```

---

## Part 1b: Extender Uptime Bridge (Pi — 192.168.0.169)

Telnets into the DIR-825 J1 extender (`192.168.0.2`) and exposes its `/proc/uptime` as a standard HTTP text endpoint. This service runs completely independently on the Pi to keep the main monitor loops clean.

* **Dependency:** `sudo apt install python3-pexpect`
* **Path:** `/usr/local/bin/extender-uptime.py`

```python
#!/usr/bin/env python3

import json
import pexpect
import threading
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler

EXTENDER_IP = "192.168.0.2"
TELNET_USER = "admin"
TELNET_PASS = "1"

_lock = threading.Lock()


def fmt_uptime(secs):
    if secs < 0:
        return "unavailable"

    days, rem = divmod(secs, 86400)
    hours, rem = divmod(rem, 3600)
    mins, secs = divmod(rem, 60)

    parts = []
    if days:
        parts.append(f"{days}d")
    if hours:
        parts.append(f"{hours}h")
    if mins:
        parts.append(f"{mins}m")
    parts.append(f"{secs}s")

    return " ".join(parts)


def get_uptime_seconds():
    with _lock:
        try:
            child = pexpect.spawn(
                f"telnet {EXTENDER_IP}",
                timeout=5,
                encoding="utf-8"
            )

            child.expect("login:")
            child.sendline(TELNET_USER)

            child.expect("Password:")
            child.sendline(TELNET_PASS)

            child.expect(r"[$#>]")
            child.sendline("cat /proc/uptime")

            child.expect(r"[$#>]")
            output = child.before

            child.sendline("exit")
            child.close()

            for line in output.splitlines():
                line = line.strip()

                # Look for the uptime line, e.g.:
                # "12345.67 6789.01"
                if line and line[0].isdigit():
                    return int(float(line.split()[0]))

        except pexpect.ExceptionPexpect as e:
            print(f"Telnet error: {e}")

        except Exception as e:
            print(f"Unexpected error: {e}")

    return -1


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):

        if self.path == "/extender-uptime":
            secs = get_uptime_seconds()

            self.send_response(200 if secs != -1 else 503)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.end_headers()

            self.wfile.write(str(secs).encode("utf-8"))

        elif self.path == "/extender-uptime-json":
            secs = get_uptime_seconds()

            self.send_response(200 if secs != -1 else 503)
            self.send_header(
                "Content-Type",
                "application/json; charset=utf-8"
            )
            self.end_headers()

            response = {
                "uptime": fmt_uptime(secs),
                "uptime_seconds": secs
            }

            self.wfile.write(
                json.dumps(response).encode("utf-8")
            )

        else:
            self.send_response(404)
            self.send_header("Content-Type", "text/plain")
            self.end_headers()
            self.wfile.write(b"Not Found")

    def log_message(self, format, *args):
        # Suppress HTTP request logging
        pass


if __name__ == "__main__":
    print("Starting threaded uptime bridge on port 9998...")
    server = ThreadingHTTPServer(("0.0.0.0", 9998), Handler)

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down...")
        server.server_close()
```

---

## Part 1c: Raspberry Pi Main Brain Service

Runs the central Telegram bot engine, long-polls updates, interacts with local SOCKS5 proxy architectures, and uses an immediate inbound HTTP webhook interceptor (`port 9997`) to catch instant event notifications fired from the ESP32.

* **Path:** `/usr/local/bin/ups-monitor.py`

```python
#!/usr/bin/env python3
"""
UPS Monitor Brain — Pi (192.168.0.169)
Version: 5.0 (Asynchronous Notification Ingestion and Event Controller)
"""

import json
import logging
import socket
import ssl
import http.client
import threading
import time
import urllib.request
import urllib.parse
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler

# ===================== CONFIG =====================
ESP32_IP            = "192.168.0.178"
ESP32_PORT          = 80
ESP32_POLL_INTERVAL = 15        # seconds between state polls
ESP32_TIMEOUT       = 12         # per-request timeout
ESP32_DEAD_THRESH   = 3         # consecutive failures → alert

PROXMOX_IP          = "192.168.0.50"
PROXMOX_PORT        = 8006
PROXMOX_NODE        = "prox"
PVE_API_TOKEN       = "PVEAPIToken=root@pam!esp32=PROX_API"
PROXMOX_TIMEOUT     = 5

EXTENDER_URL        = "http://127.0.0.1:9998/extender-uptime"
EXTENDER_TIMEOUT    = 4

TG_BOT_TOKEN        = "TG_BOT_TOKEN"
TG_CHAT_ID          = "TG_CHAT_ID"
TG_POLL_TIMEOUT     = 5         # Telegram long-poll seconds
TG_RETRY_DELAY      = 5         # wait after Telegram error

# Plug-and-play SOCKS5 proxy
TG_PROXY            = None  
# TG_PROXY = "socks5h://PROXY_USERNAME:PROXY_PASSWORD@10.10.10.218:8388"
# Timeouts for mains/WAN failures
MAINS_FAILURE_TIMEOUT_MS = 300_000    # 5 min
WAN_FAILURE_TIMEOUT_MS   = 600_000    # 10 min

LOG_FILE = "/var/log/ups-monitor.log"
# ==================================================

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[
        logging.FileHandler(LOG_FILE),
        logging.StreamHandler(),
    ],
)
log = logging.getLogger(__name__)

# --- Shared State ---
_lock          = threading.Lock()
_esp32_state   = {}       
_esp32_fail    = 0        
_esp32_alerted = False    
_tg_last_id    = -1

# ==================================================
# NETWORK OPERATIONS HELPERS
# ==================================================

def _http_get_raw(url, timeout=5, headers=None):
    req = urllib.request.Request(url, headers=headers or {})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.status, r.read().decode()

def _https_get_insecure(host, port, path, timeout=5, headers=None):
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode    = ssl.CERT_NONE
    conn = http.client.HTTPSConnection(host, port, timeout=timeout, context=ctx)
    conn.request("GET", path, headers=headers or {})
    r = conn.getresponse()
    return r.status, r.read().decode()

def _tcp_reachable(host, port, timeout=3):
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return True
    except OSError:
        return False

# ==================================================
# TELEGRAM SERVICE CLIENT
# ==================================================

def _tg_request(method, params=None):
    url = f"https://api.telegram.org/bot{TG_BOT_TOKEN}/{method}"
    if TG_PROXY:
        try:
            import requests as req_lib
            proxies = {"https": TG_PROXY, "http": TG_PROXY}
            r = req_lib.get(url, params=params or {}, proxies=proxies, timeout=TG_POLL_TIMEOUT + 3)
            return r.json()
        except Exception as e:
            log.warning(f"Telegram via proxy failed: {e}")
            return None
    if params:
        url += "?" + urllib.parse.urlencode(params)
    try:
        _, body = _http_get_raw(url, timeout=TG_POLL_TIMEOUT + 3)
        return json.loads(body)
    except Exception as e:
        log.warning(f"Telegram direct operation failed: {e}")
        return None

def send_telegram(text):
    result = _tg_request("sendMessage", {
        "chat_id":    TG_CHAT_ID,
        "text":       text,
        "parse_mode": "HTML",
    })
    if not result or not result.get("ok"):
        log.warning(f"sendMessage dropped payload: {result}")

# ==================================================
# CORE LOGIC AGGREGATORS
# ==================================================

def fmt_uptime(secs):
    if secs < 0: return "Unavailable"
    days  = int(secs) // 86400
    hours = (int(secs) % 86400) // 3600
    mins  = (int(secs) % 3600)  // 60
    parts = []
    if days:  parts.append(f"{days}d")
    if hours: parts.append(f"{hours}h")
    parts.append(f"{mins}m")
    return " ".join(parts)

def get_proxmox_uptime():
    if not _tcp_reachable(PROXMOX_IP, PROXMOX_PORT, timeout=3):
        return False, "Offline"
    try:
        path = f"/api2/json/nodes/{PROXMOX_NODE}/status"
        status, body = _https_get_insecure(PROXMOX_IP, PROXMOX_PORT, path, timeout=PROXMOX_TIMEOUT, headers={"Authorization": PVE_API_TOKEN})
        if status != 200: return True, "Unavailable"
        data = json.loads(body)
        secs = data.get("data", {}).get("uptime", -1)
        return True, fmt_uptime(int(secs))
    except Exception:
        return True, "Unavailable"

def get_extender_uptime():
    try:
        _, body = _http_get_raw(EXTENDER_URL, timeout=EXTENDER_TIMEOUT)
        secs = int(body.strip())
        return fmt_uptime(secs) if secs > 0 else "Unavailable"
    except Exception:
        return "Unavailable"

def _poll_esp32():
    try:
        url = f"http://{ESP32_IP}:{ESP32_PORT}/state"
        _, body = _http_get_raw(url, timeout=ESP32_TIMEOUT)
        return json.loads(body)
    except Exception as e:
        log.warning(f"Background thread state poll encountered error: {e}")
        return None

def _send_esp32_command(cmd_dict):
    try:
        url  = f"http://{ESP32_IP}:{ESP32_PORT}/command"
        data = json.dumps(cmd_dict).encode()
        req  = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json"}, method="POST")
        with urllib.request.urlopen(req, timeout=ESP32_TIMEOUT) as r:
            return r.status == 200
    except Exception as e:
        log.error(f"Failed to submit execution structural request: {e}")
        return False

def _get_esp32_state():
    with _lock: return dict(_esp32_state)

def _is_esp32_reachable():
    with _lock: return _esp32_fail < ESP32_DEAD_THRESH

# ==================================================
# ESP32 POLLING DAEMON
# ==================================================

def esp32_poll_loop():
    global _esp32_fail, _esp32_alerted, _esp32_state
    log.info("Starting background worker polling loop...")
    while True:
        state = _poll_esp32()
        alert_dead, alert_recovery, recovery_fw = False, False, "?"
        with _lock:
            if state is not None:
                if _esp32_alerted:
                    alert_recovery = True
                    recovery_fw = state.get("fw", "?")
                _esp32_state = state
                _esp32_fail = 0
                _esp32_alerted = False
            else:
                _esp32_fail += 1
                if _esp32_fail >= ESP32_DEAD_THRESH and not _esp32_alerted:
                    _esp32_alerted = True
                    alert_dead = True
        
        if alert_recovery:
            send_telegram(f"✅ <b>ESP32 BACK ONLINE</b>\n\nUPS sensor ({ESP32_IP}) recovered.\nFirmware: {recovery_fw}")
        elif alert_dead:
            send_telegram(f"⚠️ <b>ESP32 UNREACHABLE</b>\n\nSensor missed metrics. Authority systems remain autonomous.")
            
        time.sleep(ESP32_POLL_INTERVAL)

# ==================================================
# REALTIME ESP32 NOTIFICATION WEBHOOK SERVER
# ==================================================

class ESPNotifyHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        parsed_url = urllib.parse.urlparse(self.path)
        if parsed_url.path == "/notify":
            params = urllib.parse.parse_qs(parsed_url.query)
            event_type = params.get("event", [""])[0]
            
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"OK")
            
            if event_type:
                threading.Thread(target=process_esp_notification, args=(event_type,)).start()
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, format, *args): pass

def process_esp_notification(event):
    log.info(f"Asynchronous webhook hit from ESP32: event={event}")
    global _esp32_state

    # --- Real-Time State Overrides to Prevent Cache Stodginess ---
    with _lock:
        if event == "mains_down_countdown_start":
            _esp32_state["mainsUp"] = False
            _esp32_state["mainsFailSinceMs"] = 1 # Force metrics to reflect a running countdown
        elif event == "mains_false_alarm" or event == "mains_restored_override_cleared":
            _esp32_state["mainsUp"] = True
            _esp32_state["mainsFailSinceMs"] = 0
        elif event == "shutdown_mains_start":
            _esp32_state["mainsUp"] = False
            _esp32_state["sdMains"] = True
        elif event == "shutdown_wan_start":
            _esp32_state["wanUp"] = False
            _esp32_state["sdWAN"] = True

    mapping = {
        "esp_booted":
            "🟢 <b>ESP32 Online</b>\n\nUPS monitor started. Watching mains and WAN.",
        "power_instability":
            "⚡ <b>Power Instability</b>\n\nMains has flapped 3+ times in the last 10 minutes. Worth checking the supply.",
        "mains_down_countdown_start":
            "⚠️ <b>Mains Down</b>\n\nCan't reach 192.168.0.2. Shutdown in <b>5 minutes</b> if not restored.",
        "mains_down_override_active":
            "⚠️ <b>Mains Down</b>\n\nManual override is active — auto-shutdown suppressed. Send /off to shut down manually.",
        "mains_false_alarm":
            "✅ <b>Mains Restored</b>\n\nLine recovered before the 5 min timeout. No action taken.",
        "mains_restored_override_cleared":
            "✅ <b>Mains Restored</b>\n\nManual override cleared. Monitoring resumed normally.",
        "shutdown_mains_start":
            "🔴 <b>Shutting Down — Mains Timeout</b>\n\nMains was down for 5 minutes. Sending shutdown to Proxmox now.",
        "shutdown_wan_start":
            "🔴 <b>Shutting Down — WAN Timeout</b>\n\nNo internet for 10 minutes. Sending shutdown to Proxmox now.",
        "shutdown_manual_mains_down":
            "🔴 <b>Shutting Down — Manual</b>\n\n/off received while mains is down. Proxmox will auto-restore when power returns.",
        "shutdown_manual_normal":
            "🔴 <b>Shutting Down — Manual</b>\n\n/off received. Send /on to bring it back up.",
        "shutdown_complete":
            "✅ <b>Shutdown Complete</b>\n\nProxmox webhook acknowledged. Node going down.",
        "restoring_network_stabilization":
            "🟡 <b>Preparing to Wake</b>\n\nWaiting 15 seconds for network to stabilize before sending WOL...",
        "wol_packet_sent":
            "📡 <b>WOL Sent</b>\n\nWake-on-LAN packet broadcast to M900 (00:23:24:c7:1f:5d). Boot takes ~30–60s.",
        "wan_restored_mains_down_hold":
            "🌐 <b>WAN Restored</b>\n\nInternet is back, but mains is still down. Holding restore until power returns.",
    }
    if event in mapping: send_telegram(mapping[event])

def start_webhook_server():
    log.info("Launching incoming notification intercept engine on port 9997...")
    server = ThreadingHTTPServer(("0.0.0.0", 9997), ESPNotifyHandler)
    server.serve_forever()

# ==================================================
# STATUS CONTEXT ASSEMBLY
# ==================================================

def build_status_message():
    state = _get_esp32_state()
    sensor_alive = _is_esp32_reachable()

    prox_up, prox_uptime = get_proxmox_uptime()
    ext_uptime = get_extender_uptime()

    if state:
        mains_up = state.get("mainsUp", False)
        wan_up   = state.get("wanUp",   False)

        sd_mains  = state.get("sdMains",            False)
        sd_wan    = state.get("sdWAN",              False)
        sd_manual = state.get("sdManual",           False)
        man_ovr   = state.get("manualOverride",     False)

        mains_fail_ms = state.get("mainsFailSinceMs", 0)
        wan_fail_ms   = state.get("wanFailSinceMs",   0)

        mains_icon = "🟢" if mains_up else "🔴"
        wan_icon   = "🟢" if wan_up   else "🔴"

        ext_str = f"  (ext: {ext_uptime})" if ext_uptime != "Unavailable" else ""
        mains_line = f"{mains_icon} Mains: {'UP' + ext_str if mains_up else 'DOWN'}"

        # Countdown line — only when actively counting down
        countdown_line = ""
        if not mains_up and mains_fail_ms > 0 and not man_ovr and not (sd_mains or sd_wan or sd_manual):
            remaining = MAINS_FAILURE_TIMEOUT_MS - mains_fail_ms
            m = int(remaining // 1000 // 60)
            s = int(remaining // 1000 % 60)
            countdown_line = f"\n⏳ Shutting down in {m}m {s}s..."
        elif not wan_up and wan_fail_ms > 0 and not (sd_mains or sd_wan or sd_manual):
            remaining = WAN_FAILURE_TIMEOUT_MS - wan_fail_ms
            m = int(remaining // 1000 // 60)
            s = int(remaining // 1000 % 60)
            countdown_line = f"\n⏳ WAN shutdown in {m}m {s}s..."

        wan_line  = f"{wan_icon} WAN: {'UP' if wan_up else 'DOWN'}"

        if sd_manual:             sd_reason = "Manual /off"
        elif sd_mains and sd_wan: sd_reason = "Mains &amp; WAN failure"
        elif sd_mains:            sd_reason = "Mains failure"
        elif sd_wan:              sd_reason = "WAN failure"
        else:                     sd_reason = None

    else:
        mains_line = "⚪ Mains: UNKNOWN"
        wan_line   = "⚪ WAN: UNKNOWN"
        countdown_line = ""
        sd_reason = None

    stale_note = "\n⚠️ ESP32 offline — cached data" if not sensor_alive else ""
    prox_line  = f"{'🟢' if prox_up else '🔴'} Proxmox: {'ONLINE' if prox_up else 'OFFLINE'}  ⌚ {prox_uptime}"
    footer     = f"⚙️ {sd_reason}" if sd_reason else "⚙️ No active shutdown reason"

    return (
        f"📊 UPS STATUS\n"
        f"━━━━━━━━━━━━━━\n"
        f"{mains_line}{countdown_line}\n"
        f"{wan_line}\n"
        f"{prox_line}\n"
        f"━━━━━━━━━━━━━━\n"
        f"{footer}"
        f"{stale_note}"
    )


# ==================================================
# DIAGNOSIS CONTEXT ASSEMBLY
# ==================================================

def build_diag_message():
    state = _get_esp32_state()
    sensor_alive = _is_esp32_reachable()

    if not state:
        return "🔧 ESP32 DIAGNOSTICS\n━━━━━━━━━━━━━━\n⚪ ESP32 unreachable — no data available."

    fw        = state.get("fw", "?")
    esp_ms    = state.get("espUptimeMs", 0)
    rssi      = state.get("rssi", 0)
    free_heap = state.get("freeHeap", 0)
    flaps     = state.get("recentFlaps", 0)
    man_mains = state.get("manualOffMainsDown", False)
    man_ovr   = state.get("manualOverride", False)

    if rssi >= -50:   rssi_q = "Excellent"
    elif rssi >= -65: rssi_q = "Good"
    elif rssi >= -80: rssi_q = "Weak"
    else:             rssi_q = "Critical"

    stale = " ⚠️ (STALE)" if not sensor_alive else ""

    return (
        f"🔧 ESP32 DIAGNOSTICS\n"
        f"━━━━━━━━━━━━━━\n"
        f"📡 ESP32: {ESP32_IP}  ⌚ {fmt_uptime(esp_ms // 1000)}{stale}\n"
        f"📶 RSSI: {rssi} dBm ({rssi_q}){stale}\n"
        f"🧠 Heap: {free_heap // 1024} KB{stale}\n"
        f"🏷️ Firmware: {fw}\n"
        f"📈 Flaps (10m): {flaps}/3{stale}\n"
        f"🛡️ Manual override: {'ON' if man_ovr else 'OFF'}{stale}\n"
        f"🔌 ManualOff while mains down: {'YES' if man_mains else 'NO'}{stale}\n"
        f"⏱️ Poll: {ESP32_POLL_INTERVAL}s"
    )

# ==================================================
# TELEGRAM POLLING & COMMAND DISPATCH ENGINE
# ==================================================

def handle_command(text):
    text = text.strip()
    log.info(f"Processing chat instruction string tokens: {text!r}")

    if text == "/status":
        send_telegram(build_status_message())

    elif text == "/diag":
        send_telegram(build_diag_message())

    elif text == "/on":
        if not _is_esp32_reachable():
            send_telegram(
                "❌ <b>ESP32 Unreachable</b>\n\n"
                "Can't send wake command — no link to sensor.\n"
                "Check 192.168.0.178 manually."
            )
            return
        prox_up, _ = get_proxmox_uptime()
        if prox_up:
            send_telegram(
                "ℹ️ <b>Already Online</b>\n\n"
                "Proxmox is already running. No action taken."
            )
            return
        _send_esp32_command({"cmd": "wake"})

    elif text == "/off":
        if not _is_esp32_reachable():
            send_telegram(
                "❌ <b>ESP32 Unreachable</b>\n\n"
                "Can't send shutdown command — no link to sensor.\n"
                "Shut down Proxmox manually via console."
            )
            return
        prox_up, _ = get_proxmox_uptime()
        if not prox_up:
            send_telegram(
                "ℹ️ <b>Already Offline</b>\n\n"
                "Proxmox is already down. No action taken."
            )
            return
        _send_esp32_command({"cmd": "shutdown"})

def telegram_poll_loop():
    global _tg_last_id
    log.info("Starting long polling service interaction worker threads...")
    while True:
        try:
            params = {"timeout": TG_POLL_TIMEOUT, "allowed_updates": ["message"]}
            if _tg_last_id >= 0: params["offset"] = _tg_last_id + 1
            result = _tg_request("getUpdates", params)
            if result is None or not result.get("ok"):
                time.sleep(TG_RETRY_DELAY)
                continue
            for update in result.get("result", []):
                uid = update.get("update_id", 0)
                if uid > _tg_last_id: _tg_last_id = uid
                msg = update.get("message", {})
                if str(msg.get("chat", {}).get("id", "")) == str(TG_CHAT_ID):
                    text = msg.get("text", "").strip()
                    if text: handle_command(text)
        except Exception as e:
            log.error(f"Long polling engine error: {e}")
            time.sleep(TG_RETRY_DELAY)

if __name__ == "__main__":
    log.info("=== Decoupled UPS Brain System Initialization ===")
    
    # 1. Start notification server for immediate callback execution
    threading.Thread(target=start_webhook_server, daemon=True, name="webhook-srv").start()
    
    # 2. Start polling background threads for metrics collation
    threading.Thread(target=esp32_poll_loop, daemon=True, name="esp32-poll").start()
    
    time.sleep(1.5)
    
    # 3. Enter permanent polling loops for management plane commands
    telegram_poll_loop()

```

* **Path:** `/etc/systemd/system/ups-monitor.service`

```ini
[Unit]
Description=Decoupled UPS Monitor Main Brain Service
After=network.target extender-uptime.service

[Service]
ExecStart=/usr/bin/python3 /usr/local/bin/ups-monitor.py
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target

```

Enable: `sudo systemctl enable --now ups-monitor`

---

## Part 2: ESP32 Firmware (V5 Decoupled)

Exposes a JSON telemetry api endpoint on `/state` via a lightweight local server and listens for deferred inputs over `/command`.

* **Path:** `/mnt/data/public/esp32-ups-monitor/src/main.cpp`

```cpp
// ESP firmware/ main.cpp - V5 Architecture (Decoupled & Optimized)
#include <Arduino.h>
#include <WiFi.h>
#include <HTTPClient.h>
#include <WiFiUdp.h>
#include <Preferences.h>
#include <ArduinoOTA.h>
#include <ArduinoJson.h>
#include <WebServer.h>

// ===================== CONFIG =====================
const char* WIFI_SSID    = "ASUS_70_2G";
const char* WIFI_PASS    = "WIFI_PASSWORD";
// --- HARDWARE LOCK: Bound strictly to the Main Router's 2.4GHz BSSID ---
const uint8_t MAIN_ROUTER_BSSID[] = {0xCC, 0x28, 0xAA, 0xC0, 0xA2, 0x70}; 

const char* OTA_PASSWORD = "OTA_PASSWORD";
const char* FW_VERSION   = "V5.2";

const char* PING_TARGET  = "192.168.0.2"; // Extender IP for checking mains status
const int   PING_PORT    = 80;
const char* WAN_TARGET_1 = "8.8.8.8";
const char* WAN_TARGET_2 = "1.1.1.1";
const int   WAN_PORT     = 53;

const char* SHUTDOWN_URL = "http://192.168.0.50:9999/shutdown";
const char* BROADCAST_IP = "192.168.0.255";
const char* M900_MAC     = "00:23:24:c7:1f:5d";

// Target Pi notification endpoint
const char* PI_NOTIFY_URL = "http://192.168.0.169:9997/notify";

const unsigned long PING_INTERVAL_MS         = 30000;
const unsigned long MAINS_FAILURE_TIMEOUT_MS = 300000;   // 5 min
const unsigned long WAN_FAILURE_TIMEOUT_MS   = 600000;   // 10 min

// Mains flap detection
const int           FLAP_THRESHOLD  = 3;
const unsigned long FLAP_WINDOW_MS = 600000;   // 10 min rolling window
// ==================================================

// --- Persisted flags ---
bool shutdownReasonMains       = false;
bool shutdownReasonWAN         = false;
bool shutdownReasonManual      = false;   // manual /off — blocks auto-restore
bool manualOffWhileMainsDown   = false;   // /off while mains was down — allow auto-restore on mains up
bool manualOverride            = false;   // manual /on while mains down — suppresses mains auto-shutdown

// --- Live state ---
bool wakeExecuted = false; 
bool mainsFailureStarted = false;
bool wanFailureStarted   = false;
unsigned long mainsFirstFailTime = 0;
unsigned long wanFirstFailTime   = 0;
unsigned long lastPingTime       = 0;
unsigned long espBootTime        = 0;

// --- Cached sensor state (updated by main loop only) ---
bool cachedMainsUp = false;
bool cachedWanUp   = false;

// --- Flap detection ---
unsigned long flapTimestamps[10];
int  flapCount  = 0;
bool flapWarned = false;

// --- Command Deferral Flag ---
String pendingCommand = "";

WiFiUDP udp;
WebServer server(80);

// ==================================================
// PERSIST
// ==================================================

void saveState() {
    Preferences prefs;
    prefs.begin("ups", false);
    prefs.putBool("sdMains",      shutdownReasonMains);
    prefs.putBool("sdWAN",        shutdownReasonWAN);
    prefs.putBool("sdManual",     shutdownReasonManual);
    prefs.putBool("sdManMains",   manualOffWhileMainsDown);
    prefs.putBool("manOvr",       manualOverride);
    prefs.end();
}

void loadState() {
    Preferences prefs;
    prefs.begin("ups", true);
    shutdownReasonMains     = prefs.getBool("sdMains",    false);
    shutdownReasonWAN       = prefs.getBool("sdWAN",      false);
    shutdownReasonManual    = prefs.getBool("sdManual",   false);
    manualOffWhileMainsDown = prefs.getBool("sdManMains", false);
    manualOverride          = prefs.getBool("manOvr",     false);
    prefs.end();
}

// ==================================================
// HELPERS
// ==================================================

void notifyPi(String eventType) {
    if (WiFi.status() != WL_CONNECTED) return;
    HTTPClient http;
    http.begin(String(PI_NOTIFY_URL) + "?event=" + eventType);
    http.setTimeout(2000);
    http.GET();
    http.end();
}
bool tcpCheck(const char* host, int port, int timeoutMs = 2000) {
    WiFiClient client;
    client.setTimeout(timeoutMs);
    bool result = client.connect(host, port);
    client.stop();
    server.handleClient(); 
    ArduinoOTA.handle();   
    return result;
}

bool isMainsUp() { return tcpCheck(PING_TARGET, PING_PORT); }

bool isWANUp() {
    if (tcpCheck(WAN_TARGET_1, WAN_PORT, 2000)) return true;
    if (tcpCheck(WAN_TARGET_2, WAN_PORT, 2000)) return true;
    return false;
}

bool isM900ShutDown() {
    return shutdownReasonMains || shutdownReasonWAN || shutdownReasonManual;
}

void sendNativeWOL(const char* macStr) {
    byte mac[6];
    int m[6];
    sscanf(macStr, "%x:%x:%x:%x:%x:%x", &m[0], &m[1], &m[2], &m[3], &m[4], &m[5]);
    for (int i = 0; i < 6; i++) mac[i] = (byte)m[i];
    byte magicPacket[102];
    for (int i = 0; i < 6; i++) magicPacket[i] = 0xFF;
    for (int i = 1; i <= 16; i++)
        for (int j = 0; j < 6; j++) magicPacket[i * 6 + j] = mac[j];
    udp.beginPacket(BROADCAST_IP, 9);
    udp.write(magicPacket, 102);
    udp.endPacket();
}

// ==================================================
// FLAP DETECTION
// ==================================================

void recordMainsFlap() {
    unsigned long now = millis();

    if (flapCount < 10) {
        flapTimestamps[flapCount++] = now;
    } else {
        for (int i = 0; i < 9; i++) flapTimestamps[i] = flapTimestamps[i + 1];
        flapTimestamps[9] = now;
    }

    int recentFlaps = 0;
    for (int i = 0; i < flapCount; i++) {
        if ((now - flapTimestamps[i]) <= FLAP_WINDOW_MS) recentFlaps++;
    }

    Serial.printf("Mains flap recorded — %d flaps in last 10 min\n", recentFlaps);

    if (recentFlaps >= FLAP_THRESHOLD && !flapWarned) {
        flapWarned = true;
        notifyPi("power_instability");
    }
}

void checkFlapReset() {
    if (flapCount == 0) return;
    unsigned long now = millis();
    int lastIdx = (flapCount < 10) ? flapCount - 1 : 9;
    if ((now - flapTimestamps[lastIdx]) > FLAP_WINDOW_MS) {
        flapCount  = 0;
        flapWarned = false;
        Serial.println("Flap window expired — counter reset");
    }
}

// ==================================================
// SHUTDOWN & WAKE EXECUTION
// ==================================================

void executeShutdownProxmox(String mode) {
    if (mode != "manual" && isM900ShutDown()) {
        return;
    }

    if (mode == "mains") {
        shutdownReasonMains = true;
        notifyPi("shutdown_mains_start");
    } else if (mode == "wan") {
        shutdownReasonWAN = true;
        notifyPi("shutdown_wan_start");
    } else { // manual
        shutdownReasonManual = true;
        if (!isMainsUp()) {
            manualOffWhileMainsDown = true;
            notifyPi("shutdown_manual_mains_down");
        } else {
            manualOffWhileMainsDown = false;
            notifyPi("shutdown_manual_normal");
        }
    }

    manualOverride = false;
    saveState();

    // Fire Proxmox Hook — tighter timeout, pump server immediately after
    HTTPClient http;
    http.begin(SHUTDOWN_URL);
    http.setTimeout(1000);
    http.GET();
    http.end();
    ArduinoOTA.handle();
    server.handleClient();

    notifyPi("shutdown_complete");
}

void executeWakeProxmox(String reason) {
    notifyPi("restoring_network_stabilization");
    
    // Non-blocking 15-second delay replacement inside main flow
    unsigned long waitStart = millis();
    while (millis() - waitStart < 15000) {
        ArduinoOTA.handle();
        server.handleClient();
        delay(10);
    }

    udp.begin(9);
    sendNativeWOL(M900_MAC);
    udp.stop();

    notifyPi("wol_packet_sent");
    
    wakeExecuted = true;
    shutdownReasonMains     = false;
    shutdownReasonWAN       = false;
    shutdownReasonManual    = false;
    manualOffWhileMainsDown = false;
    saveState();
}

// ==================================================
// HTTP WEB API HANDLERS
// ==================================================

void handleGetState() {
    DynamicJsonDocument doc(512);
    doc["mainsUp"] = cachedMainsUp;
    doc["wanUp"]   = cachedWanUp;
    doc["sdMains"] = shutdownReasonMains;
    doc["sdWAN"] = shutdownReasonWAN;
    doc["sdManual"] = shutdownReasonManual;
    doc["manualOffMainsDown"] = manualOffWhileMainsDown;
    doc["manualOverride"] = manualOverride;
    
    // Calculate current rolling window flaps
    unsigned long now = millis();
    int recentFlaps = 0;
    for (int i = 0; i < flapCount; i++) {
        if ((now - flapTimestamps[i]) <= FLAP_WINDOW_MS) recentFlaps++;
    }
    doc["recentFlaps"] = recentFlaps;
    
    doc["mainsFailSinceMs"] = (mainsFailureStarted && mainsFirstFailTime > 0) ? (now - mainsFirstFailTime) : 0;
    doc["wanFailSinceMs"] = (wanFailureStarted && wanFirstFailTime > 0) ? (now - wanFirstFailTime) : 0;
    doc["espUptimeMs"] = millis() - espBootTime;
    doc["rssi"] = WiFi.RSSI();
    doc["freeHeap"] = ESP.getFreeHeap();
    doc["fw"] = FW_VERSION;

    String response;
    serializeJson(doc, response);
    server.send(200, "application/json", response);
}

void handlePostCommand() {
    if (server.hasArg("plain") == false) {
        server.send(400, "application/json", "{\"error\":\"Body empty\"}");
        return;
    }
    
    DynamicJsonDocument doc(256);
    DeserializationError error = deserializeJson(doc, server.arg("plain"));
    if (error) {
        server.send(400, "application/json", "{\"error\":\"Invalid JSON\"}");
        return;
    }

    String cmd = doc["cmd"] | "";
    if (cmd == "wake" || cmd == "shutdown") {
        pendingCommand = cmd; // Defers processing to main loop, avoiding stack re-entrancy crashes
        server.send(200, "application/json", "{\"status\":\"pending\"}");
    } else {
        server.send(400, "application/json", "{\"error\":\"Unknown command\"}");
    }
}

// ==================================================
// SETUP
// ==================================================

void setup() {
    Serial.begin(115200);
    loadState();

    // --- UPDATED WI-FI INITIALIZATION LAYER ---
    Serial.println("Connecting explicitly to Main Router BSSID...");
    
    // Pass the SSID, Password, Channel (0/passed over), and the explicit hardware MAC array
    WiFi.begin(WIFI_SSID, WIFI_PASS, 0, MAIN_ROUTER_BSSID);
    
    while (WiFi.status() != WL_CONNECTED) { 
        delay(500); 
        Serial.print("."); 
    }
    Serial.println("\nWiFi locked to Main Router! IP: " + WiFi.localIP().toString());

    // Setup OTA
    ArduinoOTA.setHostname("esp32-ups-monitor"); 
    ArduinoOTA.setPassword(OTA_PASSWORD); 
    ArduinoOTA.begin();

    // API Routes Setup
    server.on("/state", HTTP_GET, handleGetState); 
    server.on("/command", HTTP_POST, handlePostCommand); 
    server.begin();

    espBootTime = millis(); 
    delay(1000); 
    notifyPi("esp_booted");
}

// ==================================================
// MAIN LOOP
// ==================================================

void loop() {
    ArduinoOTA.handle();
    server.handleClient();

    // Non-blocking WiFi reconnect
    if (WiFi.status() != WL_CONNECTED) {
        static unsigned long lastReconnectAttempt = 0;
        unsigned long now2 = millis();
        if (now2 - lastReconnectAttempt > 5000) {
            lastReconnectAttempt = now2;
            WiFi.disconnect();
            WiFi.begin(WIFI_SSID, WIFI_PASS, 0, MAIN_ROUTER_BSSID);
        }
        return;
    }

    // Handle Deferred Commands safely outside Server context
    if (pendingCommand != "") {
        String executeCmd = pendingCommand;
        pendingCommand = ""; // clear flag immediately
        if (executeCmd == "wake") {
            if (!isMainsUp()) {
                manualOverride = true;
                saveState();
            }
            executeWakeProxmox("Manual request executed via Pi.");
        } else if (executeCmd == "shutdown") {
            executeShutdownProxmox("manual");
        }
    }

    unsigned long now = millis();
    if (now - lastPingTime < PING_INTERVAL_MS) return;
    lastPingTime = now;

    bool mainsUp = isMainsUp();
    bool wanUp   = isWANUp();
    cachedMainsUp = mainsUp;   // ← add this
    cachedWanUp   = wanUp;     // ← add this

    if (mainsUp) checkFlapReset();

    // ==================================================
    // AUTONOMOUS AUTOMATION & FAILSAFE ENGINE
    // ==================================================
    if (isM900ShutDown()) {
        // Case 1: Auto-shutdown (mains/WAN) — restore when both back up
        if (!shutdownReasonManual) {
            if (mainsUp && wanUp) {
                executeWakeProxmox("Failsafe triggers: Infrastructure healthy.");
            } else if (wanUp && !mainsUp && shutdownReasonWAN) {
                notifyPi("wan_restored_mains_down_hold");
            }
        // Case 2: Manual /off while mains was DOWN — restore when mains comes back up
        } else if (shutdownReasonManual && manualOffWhileMainsDown) {
            if (mainsUp && wanUp) {
                executeWakeProxmox("Mains restored after deferred manual off.");
            }
        }
    }

    // FAILURE DETECTION — MAINS
    if (!mainsUp) {
        if (!mainsFailureStarted) {
            mainsFailureStarted = true;
            mainsFirstFailTime  = now;
            if (wanUp) notifyPi(manualOverride ? "mains_down_override_active" : "mains_down_countdown_start");
        }
        if (!manualOverride && !isM900ShutDown() && (now - mainsFirstFailTime >= MAINS_FAILURE_TIMEOUT_MS)) {
            executeShutdownProxmox("mains");
        }
    } else {
        if (mainsFailureStarted) {
            mainsFailureStarted = false;
            mainsFirstFailTime  = 0;
            if (manualOverride) {
                manualOverride = false;
                saveState();
                notifyPi("mains_restored_override_cleared");
            } else if (!isM900ShutDown() && !wakeExecuted) {
                recordMainsFlap();
                notifyPi("mains_false_alarm");
            }
            wakeExecuted = false;
        }
    }

    // FAILURE DETECTION — WAN
    if (!wanUp) {
        if (!wanFailureStarted) {
            wanFailureStarted = true;
            wanFirstFailTime  = now;
        }
        if (!isM900ShutDown() && (now - wanFirstFailTime >= WAN_FAILURE_TIMEOUT_MS)) {
            executeShutdownProxmox("wan");
        }
    } else {
        if (wanFailureStarted) {
            wanFailureStarted = false;
            wanFirstFailTime  = 0;
        }
    }
}
```

---

## Part 3: ESP32 Builder LXC Scripts

These scripts run inside **LXC 117 (`esp32-builder`)**. They automate the compilation and OTA deployment of the ESP32 firmware whenever the `main.cpp` file is modified from a network share.

### Usage

1. Start the container: `pct start 117`
2. Edit `main.cpp` via SMB: `\\192.168.0.10\public\esp32-ups-monitor\src\main.cpp`
3. Wait for the Telegram 🚀 notification confirming the successful push.
4. Shut down when done: `pct stop 117`

### Script 1: Build and Push

Compiles the code using PlatformIO and pushes it over OTA.
**Path:** `/usr/local/bin/esp32-build-push.sh`

```bash
#!/bin/bash
PROJECT_DIR="/opt/esp32-ups-monitor"
ESP32_IP="192.168.0.178"
ESP32_OTA_PORT="3232"
ESP32_OTA_PASS="your_ota_pass"
TG_BOT_TOKEN="YOUR_BOT_TOKEN"
TG_CHAT_ID="YOUR_CHAT_ID"
PIO="/opt/platformio-venv/bin/pio"
LOG="/var/log/esp32-builder.log"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG"; }
tg()  { curl -sf -X POST "[https://api.telegram.org/bot$](https://api.telegram.org/bot$){TG_BOT_TOKEN}/sendMessage" \
        --data-urlencode "chat_id=${TG_CHAT_ID}" --data-urlencode "text=$1" > /dev/null; }

log "=== Change detected in main.cpp — starting build ==="
tg "🔨 ESP32 Build Started

File change detected in main.cpp. Compiling firmware..."

cd "$PROJECT_DIR"
BUILD_OUTPUT=$($PIO run 2>&1); BUILD_EXIT=$?

if [ $BUILD_EXIT -ne 0 ]; then
    ERROR_LINES=$(echo "$BUILD_OUTPUT" | grep -E "error:|Error" | head -5)
    tg "❌ ESP32 Build FAILED

${ERROR_LINES}

Fix and save again to retry."
    exit 1
fi

tg "✅ Compile Successful

Pushing OTA to ESP32 ($ESP32_IP)..."

BIN_FILE=$(find "$PROJECT_DIR/.pio/build" -name "firmware.bin" | head -1)
[ -z "$BIN_FILE" ] && { tg "❌ OTA Failed — firmware.bin not found."; exit 1; }

OTA_OUTPUT=$(python3 /usr/local/bin/espota.py -i "$ESP32_IP" -p "$ESP32_OTA_PORT" \
    -a "$ESP32_OTA_PASS" -f "$BIN_FILE" 2>&1); OTA_EXIT=$?

if [ $OTA_EXIT -ne 0 ]; then
    tg "❌ OTA Push FAILED

ESP32 unreachable at $ESP32_IP.
Error: ${OTA_OUTPUT}"
    exit 1
fi

log "OTA push successful"
tg "🚀 OTA Update Complete

Firmware pushed to ESP32 ($ESP32_IP). Rebooting now."

```

### Script 2: File Watcher

Uses `inotifywait` to monitor `main.cpp` for changes.
**Path:** `/usr/local/bin/esp32-watcher.sh`

```bash
#!/bin/bash
SRC_DIR="/opt/esp32-ups-monitor/src"
LOG="/var/log/esp32-builder.log"
LOCK="/tmp/esp32-build.lock"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG"; }
log "=== ESP32 file watcher started, watching $SRC_DIR ==="

while true; do
    EVENT=$(inotifywait -e close_write,moved_to,modify "$SRC_DIR" 2>/dev/null)
    [ $? -ne 0 ] && { log "WARN: inotifywait exited, restarting..."; sleep 2; continue; }
    if echo "$EVENT" | grep -q "main.cpp"; then
        [ -f "$LOCK" ] && { log "Build already in progress, skipping..."; continue; }
        touch "$LOCK"
        log "Event detected on main.cpp — waiting for file to settle..."
        sleep 3
        /usr/local/bin/esp32-build-push.sh
        rm -f "$LOCK"
    fi
done

```

### Script 3: Systemd Service

Runs the watcher continuously in the background.
**Path:** `/etc/systemd/system/esp32-watcher.service`

```ini
[Unit]
Description=ESP32 Firmware File Watcher and OTA Pusher
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/esp32-watcher.sh
Restart=always
RestartSec=10
Environment="PATH=/usr/local/bin:/usr/bin:/bin"
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target

```
### PlatformIO Configuration
This configuration tells PlatformIO how to compile the firmware and defines the dependencies and OTA upload parameters.
**Path:** `/opt/esp32-ups-monitor/platformio.ini`

```ini
[env:esp32dev]
platform = espressif32
board = esp32dev
framework = arduino
monitor_speed = 115200
upload_protocol = espota
upload_port = 192.168.0.178
upload_flags =
    --auth=password
lib_deps =
    ayushsharma82/ElegantOTA
    bblanchon/ArduinoJson
```
