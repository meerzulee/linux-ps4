/*
 * Orbis MTS BAR0 dumper (SAFE variant) — PSFree-Enhanced payload, FW 12.02.
 *
 * Why this exists:
 *   The previous bar-dumper variants did raw kernel pointer
 *   dereferences inside the kexec function:
 *     uint64_t softc_ptr = *(volatile uint64_t *)(kbase + 0x021f4938);
 *   If that address isn't mapped in the current boot's kernel pmap,
 *   the CPU takes an unprotected supervisor-mode page fault.  Without
 *   `pcb_onfault` set up, the kernel either panics or wedges the
 *   thread holding a global lock — taking down the scheduler.  We saw
 *   exactly this happen tonight (kbase=0xffffffffdefa8000 boot).
 *
 * What this dumper does differently:
 *   - Zero raw kernel dereferences.  Every kernel read goes through
 *     libPS4's get_memory_dump(), which uses copyout() with
 *     pcb_onfault protection — faults return -1 cleanly, no panic.
 *   - All pointer-walking happens in userspace, not in kexec.
 *   - Each kernel read is a separate kexec call (bounded).
 *   - Every step prints a diagnostic notification so we know exactly
 *     where it failed.
 *
 * Walk chain (all reads done via get_memory_dump):
 *   1. kbase + 0x021f4938                  -> softc pointer slot
 *   2. softc + 0x3068                       -> bar0 struct resource *
 *   3. bar0_res + 0x08, bar0_res + 0x10     -> mmio flag, kva
 *   4. bar0_kva + 0..16                     -> probe (sanity check)
 *   5. bar0_kva + 0..0x1000                 -> full 4 KiB BAR dump
 *
 * Output: /data/orbis-dump/<FW>/mts-bar0.bin
 */

#include "ps4.h"

#define MTS_BAR0_SIZE 0x1000  /* 4 KiB */
#define MTS_SOFTC_PTR_OFFSET 0x021f4938ULL /* slot address relative to kbase */
#define MTS_SOFTC_BAR0_RES_OFF 0x3068ULL
#define MTS_RESOURCE_MMIO_FLAG_OFF 0x08ULL
#define MTS_RESOURCE_HANDLE_OFF 0x10ULL

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
 * Safe kernel read: routes through get_memory_dump (copyout +
 * pcb_onfault).  Returns 0 on success, -1 on EFAULT (buffer zeroed
 * by kpayload_dump).
 *
 * The userspace buffer must come from mmap with PROT_READ|PROT_WRITE.
 */
static int safe_kread(uint64_t kaddr, void *ubuf, size_t size) {
  return get_memory_dump(kaddr, (uint64_t *)ubuf, size);
}

/*
 * Heuristic: a value is plausibly a kernel VA on Orbis 12.02 if bit
 * 63 is set (canonical-high-half) and the low 12 bits are 0 or 8
 * (kernel pointers are usually 8-byte aligned).  We're lenient on
 * the low bits because struct fields can have any alignment.
 */
static int looks_like_kva(uint64_t v) {
  return (v != 0) && ((int64_t)v < 0);
}

/*
 * Detect dead/uninitialized MMIO read: all-0xFF means PCIe config
 * read returned the bus-error pattern (device not powered, not
 * mapped, or completion timeout).  All-zero means we read DRAM, not
 * MMIO (BAR not mapped).
 */
