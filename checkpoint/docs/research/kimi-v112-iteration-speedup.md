# v112 iteration speedup recommendation

**kimi-k2.6, 2026-05-13**

## Go with the module plan. It is the right tool.

Switch `CONFIG_PS4_MTS=y` → `CONFIG_PS4_MTS=m`, boot once, then iterate via `make M=drivers/net/ethernet/sony modules` + `scp` + `rmmod && insmod`. This is standard Linux driver development and works on Baikal.

## Single biggest gotcha: MSI IRQ release on rmmod

Your `request_irq()` / `free_irq()` path goes through the bpcie MSI domain. If `rmmod` fails with `rmmod: ERROR: Module ps4_mts is in use`, it means the MSI vector is not being released cleanly — bpcie may be holding a refcount. 

**Mitigation**: Ensure `mts_remove()` calls `free_irq()` **before** `pci_free_irq_vectors()`, and verify `kthread_stop()` actually returns (not hung in `msleep_interruptible`). Add `wake_up_process(mts->phy_ctrl_thread)` before `kthread_stop()` if needed.

**Test once**: Before committing to the fast loop, manually `rmmod ps4_mts` from a known-good boot and confirm it returns 0. If it fails, fix `mts_remove()` first.

## Skip userspace and kpatch

- **Userspace UIO**: You can't do MSI/NAPI/DMA rings from userspace. Not practical for a netdev.
- **kpatch**: Requires livepatch infrastructure your kernel doesn't have. Overkill.

## Safety net

If an `insmod` wedges the kernel (e.g., BAR already mapped from failed `rmmod`), keep a `ps4_mts.ko` built from the last known-good source. `insmod /tmp/ps4_mts-good.ko` over the broken one without rebooting.
