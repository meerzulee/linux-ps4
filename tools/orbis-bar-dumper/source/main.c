/*
 * Orbis MTS BAR0 dumper — port-9020 payload for PSFree-Enhanced (FW 12.02).
 *
 * Captures the 4 KiB MMIO state of the Sony MTS ethernet controller while
 * Orbis has the device fully initialized (link UP, TX working).
 *
 * v110 approach: DMAP does not cover PCI MMIO on Orbis.  Walk the live MTS
 * softc found by Ghidra RE, range-check every pointer, then do a bounded
 * 16-byte volatile probe before any full BAR copyout:
 *
 *   *(kbase + 0x021f4938)      -> global mts softc pointer slot
 *   *(softc + 0x3068)          -> BAR0 struct resource *
 *   *(bar0_res + 0x10)         -> BAR0 KVA / r_handle
 *
 * Output:
 *   /mnt/usb<N>/orbis-dump/<FW>/mts-bar0.bin
 */

#include "ps4.h"

#define MTS_BAR0_SIZE 0x1000  /* 4 KiB */
#define MTS_SOFTC_PTR_OFFSET 0x021f4938ULL /* 0xffffffffca590938 - kernel.elf LOAD base 0xffffffffc839c000 */
#define MTS_SOFTC_BAR0_RES_OFF 0x3068ULL
#define MTS_RESOURCE_MMIO_FLAG_OFF 0x08ULL
#define MTS_RESOURCE_HANDLE_OFF 0x10ULL

struct kpayload_mts_bar0_info {
  uint16_t fw_version;
  uint64_t uaddr;
  uint64_t size;
  uint64_t softc_ptr;
  uint64_t bar0_res;
  uint64_t bar0_kva;
  uint64_t bar0_is_mmio;
  int copyout_ret;
};

static int kpayload_mts_bar0_dump(struct thread *td, struct kpayload_mts_bar0_info *info) {
  UNUSED(td);
  void *kernel_base;
  int (*copyout)(const void *kaddr, void *uaddr, size_t len);

  uint16_t fw_version = info->fw_version;

  /* NOTE: This is a C preprocessor macro from libPS4/payload_utils.h. */
  build_kpayload(fw_version, copyout_macro);

  uint8_t *kernel_ptr = (uint8_t *)kernel_base;
  uint64_t softc_ptr = *(volatile uint64_t *)(kernel_ptr + MTS_SOFTC_PTR_OFFSET);
  info->softc_ptr = softc_ptr;
  if (softc_ptr == 0) {
    info->copyout_ret = -2;
    return -2;
  }
  if ((int64_t)softc_ptr >= 0) {
    info->copyout_ret = -5;
    return -5;
  }

  uint64_t bar0_res = *(volatile uint64_t *)(softc_ptr + MTS_SOFTC_BAR0_RES_OFF);
  info->bar0_res = bar0_res;
  if (bar0_res == 0) {
    info->copyout_ret = -3;
    return -3;
  }
  if ((int64_t)bar0_res >= 0) {
    info->copyout_ret = -6;
    return -6;
  }

  uint64_t bar0_is_mmio = *(volatile uint64_t *)(bar0_res + MTS_RESOURCE_MMIO_FLAG_OFF);
  uint64_t bar0_kva = *(volatile uint64_t *)(bar0_res + MTS_RESOURCE_HANDLE_OFF);
  info->bar0_is_mmio = bar0_is_mmio;
  info->bar0_kva = bar0_kva;
  if (bar0_is_mmio == 0 || bar0_kva == 0) {
    info->copyout_ret = -4;
    return -4;
  }
  if ((int64_t)bar0_kva >= 0) {
    info->copyout_ret = -7;
    return -7;
  }

  uint32_t probe[4];
  probe[0] = *(volatile uint32_t *)(bar0_kva + 0x0);
  probe[1] = *(volatile uint32_t *)(bar0_kva + 0x4);
  probe[2] = *(volatile uint32_t *)(bar0_kva + 0x8);
  probe[3] = *(volatile uint32_t *)(bar0_kva + 0xc);

  int ret = copyout(probe, (void *)info->uaddr, sizeof(probe));
  info->copyout_ret = ret;
  if (ret != 0) {
    return ret;
  }

  if (probe[0] == 0xffffffffU && probe[1] == 0xffffffffU &&
      probe[2] == 0xffffffffU && probe[3] == 0xffffffffU) {
    info->copyout_ret = -8;
    return -8;
  }

  size_t size = (info->size > MTS_BAR0_SIZE) ? MTS_BAR0_SIZE : (size_t)info->size;
  if (size <= sizeof(probe)) {
    return 0;
  }

  size_t rest = size - sizeof(probe);
  ret = copyout((const void *)(bar0_kva + sizeof(probe)),
                (void *)(info->uaddr + sizeof(probe)), rest);
  info->copyout_ret = ret;
  return ret;
}

static int get_mts_bar0_dump(uint8_t *buf, size_t size, struct kpayload_mts_bar0_info *info) {
  memset_s(info, sizeof(*info), 0, sizeof(*info));
  info->fw_version = get_firmware();
  info->uaddr = (uint64_t)buf;
  info->size = size;
  return kexec(&kpayload_mts_bar0_dump, info);
}

