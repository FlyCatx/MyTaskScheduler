#ifndef TS_MEM_H
#define TS_MEM_H

/*
 * mem.h — 内存与缓冲基础能力：带溢出检查的分配、字符串复制、敏感内容安全释放、可增长字节缓冲。
 *
 * 主要类型/函数：ts_malloc / ts_calloc / ts_realloc、ts_strdup / ts_strndup、
 * ts_free / ts_secure_free、TsBuf 及其 ts_buf_append / ts_buf_puts / ts_buf_printf。
 */
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdio.h>
#include <stdarg.h>

/* 检查 a*b 是否溢出 size_t；溢出返回 1 并置 out=0，否则返回 0 并写 out。 */
static inline int ts_mul_overflow(size_t a, size_t b, size_t *out)
{
    if (b != 0 && a > SIZE_MAX / b) {
        *out = 0;
        return 1;
    }
    *out = a * b;
    return 0;
}

/* 检查 a+b 是否溢出 size_t。 */
static inline int ts_add_overflow(size_t a, size_t b, size_t *out)
{
    if (b > SIZE_MAX - a) {
        *out = 0;
        return 1;
    }
    *out = a + b;
    return 0;
}

static inline void *ts_malloc(size_t n)
{
    return n == 0 ? NULL : malloc(n);
}

static inline void *ts_calloc(size_t n, size_t sz)
{
    size_t total;
    if (ts_mul_overflow(n, sz, &total)) {
        return NULL;
    }
    return calloc(n, sz);
}

static inline void *ts_realloc(void *p, size_t n)
{
    return realloc(p, n);
}

static inline char *ts_strdup(const char *s)
{
    size_t n;
    char *d;
    if (s == NULL) {
        return NULL;
    }
    n = strlen(s) + 1;
    d = (char *)malloc(n);
    if (d != NULL) {
        memcpy(d, s, n);
    }
    return d;
}

/* 复制至多 n 字节并追加 NUL。 */
static inline char *ts_strndup(const char *s, size_t n)
{
    char *d = (char *)malloc(n + 1);
    if (d != NULL) {
        memcpy(d, s, n);
        d[n] = '\0';
    }
    return d;
}

static inline void ts_free(void *p)
{
    free(p);
}

/* 敏感字符串释放：先把内容清零（volatile 写，编译器不会优化掉）再 free，并置空指针。 */
static inline void ts_secure_free(char **p)
{
    if (p == NULL || *p == NULL) {
        return;
    }
    {
        volatile char *v = (volatile char *)*p;
        size_t n = strlen(*p);
        size_t i;
        for (i = 0; i < n; i++) v[i] = 0;
    }
    free(*p);
    *p = NULL;
}

/* ------------------------------------------------------------------ */
/* 可增长字节缓冲（UTF-8 文本拼接）。所有 append 失败时返回非 0，缓冲仍可用。 */
/* ------------------------------------------------------------------ */

typedef struct TsBuf {
    char *data;   /* 始终以 NUL 结尾（若非 NULL） */
    size_t len;
    size_t cap;
} TsBuf;

static inline void ts_buf_init(TsBuf *b)
{
    b->data = NULL;
    b->len = 0;
    b->cap = 0;
}

static inline void ts_buf_free(TsBuf *b)
{
    free(b->data);
    b->data = NULL;
    b->len = 0;
    b->cap = 0;
}

/* 确保还能追加 extra 字节（外加结尾 NUL）。 */
static inline int ts_buf_reserve(TsBuf *b, size_t extra)
{
    size_t need, ncap;
    if (ts_add_overflow(b->len, extra, &need)) return 1;
    if (ts_add_overflow(need, 1, &need)) return 1;
    if (need <= b->cap) return 0;
    ncap = b->cap ? b->cap : 256;
    while (ncap < need) {
        size_t nn;
        if (ts_mul_overflow(ncap, 2, &nn)) return 1;
        ncap = nn;
    }
    {
        char *nd = (char *)realloc(b->data, ncap);
        if (nd == NULL) return 1;
        b->data = nd;
        b->cap = ncap;
    }
    if (b->len == 0) b->data[0] = '\0';
    return 0;
}

static inline int ts_buf_append(TsBuf *b, const char *s, size_t n)
{
    if (n == 0) return 0;
    if (ts_buf_reserve(b, n)) return 1;
    memcpy(b->data + b->len, s, n);
    b->len += n;
    b->data[b->len] = '\0';
    return 0;
}

static inline int ts_buf_puts(TsBuf *b, const char *s)
{
    return ts_buf_append(b, s, strlen(s));
}

static inline int ts_buf_printf(TsBuf *b, const char *fmt, ...)
{
    va_list ap;
    int need;
    va_start(ap, fmt);
    need = vsnprintf(NULL, 0, fmt, ap);
    va_end(ap);
    if (need < 0) return 1;
    if (ts_buf_reserve(b, (size_t)need)) return 1;
    va_start(ap, fmt);
    vsnprintf(b->data + b->len, (size_t)need + 1, fmt, ap);
    va_end(ap);
    b->len += (size_t)need;
    return 0;
}

#endif /* TS_MEM_H */

