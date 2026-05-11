#include "kernel.h"
#include "module.h"

#include "zlib.h"

int libZlib;

int (*sceZlibInitialize)(const void *buffer, size_t len);
int (*sceZlibInflate)(const void *src, uint32_t srcLen, void *dst, uint32_t dstLen, uint64_t *reqId);
int (*sceZlibWaitForDone)(uint64_t *reqId, uint32_t *timeout);
int (*sceZlibGetResult)(uint64_t reqId, uint32_t *dstLen, int *status);
int (*sceZlibFinalize)(void);

void initZlib(void) {
  if (libZlib) {
    return;
  }
  initModule();
  const int ORBIS_SYSMODULE_ZLIB = 0x00C5;
  if (sceSysmoduleLoadModule(ORBIS_SYSMODULE_ZLIB) < 0) {
    return;
  }

  libZlib = sceKernelLoadStartModule("libSceZlib.sprx", 0, 0, 0, NULL, NULL);

  RESOLVE(libZlib, sceZlibInitialize);
  RESOLVE(libZlib, sceZlibInflate);
  RESOLVE(libZlib, sceZlibWaitForDone);
  RESOLVE(libZlib, sceZlibGetResult);
  RESOLVE(libZlib, sceZlibFinalize);
}
