# Build an out-of-tree kernel module against the project's 6.x-baikal tree.
# Run on host (where the kernel was built); scp the resulting .ko to PS4
# and `sudo insmod ./eth_probe.ko` — output appears in dmesg.

KERNEL_DIR ?= $(abspath ../../../src/6.x-baikal)

obj-m += eth_probe.o

all:
	$(MAKE) -C $(KERNEL_DIR) M=$(CURDIR) modules

clean:
	$(MAKE) -C $(KERNEL_DIR) M=$(CURDIR) clean
