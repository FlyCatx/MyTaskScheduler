#ifndef TS_FILE_IO_H
#define TS_FILE_IO_H

/*
 * file_io.h — 平台文件读取：按 UTF-8 路径整份读入原始字节。
 *
 * 主要函数：
 *   ts_file_read_raw：按路径读取整个文件（含结尾 NUL），不做编码校验。
 *
 * 被 state/config.c（读取配置文件）与 domain/input/input.c（读取材料文件）复用。
 */

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * 以原始字节读取整个文件到 *out（含结尾 NUL），不校验编码。
 *
 * max_bytes > 0 时，会**在分配缓冲之前**先按文件大小拒绝超限文件
 * （避免为大文件分配内存）；max_bytes == 0 表示不限制。
 * 成功返回 0，写 *out（调用方用 ts_free 释放）与 *out_len；失败返回非 0 并写 err。
 */
int ts_file_read_raw(const char *path, size_t max_bytes,
                     unsigned char **out, size_t *out_len,
                     char *err, size_t err_sz);

#ifdef __cplusplus
}
#endif

#endif /* TS_FILE_IO_H */

