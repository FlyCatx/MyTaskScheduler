/*
 * file_io.c — 按 UTF-8 路径整份读取文件原始字节，大小上限在分配缓冲之前检查。
 *
 * 主要函数：ts_file_read_raw。
 */

#include "file_io.h"

#include "mem.h"
#include "text.h"

#include <stdio.h>
#include <string.h>

/*
 * 读取整个文件到新分配的缓冲；大小上限在分配缓冲之前检查，
 * 因此“选择了一个大文件”不会先按真实大小分配内存。
 */
int ts_file_read_raw(const char *path, size_t max_bytes,
                     unsigned char **out, size_t *out_len,
                     char *err, size_t err_sz)
{
    wchar_t *wpath = NULL;
    size_t wlen = 0;
    FILE *f = NULL;
    long long sz;
    size_t size_bytes;
    unsigned char *buf = NULL;
    size_t n;

    if (out != NULL) *out = NULL;
    if (out_len != NULL) *out_len = 0;

    if (path == NULL || path[0] == '\0') {
        snprintf(err, err_sz, "文件路径为空");
        return 1;
    }
    wpath = ts_utf8_to_wide(path, strlen(path), &wlen);
    if (wpath == NULL) {
        snprintf(err, err_sz, "文件路径编码转换失败：%s", path);
        return 1;
    }

    f = _wfopen(wpath, L"rb");
    if (f == NULL) {
        snprintf(err, err_sz, "无法打开文件：%s", path);
        ts_free(wpath);
        return 1;
    }

    if (_fseeki64(f, 0, SEEK_END) != 0) {
        snprintf(err, err_sz, "无法定位文件末尾：%s", path);
        goto fail;
    }
    sz = _ftelli64(f);
    if (sz < 0) {
        snprintf(err, err_sz, "无法获取文件大小：%s", path);
        goto fail;
    }
    if (_fseeki64(f, 0, SEEK_SET) != 0) {
        snprintf(err, err_sz, "无法定位文件开头：%s", path);
        goto fail;
    }

    /* 用 size_t 比较，避免 (long) 窄化。 */
    if ((unsigned long long)sz > (unsigned long long)(SIZE_MAX - 1)) {
        snprintf(err, err_sz, "文件过大，无法读取：%s", path);
        goto fail;
    }
    size_bytes = (size_t)sz;
    if (max_bytes > 0 && size_bytes > max_bytes) {
        snprintf(err, err_sz,
                 "文件超过大小上限(%zu 字节)，未读取也未截断：%s（实际 %zu 字节）",
                 max_bytes, path, size_bytes);
        goto fail;
    }

    buf = (unsigned char *)ts_malloc(size_bytes + 1);
    if (buf == NULL) {
        snprintf(err, err_sz, "内存分配失败");
        goto fail;
    }

    n = fread(buf, 1, size_bytes, f);
    if (n != size_bytes) {
        snprintf(err, err_sz, "读取文件失败：%s", path);
        goto fail;
    }
    buf[size_bytes] = '\0';

    fclose(f);
    ts_free(wpath);
    if (out != NULL) *out = buf;
    if (out_len != NULL) *out_len = size_bytes;
    return 0;

fail:
    if (f != NULL) {
        fclose(f);
    }
    ts_free(wpath);
    ts_free(buf);
    return 1;
}

