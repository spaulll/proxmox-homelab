# LXC 118 — tg-proxy: Full Technical Reference

## Purpose
A dedicated lightweight LXC with two jobs:
1. **SOCKS5 proxy** for Telegram (and any other SOCKS5-capable client on the LAN).
2. **Transparent VPN gateway** — any machine/LXC that points its default gateway at
   this LXC gets *all* its traffic pushed through the VPN tunnel automatically,
   with no VPN app and no proxy settings on the client ("VPN without connecting
   to a VPN").

All outbound traffic exits via a ProtonVPN WireGuard full-tunnel, bypassing the
ISP-level block on `api.telegram.org`. The SOCKS5 proxy is provided by GOST, a
Go-based tunnel tool that listens on port 8388 and forwards SOCKS5 traffic
through the VPN tunnel.

## Architecture

```
Main-LAN clients (gw=192.168.0.218)          vmbr1 clients (gw=10.10.10.218)
        │ plain IP, on-link                          │ plain IP / SOCKS5 :8388
        ▼                                            ▼
tg-proxy eth1 (192.168.0.218)   tg-proxy eth0 (10.10.10.218) ◄── OpenWrt MASQUERADE ◄── 192.168.0.x Telegram
        │                            │            │                    (192.168.0.150)
        └────────────┬───────────────┘             │
                     │                       GOST :8388
                FORWARD + MASQUERADE                 │
                     └───────────────┬──────────────┘
                                     │
                          WireGuard wg0 (full tunnel)
                                     │
                           ProtonVPN SG server
                                     │
                        api.telegram.org / internet
```

## Container Info

| Property | Value |
|---|---|
| CT ID | 118 |
| Hostname | tg-proxy |
| NIC 1 (eth0) | 10.10.10.218/24 (vmbr1) |
| NIC 2 (eth1) | 192.168.0.218/24 (vmbr0, main home LAN) |
| OS | Debian 13 (trixie) |
| CPU | 1 core |
| RAM | 512 MB |
| Disk | 4 GB (local-lvm) |
| Firewall | None — intentionally open for LAN |
| onboot | yes |
| Role | SOCKS5 proxy + transparent VPN gateway (NAT router) |

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
Embedded in every `*.conf` file. Without these, return traffic to Tailscale
(`100.64.0.0/10`) gets swallowed by the full tunnel:

```ini
PostUp = ip route replace 100.64.0.0/10 via 10.10.10.1
PreDown = ip route del 100.64.0.0/10 via 10.10.10.1
PostUp = iptables -t mangle -A POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
PreDown = iptables -t mangle -D POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
```

> ⚠️ **The old `192.168.0.0/24 via 10.10.10.1` lines were REMOVED from all confs**
> (2026-08-26). Since eth1 (192.168.0.218) exists, that `ip route replace` would
> clobber eth1's connected route and blackhole direct LAN replies. Return paths
> are now handled naturally: hairpinned clients reply to `10.10.10.1` (eth0
> connected), main-LAN clients reply via eth1's connected route.

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
PostUp = ip route replace 100.64.0.0/10 via 10.10.10.1
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
    curl --max-time 10 --socks5-hostname tg:<PASSWORD>@127.0.0.1:8388 \
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
ExecStart=/usr/local/bin/gost -L=socks5://tg:<PASSWORD>@:8388
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
curl -v --socks5-hostname tg:<PASSWORD>@10.10.10.218:8388 https://api.telegram.org
# Expect: HTTP/2 302

# Check exit IP (should be ProtonVPN Singapore):
curl --socks5-hostname tg:<PASSWORD>@10.10.10.218:8388 https://ipapi.co/json
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

## Transparent Gateway Mode ("VPN without connecting to VPN")

### Concept
tg-proxy doubles as a NAT router, dual-homed on both networks: `eth0`
(`10.10.10.218`, vmbr1), `eth1` (`192.168.0.218`, main home LAN), WAN side is
`wg0`. Any client that sets its default gateway to the tg-proxy IP on its own
subnet has all its traffic forwarded into the ProtonVPN tunnel — no proxy
config, no VPN software.

```
Client (gw = 10.10.10.218 or 192.168.0.218)
   │  packet src = client IP, dst = internet
   ▼
eth0/eth1 ── FORWARD ── MASQUERADE (src → 10.2.0.2) ──► wg0 ──► ProtonVPN
◄──────────── return traffic de-NATted by conntrack ◄──────────┘
```

**Kill switch by design:** if `wg0` goes down, forwarding is blackholed (clients
lose internet briefly) instead of silently leaking out via `10.10.10.1` in
plaintext. `wg-rotate.sh` restores the tunnel within ~2 minutes.

### One-time setup (inside LXC 118)

#### 1. Enable forwarding + router sysctls

`/etc/sysctl.d/99-vpn-gateway.conf`:

```text
net.ipv4.ip_forward = 1
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
net.ipv4.conf.all.send_redirects = 0
```

```bash
sysctl --system    # verify: sysctl net.ipv4.ip_forward  → 1
```

> `rp_filter = 2` (loose) prevents strict reverse-path drops on asymmetric
> return paths; `send_redirects = 0` stops the kernel from telling clients to
> bypass the gateway.

#### 2. NAT + forwarding rules with built-in kill switch

```bash
apt install -y iptables-persistent
```

Write `/etc/iptables/rules.v4`:

```text
*filter
:INPUT ACCEPT [0:0]
:FORWARD DROP [0:0]
:OUTPUT ACCEPT [0:0]
-A FORWARD -i eth0 -o eth0 -j ACCEPT
-A FORWARD -i wg0 -o eth0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
-A FORWARD -i eth0 -o wg0 -j ACCEPT
-A FORWARD -i eth1 -o wg0 -j ACCEPT
-A FORWARD -i wg0 -o eth1 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
COMMIT
*nat
:PREROUTING ACCEPT [0:0]
:INPUT ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
:POSTROUTING ACCEPT [0:0]
-A POSTROUTING -o wg0 -j MASQUERADE
COMMIT
```

Apply:

```bash
netfilter-persistent reload
iptables -L FORWARD -nv          # verify rules are loaded
iptables -t nat -L POSTROUTING -nv
```

Why this shape:

| Rule | Reason |
|---|---|
| `-A FORWARD -i eth0/eth1 -o wg0 -j ACCEPT` | client → internet, only ever via tunnel |
| `-A FORWARD -i wg0 -o eth0/eth1 -m conntrack --ctstate RELATED,ESTABLISHED` | replies back to clients |
| `-P FORWARD DROP` | when `wg0` is down nothing matches → traffic dies (kill switch), never falls back to `10.10.10.1` |
| `-t nat -A POSTROUTING -o wg0 -j MASQUERADE` | hides client IPs behind `10.2.0.2`, so tunnel return traffic finds its way back |
| `-A FORWARD -i eth0 -o eth0 -j ACCEPT` | LAN↔LAN hairpin through this box |
| *no* eth0↔eth1 rule | vmbr1 stays isolated from the main LAN (intentional) |

Notes:
- Rules are **permanent** and reference `wg0` even when the interface doesn't
  exist yet, so they survive reboots and every `wg-rotate.sh` rotation with zero
  changes to `wg0.conf`, PostUp/PreDown, or the rotate script.
- The existing TCPMSS clamp rule in `wg0.conf` already applies to forwarded SYN
  packets egressing `wg0` — no extra MTU work needed.
- GOST (:8388) is INPUT traffic, unaffected by the `FORWARD DROP` policy.
- DNS needs no special handling: a client's DNS queries are plain IP packets and
  ride the tunnel like everything else (resolution happens from the SG exit).

### Pointing clients at the gateway

#### Another LXC on vmbr1 (simplest case)

On the Proxmox host:

```bash
pct set <CTID> --net0 name=eth0,bridge=vmbr1,ip=10.10.10.X/24,gw=10.10.10.218
```

or inside the container's `/etc/network/interfaces`:

```text
auto eth0
iface eth0 inet static
    address 10.10.10.X/24
    gateway 10.10.10.218
    dns-nameservers 1.1.1.1
```

DHCP-based LXCs must switch to static (or override the DHCP-provided gateway)
since their DHCP server hands out `10.10.10.1`.

#### Machine on the 192.168.0.x main LAN (preferred path)

Since eth1 (`192.168.0.218`) lives on the main LAN, the gateway is **on-link** —
a single default route, no hairpin, no extra host-route needed:

```text
# Windows (admin):                    route add 0.0.0.0 mask 0.0.0.0 192.168.0.218 metric 5
# Linux/macOS:                        ip route replace default via 192.168.0.218
                                      sudo route change default 192.168.0.218
```

Verified working (2026-08-26): ping + exit IP through `FORWARD → wg0 → ProtonVPN`.

Legacy alternative (no eth1 / other routers' clients): set gateway
`10.10.10.218` and rely on Asus static route → OpenWrt MASQUERADE → tg-proxy.
Caveat: traffic hairpins two routers, and some kernels reject recursive
gateways — those devices need a host route first
(`ip route add 10.10.10.218/32 via 192.168.0.1`). Prefer the on-link path above.

SOCKS5 note: GOST binds all interfaces, so main-LAN Telegram clients can use
`192.168.0.218:8388` directly instead of the old OpenWrt-hairpin path.

> ⚠️ **Disable IPv6 on all gateway clients.** The tunnel routes IPv4 only
> (`0.0.0.0/0`). Any client that gets IPv6 via RA from your routers will bypass
> the v4 gateway entirely — a full leak around the VPN.

### Verify

```bash
# On the CLIENT machine:
ip route get 1.1.1.1                  # expect: via 10.10.10.218 dev eth0
curl -s https://ipapi.co/json         # expect ProtonVPN Singapore

# Kill-switch test (on tg-proxy):
systemctl stop wg-quick@wg0
# → client curl should now HANG/FAIL, not succeed via ISP
/usr/local/bin/wg-rotate.sh           # restore the tunnel

# Watch client traffic live (on tg-proxy):
tcpdump -ni wg0 host <client-IP>
```

---

## Telegram Client Config

**Settings → Privacy and Security → Proxy → Add Proxy → SOCKS5**

| Field | Value |
|---|---|
| Server | `10.10.10.218` |
| Port | `8388` |
| Username | `tg` |
| Password | `********` |

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
curl --max-time 10 --socks5-hostname tg:<PASSWORD>@10.10.10.218:8388 \
    -s -o /dev/null -w "%{http_code}" https://api.telegram.org

# 3. Check OpenWrt MASQUERADE still present
pct exec 106 -- nft list chain inet fw4 srcnat
```

### Gateway client has no internet?
```bash
# On tg-proxy:
sysctl net.ipv4.ip_forward                       # must be 1
iptables -L FORWARD -nv                          # rules present? wg0 up?
iptables -t nat -L POSTROUTING -nv               # MASQUERADE counter increasing?
wg show wg0 latest-handshakes                    # tunnel alive?
tail /var/log/wg-rotate.log

# On the client:
ip route get 8.8.8.8                             # must say via 10.10.10.218
ping -c1 10.10.10.218                            # gateway reachable at all?
curl -v --max-time 5 https://1.1.1.1             # if ping works but this hangs → tunnel down (kill switch doing its job)
```

### Known Issues
- ProtonVPN free DNS `10.2.0.1` is unreliable — always use `10.10.10.1`
- Gateway clients leak via IPv6 if enabled — **disable IPv6 on them** (tunnel is v4-only)
- When the tunnel is down, gateway clients have NO internet by design (kill switch) — wait for `wg-rotate.sh` (~2 min)