static int nthread_run = 1;
static int notify_time = 5;
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
 * Return 1 if the buffer looks like valid MMIO (non-all-zeroes,
 * non-all-0xFF — both of which indicate the copyout returned without
 * actually reading the device).
 */
static int looks_valid(const uint8_t *buf, size_t size) {
  int has_nonzero = 0;
  int has_non_ff = 0;
  for (size_t i = 0; i < size; i++) {
    if (buf[i] != 0x00) has_nonzero = 1;
    if (buf[i] != 0xFF) has_non_ff = 1;
    if (has_nonzero && has_non_ff) return 1;
  }
  return 0;
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

  printf_notification("Orbis MTS BAR0 dumper (FW %s, kbase=0x%llx)",
                      fw_version, (unsigned long long)kernel_base);

  snprintf_s(notify_buf, sizeof(notify_buf), "Waiting for USB device...");
  wait_for_usb(usb_name, usb_path);
  notify_buf[0] = '\0';

  /* /mnt/usb<N>/orbis-dump/<FW>/ */
  snprintf_s(output_root, sizeof(output_root), "%s/orbis-dump", usb_path);
  mkdir(output_root, 0777);
  snprintf_s(output_root, sizeof(output_root), "%s/orbis-dump/%s", usb_path, fw_version);
  mkdir(output_root, 0777);

  uint8_t *buf = mmap(NULL, MTS_BAR0_SIZE, PROT_READ | PROT_WRITE,
                      MAP_ANONYMOUS | MAP_PRIVATE, -1, 0);
  if (buf == MAP_FAILED || buf == NULL) {
    printf_notification("ERROR: mmap failed for dump buffer");
    return 1;
  }

  snprintf_s(notify_buf, sizeof(notify_buf), "Walking MTS softc and probing BAR0 first 16 bytes...");
  memset_s(buf, MTS_BAR0_SIZE, 0, MTS_BAR0_SIZE);

  struct kpayload_mts_bar0_info probe_info;
  int probe_ret = get_mts_bar0_dump(buf, 16, &probe_info);
  notify_buf[0] = '\0';

  int probe_ok = (probe_ret == 0 && probe_info.copyout_ret == 0 && looks_valid(buf, 16));
  printf_notification(
      "BAR0 probe ret=%d copyout=%d softc=0x%llx res=0x%llx kva=0x%llx mmio=0x%llx probe=%02x%02x%02x%02x %02x%02x%02x%02x",
      probe_ret, probe_info.copyout_ret,
      (unsigned long long)probe_info.softc_ptr,
      (unsigned long long)probe_info.bar0_res,
      (unsigned long long)probe_info.bar0_kva,
      (unsigned long long)probe_info.bar0_is_mmio,
      buf[0], buf[1], buf[2], buf[3], buf[4], buf[5], buf[6], buf[7]);

  struct kpayload_mts_bar0_info dump_info = probe_info;
  int ret = probe_ret;
  int ok = 0;

  if (probe_ok) {
    snprintf_s(notify_buf, sizeof(notify_buf), "BAR0 16-byte probe OK; dumping full 4KB...");
    memset_s(buf + 16, MTS_BAR0_SIZE - 16, 0, MTS_BAR0_SIZE - 16);
    ret = get_mts_bar0_dump(buf, MTS_BAR0_SIZE, &dump_info);
    notify_buf[0] = '\0';
    ok = (ret == 0 && dump_info.copyout_ret == 0 && looks_valid(buf, MTS_BAR0_SIZE));
  }

  if (ok) {
    snprintf_s(save_file, sizeof(save_file), "%s/mts-bar0.bin", output_root);
    int fd = open(save_file, O_WRONLY | O_CREAT | O_TRUNC, 0777);
    if (fd >= 0) {
      write(fd, buf, MTS_BAR0_SIZE);
      close(fd);
      printf_notification(
          "MTS BAR0 saved: softc=0x%llx res=0x%llx kva=0x%llx mmio=0x%llx %02x%02x%02x%02x %02x%02x%02x%02x",
          (unsigned long long)dump_info.softc_ptr,
          (unsigned long long)dump_info.bar0_res,
          (unsigned long long)dump_info.bar0_kva,
          (unsigned long long)dump_info.bar0_is_mmio,
          buf[0], buf[1], buf[2], buf[3], buf[4], buf[5], buf[6], buf[7]);
    } else {
      ok = 0;
      printf_notification("ERROR: open failed for %s", save_file);
    }
  }

  munmap(buf, MTS_BAR0_SIZE);

  nthread_run = 0;

  if (ok) {
    printf_notification("Done. Dump is %s/mts-bar0.bin. Power off and pull USB.", output_root);
  } else {
    printf_notification(
        "FAIL: MTS BAR0 dump failed ret=%d copyout=%d softc=0x%llx res=0x%llx kva=0x%llx mmio=0x%llx",
        ret, dump_info.copyout_ret,
        (unsigned long long)dump_info.softc_ptr,
        (unsigned long long)dump_info.bar0_res,
        (unsigned long long)dump_info.bar0_kva,
        (unsigned long long)dump_info.bar0_is_mmio);
  }

  return ok ? 0 : 1;
}
