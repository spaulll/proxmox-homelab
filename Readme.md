<p align="center">
    <picture>
        <img alt="Proxmox Logo" src="https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/png/proxmox.png" width="120">
    </picture>
</p>

<h1 align="center">🛠️ Homelab — Proxmox & Self-Hosted Services</h1>

<p align="center">
  <b>Single-Node LXC · OpenWrt Routing · Tailscale Mesh · Nginx Proxy Manager</b><br>
  Isolated · Secure · Automated · Self-Healing
</p>

---

Personal homelab running on a single Proxmox VE node with LXC containers for all services. Internal network routed via OpenWrt LXC. Remote access via Tailscale and Nginx Proxy Manager with Let's Encrypt SSL.

---

## 🖥️ Host Node — `prox`

| Property | Value |
| --- | --- |
| **Hardware** | Lenovo ThinkCentre M900 Tiny |
| **IP** | 192.168.0.50/24, gw 192.168.0.1 |
| **OS** | Proxmox VE 9.1.11, kernel 7.0.2-2-pve |
| **CPU / RAM** | 4 cores x86_64 / ~16 GB |
| **Web UI** | [https://192.168.0.50:8006](https://192.168.0.50:8006) → prox.myownserv.duckdns.org |

### 💾 Storage

| Name | Type | Mount | Size | Used |
| --- | --- | --- | --- | --- |
| **local** | dir | `/var/lib/vz` | 65 GB | 38% |
| **local-lvm** | LVM-thin | — | ~134 GB | 76% |
| **/dev/sdb** | ext4 SSD | `/mnt/data` | 469 GB | 76% |

* `local`: ISOs, templates, backups
* `local-lvm`: all LXC rootfs and VM disks
* `/mnt/data`: main data drive, shared to containers via bind mounts

### 🌐 Network Bridges

| Bridge | Attached | Subnet | Purpose |
| --- | --- | --- | --- |
| **vmbr0** | eno1 | 192.168.0.0/24 | Main LAN |
| **vmbr1** | none | 10.10.10.0/24 | Internal, routed by OpenWrt LXC |
| **vmbr2** | none | — | Unused |

---

## 🍓 Raspberry Pi — `192.168.0.169`

Runs three independent services:

🔹 **1. Extender Uptime Bridge**

* **Script:** `/usr/local/bin/extender-uptime.py`
* Exposes `GET http://192.168.0.169:9998/extender-uptime` → returns DIR-825 J1 uptime in seconds via Telnet/pexpect, 503 on failure

🔹 **2. UPS Monitor Brain (`ups-monitor.py`)**

* Telegram bot (long-polling): `/on` `/off` `/status` `/diag`
* Polls ESP32 `GET /state` every 15s; sends commands via `POST /command`
* Receives instant event notifications from ESP32 on port 9997
* Queries Proxmox API (192.168.0.50:8006) and extender bridge independently
* ESP32 liveness alert after 3 consecutive failed polls (~45s)
* Optional SOCKS5 proxy for Telegram via `TG_PROXY` config var

🔹 **3. AdGuard Home** — backup DNS (see DNS Architecture)

* Also runs: Keepalived (BACKUP), AdGuardHome-Sync

---

## 🗺️ Network Topology

```
Internet → Asus RT-AX53U (192.168.0.1) — LAN 192.168.0.0/24
           Static route: 10.10.10.0/24 via 192.168.0.150 (OpenWrt WAN)

vmbr0 (LAN):      prox .50 | NAS .10 | AdGuard .146 | Tailscale .5 | Syncthing .57 | OpenWrt eth0 .150
vmbr1 (internal): OpenWrt eth1 → gw 10.10.10.1
                  npm .200 | jellyfin .201 | immich .234 | filebrowser .144
                  aria2/anchor/immich/warp-exit/tg-proxy → DHCP

```

* **Remote access:** Tailscale (LXC 110) exposes both subnets.
* **Reverse proxy:** All `*.myownserv.duckdns.org` via NPM (LXC 101) with Let's Encrypt.

---

## LXC Containers
> 🗓️ Last Snapshot — Fri Jun 19 2026 | *Run snapshot script to refresh*

| ID | Name | Status | OS | CPU | RAM | Disk | Boot | Bridge | IP | Mounts |
|---|---|---|---|---|---|---|---|---|---|---|
| 100 | anchor | running | debian | 1 | 2048 MB | 6G | yes | vmbr1 | dhcp | — |
| 101 | npm | running | debian | 1 | 512 MB | 4G | yes | vmbr1 | dhcp | — |
| 103 | aria2 | running | debian | 2 | 1024 MB | 8G | yes | vmbr1 | 10.10.10.177/24, rate=3MB/s | /mnt/data/public/Downloads → /mnt/nas |
| 104 | jellyfin | running | ubuntu | 3 | 2048 MB | 16G | yes | vmbr1 | 10.10.10.201/24, rate=2MB/s | /mnt/data/public/Downloads/ → /mnt/smb |
| 105 | NAS | running | alpine | 1 | 512 MB | 2G | yes | vmbr0 | 192.168.0.10/24 | /mnt/data/ → /srv/samba |
| 106 | openwrt | running | unmanaged | 1 | 256 MB | 4G | yes | vmbr0+vmbr1 | — | — |
| 107 | adguard | running | debian | 1 | 512 MB | 4G | yes | vmbr0 | 192.168.0.146/24 | — |
| 109 | immich | running | debian | 4 | 6144 MB | 20G | yes | vmbr1 | dhcp | /mnt/data/public/immich/ → /mnt/nas |
| 110 | tailscale-LXC | running | debian | 1 | 512 MB | 4G | yes | vmbr0 | 192.168.0.5/24 | — |
| 111 | filebrowser | running | debian | 1 | 512 MB | 8G | yes | vmbr1 | dhcp | /mnt/data/ → /mnt/smb |
| 113 | warp-exit | running | debian | 1 | 512 MB | 4G | yes | vmbr1 | dhcp | — |
| 115 | openwebui | stopped | debian | 2 | 2048 MB | 21G | no | vmbr1 | dhcp | — |
| 116 | syncthing | running | debian | 2 | 2048 MB | 8G | yes | vmbr0 | 192.168.0.57/24 | /mnt/data/public/syncthing → /root/syncthing |
| 117 | esp32-builder | stopped | debian | 2 | 2048 MB | 8G | no | vmbr1 | dhcp | /mnt/data/public/esp32-ups-monitor → /opt/esp32-ups-monitor |
| 118 | tg-proxy | running | debian | 1 | 512 MB | 4G | yes | vmbr1 | 10.10.10.218/24 | — |

| ID | Name | Purpose |
|---|---|---|
| 100 | anchor | Self-hosted note-taking |
| 101 | npm | Nginx Proxy Manager — reverse proxy + SSL |
| 103 | aria2 | Aria2 download manager + ariaflow auto-organizer |
| 104 | jellyfin | Jellyfin media server, HW transcoding via /dev/dri |
| 105 | NAS | Samba/SMB — exposes /mnt/data to LAN |
| 106 | openwrt | Router/gateway + DHCP for vmbr1 |
| 107 | adguard | AdGuard Home — primary DNS, Keepalived MASTER |
| 109 | immich | Immich photo backup, HW transcoding via /dev/dri |
| 110 | tailscale-LXC | Tailscale subnet router (both subnets) |
| 111 | filebrowser | Filebrowser web UI for /mnt/data |
| 112 | opencode | OpenCode AI assistant (stopped, onboot=0) |
| 113 | warp-exit | Cloudflare WARP egress + Tailscale exit node |
| 115 | openwebui | Open WebUI for LLMs (stopped, onboot=0) |
| 116 | syncthing | Syncthing continuous file sync |
| 117 | esp32-builder | PlatformIO build + OTA push for ESP32 (stopped, onboot=0) |
| 118 | tg-proxy | SOCKS5 proxy (GOST) via ProtonVPN WireGuard |

### NPM Proxy Hosts

| Domain | Backend | SSL |
|---|---|---|
| dns.myownserv.duckdns.org | http://192.168.0.146:80 | Let's Encrypt |
| files.myownserv.duckdns.org | http://10.10.10.144:8080 | Let's Encrypt |
| immich.myownserv.duckdns.org | http://10.10.10.234:2283 | Let's Encrypt |
| jellyfin.myownserv.duckdns.org | http://10.10.10.201:8096 | Let's Encrypt |
| npm.myownserv.duckdns.org | http://10.10.10.200:81 | Let's Encrypt |
| prox.myownserv.duckdns.org | https://192.168.0.50:8006 | Let's Encrypt |
| asus.lan | https://192.168.0.1:8443 | Custom |

---

## 🔲 VM

| ID | Name | Purpose | RAM | Disk |
| --- | --- | --- | --- | --- |
| **108** | win10 | Isolated Windows 10 sandbox | 4096 MB | 32 GB (local-lvm) |

---

## 📛 DNS Architecture

* **VIP:** `192.168.0.147` (Keepalived floating IP — all clients use this as DNS)
* **Failover:** VIP floats to Pi if Proxmox shuts down.
* **Domain:** `prox.dpdns.org` (DigitalPlat, free permanent) — NS delegated to Cloudflare
* **Cloudflare API token** `adguard-cert`: Zone DNS Edit, scoped to `dns.prox.dpdns.org`

### 🛡️ AdGuard Home

|  | LXC 107 (MASTER) | Pi (BACKUP) |
| --- | --- | --- |
| **IP** | 192.168.0.146 | 192.168.0.169 |
| **Role** | Keepalived MASTER, priority 100 | Keepalived BACKUP, priority 50 |
| **Encryption** | DoT :853, HTTPS :443 | Same |
| **Server name** | dns.prox.dpdns.org | Same |
| **HTTP bind** | 0.0.0.0:80 | — |
| **Certs** | `/etc/adguard-certs/` (acme.sh, Cloudflare DNS challenge) | Synced from LXC 107 via scp |

### 🔄 Keepalived

| Parameter | MASTER (LXC 107) | BACKUP (Pi) |
| --- | --- | --- |
| **interface** | eth0 | eth0 |
| **virtual_router_id** | 147 | 147 |
| **unicast_src_ip** | 192.168.0.146 | 192.168.0.169 |
| **unicast_peer** | 192.168.0.169 | 192.168.0.146 |
| **priority** | 100 | 50 |
| **auth_pass** | AdfG4IJK | AdfG4IJK |
| **virtual_ipaddress** | 192.168.0.147/24 | 192.168.0.147/24 |
| **vrrp_startup_delay** | 10 (global_defs) | — |

### 🔄 AdGuardHome-Sync (LXC 107)

* Origin → Replica: `https://192.168.0.146` → `http://192.168.0.169`
* `rewrites: false` (per-node rewrites independent)
* **Cron:** `0 */2 * * *` | **Config:** `/etc/adguardhome-sync/adguardhome-sync.yaml`

---

## ⚡ ESP32 UPS Monitor — V5.2

Monitors mains power (TCP → 192.168.0.2:80) and WAN (TCP → 8.8.8.8:53 / 1.1.1.1:53). Triggers graceful Proxmox shutdown on failure, restores via WOL. Telegram control via Pi ups-monitor.py.

**Source:** `/mnt/data/public/esp32-ups-monitor/src/main.cpp`

### ⚙️ Firmware Config

| Parameter | Value |
| --- | --- |
| **ESP32 IP** | 192.168.0.178 (static) |
| **OTA** | ArduinoOTA, hostname `esp32-ups-monitor`, password `password` |
| **BSSID lock** | CC:28:AA:C0:A2:70 (Asus 2.4GHz) |
| **Mains check** | TCP → 192.168.0.2:80 |
| **WAN check** | TCP → 8.8.8.8:53 or 1.1.1.1:53 |
| **Mains failure timeout** | 5 min |
| **WAN failure timeout** | 10 min |
| **Check interval** | 30s |
| **Shutdown webhook** | [http://192.168.0.50:9999/shutdown](http://192.168.0.50:9999/shutdown) (also /reboot) |
| **WOL target** | MAC 00:23:24:c7:1f:5d, broadcast 192.168.0.255 |
| **Pi notify URL** | [http://192.168.0.169:9997/notify?event=](http://192.168.0.169:9997/notify?event=)... |
| **ESP32 state API** | GET [http://192.168.0.178/state](http://192.168.0.178/state) |
| **ESP32 command API** | POST [http://192.168.0.178/command](http://192.168.0.178/command) |
| **Flap detection** | 3 events / 10 min rolling window |
| **Extender uptime** | [http://192.168.0.169:9998/extender-uptime](http://192.168.0.169:9998/extender-uptime) |

### 🛠️ PlatformIO Config (LXC 117 — `/opt/esp32-ups-monitor/platformio.ini`)

| Parameter | Value |
| --- | --- |
| **platform** | espressif32 |
| **board** | esp32dev |
| **framework** | arduino |
| **upload_protocol** | espota, port 192.168.0.178, auth `password` |
| **lib_deps** | bblanchon/ArduinoJson |

### 💾 NVS Persisted Flags

| Variable | NVS Key | Purpose |
| --- | --- | --- |
| **shutdownReasonMains** | sdMains | Auto-shutdown: mains failure |
| **shutdownReasonWAN** | sdWAN | Auto-shutdown: WAN failure |
| **shutdownReasonManual** | sdManual | Manual /off — blocks auto-restore |
| **manualOffWhileMainsDown** | sdManMains | /off while mains down — allow auto-restore on mains up |
| **manualOverride** | manOvr | /on while mains down — suppresses mains auto-shutdown |

### 🔄 Restore Logic

| Scenario | Auto-restore? |
| --- | --- |
| **Auto-shutdown (mains/WAN)** | Yes — when both mains and WAN back up |
| **Manual /off while mains UP** | No — user must send /on |
| **Manual /off while mains DOWN** | Yes — when mains and WAN both restore |

### 💬 Telegram Commands (handled by Pi — not firmware)

| Command | Behavior |
| --- | --- |
| `/on` | Pi → POST /command {"cmd":"wake"} to ESP32 |
| `/off` | Pi → POST /command {"cmd":"shutdown"} to ESP32 |
| `/status` | Mains, WAN, Proxmox uptime, extender uptime, countdown if active |
| `/diag` | ESP32: IP, uptime, RSSI, heap, firmware, flap count, override flags |

### 🔔 ESP32 Notification Events (→ Pi port 9997)

| Event | Meaning |
| --- | --- |
| `esp_booted` | ESP32 started |
| `power_instability` | Flap threshold crossed |
| `mains_down_countdown_start` | Mains dropped, countdown started |
| `mains_down_override_active` | Mains dropped, manualOverride set |
| `mains_false_alarm` | Mains recovered before timeout |
| `mains_restored_override_cleared` | Mains up, manualOverride cleared |
| `shutdown_mains_start` | Executing mains-timeout shutdown |
| `shutdown_wan_start` | Executing WAN-timeout shutdown |
| `shutdown_manual_mains_down` | Manual /off while mains was down |
| `shutdown_manual_normal` | Manual /off while mains up |
| `shutdown_complete` | Proxmox webhook fired |
| `restoring_network_stabilization` | Pre-WOL 15s stabilization wait |
| `wol_packet_sent` | WOL frame broadcast |
| `wan_restored_mains_down_hold` | WAN back but mains still down, holding restore |

---

## 🏗️ LXC 117 — ESP32 Builder

Start manually when needed: `pct start 117` → edit `main.cpp` via SMB → Telegram 🚀 on build → `pct stop 117`
SMB path: `\\192.168.0.10\public\esp32-ups-monitor\src\main.cpp`

| File | Path (inside LXC) | Purpose |
| --- | --- | --- |
| **Build & push** | `/usr/local/bin/esp32-build-push.sh` | Compiles via PlatformIO, OTA push, Telegram notify |
| **File watcher** | `/usr/local/bin/esp32-watcher.sh` | inotify on src/; triggers build on main.cpp save |
| **Systemd service** | `/etc/systemd/system/esp32-watcher.service` | Runs watcher persistently |
| **PlatformIO venv** | `/opt/platformio-venv/` | — |
| **Build log** | `/var/log/esp32-builder.log` | — |
| **Lock file** | `/tmp/esp32-build.lock` | Prevents concurrent builds |

---

## 🚀 LXC 113 — WARP Exit Node

Cloudflare WARP full-tunnel + Tailscale exit node.

* WARP uses fwmark-based policy routing (table 65743) — NOT a default route change
* Diagnose with `ip rule show` / `ip route show table all`
* Tailscale NAT: ts-postrouting chain, MASQUERADE on mark 0x40000/0xff0000
* Double WireGuard tunnel (Tailscale + WARP) reduces MTU — fix: `iptables -t mangle -A POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu`
* Consumer WARP: no country selection

---

## ✈️ LXC 118 — Telegram SOCKS5 Proxy

GOST SOCKS5 on `:8388` (user/pass auth) routed through ProtonVPN WireGuard full-tunnel.

**WireGuard:**

* Managed via `wg-quick@wg0.service`, config at `/etc/wireguard/wg0.conf`
* DNS: `10.10.10.1` (OpenWrt — ProtonVPN's `10.2.0.1` unreliable on free tier)

**Config Rotation (`/usr/local/bin/wg-rotate.sh`):**

* Configs: `/etc/wireguard/sg0..sg5` (Singapore) + `jp0` (Japan fallback)
* Health check: handshake age + curl through GOST to `api.telegram.org`
* Boot: `wg-rotate-boot.service` | Cron: `*/2 * * * *`
* State: `/var/lib/wg-rotate/current_conf` | Log: `/var/log/wg-rotate.log`

Telegram client config: SOCKS5 → `10.10.10.218:8388`, IPv6 must be unchecked.
OpenWrt MASQUERADE rule required for LAN (`192.168.0.0/24`) clients to reach vmbr1.

---

## 📸 Immich Backup — Backblaze B2 (LXC 109)

Client-side encrypted via rclone crypt remote `b2immichcrypt`.

| Script | Purpose |
| --- | --- |
| `immich-data-backup-flow.sh` | Master — runs all three below in sequence |
| `immich-library-backup.sh` | Syncs /mnt/nas/upload/library → b2immichcrypt:immich-library |
| `immich-db-backup.sh` | Syncs /mnt/nas/upload/backups → b2immichcrypt:immich-db |
| `immich-backup-report.sh` | Sends email summary after backup |

* **Scripts:** `/usr/local/bin/immich-backup/` | **Logs:** `/var/log/immich-*`
* **Status files:** `/var/lib/immich-backup/`
* **Safety:** aborts if local count < 70% of remote (library) or < 50% (DB); 3x retries

---

## 💾 Proxmox LXC Backup — Backblaze B2

| Parameter | Value |
| --- | --- |
| **Script** | `/usr/local/bin/lxc-backup-b2.sh` |
| **Schedule** | Sunday 03:00 cron on prox host |
| **Local staging** | `/mnt/data/public/backups/lxc/` |
| **B2 bucket** | prox-lxc-backups |
| **rclone crypt remote** | b2lxccrypt |
| **Compression** | zstd |
| **Retention** | 1 latest per CT (local + B2) |

* **LXCs backed up:** 101 (npm), 103 (aria2), 105 (NAS), 106 (openwrt), 107 (adguard), 110 (tailscale)
* *Note:* CT 106 (ostype: unmanaged) backs up but is not restorable via `pct restore`.

---

## 📜 LXC Inventory Snapshot Script

Run on `prox` to regenerate the container table:

```bash
#!/bin/bash
echo "# LXC Inventory Snapshot"
echo ""
echo "Generated: $(date)"
echo ""
echo "| ID | Name | Status | OS | CPU | RAM | Disk | Boot | Bridge | IP | Mounts |"
echo "|---|---|---|---|---|---|---|---|---|---|---|"

for ctid in $(pct list | awk 'NR>1 {print $1}' | sort -n); do
    CONFIG=$(pct config "$ctid")
    NAME=$(pct list | awk -v id="$ctid" '$1==id {print $3}')
    STATUS=$(pct list | awk -v id="$ctid" '$1==id {print $2}')
    OS=$(echo "$CONFIG" | grep -i '^ostype' | awk '{print $2}')
    CPU=$(echo "$CONFIG" | grep '^cores' | awk '{print $2}')
    RAM=$(echo "$CONFIG" | grep '^memory' | awk '{print $2}' | sed 's/$/ MB/')
    DISK=$(echo "$CONFIG" | grep '^rootfs' | grep -oP 'size=\K[^,]+')
    BOOT=$(echo "$CONFIG" | grep '^onboot' | awk '{print $2}')
    [ "$BOOT" = "1" ] && BOOT="yes" || BOOT="no"
    BRIDGES=$(echo "$CONFIG" | grep '^net' | grep -oP 'bridge=\K[^,]+' | sort -u | paste -sd '+')
    IPS=$(echo "$CONFIG" | grep '^net' | grep -oP '(?:ip|ip6)=\K[^,]+' | grep -v '^$' | paste -sd ' ')
    RATE=$(echo "$CONFIG" | grep '^net' | grep -oP 'rate=\K[^,]+' | head -1)
    [ -n "$RATE" ] && IPS="${IPS}, rate=${RATE}MB/s"
    [ -z "$IPS" ] && IPS="—"
    MOUNTS=$(echo "$CONFIG" | grep '^mp' | grep -oP '([^,\s]+),mp=([^,\s]+)' | sed 's/,mp=/ → /' | paste -sd ' | ')
    [ -z "$MOUNTS" ] && MOUNTS="—"
    echo "| $ctid | $NAME | $STATUS | $OS | $CPU | $RAM | $DISK | $BOOT | $BRIDGES | $IPS | $MOUNTS |"
done

```
