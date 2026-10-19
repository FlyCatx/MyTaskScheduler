/*
 * runtime.c — 单调时钟、本地墙钟与可跨线程共享的取消状态。
 *
 * 主要函数：ts_clock_ms、ts_clock_elapsed_ms、ts_clock_wall_iso、ts_cancel_*、ts_sleep_ms。
 */

#include "runtime.h"

#include <stdio.h>

#define WIN32_LEAN_AND_MEAN
#include <windows.h>

static LARGE_INTEGER g_qpc_freq = { 0 };

/*
 * 频率只需读取一次，但 ts_clock_ms() 会被 GUI 定时器与工作线程并发调用，
 * 因此用 Windows 的 InitOnce 做线程安全的一次性初始化
 * （避免“直接读 + Interlocked 写”的双重检查竞态）。
 */
/*
 * 注意：InitOnceExecuteOnce 的 *Context 低 INIT_ONCE_CTX_RESERVED_BITS(=2) 位由系统保留，
 * 不能写入小整数（实测写 1/2/3 会导致进程以 0xC00000F1 终止）。这里不写 *Context。
 */
static BOOL CALLBACK qpc_freq_init(PINIT_ONCE once, PVOID param, PVOID *ctx)
{
    LARGE_INTEGER f;
    (void)once;
    (void)param;
    (void)ctx;  /* 绝不写入 */
    QueryPerformanceFrequency(&f);
    g_qpc_freq.QuadPart = (f.QuadPart > 0) ? f.QuadPart : 1;
    return TRUE;
}

uint64_t ts_clock_ms(void)
{
    static INIT_ONCE once = INIT_ONCE_STATIC_INIT;
    PVOID context = NULL;
    LARGE_INTEGER counter;

    InitOnceExecuteOnce(&once, qpc_freq_init, NULL, &context);
    QueryPerformanceCounter(&counter);
    /* counter.QuadPart 为 64 位计数；*1000 在合理运行时长内不会溢出 int64。 */
    return (uint64_t)((counter.QuadPart * 1000) / g_qpc_freq.QuadPart);
}

uint64_t ts_clock_elapsed_ms(uint64_t start_ms)
{
    uint64_t now = ts_clock_ms();
    return now >= start_ms ? (now - start_ms) : 0;
}

void ts_clock_wall_iso(char *buf, size_t size)
{
    SYSTEMTIME st;
    if (buf == NULL || size == 0) {
        return;
    }
    GetLocalTime(&st);
    _snprintf_s(buf, size, _TRUNCATE, "%04d-%02d-%02d %02d:%02d:%02d",
                (int)st.wYear, (int)st.wMonth, (int)st.wDay,
                (int)st.wHour, (int)st.wMinute, (int)st.wSecond);
}

void ts_cancel_init(TsCancel *c)
{
    if (c == NULL) {
        return;
    }
    c->generation = 0;
    c->cancel_requested = 0;
}

int ts_cancel_begin(TsCancel *c)
{
    if (c == NULL) {
        return 0;
    }
    InterlockedExchange(&c->cancel_requested, 0);
    return (int)InterlockedIncrement(&c->generation);
}

int ts_cancel_gen(const TsCancel *c)
{
    if (c == NULL) {
        return 0;
    }
    return (int)c->generation;
}

void ts_cancel_request(TsCancel *c)
{
    if (c != NULL) {
        InterlockedExchange(&c->cancel_requested, 1);
    }
}

int ts_cancel_should_stop(const TsCancel *c, int generation)
{
    if (c == NULL) {
        return 0;
    }
    return (c->cancel_requested != 0) || (generation != (int)c->generation);
}

int ts_cancel_is_requested(const TsCancel *c)
{
    return (c != NULL) ? (c->cancel_requested != 0) : 0;
}

void ts_sleep_ms(unsigned ms)
{
    Sleep((DWORD)ms);
}

