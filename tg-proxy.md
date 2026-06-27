# LXC 118 — tg-proxy: Full Technical Reference

## Purpose
A dedicated lightweight LXC whose sole job is to act as a SOCKS5 proxy for Telegram
(and any other SOCKS5-capable client on the LAN). All outbound traffic from this LXC
is routed through a ProtonVPN WireGuard full-tunnel, bypassing the ISP-level block on
`api.telegram.org`. The proxy is provided by GOST, a Go-based tunnel tool that listens
on port 8388 and forwards SOCKS5 traffic through the VPN tunnel.

## Architecture

```
Telegram client (192.168.0.x)
        │  SOCKS5 TCP :8388
        ▼
OpenWrt (192.168.0.150) ── MASQUERADE ──► tg-proxy (10.10.10.218)
                                                │
                                           GOST :8388
                                                │
                                        WireGuard wg0
                                                │
                                     ProtonVPN SG server
                                                │
                                        api.telegram.org
```

## Container Info

| Property | Value |
|---|---|
| CT ID | 118 |
| Hostname | tg-proxy |
| IP | 10.10.10.218/24 (DHCP, vmbr1) |
| OS | Debian 13 (trixie) |
| CPU | 1 core |
| RAM | 512 MB |
| Disk | 4 GB (local-lvm) |
| Firewall | None — intentionally open for LAN |
| onboot | yes |

## Host-side LXC Config (`/etc/pve/lxc/118.conf`)

```text
lxc.cgroup2.devices.allow: c 10:200 rwm
lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file
```

Required to expose the host's TUN device inside the unprivileged container so
WireGuard can create the `wg0` interface.

## Installed Packages

```bash
apt install wireguard openresolv curl wget iptables cron
```

GOST is a standalone binary at `/usr/local/bin/gost` (not from apt).

---

## WireGuard

### Overview
ProtonVPN free tier WireGuard full-tunnel. All traffic from this LXC exits via
ProtonVPN Singapore servers. The tunnel uses fwmark-based policy routing (wg-quick
default) — not a direct default route change — so diagnose with `ip rule show` /
`ip route show table all`, not just `ip route`.

### DNS
`DNS = 10.10.10.1` (OpenWrt → AdGuard) — ProtonVPN's own `10.2.0.1` is unreliable
on the free tier and causes DNS failures after reboot.

### Critical PostUp/PreDown Rules
Embedded in every `*.conf` file. Without these, return traffic to LAN clients
(`192.168.0.x`) and Tailscale (`100.64.0.0/10`) gets swallowed by the full tunnel:

```ini
PostUp = ip route replace 192.168.0.0/24 via 10.10.10.1
PostUp = ip route replace 100.64.0.0/10 via 10.10.10.1
PreDown = ip route del 192.168.0.0/24 via 10.10.10.1
PreDown = ip route del 100.64.0.0/10 via 10.10.10.1
PostUp = iptables -t mangle -A POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
PreDown = iptables -t mangle -D POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
```

### Config Files

| File | Server | Location |
|---|---|---|
| `/etc/wireguard/sg0-SG-FREE-2.conf` | SG-FREE#2 | Singapore |
| `/etc/wireguard/sg1-SG-FREE-9.conf` | SG-FREE#9 | Singapore |
| `/etc/wireguard/sg2-SG-FREE-11.conf` | SG-FREE#11 | Singapore |
| `/etc/wireguard/sg3-SG-FREE-13.conf` | SG-FREE#13 | Singapore |
| `/etc/wireguard/sg4-SG-FREE-17.conf` | SG-FREE#17 | Singapore |
| `/etc/wireguard/sg5-SG-FREE-21.conf` | SG-FREE#21 | Singapore |
| `/etc/wireguard/jp0-JP-FREE-10.conf` | JP-FREE#10 | Japan (fallback) |

`/etc/wireguard/wg0.conf` is the **active config** — overwritten by `wg-rotate.sh`
on each rotation. Never edit it directly.

### wg0.conf Template Structure

