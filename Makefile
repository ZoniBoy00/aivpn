# ============================================================================
#  AiVPN — Makefile
#  Agent-Grade WireGuard Relay for Proton VPN
#
#  Usage (on the Linux host / VPS):
#    make setup          provision config + build image (interactive)
#    make build          build image
#    make up LOCATION=paris   start relay container (config/wg0.conf)
#    make wait LOCATION=paris wait until tunnel is up
#    make test LOCATION=paris show egress IP through tunnel
#    make socks LOCATION=paris print SOCKS5 host port
#    make logs LOCATION=paris tail container logs
#    make down LOCATION=paris stop + remove container
#    make clean           remove image
# ============================================================================

IMAGE       ?= aivpn
LOCATION    ?= proton
CONFIG      ?= config/wg0.conf
NAME        := vpn-$(LOCATION)
SOCKS_PORT  := 1080

.PHONY: setup build up wait test socks logs down clean

setup:
	./scripts/setup.sh

build:
	docker build -t $(IMAGE) .

up:
	@[ -f $(CONFIG) ] || (echo "Missing $(CONFIG) — run 'make setup' first" && exit 1)
	docker rm -f $(NAME) 2>/dev/null || true
	docker run -d --name $(NAME) \
		--cap-add=NET_ADMIN --device=/dev/net/tun \
		-v $(CURDIR)/$(CONFIG):/etc/wireguard/wg0.conf:ro \
		-p 127.0.0.1::$(SOCKS_PORT) \
		$(IMAGE) daemon

wait:
	./scripts/wait-for-vpn.sh $(NAME)

test:
	docker exec $(NAME) curl -s -m 10 https://ip-api.com/json
	@echo

socks:
	@echo "SOCKS5 for $(NAME): 127.0.0.1:$$(docker port $(NAME) $(SOCKS_PORT) | head -1 | awk -F: '{print $$NF}')"

logs:
	docker logs -f $(NAME)

down:
	docker stop $(NAME) 2>/dev/null || true
	docker rm $(NAME) 2>/dev/null || true

clean:
	docker rmi $(IMAGE) 2>/dev/null || true