static int looks_valid_mmio(const uint8_t *buf, size_t size) {
  int has_nonzero = 0, has_non_ff = 0;
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
  char output_root[PATH_MAX] = {0};
  char save_file[PATH_MAX] = {0};

  initKernel();
  initLibc();
  initPthread();

  jailbreak();

  initSysUtil();

  get_firmware_string(fw_version);
  uint64_t kbase = get_kernel_base();

  ScePthread nthread;
  memset_s(&nthread, sizeof(ScePthread), 0, sizeof(ScePthread));
  scePthreadCreate(&nthread, NULL, nthread_func, NULL, "nthread");

  printf_notification(
      "Orbis MTS BAR0 dumper [SAFE] (FW %s, kbase=0x%llx)",
      fw_version, (unsigned long long)kbase);

  snprintf_s(output_root, sizeof(output_root), "/data/orbis-dump");
  mkdir(output_root, 0777);
  snprintf_s(output_root, sizeof(output_root), "/data/orbis-dump/%s", fw_version);
  mkdir(output_root, 0777);

  /* All scratch buffers must be in userspace memory that copyout
   * can write to.  Use mmap so the addresses survive across kexec
   * calls and are valid in the kernel's view of userspace too. */
  uint8_t *scratch = mmap(NULL, MTS_BAR0_SIZE, PROT_READ | PROT_WRITE,
                          MAP_ANONYMOUS | MAP_PRIVATE, -1, 0);
  if (scratch == MAP_FAILED || scratch == NULL) {
    printf_notification("FAIL: mmap scratch buffer");
    nthread_run = 0;
    return 1;
  }
  memset_s(scratch, MTS_BAR0_SIZE, 0, MTS_BAR0_SIZE);

  /* Step 1: read softc pointer slot. */
  uint64_t softc_slot_addr = kbase + MTS_SOFTC_PTR_OFFSET;
  int ret = safe_kread(softc_slot_addr, scratch, 8);
  uint64_t softc_ptr = *(uint64_t *)scratch;
  printf_notification("step1 softc_slot@0x%llx ret=%d val=0x%llx",
                      (unsigned long long)softc_slot_addr, ret,
                      (unsigned long long)softc_ptr);
  if (ret != 0) {
    printf_notification("FAIL: softc slot unreadable (offset wrong for this kbase?)");
    nthread_run = 0;
    return 1;
  }
  if (!looks_like_kva(softc_ptr)) {
    printf_notification("FAIL: softc_ptr=0x%llx not a kernel VA "
                        "(driver not initialized? wrong offset?)",
                        (unsigned long long)softc_ptr);
    nthread_run = 0;
    return 1;
  }

  /* Step 2: read bar0_res = softc->bar0_res. */
  uint64_t bar0_res_addr = softc_ptr + MTS_SOFTC_BAR0_RES_OFF;
  ret = safe_kread(bar0_res_addr, scratch, 8);
  uint64_t bar0_res = *(uint64_t *)scratch;
  printf_notification("step2 bar0_res@0x%llx ret=%d val=0x%llx",
                      (unsigned long long)bar0_res_addr, ret,
                      (unsigned long long)bar0_res);
  if (ret != 0 || !looks_like_kva(bar0_res)) {
    printf_notification("FAIL: bar0_res ret=%d val=0x%llx", ret,
                        (unsigned long long)bar0_res);
    nthread_run = 0;
    return 1;
  }

  /* Step 3: read bar0_res->is_mmio (off 0x08) and ->r_handle (off 0x10). */
  uint64_t bar0_is_mmio = 0, bar0_kva = 0;
  ret = safe_kread(bar0_res + MTS_RESOURCE_MMIO_FLAG_OFF, scratch, 8);
  bar0_is_mmio = *(uint64_t *)scratch;
  if (ret != 0) {
    printf_notification("FAIL: bar0_is_mmio ret=%d", ret);
    nthread_run = 0;
    return 1;
  }
  ret = safe_kread(bar0_res + MTS_RESOURCE_HANDLE_OFF, scratch, 8);
  bar0_kva = *(uint64_t *)scratch;
  if (ret != 0) {
    printf_notification("FAIL: bar0_kva ret=%d", ret);
    nthread_run = 0;
    return 1;
  }
  printf_notification("step3 is_mmio=0x%llx kva=0x%llx",
                      (unsigned long long)bar0_is_mmio,
                      (unsigned long long)bar0_kva);
  if (bar0_is_mmio == 0) {
    printf_notification("FAIL: bar0_is_mmio is 0 (BAR not configured as MMIO)");
    nthread_run = 0;
    return 1;
  }
  if (!looks_like_kva(bar0_kva)) {
    printf_notification("FAIL: bar0_kva=0x%llx not a kernel VA",
                        (unsigned long long)bar0_kva);
    nthread_run = 0;
    return 1;
  }

  /* Step 4: probe first 16 bytes of BAR0. */
  memset_s(scratch, MTS_BAR0_SIZE, 0, MTS_BAR0_SIZE);
  ret = safe_kread(bar0_kva, scratch, 16);
  uint32_t *probe = (uint32_t *)scratch;
  printf_notification("step4 probe ret=%d [0]=0x%08x [1]=0x%08x [2]=0x%08x [3]=0x%08x",
                      ret, probe[0], probe[1], probe[2], probe[3]);
  if (ret != 0) {
    printf_notification("FAIL: BAR0 probe ret=%d (kva unmapped?)", ret);
    nthread_run = 0;
    return 1;
  }
  if (!looks_valid_mmio(scratch, 16)) {
    printf_notification("FAIL: BAR0 probe is all-0x00 or all-0xFF "
                        "(device unpowered / completion timeout)");
    nthread_run = 0;
    return 1;
  }

  /* Step 5: full 4 KiB dump. */
  memset_s(scratch, MTS_BAR0_SIZE, 0, MTS_BAR0_SIZE);
  ret = safe_kread(bar0_kva, scratch, MTS_BAR0_SIZE);
  if (ret != 0) {
    printf_notification("FAIL: BAR0 full dump ret=%d", ret);
    nthread_run = 0;
    return 1;
  }
  if (!looks_valid_mmio(scratch, MTS_BAR0_SIZE)) {
    printf_notification("FAIL: BAR0 4KB looks dead (all-0 or all-FF)");
    nthread_run = 0;
    return 1;
  }

  /* Write to file. */
  snprintf_s(save_file, sizeof(save_file), "%s/mts-bar0.bin", output_root);
  unlink(save_file);
  int fd = open(save_file, O_WRONLY | O_CREAT | O_TRUNC, 0777);
  if (fd < 0) {
    printf_notification("FAIL: open %s for write", save_file);
    nthread_run = 0;
    return 1;
  }
  ssize_t wrote = write(fd, scratch, MTS_BAR0_SIZE);
  close(fd);
  if (wrote != MTS_BAR0_SIZE) {
    printf_notification("FAIL: write %zd != %d", wrote, MTS_BAR0_SIZE);
    nthread_run = 0;
    return 1;
  }

  printf_notification(
      "OK: mts-bar0.bin saved (softc=0x%llx res=0x%llx kva=0x%llx) "
      "first8=%02x%02x%02x%02x %02x%02x%02x%02x",
      (unsigned long long)softc_ptr, (unsigned long long)bar0_res,
      (unsigned long long)bar0_kva,
      scratch[0], scratch[1], scratch[2], scratch[3],
      scratch[4], scratch[5], scratch[6], scratch[7]);
  printf_notification("Fetch via FTP: /data/orbis-dump/%s/mts-bar0.bin",
                      fw_version);

  munmap(scratch, MTS_BAR0_SIZE);
  nthread_run = 0;
  return 0;
}
