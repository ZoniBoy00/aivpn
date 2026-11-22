# ============================================================================
#  AiVPN — Makefile
#  Agent-Grade WireGuard Relay for Proton VPN
#
#  Usage (on the Linux host / VPS):
#    make setup LOCATION=fi    provision config/fi.conf + build image (interactive)
#    make build                build image
#    make up LOCATION=fi       start relay container aivpn-fi (config/fi.conf)
#    make wait                 wait until the active tunnel is up
#    make test LOCATION=fi     tunnel + SOCKS5 smoke test for one location
#    make test-all             test every config/*.conf
#    make socks                print the SOCKS5 endpoint
#    make logs                 follow container logs
#    make down                 stop + remove the managed container
#    make smoke                local smoke tests (no Docker needed)
#    make lint                 shellcheck + hadolint
#    make clean                remove image
# ============================================================================

IMAGE       ?= aivpn:latest
LOCATION    ?= fi

.PHONY: setup build up wait test test-all socks logs down smoke lint clean

setup:
	./scripts/setup.sh --location $(LOCATION)

build:
	docker build -t $(IMAGE) .

up:
	./scripts/aivpn up $(LOCATION)

wait:
	./scripts/aivpn wait

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

smoke:
	bash scripts/smoke-test.sh

lint:
	shellcheck -S warning docker-entrypoint.sh scripts/*.sh scripts/aivpn
	docker run --rm -i -v "$(CURDIR)/.hadolint.yaml:/hadolint.yaml:ro" hadolint/hadolint:v2.12.0 hadolint --config /hadolint.yaml - < Dockerfile

clean:
	docker rmi $(IMAGE) 2>/dev/null || true
