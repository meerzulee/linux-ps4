# PS4 Linux Baikal Kernel — Makefile
#
# All real work happens in build.sh. The Makefile is just convenience
# shortcuts. Pass TARGET= to switch (default: 6.18-baikal).
#
# Examples:
#   make                        # build default target (6.18-baikal)
#   make TARGET=6.x-baikal      # build archived 6.15 target
#   make clean TARGET=5.4-baikal
#   make patches-only TARGET=5.4-baikal

SHELL := /bin/bash
TARGET ?= 6.18-baikal

.PHONY: all build clean update patches-only clone-refs firmware init help

all: build

build:
	@./build.sh -t $(TARGET)

clean:
	@./build.sh -t $(TARGET) --clean

update:
	@./build.sh -t $(TARGET) --update

patches-only:
	@./build.sh -t $(TARGET) --patches-only

clone-refs:
	@./scripts/clone-refs.sh

firmware:
	@./scripts/download-firmware.sh

init: clone-refs firmware
	@echo ""
	@echo "Project initialized."
	@echo "Next: make patches-only  # verify the 6.18 patches apply"
	@echo "      make               # build the default 6.18 kernel"

help:
	@echo "PS4 Linux Baikal Kernel Build System"
	@echo ""
	@echo "Targets:"
	@echo "  make                       Build default target ($(TARGET))"
	@echo "  make TARGET=<name>         Switch target"
	@echo "  make clean TARGET=<name>   Clean build for target"
	@echo "  make update TARGET=<name>  Refresh base kernel and rebuild"
	@echo "  make patches-only          Apply patches without compiling"
	@echo "  make clone-refs            Clone reference repos to tmp/"
	@echo "  make firmware              Download firmware blobs"
	@echo "  make init                  First-time setup (clone-refs + firmware)"
	@echo ""
	@echo "Available targets:"
	@for f in targets/*.env; do echo "  - $$(basename $$f .env)"; done
	@echo ""
	@echo "See ./build.sh -h for low-level options."
