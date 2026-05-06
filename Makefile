# PS4 Linux Baikal Kernel — Makefile
#
# All real work happens in build.sh. The Makefile is just convenience
# shortcuts. Pass TARGET= to switch (default: 5.4-baikal).
#
# Examples:
#   make                        # build default target (5.4-baikal)
#   make TARGET=6.x-baikal      # build 6.x target
#   make clean TARGET=5.4-baikal
#   make patches-only TARGET=5.4-baikal

SHELL := /bin/bash
TARGET ?= 5.4-baikal

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
	@echo "Next: make TARGET=5.4-baikal patches-only  # verify patches apply"
	@echo "      make TARGET=5.4-baikal               # build kernel"

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
