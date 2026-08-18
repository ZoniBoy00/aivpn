# syntax=docker/dockerfile:1
#
# ============================================================================
#  AiVPN — Agent-Grade WireGuard Relay for Proton VPN
# ----------------------------------------------------------------------------
#  Multi-stage build:
#    Stage 1: userspace WireGuard (wireguard-go) — kernel-module fallback
#    Stage 2: microsocks (SOCKS5 proxy)
#    Stage 3: minimal Alpine runtime with iptables kill switch
#
#  Build locally, use locally. The WireGuard config mounted at runtime
#  contains your private key — NEVER `docker push` this image.
# ============================================================================

# ---- Stage 1: wireguard-go (userspace WireGuard) ---------------------------
FROM golang:1.24-alpine3.20@sha256:9f98e9893fbc798c710f3432baa1e0ac6127799127c3101d2c263c3a954f0abe AS wg-builder
ARG WIREGUARD_GO_COMMIT=ecfc5a8d54462e18e13c72173e2623d16d8e25a0
RUN apk add --no-cache git make && mkdir -p /out
WORKDIR /src
RUN git clone https://github.com/WireGuard/wireguard-go.git \
    && cd wireguard-go \
    && git checkout "$WIREGUARD_GO_COMMIT"
WORKDIR /src/wireguard-go
RUN CGO_ENABLED=0 go build -o /out/wireguard-go .

# ---- Stage 2: microsocks (SOCKS5 proxy) ------------------------------------
FROM alpine:3.20@sha256:d9e853e87e55526f6b2917df91a2115c36dd7c696a35be12163d44e6e2a4b6bc AS socks-builder
ARG MICROSOCKS_COMMIT=69f004aeb7c4ed7da3bf538d60a2d705c5a618df
RUN apk add --no-cache build-base libev-dev git make && mkdir -p /out
WORKDIR /src
RUN git clone https://github.com/rofl0r/microsocks.git \
    && cd microsocks \
    && git checkout "$MICROSOCKS_COMMIT"
WORKDIR /src/microsocks
RUN make
RUN cp microsocks /out/microsocks

# ---- Stage 3: runtime --------------------------------------------------------
FROM alpine:3.20@sha256:d9e853e87e55526f6b2917df91a2115c36dd7c696a35be12163d44e6e2a4b6bc
# wireguard-tools : wg / wg-quick
# iptables        : kill switch (no leak outside tunnel)
# iproute2        : ip (used by wg-quick and entrypoint routing)
# bash            : wg-quick + entrypoint are bash scripts
# curl            : connectivity checks + safefetch
# ca-certificates : TLS for https fetches
RUN apk add --no-cache \
        wireguard-tools \
        iptables \
        iproute2 \
        bash \
        curl \
        ca-certificates \
    && rm -rf /var/cache/apk/*

# Userspace WireGuard fallback (used only if the host kernel lacks the wg module)
COPY --from=wg-builder /out/wireguard-go /usr/local/bin/wireguard-go

# SOCKS5 proxy
COPY --from=socks-builder /out/microsocks /usr/local/bin/microsocks

# Entrypoint + tooling
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
COPY scripts/pi-scan.sh /usr/local/bin/pi-scan.sh
COPY data/pi-patterns.txt /usr/local/share/aivpn/pi-patterns.txt

RUN chmod +x /usr/local/bin/docker-entrypoint.sh \
             /usr/local/bin/pi-scan.sh \
             /usr/local/bin/wireguard-go \
             /usr/local/bin/microsocks \
    && mkdir -p /etc/wireguard /var/log/aivpn

# Default: mount your Proton WireGuard config here (read-only)
#   -v $(pwd)/config/wg0.conf:/etc/wireguard/wg0.conf:ro
ENV WG_CONF=/etc/wireguard/wg0.conf

HEALTHCHECK --interval=30s --timeout=15s --start-period=30s \
    CMD bash -c '[ -f /var/run/vpn-up ] && wg show wg0 >/dev/null 2>&1 && curl -fsS -m 10 "${HEALTHCHECK_URL:-https://api.ipify.org}" >/dev/null'

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["daemon"]
