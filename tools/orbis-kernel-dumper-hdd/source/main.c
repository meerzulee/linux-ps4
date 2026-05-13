/*
 * Orbis kernel dumper — port-9020 payload for PSFree-Enhanced (FW 12.02).
 *
 * Adapted from Scene-Collective/ps4-kernel-dumper @ 42fce7e
 * (https://github.com/Scene-Collective/ps4-kernel-dumper).
 *
 * Changes vs upstream:
 *  - Output path is /mnt/usb<N>/orbis-dump/<FW>/kernel.elf (segregates
 *    from PS4-OS folders and from our Linux files on the same USB).
 *  - No "kernel.complete" sentinel — we may re-dump on the same USB
 *    (e.g. to verify ASLR-related differences across boots).
 *  - Notification ladder: start, every 10%, complete.
 *  - Drops the debug socket path (we read serial via the host directly).
 *
 * Build context (`tools/orbis-kernel-dumper/README.md`):
 *  - Vendored SDK at vendor/ps4-payload-sdk (commit 2847f1f), which has
 *    explicit caseentry(1202, macro) in libPS4/include/payload_utils.h.
 *  - The SDK provides:
 *      get_kernel_base()  → kbase via xfast_syscall IDT trick
 *      get_memory_dump()  → kernel copyout (FW-version-aware)
 *      jailbreak()        → ucred zero + prison0 + rootvnode (FW 12.02
 *                           uses K1202_PRISON_0=0x0111FA18,
 *                           K1202_ROOTVNODE=0x02136E90 from fw_defines.h)
 *  - PSFree-Enhanced + Lapse must have already installed sys_kexec on
 *    syscall 11 (Lapse does this as part of its standard kpatch).
 *
 * Use:
 *  1. Build → orbis-kernel-dumper.bin
 *  2. Drop on PS4 USB (FAT32/exFAT) alongside linux-1024mb.bin
 *  3. PSFree-Enhanced → Payload Guest → load orbis-kernel-dumper.bin
 *  4. Wait ~30–90s; PS4 will notify on completion
 *  5. Pull /mnt/usb0/orbis-dump/<FW>/kernel.elf from USB to host
 */

#include "ps4.h"

#define KERNEL_CHUNK_SIZE PAGE_SIZE
#define NOTIFY_PERCENT_STEP 10  /* notify every 10% progress */

static int nthread_run = 1;
static int notify_time = 20;
static char notify_buf[512] = {0};

static void *nthread_func(void *arg) {
  UNUSED(arg);
  time_t t1 = 0;
  while (nthread_run) {
    if (notify_buf[0]) {
      time_t t2 = time(NULL);
      if ((t2 - t1) >= notify_time) {
        t1 = t2;
        printf_notification("%s", notify_buf);
      }
    } else {
      t1 = 0;
    }
    sceKernelSleep(1);
  }
  return NULL;
}

/*
 * Walk the ELF program-header table to find the kernel's in-memory size.
 *
 * Logic mirrors Scene-Collective's get_kernel_size():
 *  - Read e_ehsize / e_phentsize / e_phnum from the ELF header at kbase
 *  - For each program header, compute the high-watermark vaddr aligned
 *    by p_align, in the canonical kernel-text VA space (0xFFFFFFFF82200000)
 *  - Subtract the canonical base to get a size relative to kbase
 *
 * The magic 0xFFFFFFFF82200000 is the kernel-text VA Orbis ELFs are
 * linked at since FW ~5.00. If it changes in a future FW, this function
 * needs updating.
 */
static uint64_t get_kernel_size(uint64_t kernel_base) {
  uint16_t elf_header_size;
  uint16_t elf_header_entry_size;
  uint16_t num_of_elf_entries;

  get_memory_dump(kernel_base + 0x34, (uint64_t *)&elf_header_size, sizeof(uint16_t));
  get_memory_dump(kernel_base + 0x34 + sizeof(uint16_t), (uint64_t *)&elf_header_entry_size, sizeof(uint16_t));
  get_memory_dump(kernel_base + 0x34 + (sizeof(uint16_t) * 2), (uint64_t *)&num_of_elf_entries, sizeof(uint16_t));

  uint64_t max = 0;
  for (int i = 0; i < num_of_elf_entries; i++) {
    uint64_t temp_memsz;
    uint64_t temp_vaddr;
    uint64_t temp_align;
    uint64_t temp_max;

    uint64_t memsz_offset = elf_header_size + (i * elf_header_entry_size) + 0x28;
    uint64_t vaddr_offset = elf_header_size + (i * elf_header_entry_size) + 0x10;
    uint64_t align_offset = elf_header_size + (i * elf_header_entry_size) + 0x30;
    get_memory_dump(kernel_base + memsz_offset, &temp_memsz, sizeof(uint64_t));
    get_memory_dump(kernel_base + vaddr_offset, &temp_vaddr, sizeof(uint64_t));
    get_memory_dump(kernel_base + align_offset, &temp_align, sizeof(uint64_t));

    temp_vaddr -= kernel_base;
    temp_vaddr += 0xFFFFFFFF82200000;

    temp_max = (temp_vaddr + temp_memsz + (temp_align - 1)) & ~(temp_align - 1);

    if (temp_max > max) {
      max = temp_max;
    }
  }

  return max - 0xFFFFFFFF82200000;
}

