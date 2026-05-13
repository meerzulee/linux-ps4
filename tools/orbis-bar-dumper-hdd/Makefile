#
# orbis-bar-dumper-hdd — PS4 payload that dumps MTS BAR0 from Orbis memory
# to internal HDD (/data).  Variant of orbis-bar-dumper that bypasses USB
# FAT32 throughput + fragmentation, fetch via FTP afterwards.
#
# Output: orbis-bar-dumper-hdd.bin (drop in /data/payloads/ via FTP, load
# via PSFree Payload Guest or GoldHEN payload menu).
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

TARGET  := orbis-bar-dumper-hdd.bin

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
