/*
 * ts_pick_filter.h — 系统“打开文件”对话框的筛选器定义（纯数据，可离线测试）。
 *
 * 为什么单独抽出来：GetOpenFileNameW 的过滤器是双 NUL 结尾的宽字符串，
 * 拼错一个分隔符就会让整张过滤列表失效；把 kind → 过滤器映射固定成常量后，
 * C 测试可以逐项检查扩展名与显示名，Dart 侧只需要传一个确定的 kind。
 *
 * 主要函数：ts_pick_filter_spec。
 */
#ifndef TS_PICK_FILTER_H
#define TS_PICK_FILTER_H

#include <wchar.h>

#ifdef __cplusplus
extern "C" {
#endif

/* 通用文档选择（0.4.0 的既有行为，旧 ts_bridge_pick_file 转发 0）。 */
#define TS_PICK_FILTER_DOCUMENT 0
/* OCR 专用：PDF / PNG / JPG / JPEG（显示名与扩展名一致）。 */
#define TS_PICK_FILTER_OCR 1
/* 日历文件：ICS / ICAL。 */
#define TS_PICK_FILTER_CALENDAR 2

/*
 * 一个 kind 对应的对话框参数。
 *   filter        —— lpstrFilter，双 NUL 结尾（整个字符串以 "\0\0" 结束）
 *   default_ext   —— lpstrDefExt（用户输入不带扩展名的文件名时补全），可为 NULL
 *   default_title —— lpstrTitle 缺省值
 *   kind          —— 规范化后的 kind 值
 */
typedef struct TsPickFilterSpec {
    const wchar_t *filter;
    const wchar_t *default_ext;
    const wchar_t *default_title;
    int kind;
} TsPickFilterSpec;

/*
 * 返回 kind 对应的只读定义；未知 kind（含负数）返回 NULL。
 * 返回的指针指向静态常量，不归调用方释放。
 */
const TsPickFilterSpec *ts_pick_filter_spec(int filter_kind);

#ifdef __cplusplus
}
#endif

#endif /* TS_PICK_FILTER_H */
