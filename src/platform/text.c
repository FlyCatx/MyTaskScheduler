/*
 * text.c — UTF-8 校验与 UTF-8 <-> UTF-16 转换。
 *
 * 主要函数：ts_utf8_valid、ts_utf8_to_wide、ts_wide_to_utf8。
 */

#include "text.h"
#include "mem.h"

#include <limits.h>

#define WIN32_LEAN_AND_MEAN
#include <windows.h>

/* 严格 UTF-8 校验（RFC 3629）。返回 1 合法，0 非法。 */
int ts_utf8_valid(const unsigned char *s, size_t len)
{
    size_t i = 0;
    if (s == NULL) {
        return len == 0;
    }
    while (i < len) {
        unsigned char c = s[i];
        if (c < 0x80) {
            i += 1;
            continue;
        } else if ((c & 0xE0) == 0xC0) {
            /* 2 字节：U+0080..U+07FF，首字节 C2..DF */
            if (c < 0xC2 || i + 1 >= len) return 0;
            if ((s[i + 1] & 0xC0) != 0x80) return 0;
            i += 2;
        } else if ((c & 0xF0) == 0xE0) {
            /* 3 字节：U+0800..U+FFFF，排除代理区 U+D800..U+DFFF */
            unsigned char c1, c2;
            if (i + 2 >= len) return 0;
            c1 = s[i + 1];
            c2 = s[i + 2];
            if ((c1 & 0xC0) != 0x80 || (c2 & 0xC0) != 0x80) return 0;
            if (c == 0xE0 && c1 < 0xA0) return 0;            /* 过长编码 */
            if (c == 0xED && c1 > 0x9F) return 0;            /* 代理区 U+D800..U+DFFF */
            i += 3;
        } else if ((c & 0xF8) == 0xF0) {
            /* 4 字节：U+10000..U+10FFFF */
            unsigned char c1, c2, c3;
            if (i + 3 >= len) return 0;
            c1 = s[i + 1];
            c2 = s[i + 2];
            c3 = s[i + 3];
            if ((c1 & 0xC0) != 0x80 || (c2 & 0xC0) != 0x80 || (c3 & 0xC0) != 0x80) return 0;
            if (c == 0xF0 && c1 < 0x90) return 0;            /* 过长编码 */
            if (c == 0xF4 && c1 > 0x8F) return 0;            /* 超过 U+10FFFF */
            i += 4;
        } else {
            return 0;
        }
    }
    return 1;
}

wchar_t *ts_utf8_to_wide(const char *s, size_t len, size_t *out_wchars)
{
    int need;
    wchar_t *w;
    int converted;

    if (out_wchars != NULL) {
        *out_wchars = 0;
    }
    if (s == NULL) {
        return NULL;
    }
    if (len > (size_t)INT_MAX) {
        return NULL;
    }
    need = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, s, (int)len, NULL, 0);
    if (need <= 0) {
        return NULL;
    }
    w = (wchar_t *)ts_malloc(((size_t)need + 1) * sizeof(wchar_t));
    if (w == NULL) {
        return NULL;
    }
    converted = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, s, (int)len, w, need);
    if (converted <= 0) {
        ts_free(w);
        return NULL;
    }
    w[converted] = L'\0';
    if (out_wchars != NULL) {
        *out_wchars = (size_t)converted;
    }
    return w;
}

char *ts_wide_to_utf8(const wchar_t *s, size_t len)
{
    int need;
    char *u;
    int converted;

    if (s == NULL) {
        return NULL;
    }
    if (len > (size_t)INT_MAX) {
        return NULL;
    }
    need = WideCharToMultiByte(CP_UTF8, 0, s, (int)len, NULL, 0, NULL, NULL);
    if (need <= 0) {
        return NULL;
    }
    u = (char *)ts_malloc((size_t)need + 1);
    if (u == NULL) {
        return NULL;
    }
    converted = WideCharToMultiByte(CP_UTF8, 0, s, (int)len, u, need, NULL, NULL);
    if (converted <= 0) {
        ts_free(u);
        return NULL;
    }
    u[converted] = '\0';
    return u;
}

