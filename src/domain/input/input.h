#ifndef TS_INPUT_H
#define TS_INPUT_H

/*
 * input.h — 输入来源（文件 / 文段）的收集、编码与大小检查、来源编号、分析材料组装。
 *
 * 主要函数：ts_inputs_init / free、ts_inputs_add_file、ts_inputs_add_text、
 * ts_inputs_total_bytes、ts_inputs_build_material。
 */
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum TsSourceKind {
    TS_SOURCE_FILE = 1,
    TS_SOURCE_TEXT = 2
} TsSourceKind;

typedef struct TsInputSource {
    char *text;      /* owned UTF-8（已去除 BOM） */
    size_t len;      /* 字节数（不含结尾 NUL） */
    char *label;     /* owned："文件1" / "文段1" */
    char *detail;    /* owned：文件名或文段说明 */
    TsSourceKind kind;
} TsInputSource;

typedef struct TsInputs {
    TsInputSource *sources; /* owned 数组 */
    size_t source_count;
    size_t file_seq;        /* 内部编号，用于生成"文件N" */
    size_t text_seq;        /* 内部编号，用于生成"文段N" */
} TsInputs;

void ts_inputs_init(TsInputs *in);
void ts_inputs_free(TsInputs *in);

/*
 * 添加一个文件来源。
 * 成功返回 0（追加到 in->sources），失败返回非 0 并写 err。
 * max_bytes 为单文件大小上限（超出报错，不静默截断）。
 */
int ts_inputs_add_file(TsInputs *in, const char *path, long max_bytes,
                       char *err, size_t err_sz);

/*
 * 添加一段直接输入的文本。
 * text 为 UTF-8；detail 可为空（此时用"文段N"作为说明）。
 */
int ts_inputs_add_text(TsInputs *in, const char *text, const char *detail,
                       long max_bytes, char *err, size_t err_sz);

/* 所有来源的总字节数。 */
size_t ts_inputs_total_bytes(const TsInputs *in);

/*
 * 组装发送给模型的分析材料：保留来源编号（文件N/文段N）与段落编号，
 * 段落之间用空行分隔，非空连续行视为同一段落。
 * 成功返回 0（*out 为 owned UTF-8，*out_len 为字节数）；
 * 失败返回非 0 并写 err（含超过 max_bytes 上限时，不静默截断）。
 */
int ts_inputs_build_material(const TsInputs *in, long max_bytes,
                             char **out, size_t *out_len,
                             char *err, size_t err_sz);

#ifdef __cplusplus
}
#endif

#endif /* TS_INPUT_H */

