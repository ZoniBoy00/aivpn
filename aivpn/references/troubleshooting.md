# AiVPN — Troubleshooting

## Tunnel won't come up

Check the container logs first:

```bash
docker logs aivpn-<location>      # or: ./scripts/aivpn logs
```

Common causes:
- **Wrong/expired key or server down** — Proton WireGuard configs are valid
  ~1 year (expiry shown on account.protonvpn.com/downloads). Generate a fresh
  one and remount it.
- **`no IPv4 DNS server in the config`** — AiVPN refuses to fall back to
  Docker's resolver (it would leak DNS). Add `DNS = 10.2.0.1` or set
  `TUNNEL_DNS`.
- **`cannot block IPv6`** — ip6tables is unavailable and IPv6 is enabled. Run
  with `--sysctl net.ipv6.conf.all.disable_ipv6=1` (the wrapper, compose file
  and systemd unit already do this).
- **`.../disable_ipv6: no such file or directory` when starting** — the host
  boots with `ipv6.disable=1`, so the sysctl does not exist. Remove the
  `sysctls` lines from `docker-compose.yml` (the wrapper detects this itself).
- **`RTNETLINK answers: Operation not permitted`** — check that the container
  has `--cap-add=NET_ADMIN --device=/dev/net/tun`. If the host kernel has no
  WireGuard module, AiVPN falls back to the bundled `wireguard-go`
  automatically (log line: "will use wireguard-go").
- **`sysctl: ... Read-only file system` in logs** — Docker mounts `/proc/sys`
  read-only, which breaks `wg-quick`. The entrypoint's manual bring-up
  (`wg setconf` + `ip`) avoids this; if you still see it the image is stale →
  rebuild (`docker build -t aivpn:latest .`).

## Tunnel is up but no connectivity

Check the routes and firewall inside the container:

```bash
docker exec aivpn-<location> ip route
docker exec aivpn-<location> wg show
docker exec aivpn-<location> iptables -S
```

The WireGuard endpoint is pinned through the original default gateway
(`<endpoint-ip> via <gw> dev eth0`) and is the only address the kill switch
lets out on `eth0`. A `latest handshake` that never appears in `wg show`
means the endpoint is unreachable or the key is wrong/expired.

## SOCKS5 not responding

- Confirm the port mapping: `./scripts/aivpn socks` or `docker port <name> 1080`.
- The SOCKS5 proxy starts only after the tunnel is up — check the logs for
  "Ready".
- Connecting from **another container** (not via the published port)? Only the
  Docker gateway is allowed by default. Set `SOCKS_ALLOW_FROM` to that
  container's IP/CIDR (or `any`), ideally together with `SOCKS_USER` /
  `SOCKS_PASS`.
- From the host, use `curl --socks5-hostname 127.0.0.1:<host-port>`, or just
  run tools inside the container with `docker exec`.

## Container keeps coming back after `stop`

`docker exec <name> docker-entrypoint.sh stop` only signals the daemon. With a
restart policy (compose `unless-stopped`, systemd `Restart=always`) Docker
starts it again. Use `./scripts/aivpn down`, `docker stop <name>` or
`systemctl stop aivpn@<location>`.

## `safefetch` blocks a harmless page (exit 77)

The scanner is heuristic. Check stderr for the matched phrase, then either use
`SAFEFETCH_MODE=warn` (content passes with a warning) or tighten the pattern in
`data/pi-patterns.txt` and add the page text as a test case in
`scripts/smoke-test.sh`.

## Reddit / YouTube / geo sites still blocked

- Verify the egress IP actually changed:
  `docker exec aivpn-<location> curl -s https://ipinfo.io/json`
- Pick a location in the country you need (US for many geo-blocks, e.g.
  `config/us.conf`). Some sites fingerprint more than the IP (cookies, TLS).
- Reddit's JSON API requires OAuth since 2023; page fetches work fine.

## Other VPNs break on the host

Never run the container with `--network=host` — the container's routes would
replace the host's routing table. If it ever happens:
`ip link del wg0` and clean up leftover routes.

## Private key safety

- `config/*.conf` contains your WireGuard private key: `chmod 600`, never
  commit it (`*.conf` is git-ignored).
- The Docker image contains no credentials — the config is only ever mounted
  read-only at runtime. Still, build locally; there is no need to push it.
