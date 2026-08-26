# ESP32 UPS Power Monitor & Automation System

---
 
This document outlines the complete setup for the decentralized V5 ESP32-based UPS monitor. The system relies on four decoupled components to maximize Snappiness and Failsafe Autonomy:

1. **The Shutdown Webhook** (Running on the Proxmox host to execute local node cut commands).
2. **The Extender Uptime Bridge** (Running on the Pi to grab hardware logs from the ASUS/DIR router).
3. **The ESP32 Firmware** (The autonomous, lightweight hardware sensor and absolute fallback executioner).
4. **The Raspberry Pi Main Brain Service** (The control plane managing dual-channel alerting — Telegram primary with ntfy fallback — plus long-polling, SOCKS5 proxies, formatting, and live state compilation).
5. **The ESP32 Builder LXC** (CI/CD automated compilation and OTA delivery container).

---

## ESP32 Firmware — What it does

- Checks mains (TCP → `192.168.0.2:80`, extender) and WAN (`8.8.8.8`/`1.1.1.1:53`) every 30s
- **V6.0:** checks now run on core 0 (`netCheckTask`, FreeRTOS task), writing to `cachedMainsUp`/`cachedWanUp` under `cacheMux`; `loop()` (core 1) reads the cache instead of blocking — keeps `/state` responsive during outages
- Exposes `GET /state` (telemetry JSON) and `POST /command` (`wake`/`shutdown`, deferred via `pendingCommand` to avoid re-entrancy crashes)
- Fires instant event webhooks to Pi (`:9997/notify?event=...`) on every state transition
- Auto-shuts down Proxmox (`:9999/shutdown`) after 5 min mains-down or 10 min WAN-down
- Auto-wakes via WOL when mains+WAN both recover
- Tracks 3 shutdown-reason flags (`sdMains`, `sdWAN`, `sdManual` + `manualOffWhileMainsDown`) persisted in NVS, governing auto-restore eligibility
- `manualOverride` flag suppresses mains auto-shutdown when `/on` sent while mains is down
- Flap detection: 3+ mains recoveries in 10 min → one-time alert
- Runtime-adjustable mains-failure timeout (default 5 min) set from the Pi via `/command`, persisted in NVS, reported as `mainsDelayMs` in `/state`
- BSSID-locked Wi-Fi (locked to the main router's BSSID) on connect + reconnect, prevents roaming to the extender
- OTA via `ArduinoOTA`

## Pi Brain (`ups-monitor.py`) — What it does

- Polls ESP32 `/state` every 15s (background thread); after 3 fails (~45s) sends "unreachable" alert with exponential backoff (cap 60s), sends recovery alert when polling resumes
- Runs webhook server on `:9997` to catch instant ESP32 events, patches cached state in real time (e.g. `mains_down_countdown_start`)
- Formats and sends all Telegram messages (ESP32 no longer talks to Telegram directly)
- Handles Telegram long-polling + commands: `/status` (mains/WAN/Proxmox + live countdown), `/diag` (RSSI, heap, firmware, flaps, overrides, delay), `/on`, `/off` (both gated on ESP32 reachability + current Proxmox state), `/custom_delay` (set/reset/show the mains auto-shutdown delay, 1–720 min; `/custom-delay` hyphen alias also accepted)
- Queries Proxmox API (`:8006`) and extender-uptime bridge (`:9998`) directly and independently of ESP32
- Verifies shutdown/wake outcomes by polling Proxmox for up to 120s post-trigger, sends confirmation or timeout warning
- **v6.5 — Dual-channel alerting:** every outbound alert passes through a single `notify()` gate — Telegram first; if Telegram fails (typical when WAN is down), the message falls back to **ntfy**
- ntfy fallback tries the reverse-proxy domain first, then the raw LXC IP (DNS/proxy paths can degrade differently during WAN failover); the title is prefixed `[TG FAILED]`
- Priority auto-maps from emoji severity (🚨 → urgent, ⚠️/🔴 → high, else default); Telegram HTML markup is stripped for plain-text delivery
- Bodies over 4 KB are truncated before publish so neither Telegram's nor ntfy's 4096-byte caps can silently drop an alert
- Optional SOCKS5 proxy for Telegram traffic (`TG_PROXY`, currently `None`)

### Notification Channels (v6.5)

| | Channel | Endpoint(s) | Notes |
|---|---|---|---|
| Primary | Telegram Bot API | `api.telegram.org` | HTML parse mode, long-poll commands |
| Fallback | ntfy topic `ups` | `https://ntfy.<domain>` (via Nginx Proxy Manager, valid LE cert) → `http://<ntfy-lxc-ip>` (direct) | Tried in order until one accepts; `[TG FAILED]` prefix flags degraded mode |

Fallback triggers on any Telegram failure: network unreachable (WAN down), HTTP errors, malformed payload rejection. Delivery success requires an explicit `200`/`ok` from at least one channel.

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
TELNET_USER = "TELNET_USER"
TELNET_PASS = "TELNET_PASS"

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
Version: 6.5 (ntfy fallback when Telegram unreachable)
"""

import html as html_lib
import json
import logging
import os
import re
import socket
import ssl
import http.client
import threading
import time
import urllib.request
import urllib.parse
import requests
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler

# ===================== CONFIG =====================
ESP32_IP            = "192.168.0.178"
ESP32_PORT          = 80
ESP32_POLL_INTERVAL = 15        # seconds between state polls
ESP32_TIMEOUT       = 12
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

# ntfy fallback — used when Telegram delivery fails (e.g. WAN down).
# Domain first (via NPM reverse proxy), then raw LXC IP in case the
# domain/DNS path breaks during a WAN failover.
NTFY_URLS           = [
    "https://ntfy.YOUR_DOMAIN.duckdns.org",
    "http://10.10.10.241",
]
NTFY_TOPIC          = "ups"
NTFY_TIMEOUT        = 6

# Plug-and-play SOCKS5 proxy
TG_PROXY            = None  
# TG_PROXY = "socks5h://username:password@10.10.10.218:8388"
# Timeouts for mains/WAN failures
MAINS_FAILURE_TIMEOUT_MS = 300_000    # 5 min
WAN_FAILURE_TIMEOUT_MS   = 600_000    # 10 min
EXTENDER_BOOT_LAG_SEC    = 40         # 40 seconds approx time extender takes to respond after mains restores


LOG_FILE = "/var/log/ups-monitor.log"
COUNTERS_FILE = "/var/lib/ups-monitor/daily-counters.json"
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

# Fail fast (and clearly) if a SOCKS proxy is configured without PySocks
if TG_PROXY and TG_PROXY.startswith("socks"):
    try:
        import socks  # noqa: F401  — provided by PySocks, required for socks5h://
    except ImportError:
        log.error("TG_PROXY is set but PySocks is missing (pip install requests[socks]) — disabling proxy.")
        TG_PROXY = None

# --- Shared State ---
_lock          = threading.Lock()
_esp32_state   = {}       
_esp32_fail    = 0        
_esp32_alerted = False    
_tg_last_id    = -1
_tg_session = requests.Session()
_tg_lock = threading.Lock()  # requests.Session is not officially thread-safe
_mains_down_started_at = None 
_daily_counters = {"date": None, "mains_down": 0, "shutdowns": 0}

# Reconciliation: tracks how long Proxmox has been continuously confirmed
# online while the ESP32 still thinks it's shut down (e.g. BIOS auto-power-on
# after a UPS-draining outage, bypassing WOL entirely).
_prox_online_since = None
RECONCILE_MIN_ONLINE_SEC = 150   # must be online this long before we touch flags

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

def _tg_request(method, params=None, retries=2, retry_delay=2):
    url = f"https://api.telegram.org/bot{TG_BOT_TOKEN}/{method}"
    proxies = {"https": TG_PROXY, "http": TG_PROXY} if TG_PROXY else None
    last_err = None
    for attempt in range(retries + 1):
        try:
            with _tg_lock:
                r = _tg_session.get(url, params=params or {}, proxies=proxies, timeout=TG_POLL_TIMEOUT + 3)
            return r.json()
        except Exception as e:
            last_err = e
            if attempt < retries:
                time.sleep(retry_delay)
    log.warning(f"Telegram request failed after {retries + 1} attempts: {last_err}")
    return None

def send_telegram(text):
    result = _tg_request("sendMessage", {
        "chat_id":    TG_CHAT_ID,
        "text":       text,
        "parse_mode": "HTML",
    })
    if not result or not result.get("ok"):
        log.error(f"FATAL: Telegram dropped payload (WAN down?): {result}")
        return False
    return True

# ==================================================
# NTFY FALLBACK CHANNEL (used when Telegram fails)
# ==================================================

def _strip_html(text):
    """Converts Telegram HTML markup to plain text for ntfy."""
    text = re.sub(r"</?(b|i|u|s|code|pre|a)[^>]*>", "", text)
    return html_lib.unescape(text)

def send_ntfy(text, tg_failed=False):
    """
    Publishes to every ntfy endpoint until one accepts. Returns True if
    any delivery succeeded. Tries the reverse-proxy domain first, then
    the raw container IP — during a WAN outage DNS/proxy paths can
    degrade differently, so both are attempted.
    """
    body     = _strip_html(text)
    # ntfy rejects bodies over ~4KB just like Telegram — truncate so the
    # fallback channel can still deliver an oversized alert.
    if len(body) > 4000:
        body = body[:4000] + "\n… [truncated]"
    lines    = [l.strip() for l in body.splitlines() if l.strip()]
    title    = lines[0] if lines else "UPS Notification"
    payload  = ("\n".join(lines[1:]) or title).encode()

    if "🚨" in body:
        priority, tag = "urgent", "rotating_light"
    elif ("⚠️" in body) or ("🔴" in body):
        priority, tag = "high", "warning"
    else:
        priority, tag = "default", "information_source"

    # HTTP headers are latin-1 only — drop emoji/unicode from the title.
    safe_title = re.sub(r"[^\x20-\x7e]", "", title).strip() or "UPS Notification"
    if tg_failed:
        safe_title = "[TG FAILED] " + safe_title
    headers = {"Title": safe_title[:200], "Priority": priority, "Tags": tag}

    delivered_via = None
    for base in NTFY_URLS:
        try:
            req = urllib.request.Request(f"{base}/{NTFY_TOPIC}", data=payload, headers=headers, method="POST")
            with urllib.request.urlopen(req, timeout=NTFY_TIMEOUT) as r:
                if r.status == 200:
                    delivered_via = base
                    break
        except Exception as e:
            log.warning(f"ntfy delivery via {base} failed: {e}")
    if delivered_via:
        log.info(f"ntfy notification delivered via {delivered_via}")
        return True
    log.error("ntfy delivery failed on all endpoints")
    return False

def notify(text):
    """
    Single entry point for all outbound alerts.
    Primary: Telegram. Fallback: ntfy (message is flagged when TG dropped).
    Returns True only if at least one channel confirmed delivery.
    """
    if send_telegram(text):
        return True
    log.warning("Telegram unreachable — falling back to ntfy")
    return send_ntfy(text, tg_failed=True)

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

def fmt_downtime(secs):
    secs = int(max(0, secs))
    if secs < 60:
        return f"{secs}s"
    mins, s = divmod(secs, 60)
    if mins < 60:
        return f"{mins}m {s}s"
    h, m = divmod(mins, 60)
    return f"{h}h {m}m"

def _bar(frac, width=10):
    """Progress bar for countdowns — e.g. ▰▰▰▰▰▰▰▱▱▱"""
    try:
        frac = max(0.0, min(1.0, float(frac)))
    except (TypeError, ValueError):
        frac = 0.0
    filled = round(frac * width)
    return "▰" * filled + "▱" * (width - filled)

def _rssi_bars(rssi):
    """4-segment signal-strength indicator from dBm."""
    if rssi >= -50:   return "▂▄▆█"
    elif rssi >= -65: return "▂▄▆░"
    elif rssi >= -80: return "▂▄░░"
    else:             return "▂░░░"

def _today_str():
    return time.strftime("%Y-%m-%d")

def _load_counters():
    global _daily_counters
    try:
        with open(COUNTERS_FILE, "r") as f:
            data = json.load(f)
        if data.get("date") == _today_str():
            _daily_counters = data
        else:
            _daily_counters = {"date": _today_str(), "mains_down": 0, "shutdowns": 0}
    except Exception:
        _daily_counters = {"date": _today_str(), "mains_down": 0, "shutdowns": 0}

def _save_counters():
    try:
        os.makedirs(os.path.dirname(COUNTERS_FILE), exist_ok=True)
        tmp_path = COUNTERS_FILE + ".tmp"
        with open(tmp_path, "w") as f:
            json.dump(_daily_counters, f)
        os.replace(tmp_path, COUNTERS_FILE)  # atomic on same filesystem
    except Exception as e:
        log.warning(f"Failed to persist daily counters: {e}")

def _bump_counter(key):
    """Increments a daily counter, resetting on date rollover. Call under _lock."""
    today = _today_str()
    if _daily_counters.get("date") != today:
        _daily_counters["date"] = today
        _daily_counters["mains_down"] = 0
        _daily_counters["shutdowns"] = 0
    _daily_counters[key] = _daily_counters.get(key, 0) + 1
    _save_counters()

def _get_counters():
    today = _today_str()
    with _lock:
        if _daily_counters.get("date") != today:
            _daily_counters["date"] = today
            _daily_counters["mains_down"] = 0
            _daily_counters["shutdowns"] = 0
            _save_counters()
        return dict(_daily_counters)

def get_proxmox_uptime():
    # NOTE: TCP reachability counts as "online" on purpose — for a UPS monitor,
    # a node still accepting connections means it has power. A hard-hung node
    # that keeps listening will simply never confirm "offline" and hit the
    # verification timeout warning instead, which is the desired failsafe.
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

def _verify_proxmox_transition(expect_up, trigger_label, timeout_sec=120, interval_sec=10):
    """
    Polls Proxmox until it reaches the expected state (up or down),
    then sends a Telegram confirmation. Runs in its own thread — never
    blocks the caller.
    """
    global _mains_down_started_at
    start = time.time()
    while time.time() - start < timeout_sec:
        prox_up, prox_uptime = get_proxmox_uptime()
        if prox_up == expect_up:
            if expect_up:
                downtime_line = ""
                with _lock:
                    if _mains_down_started_at is not None:
                        elapsed = time.time() - _mains_down_started_at
                        adjusted = max(0, elapsed - EXTENDER_BOOT_LAG_SEC)
                        downtime_line = f"\n⏱️ Approx mains downtime: ~{fmt_downtime(adjusted)}"
                        _mains_down_started_at = None
                notify(
                    f"✅ <b>Proxmox Confirmed Online</b>\n\n"
                    f"Trigger: {trigger_label}\n⌚ Uptime: {prox_uptime}"
                    f"{downtime_line}"
                )
            else:
                notify(
                    f"✅ <b>Proxmox Confirmed Offline</b>\n\n"
                    f"Trigger: {trigger_label}"
                )
            return
        time.sleep(interval_sec)

    # Timed out without reaching expected state
    state_word = "online" if expect_up else "offline"
    notify(
        f"⚠️ <b>Verification Timeout</b>\n\n"
        f"Trigger: {trigger_label}\n"
        f"Proxmox did not confirm {state_word} within {timeout_sec}s. Check manually."
    )

def start_verification(expect_up, trigger_label, timeout_sec=120, interval_sec=10):
    threading.Thread(
        target=_verify_proxmox_transition,
        args=(expect_up, trigger_label, timeout_sec, interval_sec),
        daemon=True,
    ).start()
    
# ==================================================
# ESP32 POLLING DAEMON
# ==================================================

def _check_bios_reconciliation(state):
    """
    If the ESP32 still believes Proxmox is shut down (any sdMains/sdWAN/
    sdManual flag set) but Proxmox has been confirmed ONLINE continuously
    for RECONCILE_MIN_ONLINE_SEC, it almost certainly booted on its own
    (BIOS 'power on after AC loss') without going through executeWakeProxmox().
    Force a wake command to clear the stale flags.

    Deliberately does NOT trigger on mains/WAN health alone — only on
    Proxmox's actual confirmed online state, so a genuine manual /off
    (where Proxmox stays truly offline) is never touched.
    """
    global _prox_online_since

    if not state:
        return
    flags_stuck = state.get("sdMains") or state.get("sdWAN") or state.get("sdManual")
    if not flags_stuck:
        _prox_online_since = None
        return

    prox_up, _ = get_proxmox_uptime()
    if not prox_up:
        _prox_online_since = None
        return

    now = time.time()
    if _prox_online_since is None:
        _prox_online_since = now
        return

    if now - _prox_online_since >= RECONCILE_MIN_ONLINE_SEC:
        log.warning("Reconciling stale shutdown flags — Proxmox online without WOL trigger.")
        _send_esp32_command({"cmd": "wake"})
        notify(
            "⚠️ <b>Flags Reconciled</b>\n\n"
            "Proxmox has been online for 2.5+ min but the ESP32 still had a "
            "shutdown flag set (likely BIOS auto-power-on after mains restored, "
            "bypassing WOL). Sent a wake command to clear stale flags."
        )
        _prox_online_since = None

def esp32_poll_loop():
    global _esp32_fail, _esp32_alerted, _esp32_state
    log.info("Starting background worker polling loop...")
    BACKOFF_CAP = 60  # never wait longer than this between polls
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
                    # Do not set _esp32_alerted to True here yet!
                    alert_dead = True
        
        if alert_recovery:
            notify(f"✅ <b>ESP32 BACK ONLINE</b>\n\nUPS sensor ({ESP32_IP}) recovered.\nFirmware: {recovery_fw}")
        elif alert_dead:
            success = notify(f"⚠️ <b>ESP32 UNREACHABLE</b>\n\nSensor missed metrics. Authority systems remain autonomous.")
            with _lock:
                if success:
                    _esp32_alerted = True # Only lock out future alerts if we actually told the user

        if state is not None:
            _check_bios_reconciliation(state)

        with _lock:
            fail_count = _esp32_fail
        if fail_count >= ESP32_DEAD_THRESH:
            sleep_time = min(ESP32_POLL_INTERVAL * (2 ** (fail_count - ESP32_DEAD_THRESH + 1)), BACKOFF_CAP)
        else:
            sleep_time = ESP32_POLL_INTERVAL
        time.sleep(sleep_time)

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
                mins_raw = params.get("mins", [None])[0]
                threading.Thread(target=process_esp_notification, args=(event_type, mins_raw)).start()
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, format, *args): pass

def _patch_esp32_state(patch):
    """
    Applies realtime corrections to the cached ESP32 state. Only patches
    after a real poll has populated the cache — never fabricates partial
    state (a partial dict would make build_status_message() report bogus
    defaults like "WAN DOWN" before the first successful poll).
    Call under _lock.
    """
    if _esp32_state:
        _esp32_state.update(patch)

def process_esp_notification(event, mins_raw=None):
    log.info(f"Asynchronous webhook hit from ESP32: event={event} mins={mins_raw}")
    global _esp32_state, _mains_down_started_at

    approx_downtime_str = None  # populated only on a real restore-from-down event

    # ESP32 reports its current (possibly custom) mains delay in the
    # countdown-start webhook so the Telegram message is always accurate.
    countdown_mins_txt = None
    if mins_raw:
        try:
            m = max(1, int(str(mins_raw)))
            countdown_mins_txt = f"{m} minute{'s' if m != 1 else ''}"
        except (TypeError, ValueError):
            pass

    # --- Real-Time State Overrides to Prevent Cache Stodginess ---
    with _lock:
        if event == "mains_down_countdown_start":
            _mains_down_started_at = time.time()
            _bump_counter("mains_down")
            _patch_esp32_state({"mainsUp": False, "mainsFailSinceMs": 1})  # Force metrics to reflect a running countdown
        elif event == "mains_false_alarm" or event == "mains_restored_override_cleared":
            if _mains_down_started_at is not None:
                elapsed = time.time() - _mains_down_started_at
                adjusted = max(0, elapsed - EXTENDER_BOOT_LAG_SEC)
                approx_downtime_str = fmt_downtime(adjusted)
                _mains_down_started_at = None
            _patch_esp32_state({"mainsUp": True, "mainsFailSinceMs": 0})
        elif event == "shutdown_mains_start":
            _bump_counter("shutdowns")
            _patch_esp32_state({"mainsUp": False, "sdMains": True})
        elif event == "shutdown_wan_start":
            _bump_counter("shutdowns")
            _patch_esp32_state({"wanUp": False, "sdWAN": True})

    mapping = {
        "esp_booted":
            "🟢 <b>ESP32 Online</b>\n\nUPS monitor started. Watching mains and WAN.",
        "power_instability":
            "⚡ <b>Power Instability</b>\n\nMains has flapped 3+ times in the last 10 minutes. Worth checking the supply.",
        "mains_down_countdown_start":
            "⚠️ <b>Mains Down</b>\n\nCan't reach 192.168.0.2. Shutdown in <b>"
            + (countdown_mins_txt or "5 minutes") + "</b> if not restored.",
        "mains_down_override_active":
            "⚠️ <b>Mains Down</b>\n\nManual override is active — auto-shutdown suppressed. Send /off to shut down manually.",
        "mains_down_shutdown_suppressed":
            "🚨 <b>Mains Down — SHUTDOWN SUPPRESSED</b>\n\nA shutdown flag is already stuck set (sdMains/sdWAN/sdManual) so auto-shutdown will NOT fire. This is likely a stale flag from a previous event. Run /diag and reconcile — Proxmox is currently unprotected.",
        "mains_false_alarm":
            "✅ <b>Mains Restored</b>\n\nLine recovered before the 5 min timeout. No action taken."
            + (f"\n⏱️ Approx downtime: ~{approx_downtime_str}" if approx_downtime_str else ""),
        "mains_restored_override_cleared":
            "✅ <b>Mains Restored</b>\n\nManual override cleared. Monitoring resumed normally."
            + (f"\n⏱️ Approx downtime: ~{approx_downtime_str}" if approx_downtime_str else ""),
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
            "📡 <b>WOL Sent</b>\n\nWake-on-LAN packet broadcast to M900. Boot takes ~30–60s.",
        "wan_restored_mains_down_hold":
            "🌐 <b>WAN Restored</b>\n\nInternet is back, but mains is still down. Holding restore until power returns.",
    }
    if event in mapping:
        notify(mapping[event])

    # --- Outcome verification for shutdown/wake triggers ---
    if event in ("shutdown_mains_start", "shutdown_wan_start",
                "shutdown_manual_mains_down", "shutdown_manual_normal"):
        start_verification(expect_up=False, trigger_label=event, timeout_sec=120, interval_sec=8)
    elif event == "wol_packet_sent":
        start_verification(expect_up=True, trigger_label=event, timeout_sec=120, interval_sec=10)

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

    header = (
        f"⚡ <b>UPS STATUS</b>  <i>{time.strftime('%H:%M:%S')}</i>\n"
        f"━━━━━━━━━━━━━━━━━━━━"
    )

    if state:
        mains_up = state.get("mainsUp", False)
        wan_up   = state.get("wanUp",   False)

        sd_mains  = state.get("sdMains",            False)
        sd_wan    = state.get("sdWAN",              False)
        sd_manual = state.get("sdManual",           False)
        man_ovr   = state.get("manualOverride",     False)

        mains_fail_ms = state.get("mainsFailSinceMs", 0)
        wan_fail_ms   = state.get("wanFailSinceMs",   0)

        # Runtime-adjustable delay reported by the ESP32; fall back to the
        # compiled-in default when absent (older firmware / no data).
        mains_delay_ms = state.get("mainsDelayMs", MAINS_FAILURE_TIMEOUT_MS)
        if not isinstance(mains_delay_ms, (int, float)) or mains_delay_ms < 60000:
            mains_delay_ms = MAINS_FAILURE_TIMEOUT_MS

        ext_str = f"  · ext <code>{ext_uptime}</code>" if ext_uptime != "Unavailable" else ""
        mains_line = f"{'🟢' if mains_up else '🔴'} <b>Mains</b>  <code>{'UP' if mains_up else 'DOWN'}</code>{ext_str}"
        wan_line   = f"{'🟢' if wan_up else '🔴'} <b>WAN</b>    <code>{'UP' if wan_up else 'DOWN'}</code>"
        prox_line  = (
            f"{'🟢' if prox_up else '🔴'} <b>Proxmox</b>  "
            f"<code>{'ONLINE' if prox_up else 'OFFLINE'}</code>  · ⏱ <code>{prox_uptime}</code>"
        )

        # Countdown — only when actively counting down, with progress bar
        countdown_line = ""
        if not mains_up and mains_fail_ms > 0 and not man_ovr and not (sd_mains or sd_wan or sd_manual):
            remaining = max(0, mains_delay_ms - mains_fail_ms)
            m = int(remaining // 1000 // 60)
            s = int(remaining // 1000 % 60)
            frac = remaining / mains_delay_ms
            countdown_line = (
                f"\n\n⏳ <b>Shutting down in {m}m {s}s</b>\n"
                f"<code>{_bar(frac)}</code> <i>{int(round(frac * 100))}% left</i>"
            )
        elif not wan_up and wan_fail_ms > 0 and not (sd_mains or sd_wan or sd_manual):
            remaining = max(0, WAN_FAILURE_TIMEOUT_MS - wan_fail_ms)
            m = int(remaining // 1000 // 60)
            s = int(remaining // 1000 % 60)
            frac = remaining / WAN_FAILURE_TIMEOUT_MS
            countdown_line = (
                f"\n\n⏳ <b>WAN shutdown in {m}m {s}s</b>\n"
                f"<code>{_bar(frac)}</code> <i>{int(round(frac * 100))}% left</i>"
            )

        if sd_manual:             sd_reason = "Manual /off"
        elif sd_mains and sd_wan: sd_reason = "Mains &amp; WAN failure"
        elif sd_mains:            sd_reason = "Mains failure"
        elif sd_wan:              sd_reason = "WAN failure"
        else:                     sd_reason = None

    else:
        mains_line = "⚪ <b>Mains</b>  <code>UNKNOWN</code>"
        wan_line   = "⚪ <b>WAN</b>    <code>UNKNOWN</code>"
        prox_line  = f"{'🟢' if prox_up else '🔴'} <b>Proxmox</b>  <code>{'ONLINE' if prox_up else 'OFFLINE'}</code>  · ⏱ <code>{prox_uptime}</code>"
        countdown_line = ""
        sd_reason = None

    stale_note = "\n⚠️ <i>ESP32 offline — showing cached data</i>" if not sensor_alive else ""
    footer     = f"🛡 <b>{sd_reason}</b>" if sd_reason else "🛡 <i>No active shutdown reason</i>"

    counters = _get_counters()
    stats_line = (
        f"📊 Today · <b>{counters['mains_down']}</b> mains down · "
        f"<b>{counters['shutdowns']}</b> shutdown{'s' if counters['shutdowns'] != 1 else ''}"
    )

    return (
        f"{header}\n"
        f"{mains_line}\n"
        f"{wan_line}\n"
        f"{prox_line}"
        f"{countdown_line}\n"
        f"━━━━━━━━━━━━━━━━━━━━\n"
        f"{footer}\n"
        f"{stats_line}"
        f"{stale_note}"
    )

# ==================================================
# DIAGNOSIS CONTEXT ASSEMBLY
# ==================================================

def build_diag_message():
    state = _get_esp32_state()
    sensor_alive = _is_esp32_reachable()

    if not state:
        return "🔧 <b>ESP32 DIAGNOSTICS</b>\n\n⚪ <i>Unreachable — no data available.</i>"

    fw        = state.get("fw", "?")
    esp_ms    = state.get("espUptimeMs", 0)
    rssi      = state.get("rssi", 0)
    free_heap = state.get("freeHeap", 0)
    flaps     = state.get("recentFlaps", 0)
    man_mains = state.get("manualOffMainsDown", False)
    man_ovr   = state.get("manualOverride", False)

    if rssi >= -50:   rssi_q, bars = "EXCELLENT", _rssi_bars(rssi)
    elif rssi >= -65: rssi_q, bars = "Good",     _rssi_bars(rssi)
    elif rssi >= -80: rssi_q, bars = "Weak",     _rssi_bars(rssi)
    else:             rssi_q, bars = "Critical", _rssi_bars(rssi)

    badge = "🔴 STALE" if not sensor_alive else "🟢 LIVE"

    panel = (
        f"┌─ ESP32 NODE ───────────────\n"
        f"│ ip       {ESP32_IP}\n"
        f"│ firmware {fw}\n"
        f"│ uptime   {fmt_uptime(esp_ms // 1000)}\n"
        f"│ signal   {rssi} dBm {bars} {rssi_q}\n"
        f"│ heap     {free_heap // 1024} KB free\n"
        f"│ flaps    {flaps}/3 · last 10 min\n"
        f"├─ CONFIG ───────────────────\n"
        f"│ mains delay  {int(state.get('mainsDelayMs', MAINS_FAILURE_TIMEOUT_MS)) // 60000} min\n"
        f"│ wan timeout  {WAN_FAILURE_TIMEOUT_MS // 60000} min\n"
        f"│ poll         every {ESP32_POLL_INTERVAL}s\n"
        f"├─ FLAGS ────────────────────\n"
        f"│ override     {'ON ' if man_ovr else 'OFF'}\n"
        f"│ off-while-down {'YES' if man_mains else 'NO'}\n"
        f"└────────────────────────────"
    )

    return (
        f"🔧 <b>ESP32 DIAGNOSTICS</b>  <i>{badge}</i>\n\n"
        f"<code>{panel}</code>"
    )

# ==================================================
# TELEGRAM POLLING & COMMAND DISPATCH ENGINE
# ==================================================

def handle_command(text):
    text = text.strip()
    log.info(f"Processing chat instruction string tokens: {text!r}")

    if text == "/status":
        notify(build_status_message())

    elif text == "/diag":
        notify(build_diag_message())

    elif text == "/on":
        if not _is_esp32_reachable():
            notify(
                "❌ <b>ESP32 Unreachable</b>\n\n"
                "Can't send wake command — no link to sensor.\n"
                "Check 192.168.0.178 manually."
            )
            return
        prox_up, _ = get_proxmox_uptime()
        if prox_up:
            notify(
                "ℹ️ <b>Already Online</b>\n\n"
                "Proxmox is already running. No action taken."
            )
            return
        _send_esp32_command({"cmd": "wake"})

    elif text == "/off":
        if not _is_esp32_reachable():
            notify(
                "❌ <b>ESP32 Unreachable</b>\n\n"
                "Can't send shutdown command — no link to sensor.\n"
                "Shut down Proxmox manually via console."
            )
            return
        prox_up, _ = get_proxmox_uptime()
        if not prox_up:
            notify(
                "ℹ️ <b>Already Offline</b>\n\n"
                "Proxmox is already down. No action taken."
            )
            return
        _send_esp32_command({"cmd": "shutdown"})

    elif text.split()[0] in ("/custom-delay", "/custom_delay"):
        parts = text.split()
        state = _get_esp32_state()
        cur_ms = state.get("mainsDelayMs") if state else None

        if len(parts) == 1:
            # No argument — show current setting and usage
            cur = f"{int(cur_ms) // 60000} min" if isinstance(cur_ms, (int, float)) and cur_ms >= 60000 else "unknown (no data from ESP32)"
            notify(
                "ℹ️ <b>Mains Shutdown Delay</b>\n\n"
                f"Current: <b>{cur}</b> (default 5 min)\n"
                "Usage: <code>/custom-delay &lt;minutes&gt;</code> (1–720)\n"
                "Or: <code>/custom-delay reset</code>"            )
            return

        arg = parts[1].lower()
        if arg == "reset":
            minutes = 5
        else:
            try:
                minutes = int(arg)
            except ValueError:
                notify("⚠️ Usage: <code>/custom-delay &lt;minutes&gt;</code> (1–720) or <code>/custom-delay reset</code>")
                return
            if not (1 <= minutes <= 720):
                notify("⚠️ Delay must be between <b>1</b> and <b>720</b> minutes.")
                return

        if not _is_esp32_reachable():
            notify(
                "❌ <b>ESP32 Unreachable</b>\n\n"
                "Can't change the delay — no link to sensor."
            )
            return

        if _send_esp32_command({"cmd": "custom_delay", "minutes": minutes}):
            suffix = " (default)" if minutes == 5 else ""
            notify(
                f"✅ <b>Mains Shutdown Delay Set</b>\n\n"
                f"Auto-shutdown now fires after <b>{minutes} min{suffix}</b> of mains failure.\n"
                f"Setting is persisted on the ESP32 and survives reboots. WAN timeout unchanged (10 min)."
            )
        else:
            notify("❌ Failed to deliver the delay command to the ESP32.")

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

    with _lock:
        _load_counters()

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

## Part 2: ESP32 Firmware

Exposes a JSON telemetry api endpoint on `/state` via a lightweight local server and listens for deferred inputs over `/command`.

* **Path:** `/mnt/data/public/esp32-ups-monitor/src/main.cpp`

```cpp
// ESP firmware/ main.cpp

#include <Arduino.h>
#include <WiFi.h>
#include <HTTPClient.h>
#include <WiFiUdp.h>
#include <Preferences.h>
#include <ArduinoOTA.h>
#include <ArduinoJson.h>
#include <WebServer.h>

// ===================== CONFIG =====================
const char* WIFI_SSID    = "YOUR_WIFI_SSID";
const char* WIFI_PASS    = "YOUR_WIFI_PASSWORD";
// --- HARDWARE LOCK: Bound strictly to the Main Router's 2.4GHz BSSID ---
const uint8_t MAIN_ROUTER_BSSID[] = {0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF}; 

const char* OTA_PASSWORD = "YOUR_OTA_PASSWORD";
const char* FW_VERSION   = "V6.6";

const char* PING_TARGET  = "192.168.0.2"; // Extender IP for checking mains status
const int   PING_PORT    = 80;
const char* WAN_TARGET_1 = "8.8.8.8";
const char* WAN_TARGET_2 = "1.1.1.1";
const int   WAN_PORT     = 53;

const char* SHUTDOWN_URL = "http://192.168.0.50:9999/shutdown";
const char* BROADCAST_IP = "192.168.0.255";
const char* M900_MAC     = "AA:BB:CC:DD:EE:FF";

// Target Pi notification endpoint
const char* PI_NOTIFY_URL = "http://192.168.0.169:9997/notify";

// --- Polling intervals (DECOUPLED: mains checked far more often than WAN) ---
// Previously a single 15s interval was shared by both mains + WAN checks,
// and since checks themselves could take up to ~7-8s under failure, the real
// gap between mains samples could stretch to ~25s+ — long enough for a
// 10-15s power blip to fall entirely between two samples and never be seen.
const unsigned long MAINS_POLL_INTERVAL_MS   = 3000;    // fast mains sampling
const unsigned long WAN_POLL_INTERVAL_MS     = 15000;   // unchanged cadence for WAN
const unsigned long MAINS_FAILURE_TIMEOUT_MS = 300000;   // 5 min (unchanged)
const unsigned long WAN_FAILURE_TIMEOUT_MS   = 600000;   // 10 min (unchanged)

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
bool mainsDownNotified   = false;
bool wanFailureStarted   = false;
unsigned long mainsFirstFailTime = 0;
unsigned long wanFirstFailTime   = 0;
unsigned long espBootTime        = 0;
unsigned long shutdownIssuedAt   = 0;   // when shutdown_complete last fired

// --- Settle timing ---
const unsigned long MIN_SHUTDOWN_SETTLE_MS = 45000;  // min wait before wake-eligible

// --- Cached sensor state (updated by background tasks only) ---
bool cachedMainsUp = false;
bool cachedWanUp   = false;

// --- Flap detection ---
unsigned long flapTimestamps[10];
int  flapCount  = 0;
bool flapWarned = false;

// --- Command Deferral Flag ---
String pendingCommand = "";
long pendingCustomDelayMin = -1;

// --- Runtime-adjustable timeouts ---
// Mains failure timeout can be changed at runtime via the Pi (/custom-delay
// -> POST /command). Defaults to MAINS_FAILURE_TIMEOUT_MS, persisted in NVS.
unsigned long mainsFailureTimeoutMs = MAINS_FAILURE_TIMEOUT_MS;

WiFiUDP udp;
WebServer server(80);

// --- Background network-check tasks (run on core 0, parallel to loop()/server on core 1) ---
// Mains and WAN are now checked by TWO SEPARATE tasks on their own schedules,
// so a slow/failing WAN check can never delay how often mains is sampled.
TaskHandle_t mainsCheckTaskHandle = NULL;
TaskHandle_t wanCheckTaskHandle   = NULL;
portMUX_TYPE cacheMux = portMUX_INITIALIZER_UNLOCKED; // guards cachedMainsUp/cachedWanUp

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
    prefs.putULong("mainsDelay",  mainsFailureTimeoutMs);
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
    unsigned long savedDelay = prefs.getULong("mainsDelay", 0);
    if (savedDelay >= 60000UL && savedDelay <= 720UL * 60000UL) {
        mainsFailureTimeoutMs = savedDelay;
    }
    prefs.end();

    // if we're booting up already marked as "shut down" (e.g. ESP32
    // itself rebooted mid-window), restart the settle timer from now rather
    // than trusting a pre-reboot millis() value or defaulting to 0.
    // (A persisted millis() stamp is meaningless across reboots, so the old
    // "sdIssuedAt" NVS key was removed entirely.)
    if (shutdownReasonMains || shutdownReasonWAN || shutdownReasonManual) {
        shutdownIssuedAt = millis();
    }
}

// ==================================================
// HELPERS
// ==================================================

void notifyPi(String eventType, String extra = "") {
    if (WiFi.status() != WL_CONNECTED) return;
    WiFiClient client;
    HTTPClient http;
    String url = String(PI_NOTIFY_URL) + "?event=" + eventType;
    if (extra.length()) url += "&" + extra;
    http.begin(client, url);
    http.setTimeout(2000);
    http.GET();
    http.end();
}

bool tcpCheck(const char* host, int port, int timeoutMs = 2000) {
    WiFiClient client;
    // Use the connect(host, port, timeout_ms) overload — setTimeout() only
    // affects socket READS, not the TCP connect handshake, so the old code
    // could block for the core's default connect timeout (several seconds)
    // instead of the intended 800ms/2000ms budget.
    bool result = client.connect(host, port, (int64_t)timeoutMs);
    client.stop();
    return result;
}

// --- Mains check: fast single-attempt, no internal retry loop ---
// Previously this retried up to 3x with 500ms delays between attempts
// (up to ~7.5s worst case per call). That made mains sampling slow to run,
// which is exactly what caused the shared 15s task to drift and miss short
// blips. Retry/confidence is now handled by the FAST POLL RATE instead
// (MAINS_POLL_INTERVAL_MS = 3s) — a single missed sample gets corrected by
// another sample 3 seconds later, rather than spending 7.5s trying to be
// sure on any single sample.
bool isMainsUp() {
    return tcpCheck(PING_TARGET, PING_PORT, 800);
}

bool isWANUp() {
    if (tcpCheck(WAN_TARGET_1, WAN_PORT, 2000)) return true;
    if (tcpCheck(WAN_TARGET_2, WAN_PORT, 2000)) return true;
    return false;
}

bool isM900ShutDown() {
    return shutdownReasonMains || shutdownReasonWAN || shutdownReasonManual;
}

// ==================================================
// BACKGROUND NETWORK-CHECK TASKS (core 0)
// ==================================================
// Split into two independent tasks so mains sampling is never delayed by a
// slow/failing WAN check (or vice versa). Each writes its own cached value
// under the same spinlock. Fixed-rate scheduling (vTaskDelayUntil) keeps the
// polling interval accurate even if a given check takes a little time,
// instead of stacking check-time on top of the wait like the old code did.

void mainsCheckTask(void *pvParameters) {
    TickType_t lastWake = xTaskGetTickCount();
    for (;;) {
        bool mainsUp = isMainsUp();

        portENTER_CRITICAL(&cacheMux);
        cachedMainsUp = mainsUp;
        portEXIT_CRITICAL(&cacheMux);

        vTaskDelayUntil(&lastWake, pdMS_TO_TICKS(MAINS_POLL_INTERVAL_MS));
    }
}

void wanCheckTask(void *pvParameters) {
    TickType_t lastWake = xTaskGetTickCount();
    for (;;) {
        bool wanUp = isWANUp();

        portENTER_CRITICAL(&cacheMux);
        cachedWanUp = wanUp;
        portEXIT_CRITICAL(&cacheMux);

        vTaskDelayUntil(&lastWake, pdMS_TO_TICKS(WAN_POLL_INTERVAL_MS));
    }
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
    int validFlaps = 0;
    
    // Shift unexpired flaps to the front of the array
    for (int i = 0; i < flapCount; i++) {
        if ((now - flapTimestamps[i]) <= FLAP_WINDOW_MS) {
            flapTimestamps[validFlaps] = flapTimestamps[i];
            validFlaps++;
        }
    }
    
    if (flapCount != validFlaps) {
        flapCount = validFlaps;
        if (flapCount < FLAP_THRESHOLD) flapWarned = false; // Clear warning lock if we drop below threshold
        Serial.println("Old flaps expired — array compacted");
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
        portENTER_CRITICAL(&cacheMux);
        bool mainsUpNow = cachedMainsUp;
        portEXIT_CRITICAL(&cacheMux);
        if (!mainsUpNow) {
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
    WiFiClient client;                // explicit client: avoids HTTPClient reuse crash
    HTTPClient http;
    http.begin(client, SHUTDOWN_URL);
    http.setTimeout(1000);
    http.GET();
    http.end();
    ArduinoOTA.handle();
    server.handleClient();

    notifyPi("shutdown_complete");
    shutdownIssuedAt = millis();  
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
    JsonDocument doc;

    // Read the cached sensor values under the same spinlock the writer
    // tasks use (loop() does the same — keep this consistent).
    portENTER_CRITICAL(&cacheMux);
    bool mainsUpCached = cachedMainsUp;
    bool wanUpCached   = cachedWanUp;
    portEXIT_CRITICAL(&cacheMux);

    doc["mainsUp"] = mainsUpCached;
    doc["wanUp"]   = wanUpCached;
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
    doc["mainsDelayMs"] = mainsFailureTimeoutMs;

    String response;
    serializeJson(doc, response);
    server.send(200, "application/json", response);
}

void handlePostCommand() {
    if (server.hasArg("plain") == false) {
        server.send(400, "application/json", "{\"error\":\"Body empty\"}");
        return;
    }
    
    JsonDocument doc;
    DeserializationError error = deserializeJson(doc, server.arg("plain"));
    if (error) {
        server.send(400, "application/json", "{\"error\":\"Invalid JSON\"}");
        return;
    }

    String cmd = doc["cmd"] | "";
    if (cmd == "wake" || cmd == "shutdown") {
        pendingCommand = cmd; // Defers processing to main loop, avoiding stack re-entrancy crashes
        server.send(200, "application/json", "{\"status\":\"pending\"}");
    } else if (cmd == "custom_delay") {
        long mins = doc["minutes"] | -1L;
        if (mins >= 1 && mins <= 720) {
            pendingCustomDelayMin = mins;
            pendingCommand = "custom_delay"; // Deferred like the others — NVS write stays out of server context
            server.send(200, "application/json", "{\"status\":\"pending\"}");
        } else {
            server.send(400, "application/json", "{\"error\":\"minutes must be 1-720\"}");
        }
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

    // Launch mains + WAN checks as two SEPARATE tasks on core 0, parallel to
    // loop()/server on core 1. Mains polls every 3s; WAN polls every 15s.
    // Splitting them means a slow WAN check can never delay a mains sample.
    xTaskCreatePinnedToCore(
        mainsCheckTask,
        "mainsCheckTask",
        4096,
        NULL,
        2,
        &mainsCheckTaskHandle,
        0
    );

    xTaskCreatePinnedToCore(
        wanCheckTask,
        "wanCheckTask",
        4096,
        NULL,
        1,
        &wanCheckTaskHandle,
        0
    );

    espBootTime = millis(); 
    delay(1000); 
    notifyPi("esp_booted");
}

// ==================================================
// MAIN LOOP
// ==================================================
// Runs its own decision logic on a 3s cadence (matching the new fast mains
// poll rate) instead of the old shared 15s cadence, so a blip that the
// background task now catches isn't sat on for up to 15s before loop()
// even looks at it.
const unsigned long LOOP_DECISION_INTERVAL_MS = 3000;
unsigned long lastDecisionTime = 0;

void loop() {
    delay(2); // Yields core execution to RTOS background tasks

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
            portENTER_CRITICAL(&cacheMux);
            bool mainsUpNow = cachedMainsUp;
            portEXIT_CRITICAL(&cacheMux);
            if (!mainsUpNow) {
                manualOverride = true;
                saveState();
            }
            executeWakeProxmox("Manual request executed via Pi.");
            // Only keep the recovery-suppression latch armed if a mains
            // failure is actually still in progress; otherwise a stale
            // wakeExecuted would swallow the next legitimate flap /
            // mains_false_alarm event after a manual on->off->on cycle.
            if (!mainsFailureStarted) {
                wakeExecuted = false;
            }
        } else if (executeCmd == "shutdown") {
            executeShutdownProxmox("manual");
        } else if (executeCmd == "custom_delay") {
            if (pendingCustomDelayMin > 0) {
                mainsFailureTimeoutMs = (unsigned long)pendingCustomDelayMin * 60000UL;
                saveState();
                Serial.printf("Mains failure timeout set to %ld min\n", pendingCustomDelayMin);
            }
            pendingCustomDelayMin = -1;
        }
    }

    unsigned long now = millis();
    if (now - lastDecisionTime < LOOP_DECISION_INTERVAL_MS) return;
    lastDecisionTime = now;

    // Checks now run on core 0 (mainsCheckTask / wanCheckTask); read the
    // latest cached results here instead of blocking loop()/server directly.
    portENTER_CRITICAL(&cacheMux);
    bool mainsUp = cachedMainsUp;
    bool wanUp   = cachedWanUp;
    portEXIT_CRITICAL(&cacheMux);

    if (mainsUp) checkFlapReset();

    // ==================================================
    // AUTONOMOUS AUTOMATION & FAILSAFE ENGINE
    // ==================================================
    if (isM900ShutDown() && (now - shutdownIssuedAt >= MIN_SHUTDOWN_SETTLE_MS)) {
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
        }
        
        // DEBOUNCE: Only notify Pi if down for > 5 seconds.
        if (!mainsDownNotified && (now - mainsFirstFailTime >= 5000)) {
            mainsDownNotified = true; // <--- Just use the global variable directly
            if (isM900ShutDown()) {
                notifyPi("mains_down_shutdown_suppressed");
            } else if (manualOverride) {
                notifyPi("mains_down_override_active");
            } else {
                notifyPi("mains_down_countdown_start",
                         "mins=" + String(mainsFailureTimeoutMs / 60000UL));
            }
        }

        if (!manualOverride && !isM900ShutDown() && (now - mainsFirstFailTime >= mainsFailureTimeoutMs)) {
            executeShutdownProxmox("mains");
        }
    } else {
        if (mainsFailureStarted) {
            unsigned long failDuration = now - mainsFirstFailTime;
            mainsFailureStarted = false;
            mainsFirstFailTime  = 0;
            
            // Only trigger recovery logic if we actually sent a failure notification
            if (failDuration >= 5000) { 
                if (manualOverride) {
                    manualOverride = false;
                    saveState();
                    notifyPi("mains_restored_override_cleared");
                } else if (!isM900ShutDown() && !wakeExecuted) {
                    recordMainsFlap();
                    notifyPi("mains_false_alarm");
                }
            }
            wakeExecuted = false;
            mainsDownNotified = false; // <--- Reset the global variable cleanly
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
    --auth=YOUR_OTA_PASS
lib_deps =
    bblanchon/ArduinoJson@^7.0.0
```
