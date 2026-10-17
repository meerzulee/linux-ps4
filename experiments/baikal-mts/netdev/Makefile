# SPDX-License-Identifier: GPL-2.0-only
KDIR ?=
EXPECTED_KERNEL_RELEASE := 6.18.44-ps4-baikal
EXPECTED_CONFIG_SHA256 := 922dc16e4928b69cf711f377a29c75c9627d534ad3a2a208dc3b3f1dd61cf234
.PHONY: all modules clean check-kdir

all: modules

check-kdir:
	@test -n "$(KDIR)" || { echo 'Supply KDIR=/absolute/path/to/the/prepared/kernel/tree' >&2; exit 2; }
	@command -v sha256sum >/dev/null || { echo 'sha256sum is required' >&2; exit 2; }
	@test -r "$(KDIR)/.config" || { echo 'KDIR lacks the accepted .config' >&2; exit 2; }
	@printf '%s  %s\n' "$(EXPECTED_CONFIG_SHA256)" "$(KDIR)/.config" | sha256sum --check --status || { echo 'KDIR .config differs from the accepted kernel configuration' >&2; exit 2; }
	@test -r "$(KDIR)/include/config/kernel.release" || { echo 'KDIR lacks prepared kernel.release' >&2; exit 2; }
	@test "$$(cat "$(KDIR)/include/config/kernel.release")" = "$(EXPECTED_KERNEL_RELEASE)" || { echo 'KDIR release must be $(EXPECTED_KERNEL_RELEASE)' >&2; exit 2; }
	@test -s "$(KDIR)/Module.symvers" || { echo 'KDIR lacks a nonempty matching Module.symvers' >&2; exit 2; }

modules: check-kdir
	$(MAKE) -C "$(KDIR)" M="$(CURDIR)" ARCH=x86_64 LOCALVERSION= modules

clean: check-kdir
	$(MAKE) -C "$(KDIR)" M="$(CURDIR)" ARCH=x86_64 LOCALVERSION= clean

.PHONY: host-test host-test-sanitize
HOSTCC ?= cc
HOST_CFLAGS := -std=c11 -Wall -Wextra -Werror -Wpedantic -O2
host-test:
	@set -eu; test_dir=$$(mktemp -d "$${TMPDIR:-/tmp}/psx-mts-core.XXXXXX"); \
	trap 'rm -rf "$$test_dir"' EXIT HUP INT TERM; \
	$(HOSTCC) $(HOST_CFLAGS) -I. tests/core_test.c -o "$$test_dir/core_test"; \
	"$$test_dir/core_test"
host-test-sanitize:
	@set -eu; test_dir=$$(mktemp -d "$${TMPDIR:-/tmp}/psx-mts-core-asan.XXXXXX"); \
	trap 'rm -rf "$$test_dir"' EXIT HUP INT TERM; \
	$(HOSTCC) $(HOST_CFLAGS) -g -fsanitize=address,undefined -fno-omit-frame-pointer -I. tests/core_test.c -o "$$test_dir/core_test"; \
	"$$test_dir/core_test"