```ini
[Interface]
PrivateKey = <per-server key>
Address = 10.2.0.2/32
DNS = 10.10.10.1
PostUp = ip route replace 192.168.0.0/24 via 10.10.10.1
PostUp = ip route replace 100.64.0.0/10 via 10.10.10.1
PreDown = ip route del 192.168.0.0/24 via 10.10.10.1
PreDown = ip route del 100.64.0.0/10 via 10.10.10.1
PostUp = iptables -t mangle -A POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
PreDown = iptables -t mangle -D POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu

[Peer]
PublicKey = <per-server key>
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = <per-server IP>:51820
PersistentKeepalive = 25
```

### Service Management

```bash
systemctl status wg-quick@wg0
systemctl restart wg-quick@wg0
wg show wg0                        # live tunnel stats
wg show wg0 latest-handshakes      # check if tunnel is alive
```

---

## Config Rotation (wg-rotate.sh)

### Purpose
ProtonVPN free tier servers are unreliable — they accept WireGuard handshakes but
silently drop traffic. This script detects a dead tunnel and automatically rotates
to a working config without manual intervention.

### Logic
1. Check handshake age (`< 3 min = alive`)
2. Check real connectivity — curl through GOST to `api.telegram.org` (302 = working)
3. If both pass → exit, nothing to do
4. If unhealthy → shuffle SG configs randomly, try each one skipping current
5. If all SG fail → try JP as last resort
6. Log all actions to `/var/log/wg-rotate.log`

### Files

| Path | Purpose |
|---|---|
| `/usr/local/bin/wg-rotate.sh` | Main rotation script |
| `/var/lib/wg-rotate/current_conf` | Path of currently active config |
| `/var/log/wg-rotate.log` | Rotation log |
| `/etc/cron.d/wg-rotate` | Runs every 2 minutes |
| `/etc/systemd/system/wg-rotate-boot.service` | Runs once at boot after wg-quick@wg0 |

### /usr/local/bin/wg-rotate.sh

```bash
#!/bin/bash

SG_CONFIGS=(
    /etc/wireguard/sg0-SG-FREE-2.conf
    /etc/wireguard/sg1-SG-FREE-9.conf
    /etc/wireguard/sg2-SG-FREE-11.conf
    /etc/wireguard/sg3-SG-FREE-13.conf
    /etc/wireguard/sg4-SG-FREE-17.conf
    /etc/wireguard/sg5-SG-FREE-21.conf
)

FALLBACK_CONFIGS=(
    /etc/wireguard/jp0-JP-FREE-10.conf
)

STATE_FILE=/var/lib/wg-rotate/current_conf
mkdir -p /var/lib/wg-rotate
LOG=/var/log/wg-rotate.log

check_tunnel() {
    curl --max-time 10 --socks5-hostname tg:password@127.0.0.1:8388 \
        -s -o /dev/null -w "%{http_code}" https://api.telegram.org | grep -q "302"
}

check_handshake() {
    LAST=$(wg show wg0 latest-handshakes 2>/dev/null | awk '{print $2}')
    [ -z "$LAST" ] && return 1
    NOW=$(date +%s)
    [ $((NOW - LAST)) -lt 180 ]
}

try_config() {
    local CONF=$1
    echo "[$(date)] Trying $CONF..." >> $LOG
    systemctl stop wg-quick@wg0
    cp "$CONF" /etc/wireguard/wg0.conf
    systemctl start wg-quick@wg0
    sleep 10
    if check_handshake && check_tunnel; then
        echo "$CONF" > "$STATE_FILE"
        echo "[$(date)] Success with $CONF" >> $LOG
        return 0
    fi
    return 1
}

if check_handshake && check_tunnel; then
    exit 0
fi

echo "[$(date)] Tunnel unhealthy, rotating..." >> $LOG

SHUFFLED=($(printf '%s\n' "${SG_CONFIGS[@]}" | shuf))
CURRENT=$(cat "$STATE_FILE" 2>/dev/null)

for CONF in "${SHUFFLED[@]}"; do
    [ "$CONF" = "$CURRENT" ] && continue
    try_config "$CONF" && exit 0
done

[ -n "$CURRENT" ] && try_config "$CURRENT" && exit 0

echo "[$(date)] All SG configs failed, trying fallback..." >> $LOG
for CONF in "${FALLBACK_CONFIGS[@]}"; do
    try_config "$CONF" && exit 0
done

echo "[$(date)] ALL configs failed!" >> $LOG
exit 1
```

