#
# orbis-kernel-dumper — PS4 port-9020 payload to dump the Orbis kernel
#
# Variant of Scene-Collective/ps4-kernel-dumper's Makefile, parameterized
# to point at our vendored SDK at vendor/ps4-payload-sdk.
#
# Build:
#   make
# Output:
#   orbis-kernel-dumper.bin (drop on PS4 USB, load via Payload Guest)
#
# Prerequisites on host (Debian/Ubuntu/Arch):
#   build-essential / base-devel  (provides gcc, make, binutils)
#   The SDK builds with the host gcc — no PS4 toolchain or cross-compiler
#   needed. Tested with gcc 13.x and 15.x.
#
# The first build will compile vendor/ps4-payload-sdk/libPS4 into
# libPS4.a; subsequent builds reuse it (run `make sdk-clean` to rebuild).
#

PS4SDK  ?= $(abspath $(CURDIR)/../../vendor/ps4-payload-sdk)
LIBPS4  := $(PS4SDK)/libPS4

CC      := gcc
OBJCOPY := objcopy
ODIR    := build
SDIR    := source
IDIRS   := -I$(LIBPS4)/include -Iinclude
LDIRS   := -L$(LIBPS4)
MAPFILE := $(shell basename "$(CURDIR)").map

# Match Scene-Collective's CFLAGS; -march=btver2/-mtune=btver2 targets
# Jaguar (PS4 APU), which is what we want.
CFLAGS  := $(IDIRS) -Os -std=c11 -ffunction-sections -fdata-sections \
           -fno-builtin -nostartfiles -nostdlib \
           -Wall -Wextra \
           -masm=intel -march=btver2 -mtune=btver2 -m64 -mabi=sysv \
           -mcmodel=small -fpie -fPIC
LFLAGS  := $(LDIRS) -Xlinker -T $(LIBPS4)/linker.x \
           -Xlinker -Map="$(MAPFILE)" \
           -Wl,--build-id=none -Wl,--gc-sections

CFILES  := $(wildcard $(SDIR)/*.c)
SFILES  := $(wildcard $(SDIR)/*.s)
OBJS    := $(patsubst $(SDIR)/%.c, $(ODIR)/%.o, $(CFILES)) \
           $(patsubst $(SDIR)/%.s, $(ODIR)/%.o, $(SFILES))

LIBS    := -lPS4

TARGET  := orbis-kernel-dumper.bin

.PHONY: all sdk sdk-clean clean

all: $(TARGET)

$(TARGET): sdk $(ODIR) $(OBJS)
	$(CC) $(LIBPS4)/crt0.s $(ODIR)/*.o -o temp.t $(CFLAGS) $(LFLAGS) $(LIBS)
	$(OBJCOPY) -O binary temp.t "$(TARGET)"
	rm -f temp.t

sdk:
	$(MAKE) -C $(LIBPS4)

sdk-clean:
	$(MAKE) -C $(LIBPS4) clean

$(ODIR)/%.o: $(SDIR)/%.c | $(ODIR)
	$(CC) -c -o $@ $< $(CFLAGS)

$(ODIR)/%.o: $(SDIR)/%.s | $(ODIR)
	$(CC) -c -o $@ $< $(CFLAGS)

$(ODIR):
	@mkdir -p $@

clean:
	rm -rf "$(TARGET)" "$(MAPFILE)" $(ODIR)
