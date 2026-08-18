---
name: aivpn
description: "Route agent traffic through Proton VPN exit nodes via a per-location Docker WireGuard container with SOCKS5 proxy and prompt-injection-safe fetching. Use when told to use a VPN, connect from a specific country, browse from a specific region, compare geo-localized content, run curl/scrapers/yt-dlp from another country, or access region-restricted sites."
license: Apache-2.0
compatibility: Requires Docker on Linux with --cap-add=NET_ADMIN and /dev/net/tun, plus a Proton VPN WireGuard config (free plan works, Proton Unlimited → 140+ countries).
metadata:
  hermes:
    tags: [vpn, wireguard, proton, proxy, socks5, geo, privacy]
---

# AiVPN — Agent-Grade WireGuard Relay for Proton VPN

One Docker container = one WireGuard tunnel to a Proton VPN exit node. Only
traffic from inside the container goes through the VPN — the host network is
never touched. Built on the same principle as Gen Digital's AgentVPN, but on
Proton VPN infrastructure using a standard WireGuard config from your Proton
account (no API keys, no separate sign-up).

## When to Use

- Agent needs to fetch content **from another country** (pricing, availability,
  region-locked data, YouTube blocks)
- **Parallel comparison**: run multiple locations side by side
- Anonymous browsing without putting the host behind a VPN
- Prompt-injection-safe fetching (`safefetch`) for agents

## Requirements (one-time)

1. **Proton VPN subscription** (free plan works — limited locations)
2. **WireGuard config** from <https://account.protonvpn.com> → Downloads →
   WireGuard configuration. Save as `config/wg0.conf` (mode 600, never commit).
3. Docker on Linux with `/dev/net/tun`.

## Setup & Build (one-time)

```bash
git clone https://github.com/ZoniBoy00/aivpn && cd aivpn
./scripts/setup.sh --config /path/to/proton-wg.conf   # provisions config + builds
# or: make setup (interactive) / make build (build only)
```

## Start a Tunnel (per location)

One location = one config file. For a second country, download another Proton
config and mount it under a different container name.

```bash
# start (config/wg0.conf mounted read-only)
make up                # container vpn-proton
# or directly:
docker run -d --name vpn-proton \
  --cap-add=NET_ADMIN --device=/dev/net/tun \
  -v "$PWD/config/wg0.conf:/etc/wireguard/wg0.conf:ro" \
  -p 127.0.0.1::1080 \
  aivpn daemon

make wait              # wait for tunnel up
make test              # show egress IP through tunnel
make socks             # print SOCKS5 host port (for browsers/SOCKS tools)
make logs              # tail logs
make down              # stop + remove container (tunnels are ephemeral)
```

## Use It

```bash
# anything inside the container goes through the VPN
docker exec vpn-proton curl -s https://ipinfo.io/json        # check egress IP
docker exec vpn-proton /usr/local/bin/yt-dlp -f mp4 URL       # yt-dlp via VPN

# SOCKS5 for host tools (browsers, curl --socks5-hostname)
curl --socks5-hostname 127.0.0.1:$(docker port vpn-proton 1080 | cut -d: -f2) https://ipinfo.io/json

# prompt-injection-safe fetch (exit 77 = content blocked)
docker exec vpn-proton safefetch https://example.com
```

## Security

- **Kill switch**: iptables OUTPUT DROP — only wg0 + the WireGuard endpoint +
  tunnel DNS may egress. If wg0 drops, the container goes dark (no host leak).
- **DNS**: tunnel DNS enforced via /etc/resolv.conf inside the container.
- **Private key** lives only in `config/wg0.conf` (gitignored, mounted read-only).
  Never `docker push` the image with a populated config.
- **safefetch**: two-tier prompt-injection scan (heuristic regex + patterns)
  blocks injected instructions before they reach the agent. Fail-open.
- Never share a vpn-* container's network namespace with untrusted containers
  (microsocks listens on 0.0.0.0:1080 with no auth).

## Multiple Locations at Once

Run several containers, each with its own config:

```bash
docker run -d --name vpn-us   -v "$PWD/config/us.conf:/etc/wireguard/wg0.conf:ro" ... aivpn daemon
docker run -d --name vpn-jp   -v "$PWD/config/jp.conf:/etc/wireguard/wg0.conf:ro" ... aivpn daemon
```

## Troubleshooting

- Tunnel won't come up → `docker logs vpn-proton`; check the WireGuard config
  (endpoint IP, private key, AllowedIPs = 0.0.0.0/0).
- Container exits → fail-fast guard: bad config / key / network. Fix config, `make up`.
- Host-SOCKS5 timeout → prefer running tools inside the container (`docker exec`).
- See `references/troubleshooting.md` (if present) and the repo README for more.
