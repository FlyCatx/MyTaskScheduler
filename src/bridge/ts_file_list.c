/*
 * ts_file_list.c — 多选文件对话框的路径还原。
 *
 * 主要函数：ts_file_list_join。
 */

#include "ts_file_list.h"

#include <stdlib.h>
#include <string.h>

#include <windows.h>

/* 拼接结果的字符上限（宽字符个数）。 */
#define TS_FILE_LIST_MAX_WCHARS 16384

static int append_wide(wchar_t *dst, size_t cap, size_t *used, const wchar_t *src)
{
    size_t n = wcslen(src);
    if (n == 0) return 0;
    if (*used + n + 1 > cap) return -1;
    memcpy(dst + *used, src, (n + 1) * sizeof(wchar_t));
    *used += n;
    return 0;
}

static int append_char(wchar_t *dst, size_t cap, size_t *used, wchar_t ch)
{
    if (*used + 2 > cap) return -1;
    dst[*used] = ch;
    dst[*used + 1] = L'\0';
    (*used)++;
    return 0;
}

int ts_file_list_join(const wchar_t *buf, size_t cap, char **out_utf8)
{
    wchar_t joined[TS_FILE_LIST_MAX_WCHARS];
    size_t used = 0;
    size_t dir_len;
    const wchar_t *names;
    int rc;

    if (out_utf8 == NULL) return TS_FILE_LIST_INVALID;
    *out_utf8 = NULL;
    if (buf == NULL || cap == 0) return TS_FILE_LIST_INVALID;

    memset(joined, 0, sizeof(joined));
    dir_len = wcsnlen(buf, cap);
    if (dir_len >= cap) return TS_FILE_LIST_INVALID;

    if (dir_len + 1 >= cap || buf[dir_len + 1] == L'\0') {
        /* 单选：整个缓冲区就是一条完整路径。 */
        rc = append_wide(joined, TS_FILE_LIST_MAX_WCHARS, &used, buf);
        if (rc != 0) return TS_FILE_LIST_TOO_MANY;
    } else {
        /* 多选：目录 + '\0' + 文件名 + '\0' …，用 '\n' 分隔还原完整路径。 */
        names = buf + dir_len + 1;
        while (names[0] != L'\0') {
            const size_t name_len = wcsnlen(names, cap - (size_t)(names - buf));
            if (name_len == 0) break;
            if (used > 0 && append_char(joined, TS_FILE_LIST_MAX_WCHARS, &used, L'\n') != 0) {
                return TS_FILE_LIST_TOO_MANY;
            }
            if (append_wide(joined, TS_FILE_LIST_MAX_WCHARS, &used, buf) != 0) {
                return TS_FILE_LIST_TOO_MANY;
            }
            if (used > 0 && joined[used - 1] != L'\\' && joined[used - 1] != L'/') {
                if (append_char(joined, TS_FILE_LIST_MAX_WCHARS, &used, L'\\') != 0) {
                    return TS_FILE_LIST_TOO_MANY;
                }
            }
            {
                wchar_t name_buf[512];
                size_t copy = name_len;
                if (copy >= sizeof(name_buf) / sizeof(name_buf[0])) {
                    copy = sizeof(name_buf) / sizeof(name_buf[0]) - 1;
                }
                memcpy(name_buf, names, copy * sizeof(wchar_t));
                name_buf[copy] = L'\0';
                if (append_wide(joined, TS_FILE_LIST_MAX_WCHARS, &used, name_buf) != 0) {
                    return TS_FILE_LIST_TOO_MANY;
                }
            }
            names += name_len + 1;
        }
    }

    {
        int n = WideCharToMultiByte(CP_UTF8, 0, joined, -1, NULL, 0, NULL, NULL);
        char *out;
        if (n <= 0) return TS_FILE_LIST_ENCODING;
        out = (char *)malloc((size_t)n);
        if (out == NULL) return TS_FILE_LIST_ENCODING;
        if (WideCharToMultiByte(CP_UTF8, 0, joined, -1, out, n, NULL, NULL) <= 0) {
            free(out);
            return TS_FILE_LIST_ENCODING;
        }
        *out_utf8 = out;
    }
    return TS_FILE_LIST_OK;
}

