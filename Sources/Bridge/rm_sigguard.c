//  RMGuard —— 推理崩溃兜底。
//  本地模型（llama.cpp / stable-diffusion.cpp）跑在 4GB 的 iPad 上，越界、空指针、
//  内存不足都会直接 SIGSEGV 把整个 App 带走。这里用 sigsetjmp 把崩溃点"接住"并跳回来，
//  让上层能走错误分支（提示内存不够 / 换小档），而不是闪退。
//  ⚠️ 只兜"能安全跳转"的硬件/abort 信号；系统账内存杀进程（SIGKILL）接不住。

#include <signal.h>
#include <setjmp.h>
#include <string.h>

static sigjmp_buf rm_jmp;
static volatile sig_atomic_t rm_hit = 0;
static volatile sig_atomic_t rm_sig = 0;

static void rm_on_signal(int s) {
    rm_hit = 1;
    rm_sig = (sig_atomic_t)s;
    siglongjmp(rm_jmp, 1);
}

void rm_guard_install(void) {
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = rm_on_signal;
    sigemptyset(&sa.sa_mask);
    // SA_ONSTACK：崩溃时栈可能已经不稳，让 handler 走备用栈
    sa.sa_flags = SA_NODEFER | SA_ONSTACK;
    sigaction(SIGSEGV, &sa, NULL);
    sigaction(SIGBUS,  &sa, NULL);
    sigaction(SIGABRT, &sa, NULL);
    sigaction(SIGILL,  &sa, NULL);
    sigaction(SIGFPE,  &sa, NULL);
}

/* 返回 0 = 正常跑完；1 = 被信号打断（崩溃被接住了，调用方必须立刻走错误分支） */
int rm_guard_call(void (*fn)(void *), void *ud) {
    rm_hit = 0;
    rm_sig = 0;
    if (sigsetjmp(rm_jmp, 1) == 0) {
        fn(ud);
        return 0;
    }
    return 1;
}

int rm_guard_hit(void)    { return (int)rm_hit; }
int rm_guard_signal(void) { return (int)rm_sig; }