int _main(struct thread *td) {
  UNUSED(td);

  char fw_version[6] = {0};
  char usb_name[7] = {0};
  char usb_path[13] = {0};
  char output_root[PATH_MAX] = {0};
  char save_file[PATH_MAX] = {0};

  initKernel();
  initLibc();
  initPthread();

  jailbreak();

  initSysUtil();

  get_firmware_string(fw_version);
  uint64_t kernel_base = get_kernel_base();

  ScePthread nthread;
  memset_s(&nthread, sizeof(ScePthread), 0, sizeof(ScePthread));
  scePthreadCreate(&nthread, NULL, nthread_func, NULL, "nthread");

  printf_notification("Orbis kernel dumper starting (FW %s, kbase=0x%llx)",
                      fw_version, (unsigned long long)kernel_base);

  /* HDD variant: write to /data/orbis-dump/<FW>/ on internal storage.
   * Skips wait_for_usb (no USB needed) and avoids FAT32 fragmentation
   * + USB throughput bottleneck.  Fetch via FTP from /data afterwards. */
  strncpy(usb_name, "HDD", sizeof(usb_name) - 1);
  usb_name[sizeof(usb_name) - 1] = '\0';
  strncpy(usb_path, "/data", sizeof(usb_path) - 1);
  usb_path[sizeof(usb_path) - 1] = '\0';

  snprintf_s(output_root, sizeof(output_root), "%s/orbis-dump", usb_path);
  mkdir(output_root, 0777);
  snprintf_s(output_root, sizeof(output_root), "%s/orbis-dump/%s", usb_path, fw_version);
  mkdir(output_root, 0777);

  snprintf_s(save_file, sizeof(save_file), "%s/kernel.elf", output_root);
  unlink(save_file);

  int fd = open(save_file, O_WRONLY | O_CREAT | O_TRUNC, 0777);
  if (fd < 0) {
    printf_notification("Unable to create kernel.elf on %s. Aborting.", usb_name);
    nthread_run = 0;
    return 0;
  }

  printf_notification("Output ready (%s). Computing kernel size...", usb_name);

  uint64_t kernel_size = get_kernel_size(kernel_base);
  uint64_t num_of_kernel_chunks = (kernel_size + (KERNEL_CHUNK_SIZE / 2)) / KERNEL_CHUNK_SIZE;
  uint64_t size_mb = kernel_size / (1024 * 1024);

  printf_notification("Kernel size: %lu MB (0x%lx bytes). Starting dump...",
                      (unsigned long)size_mb, (unsigned long)kernel_size);

  notify_time = 5;
  uint64_t *dump = mmap(NULL, 0x4000, PROT_READ | PROT_WRITE, MAP_ANONYMOUS | MAP_PRIVATE, -1, 0);
  uint64_t pos = 0;
  int last_decile_notified = -1;
  for (uint64_t i = 0; i < num_of_kernel_chunks; i++) {
    get_memory_dump(kernel_base + pos, dump, KERNEL_CHUNK_SIZE);
    lseek(fd, pos, SEEK_SET);
    write(fd, (void *)dump, KERNEL_CHUNK_SIZE);

    int percent = ((double)(KERNEL_CHUNK_SIZE * i) /
                   ((double)KERNEL_CHUNK_SIZE * (double)num_of_kernel_chunks)) * 100;
    int decile = percent / NOTIFY_PERCENT_STEP;
    if (decile != last_decile_notified) {
      last_decile_notified = decile;
      snprintf_s(notify_buf, sizeof(notify_buf),
                 "Dumping kernel to %s: %d%%", usb_name, percent);
    }

    pos = pos + KERNEL_CHUNK_SIZE;
  }
  notify_buf[0] = '\0';
  nthread_run = 0;

  close(fd);
  munmap(dump, 0x4000);

  printf_notification("Done. kernel.elf written to %s/orbis-dump/%s/", usb_name, fw_version);
  printf_notification("Fetch via FTP: /data/orbis-dump/<FW>/kernel.elf");

  return 0;
}
