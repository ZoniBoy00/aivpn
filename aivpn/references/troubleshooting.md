# AiVPN — Troubleshooting

## Tunnel won't come up

Check the container logs first:

```bash
docker logs vpn-<loc>
```

Common causes:
- **Wrong/expired key or server down** — Proton WireGuard configs are valid
  ~1 year (expiry shown on account.protonvpn.com/downloads). Generate a fresh
  one and remount it.
- **`RTNETLINK answers: Operation not permitted`** — the host kernel lacks the
  WireGuard module. The entrypoint uses the kernel module (`wg setconf` + `ip`),
  so the host needs `/dev/net/tun` and the `wireguard` kernel module
  (e.g. `modprobe wireguard`). Inside Docker, run with
  `--cap-add=NET_ADMIN --device=/dev/net/tun`.
- **`sysctl: ... Read-only file system` in logs** — Docker 29 mounts `/proc/sys`
  read-only, which breaks `wg-quick`'s sysctl step. The entrypoint's manual
  bring-up (wg setconf + ip) avoids this entirely. If you still see the error,
  the image is stale → rebuild (`docker build -t aivpn .`).

## Tunnel is up but no connectivity

Check the routes inside the container:

```bash
docker exec vpn-<loc> ip route
docker exec vpn-<loc> wg show
```

The WireGuard endpoint must be pinned through the original default gateway
(`ip route add <endpoint-ip>/32 via <gw> dev eth0`). The entrypoint does this
automatically on bring-up; if you bring the tunnel up manually, remember it —
otherwise the UDP handshake loops back through wg0 and you get no egress.

## SOCKS5 not responding

- Confirm the port mapping: `docker port vpn-<loc> 1080`.
- The SOCKS5 proxy (microsocks) starts only after the tunnel is up — check the
  logs for "Ready".
- From the host, prefer `curl --socks5-hostname 127.0.0.1:<host-port>`, or just
  run tools inside the container with `docker exec` — that is the recommended
  path and avoids SOCKS5 quirks entirely.

## Reddit / YouTube / geo sites still blocked

- Verify the egress IP actually changed:
  `docker exec vpn-<loc> curl -s https://ipinfo.io/json`
- Pick a location in the country you need (US for many geo-blocks, e.g.
  `us.conf`). Some sites fingerprint more than the IP (cookies, TLS) — use a
  fresh user agent / cookies inside the container.
- Reddit's JSON API requires OAuth since 2023; page fetches work fine.

## Other VPNs break on the host

Never run the container with `--network=host` — the container's routes would
leak into the host's routing table. If it ever happens:
`ip link del wg0` and clean up leftover routes.

## Private key safety

- `config/*.conf` contains your WireGuard private key: `chmod 600`, never
  commit it, never `docker push` an image with a mounted config.
- The Docker image itself is safe to push (no config baked in), but there is no
  reason to push it — build locally.
