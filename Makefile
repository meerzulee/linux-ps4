# PS4 Linux 6.x Baikal Kernel - Makefile
#
# Usage:
#   make              - Build kernel
#   make clean        - Clean build artifacts
#   make clone-refs   - Clone reference repos
#   make firmware     - Download firmware files
#   make help         - Show all targets

SHELL := /bin/bash
.PHONY: all build clean clone-refs firmware update patches-only help

# Default target
all: build

# Build kernel
build:
	@./build.sh

# Clean build
clean:
	@./build.sh --clean

# Update base kernel and rebuild
update:
	@./build.sh --update

# Only apply patches, don't compile
patches-only:
	@./build.sh --patches-only

# Clone reference repositories
clone-refs:
	@./scripts/clone-refs.sh

# Download firmware files
firmware:
	@./scripts/download-firmware.sh

# Extract patches helper
extract:
	@echo "Usage: ./scripts/extract-patches.sh <command> [options]"
	@echo "Run './scripts/extract-patches.sh' for help"

# Initialize project (first time setup)
init: clone-refs firmware
	@echo ""
	@echo "Project initialized!"
	@echo "Next steps:"
	@echo "  1. Extract patches from reference repos"
	@echo "  2. Add patches to patches/series"
	@echo "  3. Run 'make build'"

# Show help
help:
	@echo "PS4 Linux 6.x Baikal Kernel Build System"
	@echo ""
	@echo "Targets:"
	@echo "  make              - Build kernel (default)"
	@echo "  make clean        - Clean and rebuild from scratch"
	@echo "  make update       - Update base kernel and rebuild"
	@echo "  make patches-only - Apply patches without building"
	@echo "  make clone-refs   - Clone reference repositories to tmp/"
	@echo "  make firmware     - Download required firmware files"
	@echo "  make init         - First-time setup (clone-refs + firmware)"
	@echo "  make help         - Show this help"
	@echo ""
	@echo "Build options (pass to build.sh):"
	@echo "  ./build.sh -j 8           - Use 8 parallel jobs"
	@echo "  ./build.sh -C config/xxx  - Use specific config file"
	@echo "  ./build.sh -n             - Build without patches"
	@echo ""
	@echo "Patch extraction:"
	@echo "  ./scripts/extract-patches.sh list <repo>"
	@echo "  ./scripts/extract-patches.sh search <repo> <pattern>"
	@echo "  ./scripts/extract-patches.sh extract <repo> <commit> <category>"
	@echo ""
	@echo "Project structure:"
	@echo "  patches/     - Patch files (tracked in git)"
	@echo "  config/      - Kernel configs (tracked in git)"
	@echo "  tmp/         - Reference repos (gitignored)"
	@echo "  src/         - Build directory (gitignored)"
	@echo "  output/      - Build artifacts (gitignored)"
