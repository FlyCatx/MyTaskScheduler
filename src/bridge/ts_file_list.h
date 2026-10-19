/*
 * ts_file_list.h — 多选文件对话框的路径还原：把 OFN_ALLOWMULTISELECT 的
 * 单文件/多文件两种缓冲区格式统一还原成“每行一条完整路径”的 UTF-8 文本。
 *
 * 主要函数：ts_file_list_join。
 */
#ifndef TS_FILE_LIST_H
#define TS_FILE_LIST_H

#include <stddef.h>
#include <wchar.h>

#ifdef __cplusplus
extern "C" {
#endif

/* 成功 */
#define TS_FILE_LIST_OK 0
/* 结果超出上限（选择过多或路径过长） */
#define TS_FILE_LIST_TOO_MANY (-1)
/* 输出编码转换失败 */
#define TS_FILE_LIST_ENCODING (-2)
/* 参数非法 */
#define TS_FILE_LIST_INVALID (-3)

/*
 * 把 [buf, buf+cap) 里的对话框输出转成 UTF-8 文本（由调用方 free）。
 *
 * out_utf8 在成功时指向 malloc 出来的字符串（长度为 0 时也会返回非 NULL 的空串）；
 * 失败时置 NULL。返回上面的 TS_FILE_LIST_* 之一。
 */
int ts_file_list_join(const wchar_t *buf, size_t cap, char **out_utf8);

#ifdef __cplusplus
}
#endif

#endif /* TS_FILE_LIST_H */

