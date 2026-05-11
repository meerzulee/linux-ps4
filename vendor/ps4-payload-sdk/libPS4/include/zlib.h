#pragma once

#ifndef ZLIB_H
#define ZLIB_H

#include "types.h"

extern int (*sceZlibInitialize)(const void *buffer, size_t len);
extern int (*sceZlibInflate)(const void *src, uint32_t srcLen, void *dst, uint32_t dstLen, uint64_t *reqId);
extern int (*sceZlibWaitForDone)(uint64_t *reqId, uint32_t *timeout);
extern int (*sceZlibGetResult)(uint64_t reqtId, uint32_t *dstLen, int *status);
extern int (*sceZlibFinalize)(void);

void initZlib(void);

#endif