### /etc/systemd/system/wg-rotate-boot.service

```ini
[Unit]
Description=WireGuard config rotator - boot run
After=network.target wg-quick@wg0.service
Wants=wg-quick@wg0.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/wg-rotate.sh
RemainAfterExit=no

[Install]
WantedBy=multi-user.target
```

### /etc/cron.d/wg-rotate

```text
*/2 * * * * root /usr/local/bin/wg-rotate.sh
```

---

## GOST SOCKS5 Proxy

### Overview
GOST is a lightweight Go-based proxy tool. It listens on `:8388` and forwards SOCKS5
traffic. Since all traffic from this LXC exits via WireGuard, GOST connections are
transparently routed through ProtonVPN.

### Binary
Downloaded from GitHub releases, placed at `/usr/local/bin/gost`. Not managed by apt.

```bash
/usr/local/bin/gost -V    # check version (currently 2.11.5)
```

### /etc/systemd/system/tg-proxy.service

```ini
[Unit]
Description=GOST SOCKS5 Proxy
After=network.target wg-quick@wg0.service

[Service]
ExecStart=/usr/local/bin/gost -L=socks5://tg:password@:8388
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```

### Service Management

```bash
systemctl status tg-proxy
systemctl restart tg-proxy
journalctl -fu tg-proxy       # live logs
```

### Test the proxy

```bash
# From any vmbr1 container:
curl -v --socks5-hostname tg:password@10.10.10.218:8388 https://api.telegram.org
# Expect: HTTP/2 302

# Check exit IP (should be ProtonVPN Singapore):
curl --socks5-hostname tg:password@10.10.10.218:8388 https://ipapi.co/json
```

---

## OpenWrt MASQUERADE Rule (LXC 106)

### Why it's needed
LAN clients (`192.168.0.x`) reach tg-proxy via the static route on the Asus router
(`10.10.10.0/24 via 192.168.0.150`). Without MASQUERADE, tg-proxy sees the source as
`192.168.0.x` and tries to reply via the WireGuard tunnel (which has a
`192.168.0.0/24 via wg0` route) — replies never reach the client.

MASQUERADE rewrites the source to `10.10.10.1` so replies stay within vmbr1 and
route back correctly via OpenWrt.

### Applied via UCI (survives reboot)

```bash
uci add firewall rule
uci set firewall.@rule[-1].name='masq-lan-to-internal'
uci set firewall.@rule[-1].src='wan'
uci set firewall.@rule[-1].dest='lan'
uci set firewall.@rule[-1].target='MASQUERADE'
uci commit firewall
service firewall restart
```

### Verify

```bash
# On LXC 106 (openwrt):
nft list chain inet fw4 srcnat
# Should show: oifname "eth1" ip saddr 192.168.0.0/24 masquerade
```

---

## Telegram Client Config

**Settings → Privacy and Security → Proxy → Add Proxy → SOCKS5**

| Field | Value |
|---|---|
| Server | `10.10.10.218` |
| Port | `8388` |
| Username | `tg` |
| Password | `password` |

> ⚠️ **"Try connecting through IPv6" MUST BE UNCHECKED** — the WireGuard tunnel
> routes IPv4 only (`0.0.0.0/0`). IPv6 connections will fail.

---

## Diagnostics

### Tunnel dead after reboot?
```bash
cat /etc/resolv.conf          # should show nameserver 10.10.10.1
grep DNS /etc/wireguard/wg0.conf  # should show DNS = 10.10.10.1
wg show wg0                   # check handshake + transfer
cat /var/log/wg-rotate.log    # see what rotation did
```

### Proxy not connecting from Telegram?
```bash
# 1. Check GOST is running
systemctl status tg-proxy

# 2. Test proxy end-to-end
curl --max-time 10 --socks5-hostname tg:password@10.10.10.218:8388 \
    -s -o /dev/null -w "%{http_code}" https://api.telegram.org

# 3. Check OpenWrt MASQUERADE still present
pct exec 106 -- nft list chain inet fw4 srcnat
```

### Known Issues
- ProtonVPN free DNS `10.2.0.1` is unreliable — always use `10.10.10.1`
