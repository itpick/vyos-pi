BOARD ?= pi4
BOARDS := pi4 pi5
VERSION ?= $(shell date -u +%Y.%m.%d)-dev

.PHONY: help iso image images raw compress vm test-image test-trial test-direct test-upgrade test test-scripts release clean

help:
	@echo "make iso [VERSION=..]        arm64 ISO + raw image with the Pi kernel (docker, arm64 host)"
	@echo "make image BOARD=pi4|pi5     out/vyos-pi-<board>.img.xz from the raw image"
	@echo "make images                  both boards"
	@echo "make raw BOARD=..            out/vyos-pi-<board>.img (uncompressed)"
	@echo "make compress BOARD=..       out/vyos-pi-<board>.img -> .img.xz + .sha256"
	@echo "make vm BOARD=pi5|pi4        boot the Pi-shaped test VM (console in this terminal)"
	@echo "make test-image BOARD=..     VM test: seed, NIC names, kernel, DHCP/DNS/NAT for a LAN client"
	@echo "make test-trial BOARD=..     VM test: reboot-after-minutes reboots by itself"
	@echo "make test-direct             VM test: boot like a Pi 5 (kernel from the FAT partition)"
	@echo "make test-upgrade BOARD=.. ISO=..  VM test: add system image, reboot into it"
	@echo "make test                    image + trial for both boards, direct for pi5"
	@echo "make test-scripts            unit tests of scripts/ (opnsense-to-vyos.py), no VM"
	@echo "make release TAG=..          upload out/* to a GitHub release (needs gh)"

iso:
	scripts/container.sh scripts/build-iso.sh $(VERSION)

image:
	scripts/build-image.sh $(BOARD)
	scripts/compress.sh $(BOARD)

images:
	@for b in $(BOARDS); do scripts/build-image.sh $$b && scripts/compress.sh $$b || exit 1; done

raw:
	scripts/build-image.sh $(BOARD)

compress:
	scripts/compress.sh $(BOARD)

vm:
	vm/run.sh --$(BOARD)

test-image:
	vm/test.sh image $(BOARD)

test-trial:
	vm/test.sh trial $(BOARD)

test-direct:
	vm/test.sh image pi5
	vm/test.sh direct pi5

test-upgrade:
	@test -n "$(ISO)" || { echo "ISO=... required (another vyos-pi ISO)" >&2; exit 2; }
	vm/test.sh image $(BOARD)
	vm/test.sh upgrade $(BOARD) $(ISO)

test:
	@for b in $(BOARDS); do vm/test.sh image $$b && vm/test.sh trial $$b || exit 1; done
	vm/test.sh image pi5 && vm/test.sh direct pi5

test-scripts:
	python3 -m unittest discover -s tests -v

release:
	@test -n "$(TAG)" || { echo "TAG=... required" >&2; exit 2; }
	gh release create "$(TAG)" out/*.img.xz out/*.img.xz.sha256 out/vyos-pi-arm64.iso out/vyos-pi-arm64.iso.sha256 \
	  out/*.manifest.txt out/vyos-pi.config.boot.default --title "vyos-pi $(TAG)" --notes-file RELEASE_NOTES.md

clean:
	rm -rf out .work/vm .work/build-*
