#ifndef RYMIND_BRIDGING_HEADER_H
#define RYMIND_BRIDGING_HEADER_H

#include "llama.h"
// stable-diffusion.cpp（真模型生图，GGUF + Metal）
#include "stable-diffusion.h"
// zip 解压/压缩用的 zlib（Skill.zip 与文件打包）
#include <zlib.h>

// 推理崩溃兜底（sigsetjmp 把 SIGSEGV / SIGBUS / SIGABRT 接住，不让它把 App 带走）
#include <signal.h>
#include <setjmp.h>
void  rm_guard_install(void);
int   rm_guard_call(void (*fn)(void *), void *ud);
int   rm_guard_hit(void);
int   rm_guard_signal(void);

#endif /* RYMIND_BRIDGING_HEADER_H */
