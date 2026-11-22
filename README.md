
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
- [Architecture](#️-architecture)
- [Requirements](#-requirements)
- [Creating a Proton WireGuard config](#️-creating-a-proton-wireguard-config)
- [Installation](#-installation)
- [Usage](#-usage)
  - [Starting the container](#starting-the-container)
  - [Commands](#commands)
  - [Browser through VPN (SOCKS5)](#browser-through-vpn-socks5)
  - [Multiple locations](#multiple-locations)
  - [systemd supervision](#systemd-supervision)
- [Security](#️-security)
- [Configuration](#️-configuration)
- [Limitations](#️-limitations)
- [Troubleshooting](#-troubleshooting)
- [Development](#-development)
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
- 🔀 **Comparing locations**: switch between exit countries, or run several
  containers side by side
- 🕵️ **Private browsing** without putting the host behind a VPN
- 🛡️ **Heuristic prompt-injection tripwire** for agent fetches (`safefetch`)

## 🏗️ Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                      HOST (VPS / homelab)                   │
│                                                             │
│   ┌───────────────────────────┐                             │
│   │   aivpn-fi (container)    │                             │
│   │                           │    WireGuard tunnel         │
│   │   ┌───────────────┐       │ ──────────────────────────► │
│   │   │  WireGuard    │       │         Proton VPN          │
│   │   │  (wg0)        │       │      exit node (140+ cntrs) │
│   │   └──────┬────────┘       │                             │
│   │          │                │                             │
│   │   ┌──────▼────────┐       │                             │
│   │   │  microsocks   │◄──────│── SOCKS5 127.0.0.1:1080     │
│   │   │  (SOCKS5)     │       │                             │
│   │   └──────┬────────┘       │                             │
│   │   ┌──────▼────────┐       │                             │
│   │   │  iptables +   │       │  kill switch: installed     │
│   │   │  ip6tables    │       │  before the tunnel, never   │
│   │   └───────────────┘       │  relaxed                    │
│   └───────────────────────────┘                             │
│                                                             │
│   docker exec aivpn-fi curl ...  ← goes through tunnel      │
└─────────────────────────────────────────────────────────────┘
```

**Components:**

| Component | Role |
|---|---|
| `wg` / `ip` | Manual tunnel bring-up (`wg setconf` + `ip route`) — no wg-quick at runtime |
| `wireguard-go` | Userspace WireGuard, used automatically when the host kernel has no WireGuard module |
| `microsocks` | SOCKS5 proxy inside the container (port 1080) |
| `iptables` / `ip6tables` | Kill switch: all IPv4 egress except the tunnel = DROP, all IPv6 = DROP |
| `pi-scan.sh` | Heuristic prompt-injection scanner behind the `safefetch` command |
| `scripts/aivpn` | Host wrapper: start/stop, status, tests, SOCKS endpoint |

## ✅ Requirements

- **Docker** on a Linux host (Docker Compose v2 for `aivpn up`)
- **Proton VPN account** ([protonvpn.com](https://protonvpn.com)) — Unlimited recommended
- `/dev/net/tun` and `--cap-add=NET_ADMIN` (the container handles the rest)

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
  (e.g. `FI#72`) and lists countries alphabetically

**3. Download**

Download the `.conf` and save it as `config/<location>.conf` — the location
name is what you pass to `aivpn up`, e.g. `config/fi.conf`, `config/us.conf`.
The config contains your private key — **keep it `chmod 600` and never commit
it** (`*.conf` is git-ignored).

```bash
./scripts/setup.sh --location fi --config ~/Downloads/Hermes-Agent-FI.conf
# or by hand:
mkdir -p config
cp ~/Downloads/Hermes-Agent-FI.conf config/fi.conf
chmod 600 config/fi.conf
sudo chown root:root config/fi.conf   # the hardened container reads it as root
```

> Use Proton's file as-is. You do **not** need to change `Address` / `DNS`
> lines for additional locations — each container has its own network
> namespace. Each config counts toward Proton's 10-device limit.

## 🔧 Installation

```bash
# 1. Create the WireGuard config — see above
# 2. Validate + copy the config and build the image
./scripts/setup.sh --location fi            # asks for the .conf path
# or: make setup LOCATION=fi

# 3. Optional: put the wrapper on your PATH
sudo ln -sfn "$(pwd)/scripts/aivpn" /usr/local/bin/aivpn
```

## 🚀 Usage

> **Local test without Docker:** `bash scripts/smoke-test.sh` (or `make smoke`)
> — syntax, security wiring, entrypoint error handling and the PI scanner.
> It never touches the host network.

### Starting the container

```bash
# The easy way (wrapper / Makefile) — container name: aivpn-<location>
./scripts/aivpn up fi          # or: make up LOCATION=fi
./scripts/aivpn wait           # blocks until the tunnel is up

# Or directly with Docker
docker run -d --name aivpn-fi \
  --cap-drop=ALL --cap-add=NET_ADMIN --security-opt=no-new-privileges:true \
  --device=/dev/net/tun \
  --sysctl net.ipv6.conf.all.disable_ipv6=1 \
  -v "$(pwd)/config/fi.conf:/etc/wireguard/wg0.conf:ro" \
  -p 127.0.0.1::1080 \
  aivpn:latest daemon
./scripts/wait-for-vpn.sh aivpn-fi
```

### Commands

```bash
# Wrapper (host side)
aivpn status                 # container, tunnel, handshake, egress IP
aivpn ip                     # egress IP
aivpn socks                  # socks5h://127.0.0.1:<port>
aivpn test fi                # tunnel + SOCKS5 smoke test for one location
aivpn test-all               # every config/*.conf
aivpn logs
aivpn down                   # stop + remove the managed container

# Inside the container
docker exec aivpn-fi curl -s https://ip-api.com/json
docker exec aivpn-fi /usr/local/bin/docker-entrypoint.sh status

# Agent fetch with a heuristic prompt-injection scan
#   0 = clean, 77 = possible injection (content withheld),
#   1 = fetch error (HTTP error / timeout / too large), 2 = scanner error
docker exec aivpn-fi safefetch https://example.com/api/data
```

**Stopping:** use `aivpn down` or `docker stop <name>`. The in-container
`stop` command only signals the daemon; with a restart policy (compose,
systemd) Docker starts it again.

### Browser through VPN (SOCKS5)

```bash
SOCKS_PORT=$(docker port aivpn-fi 1080/tcp | head -1 | awk -F: '{print $NF}')

# Chrome with a dedicated profile + leak protection
google-chrome \
  --user-data-dir="$HOME/.config/google-chrome/aivpn-fi" \
  --proxy-server="socks5://127.0.0.1:$SOCKS_PORT" \
  --host-resolver-rules="MAP * ~NOTFOUND , EXCLUDE 127.0.0.1" \
  --disable-quic \
  --webrtc-ip-handling-policy=disable_non_proxied_udp

# curl from the host (socks5-hostname = DNS through the tunnel too)
curl --socks5-hostname "127.0.0.1:$SOCKS_PORT" https://ip-api.com/json
```

### Multiple locations

The wrapper keeps **one active location** on `localhost:1080`; `aivpn up us`
replaces `aivpn-fi`. `aivpn test <location>` checks other locations in a
temporary container on a random port without touching the active one.

To run several locations side by side, start extra containers yourself with a
random host port:

```bash
docker run -d --name vpn-jp \
  --cap-drop=ALL --cap-add=NET_ADMIN --security-opt=no-new-privileges:true \
  --device=/dev/net/tun --sysctl net.ipv6.conf.all.disable_ipv6=1 \
  -v "$(pwd)/config/jp.conf:/etc/wireguard/wg0.conf:ro" \
  -p 127.0.0.1::1080 \
  aivpn:latest daemon
./scripts/wait-for-vpn.sh vpn-jp
```

Never run the **same** config in two containers at once — both peers share one
key and will keep knocking each other off.

### systemd supervision

```bash
sudo cp -r . /opt/aivpn            # configs in /opt/aivpn/config/<location>.conf
sudo install -m 0644 systemd/aivpn@.service /etc/systemd/system/aivpn@.service
sudo systemctl daemon-reload
sudo systemctl enable --now aivpn@fi.service
```

The unit runs `scripts/aivpn foreground <location>` and restarts the container
after a Docker or process failure; the container's own reconnect loop handles
ordinary WireGuard interruptions. **One instance at a time** (they share
`localhost:1080`). Optional overrides go in `/opt/aivpn/aivpn.env`.

## 🛡️ Security

- **Kill switch, fail-closed:** the IPv4 firewall is installed **before** the
  tunnel exists and stays in place during reconnects — only `wg0`, the
  WireGuard endpoint and loopback may send traffic. If the tunnel drops, the
  container goes dark. If the kill switch cannot be installed (no iptables,
  unparseable endpoint, no DNS server), the container refuses to start.
- **IPv6 blocked:** IPv6 is never routed through the tunnel, so it is disabled
  (`--sysctl net.ipv6.conf.all.disable_ipv6=1`) and blocked with ip6tables.
- **DNS leak protection:** `/etc/resolv.conf` points at the tunnel DNS; port 53
  inside the tunnel is only allowed to that server, and Docker's embedded
  resolver (`127.0.0.11`, which resolves from the host) is blocked.
- **SOCKS5 access control:** microsocks has no auth by default, so only the
  Docker gateway (where your `127.0.0.1` published port arrives from) may
  connect — other containers on the same network cannot use it as an open
  proxy. Optional `SOCKS_USER` / `SOCKS_PASS` add username/password auth.
- **Published on `127.0.0.1` only** — not reachable from your LAN.
- **Hardened runtime:** dropped capabilities (`NET_ADMIN` only),
  `no-new-privileges`, tmpfs, memory/pid limits, log rotation.
- **Rules:**
  - `config/*.conf` contains a private key → `chmod 600`, never commit it.
    The image itself contains no credentials.
  - Never use `--network=host` (the tunnel routes would replace the host's)
  - Never share the container's network namespace with an untrusted container
    (`--network=container:aivpn-...`)

### About `safefetch`

`safefetch` is a **tripwire, not a guarantee.** It normalises the page
(line breaks, HTML entities, zero-width characters, tags) and matches it
against literal injection phrasing in [`data/pi-patterns.txt`](data/pi-patterns.txt).
Paraphrased, translated or encoded attacks will get through — keep treating
fetched content as untrusted. `SAFEFETCH_MODE=warn` passes content through
with a warning on stderr instead of withholding it.

## ⚙️ Configuration

| Variable | Default | Meaning |
|---|---|---|
| `TUNNEL_DNS` | from config | Override the tunnel DNS server |
| `HEALTH_INTERVAL` | `60` | Seconds between health checks |
| `HEALTHCHECK_URL` | `https://api.ipify.org` | Egress check URL |
| `SOCKS_ALLOW_FROM` | `gateway` | `gateway`, `any`, or comma-separated IPs/CIDRs |
| `SOCKS_USER` / `SOCKS_PASS` | — | Optional SOCKS5 auth |
| `SAFEFETCH_TIMEOUT` | `30` | Fetch timeout (s) |
| `SAFEFETCH_MAX_BYTES` | `10485760` | Max response size |
| `SAFEFETCH_MODE` | `block` | `block` or `warn` |
| `PI_SCAN_TIMEOUT` | `60` | Max seconds for the scan (timeout = scanner error) |
| `AIVPN_HOST_PORT` | `1080` | Host port used by the wrapper / compose |
| `FORCE_USERSPACE_WG` | `0` | Force `wireguard-go` (testing) |

## ⚠️ Limitations

| Item | Details |
|---|---|
| Proton device limit | 10 simultaneous devices (each config = one device) |
| Netshield / Moderate NAT / Accelerator | Chosen when the config is generated, not switchable at runtime |
| Secure Core | Not supported by third-party clients — regular servers work |
| IPv6 | Not tunnelled; blocked inside the container |
| Container-only | `curl` on the host does NOT go through the tunnel |
| Healthcheck dependency | Uses `https://api.ipify.org`; override `HEALTHCHECK_URL` if unavailable |

## 🔍 Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `config ... is not readable` | The container has no `CAP_DAC_OVERRIDE`: a mode-600 config must be owned by root → `sudo chown root:root config/*.conf` |
| `Exited(1)` / tunnel won't come up | Wrong/expired key, server down → `docker logs aivpn-<location>` |
| `no IPv4 DNS server in the config` | Add `DNS = 10.2.0.1` to the config or set `TUNNEL_DNS` |
| `cannot block IPv6` | Run with `--sysctl net.ipv6.conf.all.disable_ipv6=1` (the wrapper and compose do this) |
| Container won't start: `.../disable_ipv6: no such file` | Host boots with `ipv6.disable=1` → remove the `sysctls` lines from compose |
| `RTNETLINK answers: Operation not permitted` | Check `/dev/net/tun` and `NET_ADMIN`; AiVPN falls back to `wireguard-go` when the kernel module is missing |
| `sysctl: ... Read-only file system` | Stale image from before the manual bring-up → rebuild |
| SOCKS5 not responding | `aivpn socks` / `docker port <name> 1080`; from another container set `SOCKS_ALLOW_FROM` |
| Other VPNs break on the host | Never use `--network=host`; if it leaked: `ip link del wg0` + route cleanup |

More in [`aivpn/references/troubleshooting.md`](aivpn/references/troubleshooting.md).

## 🧪 Development

```bash
make smoke     # local tests, no Docker needed
make lint      # shellcheck + hadolint
```

CI (`.github/workflows/ci.yml`) runs both and an end-to-end kill-switch test:
it starts the image against an unreachable endpoint and asserts that nothing
gets out — not through `wg0`, not around it via `eth0`, not over IPv6, not via
Docker DNS — and that neighbour containers cannot use the SOCKS5 port.

## ☕ Support this project

Not a Proton user yet? Signing up through this referral link supports the
project's development (and may earn you bonus months from Proton):

👉 **https://pr.tn/ref/97EY429P**

## 📜 License & credits

- **License:** Apache-2.0 (see [LICENSE](LICENSE))
- **Changelog:** [CHANGELOG.md](CHANGELOG.md)
- **Inspiration:** [gendigitalinc/agentvpn](https://github.com/gendigitalinc/agentvpn) —
  entrypoint architecture (kill switch, microsocks ordering, reconnect loop)
- **Protocol:** [WireGuard](https://www.wireguard.com/) — an
  [officially supported](https://protonvpn.com/support/wireguard-configurations/) third-party
  client of Proton VPN
- **Tools:** [wireguard-go](https://github.com/WireGuard/wireguard-go),
  [microsocks](https://github.com/rofl0r/microsocks)

---

*AiVPN — built at night, powered by coffee. ☕*
