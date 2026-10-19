/*
 * test_initonce.c — 验证 InitOnce 一次性初始化（审查报告 P1 的修复）。
 *
 * 背景：早期实现把整数 1 写进 InitOnceExecuteOnce 的 *Context 来报告“初始化成功”。
 * 该值的低位是系统保留位（INIT_ONCE_CTX_RESERVED_BITS），实测写入 1/2/3 会让进程
 * 以 0xC00000F1 直接终止（build/repro_initonce*.c 曾复现）。真实 HTTP 路径在调用
 * libcurl 之前就会执行这段初始化，因此每次真实请求都会崩溃。
 * 修复：不写 *Context，改用【回调返回值】报告成功/失败。
 *
 * 本测试覆盖：
 *  1) ts_clock_ms() 在多线程并发首次调用时只初始化一次，且单调不回退；
 *  2) 采用“回调返回值”写法时，回调只执行一次且 *Context 保持为空；
 *  3) 回调返回 FALSE 时 InitOnceExecuteOnce 返回 FALSE，并允许后续重试。
 */

#include <windows.h>
#include <stdio.h>
#include <string.h>

#include "../src/platform/runtime.h"

static int g_fail = 0;

#define CHECK(cond, msg) do {                                   \
    if (cond) { printf("  [PASS] %s\n", msg); }                 \
    else      { printf("  [FAIL] %s\n", msg); g_fail++; }       \
} while (0)

static volatile LONG g_clock_regressions = 0;

static DWORD WINAPI clock_thread(LPVOID param)
{
    int i;
    LONGLONG prev = 0;
    (void)param;
    for (i = 0; i < 50000; i++) {
        LONGLONG t = (LONGLONG)ts_clock_ms();
        if (t < prev) {
            InterlockedIncrement(&g_clock_regressions);
        }
        prev = t;
    }
    return 0;
}

/* 与 runtime.c / model.c 修复后一致的写法：绝不写 *Context */
static volatile LONG g_ok_calls = 0;

static BOOL CALLBACK ok_cb(PINIT_ONCE once, PVOID param, PVOID *ctx)
{
    (void)once;
    (void)param;
    (void)ctx;
    InterlockedIncrement(&g_ok_calls);
    return TRUE;
}

static volatile LONG g_fail_calls = 0;

static BOOL CALLBACK fail_cb(PINIT_ONCE once, PVOID param, PVOID *ctx)
{
    (void)once;
    (void)param;
    (void)ctx;
    InterlockedIncrement(&g_fail_calls);
    return FALSE;
}

int main(void)
{
    setvbuf(stdout, NULL, _IONBF, 0);
    printf("=== TaskScheduler InitOnce 测试 ===\n\n");

    printf("== 并发首次调用 ts_clock_ms ==\n");
    {
        HANDLE th[8];
        int i;
        for (i = 0; i < 8; i++) {
            th[i] = CreateThread(NULL, 0, clock_thread, NULL, 0, NULL);
        }
        for (i = 0; i < 8; i++) {
            if (th[i] != NULL) {
                WaitForSingleObject(th[i], 30000);
                CloseHandle(th[i]);
            } else {
                g_fail++;
                printf("  [FAIL] 创建线程 %d 失败\n", i);
            }
        }
        CHECK(g_clock_regressions == 0, "多线程并发下单调时钟不回退（InitOnce 只初始化一次）");
        CHECK(ts_clock_ms() > 0, "时钟返回有效值");
    }

    printf("== 回调返回值报告成功（修复后的写法） ==\n");
    {
        static INIT_ONCE once = INIT_ONCE_STATIC_INIT;
        PVOID ctx1 = NULL;
        PVOID ctx2 = NULL;
        BOOL r1 = InitOnceExecuteOnce(&once, ok_cb, NULL, &ctx1);
        BOOL r2 = InitOnceExecuteOnce(&once, ok_cb, NULL, &ctx2);
        CHECK(r1 && r2, "两次调用都返回 TRUE");
        CHECK(g_ok_calls == 1, "回调只被执行一次");
        CHECK(ctx1 == NULL && ctx2 == NULL, "未写入 *Context（低位保留位保持为零）");
    }

    printf("== 回调返回 FALSE 的语义 ==\n");
    {
        static INIT_ONCE once = INIT_ONCE_STATIC_INIT;
        PVOID ctx = NULL;
        BOOL r1 = InitOnceExecuteOnce(&once, fail_cb, NULL, &ctx);
        CHECK(!r1, "回调返回 FALSE 时 InitOnceExecuteOnce 返回 FALSE");
        CHECK(g_fail_calls == 1, "失败回调被调用一次");
        (void)InitOnceExecuteOnce(&once, fail_cb, NULL, &ctx);
        CHECK(g_fail_calls == 2, "失败后可重试（回调再次被调用）");
    }

    printf("\n=== 结果：%s（失败 %d 项）===\n",
           g_fail == 0 ? "全部通过" : "存在失败", g_fail);
    return g_fail == 0 ? 0 : 1;
}

