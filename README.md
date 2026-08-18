
```
  █████╗ ██╗██╗   ██╗██████╗ ███╗   ██╗
  ██╔══██╗██║██║   ██║██╔══██╗████╗  ██║
  ███████║██║██║   ██║██████╔╝██╔██╗ ██║
  ██╔══██║██║╚██╗ ██╔╝██╔═══╝ ██║╚██╗██║
  ██║  ██║██║ ╚████╔╝  ██║     ██║ ╚████║
  ╚═╝  ╚═╝╚═╝  ╚═══╝   ╚═╝     ╚═╝  ╚═══╝
```
# AiVPN — Agent-Grade WireGuard Relay for Proton VPN

A Docker-based VPN container for AI agents. One container = one WireGuard
tunnel to a Proton VPN exit node — **only traffic from inside the container
goes through the VPN; the host network is never touched.**

> ⚠️ **Requires a Proton VPN subscription.** Also works with the free Proton
> VPN plan (limited locations). Proton Unlimited → all 140+ countries.

---

## 📋 Table of Contents

- [What is this](#-what-is-this)
- [Architecture](#-architecture)
- [Requirements](#-requirements)
- [Creating a Proton WireGuard config](#-creating-a-proton-wireguard-config)
- [Installation](#-installation)
- [Usage](#-usage)
  - [Starting the container](#starting-the-container)
  - [Commands](#commands)
  - [Browser through VPN (SOCKS5)](#browser-through-vpn-socks5)
  - [Multiple locations](#multiple-locations)
- [Security](#-security)
- [Limitations](#-limitations)
- [Troubleshooting](#-troubleshooting)
- [Support this project](#-support-this-project)
- [License & credits](#-license--credits)

---

## 🧠 What is this

AiVPN is built on the same principle as Gen Digital's AgentVPN, but on top of
**Proton VPN infrastructure**. Since Proton officially supports third-party
WireGuard clients, you can download a ready-made WireGuard configuration from
your account and run it in your own container — no separate sign-up, no API
keys.

Use cases:

- 🤖 An AI agent fetches content **from another country** (pricing, availability,
  region-locked data)
- 🔀 **Parallel comparison**: run multiple locations side by side
- 🕵️ **Anonymous browsing** without putting the host behind a VPN
- 🛡️ **Prompt-injection-safe fetching** for agents (`safefetch`)

## 🏗️ Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                      HOST (VPS / homelab)                   │
│                                                             │
│   ┌───────────────────────────┐                             │
│   │   vpn-proton (container)  │                             │
│   │                           │    WireGuard tunnel         │
│   │   ┌───────────────┐       │ ──────────────────────────► │
│   │   │  WireGuard    │       │         Proton VPN          │
│   │   │  (wg0)        │       │      exit node (140+ cntrs) │
│   │   └──────┬────────┘       │                             │
│   │          │                │                             │
│   │   ┌──────▼────────┐       │                             │
│   │   │  microsocks   │◄──────│── SOCKS5 :1080              │
│   │   │  (SOCKS5)     │       │  (dynamic host port)        │
│   │   └──────┬────────┘       │                             │
│   │   ┌──────▼────────┐       │                             │
│   │   │  iptables     │       │  kill switch: never leaks   │
│   │   │  kill switch  │       │  to host network            │
│   │   └───────────────┘       │                             │
│   └───────────────────────────┘                             │
│                                                             │
│   docker exec vpn-proton curl ...  ← goes through tunnel     │
└─────────────────────────────────────────────────────────────┘
```

**Components:**

| Component | Role |
|---|---|
| `wg` / `ip` | Manual tunnel bring-up (`wg setconf` + `ip route`) — no wg-quick dependency |
| `wg-quick` | Config stripping only (`wg-quick strip` feeds `wg setconf`) |
| `wireguard-go` | Userspace WireGuard, installed in the image (not used by the manual bring-up) |
| `microsocks` | SOCKS5 proxy inside the container (port 1080) |
| `iptables` | Kill switch: all egress except through the tunnel = DROP |
| `pi-scan.sh` | Prompt-injection scanner for the `safefetch` command |

## ✅ Requirements

- **Docker** on a Linux host
- **Proton VPN account** ([protonvpn.com](https://protonvpn.com)) — Unlimited recommended
- Host kernel or userspace: `/dev/net/tun` and `--cap-add=NET_ADMIN` (the container handles the rest)

## 🛠️ Creating a Proton WireGuard config

The VPN configs are created on the Proton account page — no API keys, no
third-party sign-ups.

**1. Open the downloads page**

Go to <https://account.protonvpn.com/downloads> (Proton VPN → Downloads).
The page has two parts:
- **Proton VPN clients** — the app download buttons — not needed here
- **WireGuard configurations** — the configs you have already created, each
  with its **expiry date** (valid ~1 year, e.g. `Aug 18, 2027`)

**2. Create a new config**

Click **Create config** and fill in:
- **Name** — something recognizable, e.g. `Hermes Agent FI`
- **Platform** — select **GNU/Linux**
- **VPN options** — enable **VPN Accelerator** (NetShield / Moderate NAT are
  fixed at generation time, not switchable at runtime)
- **Server** — pick a location; the UI recommends the lowest-load server
  (e.g. `FI#72`) and lists countries alphabetically (Afghanistan, Netherlands, …)

**3. Download**

Download the `.conf`, save it as `config/wg0.conf` (or one file per location,
e.g. `config/us.conf`) and `chmod 600` it. The config contains your private
key — **never commit it, never `docker push` an image with it**.

```bash
mkdir -p config
cp ~/Downloads/Hermes-Agent-FI.conf config/wg0.conf
chmod 600 config/wg0.conf
```

> One container = one location. For more countries, create another config on
> the same page (each counts toward the Proton 10-device limit) and mount it
> under a different container name — see [Multiple locations](#multiple-locations).

## 🔧 Installation

```bash
# 1. Create the WireGuard config — see "Creating a Proton WireGuard config" above
# 2. Run setup (asks for the config path + builds the image)
./scripts/setup.sh

#   Or manually:
mkdir -p config && cp /path/to/proton-wg.conf config/wg0.conf
chmod 600 config/wg0.conf
docker build -t aivpn .
```

## 🚀 Usage

> **Local test without Docker:** `bash scripts/smoke-test.sh` — verifies the
> entrypoint, banner, error handling and the PI scanner (7 tests).

### Starting the container

```bash
# The easy way (Makefile)
make up LOCATION=proton

# Or directly with Docker
docker run -d --name vpn-proton \
  --cap-add=NET_ADMIN --device=/dev/net/tun \
  -v $(pwd)/config/wg0.conf:/etc/wireguard/wg0.conf:ro \
  -p 127.0.0.1::1080 \
  aivpn daemon

# Wait until the tunnel is up (fail-fast check)
./scripts/wait-for-vpn.sh vpn-proton
```

### Commands

```bash
# Verify traffic goes through the tunnel
docker exec vpn-proton curl -s https://ip-api.com/json

# Status + egress IP
docker exec vpn-proton status

# One-shot: connect → print IP → exit
docker exec vpn-proton connect

# AI-agent safe fetch (prompt-injection scanning)
#   0 = clean, 77 = PI detected (content blocked), 1 = fetch error
docker exec vpn-proton safefetch https://example.com/api/data

# Plain curl through the tunnel
docker exec vpn-proton curl -s -m 20 -A "Mozilla/5.0" https://example.com

# Clean shutdown
docker exec vpn-proton stop
# or
docker stop vpn-proton && docker rm vpn-proton
```

### Browser through VPN (SOCKS5)

```bash
# Get the container's dynamic host port
SOCKS_PORT=$(docker port vpn-proton 1080 | head -1 | awk -F: '{print $NF}')
echo "SOCKS5: 127.0.0.1:$SOCKS_PORT"

# Chrome with a dedicated profile + leak protection
google-chrome \
  --user-data-dir="$HOME/.config/google-chrome/vpn-proton" \
  --proxy-server="socks5://127.0.0.1:$SOCKS_PORT" \
  --host-resolver-rules="MAP * ~NOTFOUND , EXCLUDE 127.0.0.1" \
  --disable-quic \
  --webrtc-ip-handling-policy=disable_non_proxied_udp

# Or curl with SOCKS support (from the host)
curl --socks5-hostname 127.0.0.1:$SOCKS_PORT https://ip-api.com/json
```

### Multiple locations

```bash
# Download another config for a different location (e.g. Tokyo)
#   NOTE: per Proton's guide, change the Address/DNS lines:
#   Address = 10.3.0.2/32, DNS = 10.3.0.1 (bump 10.2 → 10.3 → 10.4 ...)

docker run -d --name vpn-tokyo \
  --cap-add=NET_ADMIN --device=/dev/net/tun \
  -v $(pwd)/config/tokyo.conf:/etc/wireguard/wg0.conf:ro \
  -p 127.0.0.1::1080 \
  aivpn daemon

./scripts/wait-for-vpn.sh vpn-tokyo
docker exec vpn-tokyo curl -s https://ip-api.com/json
```

## 🛡️ Security

- **Kill switch (iptables):** while the tunnel is up, all egress except `wg0`
  traffic, the WireGuard endpoint and the tunnel DNS is DROP. If the tunnel
  drops, the container goes dark — **never a fallback to the host network.**
- **DNS leak protection:** port 53 is only allowed to the tunnel's DNS server.
  A hardcoded external resolver cannot work from inside the container.
- **microsocks starts only after the tunnel** — SOCKS5 cannot leak before the
  tunnel exists.
- **SOCKS5 bound to the `127.0.0.1` host port** (`-p 127.0.0.1::1080`) — not
  reachable from your LAN.
- **Rules:**
  - `config/wg0.conf` contains a private key → `chmod 600`, never commit it
  - **Never `docker push`** the built image (the key can live in the filesystem)
  - Never use `--network=host` (leaks routes to the host)
  - Never share the container's network namespace with an untrusted container
    (`--network=container:vpn-...`)

## ⚠️ Limitations

| Item | Details |
|---|---|
| Proton device limit | 10 simultaneous devices (each container = one device) |
| Netshield / Moderate NAT / Accelerator | Chosen when the config is generated, not switchable at runtime |
| Secure Core | Not supported by third-party clients — regular servers work |
| Container-only | `curl` on the host does NOT go through the tunnel |

## 🔍 Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `Exited(1)` / tunnel won't come up | Wrong/expired key, server down → `docker logs vpn-proton` |
| Tunnel fails with `RTNETLINK answers: Operation not permitted` | Host kernel lacks the WireGuard module — manual bring-up needs the kernel module + `/dev/net/tun` |
| Logs show `sysctl: ... Read-only file system` | Docker 29 mounts `/proc/sys` read-only; the entrypoint's manual bring-up already handles this — if you still see it, the image is stale → rebuild |
| `AGENTVPN... 401` | Wrong config — Proton's generated `.conf` is ready to use as-is |
| SOCKS5 not responding | Check the port: `docker port vpn-proton 1080` |
| Other VPNs break on the host | Never use `--network=host`; if it leaked: `ip link del wg0` + route cleanup |

## ☕ Support this project

Not a Proton user yet? Signing up through this referral link supports the
project's development (and may earn you bonus months from Proton):

👉 **https://pr.tn/ref/97EY429P**

## 📜 License & credits

- **License:** Apache-2.0 (see [LICENSE](LICENSE))
- **Inspiration:** [gendigitalinc/agentvpn](https://github.com/gendigitalinc/agentvpn) —
  entrypoint architecture (kill switch, microsocks ordering, reconnect loop)
- **Protocol:** [WireGuard](https://www.wireguard.com/) — an
  [officially supported](https://protonvpn.com/support/wireguard-configurations/) third-party
  client of Proton VPN
- **Tools:** [wireguard-go](https://github.com/WireGuard/wireguard-go),
  [microsocks](https://github.com/rofl0r/microsocks)

---

*AiVPN — built at night, powered by coffee. ☕*
