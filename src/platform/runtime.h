#ifndef TS_RUNTIME_H
#define TS_RUNTIME_H

/*
 * runtime.h — 单调时钟、本地墙钟与可跨线程共享的取消状态。
 *
 * 主要函数：ts_clock_ms、ts_clock_elapsed_ms、ts_clock_wall_iso、
 * ts_cancel_init / begin / gen / request / should_stop / is_requested、ts_sleep_ms。
 */
#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* 返回当前单调时钟毫秒值（绝对，仅用于与 ts_clock_elapsed_ms 配对）。 */
uint64_t ts_clock_ms(void);

/* 返回自 start_ms 以来经过的毫秒数（单调，不会回退）。 */
uint64_t ts_clock_elapsed_ms(uint64_t start_ms);

/*
 * 本地墙钟时间，格式 "YYYY-MM-DD HH:MM:SS"（UTF-8，含结尾 NUL）。
 * 用于导出与日志（sort 时间戳）；不用于计时。
 */
void ts_clock_wall_iso(char *buf, size_t size);

/*
 * 取消状态与请求代号（generation）。
 *
 * - ts_cancel_begin：开始一次新请求，返回新的代号，并清除取消标志。
 * - ts_cancel_request：请求取消当前请求。
 * - ts_cancel_should_stop：后台线程轮询；当“本次请求被取消”或“代号已过期
 *   （已被更新的请求取代）”时返回非 0，用于丢弃迟到结果。
 */
typedef struct TsCancel {
    volatile long generation;        /* 请求代号，随每次 begin 递增 */
    volatile long cancel_requested;  /* 0/1 */
} TsCancel;

void ts_cancel_init(TsCancel *c);
int  ts_cancel_begin(TsCancel *c);
int  ts_cancel_gen(const TsCancel *c);
void ts_cancel_request(TsCancel *c);
int  ts_cancel_should_stop(const TsCancel *c, int generation);

/*
 * 只查询“是否已被请求取消”（不包含“代号已过期”的判断）。
 * 用于“结果提交前”的判定：取消是终态，即使拿到了完整结果也不采纳。
 */
int  ts_cancel_is_requested(const TsCancel *c);

/* 毫秒级睡眠，供重试退避使用（不要用它做精确计时）。 */
void ts_sleep_ms(unsigned ms);

#ifdef __cplusplus
}
#endif

#endif /* TS_RUNTIME_H */

