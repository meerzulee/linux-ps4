#pragma once

#ifndef PTHREAD_H
#define PTHREAD_H

#include "types.h"

typedef void *ScePthread;
typedef void *ScePthreadAttr;

typedef void *ScePthreadMutex;
typedef void *ScePthreadMutexattr;

typedef void *ScePthreadBarrier;
typedef void *ScePthreadBarrierattr;

extern int (*scePthreadCreate)(ScePthread *thread, const ScePthreadAttr *attr, void *(*entry)(void *), void *arg, const char *name);
extern void (*scePthreadExit)(void *value);
extern int (*scePthreadDetach)(ScePthread thread);
extern int (*scePthreadJoin)(ScePthread thread, void **value_ptr);
extern void (*scePthreadYield)(void);
extern ScePthread (*scePthreadSelf)(void);
extern int (*scePthreadCancel)(ScePthread thread);

extern int (*scePthreadMutexInit)(ScePthreadMutex *mutex, const ScePthreadMutexattr *attr, const char *name);
extern int (*scePthreadMutexDestroy)(ScePthreadMutex *mutex);
extern int (*scePthreadMutexLock)(ScePthreadMutex *mutex);
extern int (*scePthreadMutexTrylock)(ScePthreadMutex *mutex);
extern int (*scePthreadMutexTimedlock)(ScePthreadMutex *mutex, SceKernelUseconds usec);
extern int (*scePthreadMutexUnlock)(ScePthreadMutex *mutex);

extern int (*scePthreadBarrierInit)(ScePthreadBarrier *barrier, const ScePthreadBarrierattr *attr, unsigned int count);
extern int (*scePthreadBarrierWait)(ScePthreadBarrier *barrier);
extern int (*scePthreadBarrierDestroy)(ScePthreadBarrier *barrier);

void initPthread(void);

#endif
