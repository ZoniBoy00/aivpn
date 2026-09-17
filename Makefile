# ============================================================================
#  AiVPN — Makefile
#  Agent-Grade WireGuard Relay for Proton VPN
#
#  Usage (on the Linux host / VPS):
#    make setup          provision config + build image (interactive)
#    make build          build image
#    make up LOCATION=fi      start relay container (config/fi.conf)
#    make wait LOCATION=paris wait until tunnel is up
#    make test LOCATION=paris show egress IP through tunnel
#    make socks LOCATION=paris print SOCKS5 host port
#    make logs LOCATION=paris tail container logs
#    make down LOCATION=paris stop + remove container
#    make clean           remove image
# ============================================================================

IMAGE       ?= aivpn:latest
LOCATION    ?= fi
NAME        := aivpn-$(LOCATION)

.PHONY: setup build up wait test test-all socks logs down clean

setup:
	./scripts/setup.sh

build:
	docker build -t $(IMAGE) .

up:
	./scripts/aivpn up $(LOCATION)

wait:
	./scripts/aivpn status

test:
	./scripts/aivpn test $(LOCATION)

test-all:
	./scripts/aivpn test-all

socks:
	./scripts/aivpn socks

logs:
	./scripts/aivpn logs

down:
	./scripts/aivpn down

clean:
	docker rmi $(IMAGE) 2>/dev/null || true
