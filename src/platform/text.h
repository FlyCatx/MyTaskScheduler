#ifndef TS_TEXT_H
#define TS_TEXT_H

/*
 * text.h — UTF-8 校验与 UTF-8 <-> UTF-16 转换（Windows API 实现）。
 *
 * 主要函数：ts_utf8_valid、ts_utf8_to_wide、ts_wide_to_utf8。
 */
#include <stddef.h>
#include <wchar.h>

#ifdef __cplusplus
extern "C" {
#endif

/* 校验 len 字节是否为严格合法的 UTF-8（RFC 3629，拒绝过长编码与代理区）。 */
int ts_utf8_valid(const unsigned char *s, size_t len);

/*
 * UTF-8 -> UTF-16（宽字符串，含结尾 NUL）。
 * 成功返回 malloc 分配的 wchar_t*（调用方用 ts_free 释放），并写 *out_wchars（不含 NUL）。
 * 失败返回 NULL。
 */
wchar_t *ts_utf8_to_wide(const char *s, size_t len, size_t *out_wchars);

/*
 * UTF-16 -> UTF-8（含结尾 NUL）。
 * 成功返回 malloc 分配的 char*（调用方用 ts_free 释放）。
 * 失败返回 NULL。
 */
char *ts_wide_to_utf8(const wchar_t *s, size_t len);

#ifdef __cplusplus
}
#endif

#endif /* TS_TEXT_H */

