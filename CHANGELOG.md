# Changelog

All notable changes to AiVPN are documented here. The project follows
[Semantic Versioning](https://semver.org/).

## [1.1.0] — 2026-11-23

### Security
- Kill switch is now installed **before** the tunnel comes up and is never
  relaxed during reconnects (previously `OUTPUT` was set to `ACCEPT` while
  reconnecting).
- IPv6 is blocked with ip6tables and disabled via sysctl in compose, the
  wrapper and systemd — it previously bypassed the tunnel when Docker IPv6 was
  enabled.
- Fail-closed startup: missing iptables, an unparseable endpoint, a missing
  DNS server or an unwritable `/etc/resolv.conf` now stop the container
  instead of continuing without protection.
- Docker's embedded resolver (`127.0.0.11`) is blocked — it resolves from the
  host namespace and leaked DNS when the config had no `DNS =` line.
- SOCKS5 only accepts connections from the Docker gateway by default
  (`SOCKS_ALLOW_FROM`), so neighbour containers cannot use it as an open proxy.
  Optional `SOCKS_USER` / `SOCKS_PASS` auth.
- `scripts/smoke-test.sh` no longer runs the real daemon on the host (it could
  rewrite the host's `/etc/resolv.conf` and firewall when run as root with an
  existing `/etc/wireguard/wg0.conf`).

### Fixed
- `stop` no longer tears the tunnel down from a side process while the daemon
  keeps running; it signals PID 1 and documents how to stop for good.
- `setup.sh` no longer reports every real config as a "placeholder"; it writes
  `config/<location>.conf` (`--location`) to match `make up` / `aivpn up`.
- `aivpn test` / `test-all` no longer kill the active container; other
  locations are tested in a temporary container, the active one in place.
  `test-all` reports all failures instead of stopping at the first.
- `make wait` actually waits for the tunnel (`aivpn wait`); `aivpn socks`
  prints the real published port.
- MTU is read from the config (default 1420); all IPv4 `Address` entries are
  applied; endpoint parsing is shared and handles hostnames.
- `wireguard-go` runs in the foreground so its PID can be supervised.
- `docker exec <name> safefetch <url>` works (symlink in the image).
- Line endings forced to LF for every file — a Windows checkout previously
  produced a `pi-patterns.txt` whose patterns never matched.

### Changed
- `safefetch` / `pi-scan.sh`: content is normalised (line breaks, HTML
  entities, zero-width characters, tags) before matching; patterns use
  bounded gaps instead of `.*` and the broad ones that blocked ordinary pages
  (e.g. "grandma", "no limits", "developer mode") were removed. Scanner errors
  now fail closed (exit 2); HTTP errors and oversized responses
  (`SAFEFETCH_MAX_BYTES`) are fetch errors; `SAFEFETCH_MODE=warn` added.
  Documented as a heuristic tripwire rather than "prompt-injection-safe".
- systemd unit uses `scripts/aivpn foreground` and an optional env file.
- Documentation brought in line with the code (container names, config
  paths, userspace fallback, multiple locations).

### Added
- GitHub Actions CI: shellcheck, hadolint, smoke tests and an end-to-end
  kill-switch test against an unreachable endpoint.
- `make smoke`, `make lint`, OCI image labels, this changelog.

## [1.0.0]

- Initial release.
