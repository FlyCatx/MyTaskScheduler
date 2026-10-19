/*
 * input.c — 输入来源的收集（BOM 处理、编码与大小检查）与分析材料组装。
 *
 * 主要函数：ts_inputs_add_file、ts_inputs_add_text、ts_inputs_build_material、ts_inputs_free。
 */

#include "input.h"
#include "file_io.h"
#include "mem.h"
#include "text.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

/* ---------- 文件扩展名判断 ---------- */

static const char *path_ext(const char *path)
{
    const char *dot = NULL;
    const char *p;
    if (path == NULL) {
        return NULL;
    }
    for (p = path; *p != '\0'; p++) {
        if (*p == '.') {
            dot = p;
        } else if (*p == '/' || *p == '\\') {
            dot = NULL;
        }
    }
    return (dot != NULL) ? (dot + 1) : NULL;
}

static int is_binary_ext(const char *ext)
{
    static const char *const list[] = {
        "pdf", "docx", "doc", "xlsx", "xls", "pptx", "ppt",
        "png", "jpg", "jpeg", "gif", "bmp", "webp", "ico",
        "zip", "rar", "7z", "tar", "gz",
        "exe", "dll", "bin", "obj", "lib",
        "mp3", "mp4", "mov", "avi", "mkv", "wav",
        NULL
    };
    int i;
    if (ext == NULL) {
        return 0;
    }
    for (i = 0; list[i] != NULL; i++) {
        if (_stricmp(ext, list[i]) == 0) {
            return 1;
        }
    }
    return 0;
}

/* ---------- 生命周期 ---------- */

void ts_inputs_init(TsInputs *in)
{
    if (in != NULL) {
        memset(in, 0, sizeof(*in));
    }
}

void ts_inputs_free(TsInputs *in)
{
    size_t i;
    if (in == NULL) {
        return;
    }
    for (i = 0; i < in->source_count; i++) {
        ts_free(in->sources[i].text);
        ts_free(in->sources[i].label);
        ts_free(in->sources[i].detail);
    }
    ts_free(in->sources);
    memset(in, 0, sizeof(*in));
}

/* ---------- 内部辅助 ---------- */

static int inputs_append(TsInputs *in, TsInputSource src, char *err, size_t err_sz)
{
    size_t newcount;
    size_t bytes;
    TsInputSource *newarr;

    newcount = in->source_count + 1;
    if (ts_mul_overflow(newcount, sizeof(TsInputSource), &bytes)) {
        snprintf(err, err_sz, "来源数量溢出");
        return 1;
    }
    newarr = (TsInputSource *)ts_realloc(in->sources, bytes);
    if (newarr == NULL) {
        snprintf(err, err_sz, "内存分配失败");
        return 1;
    }
    in->sources = newarr;
    in->sources[in->source_count] = src; /* 所有权移交 */
    in->source_count = newcount;
    return 0;
}

static char *make_label(TsSourceKind kind, size_t seq)
{
    char buf[64];
    snprintf(buf, sizeof(buf), kind == TS_SOURCE_FILE ? "文件%zu" : "文段%zu", seq);
    return ts_strdup(buf);
}

/* ---------- 添加文件 ---------- */

int ts_inputs_add_file(TsInputs *in, const char *path, long max_bytes,
                       char *err, size_t err_sz)
{
    unsigned char *raw = NULL;
    size_t raw_len = 0;
    size_t off = 0;
    size_t text_len = 0;
    unsigned char *text = NULL;
    char *label = NULL;
    char *detail = NULL;
    const char *ext;
    TsInputSource src;
    int rc = 1;

    if (in == NULL) {
        return 1;
    }

    ext = path_ext(path);
    if (is_binary_ext(ext)) {
        snprintf(err, err_sz,
                 "首版不支持 %s 格式，请先转换为 UTF-8 文本(.txt/.md)：%s",
                 ext != NULL ? ext : "二进制", path);
        return 1;
    }

    /* 把大小上限交给读取函数：超限会在分配缓冲之前就被拒绝 */
    if (ts_file_read_raw(path, (max_bytes > 0) ? (size_t)max_bytes : 0,
                               &raw, &raw_len, err, err_sz) != 0) {
        return 1;
    }

    /* BOM 处理：UTF-8 BOM 跳过；UTF-16/32 明确拒绝并提示转码。 */
    if (raw_len >= 3 && raw[0] == 0xEF && raw[1] == 0xBB && raw[2] == 0xBF) {
        off = 3;
    } else if (raw_len >= 4 && raw[0] == 0xFF && raw[1] == 0xFE &&
               raw[2] == 0x00 && raw[3] == 0x00) {
        snprintf(err, err_sz, "检测到 UTF-32LE 编码，请转换为 UTF-8：%s", path);
        goto done;
    } else if (raw_len >= 4 && raw[0] == 0x00 && raw[1] == 0x00 &&
               raw[2] == 0xFE && raw[3] == 0xFF) {
        snprintf(err, err_sz, "检测到 UTF-32BE 编码，请转换为 UTF-8：%s", path);
        goto done;
    } else if (raw_len >= 2 && raw[0] == 0xFF && raw[1] == 0xFE) {
        snprintf(err, err_sz, "检测到 UTF-16LE 编码，请转换为 UTF-8：%s", path);
        goto done;
    } else if (raw_len >= 2 && raw[0] == 0xFE && raw[1] == 0xFF) {
        snprintf(err, err_sz, "检测到 UTF-16BE 编码，请转换为 UTF-8：%s", path);
        goto done;
    }

    text_len = raw_len - off;
    if (text_len == 0) {
        snprintf(err, err_sz, "文件内容为空：%s", path);
        goto done;
    }
    if (max_bytes > 0 && text_len > (size_t)max_bytes) {
        snprintf(err, err_sz,
                 "文件超过大小上限(%zu 字节)，未截断：%s（实际 %zu 字节）",
                 (size_t)max_bytes, path, text_len);
        goto done;
    }
    if (!ts_utf8_valid(raw + off, text_len)) {
        snprintf(err, err_sz, "文件包含无效 UTF-8 编码，请转换为 UTF-8：%s", path);
        goto done;
    }

    text = (unsigned char *)ts_malloc(text_len + 1);
    if (text == NULL) {
        snprintf(err, err_sz, "内存分配失败");
        goto done;
    }
    memcpy(text, raw + off, text_len);
    text[text_len] = '\0';

    label = make_label(TS_SOURCE_FILE, in->file_seq + 1);
    detail = ts_strdup(path);
    if (label == NULL || detail == NULL) {
        snprintf(err, err_sz, "内存分配失败");
        goto done;
    }

    src.text = (char *)text;
    src.len = text_len;
    src.label = label;
    src.detail = detail;
    src.kind = TS_SOURCE_FILE;

    if (inputs_append(in, src, err, err_sz) != 0) {
        goto done;
    }

    in->file_seq++;
    text = NULL;   /* 所有权已移交 */
    label = NULL;
    detail = NULL;
    rc = 0;

done:
    ts_free(raw);
    ts_free(text);
    ts_free(label);
    ts_free(detail);
    return rc;
}

/* ---------- 添加文段 ---------- */

int ts_inputs_add_text(TsInputs *in, const char *text, const char *detail,
                       long max_bytes, char *err, size_t err_sz)
{
    size_t len;
    char *copy = NULL;
    char *label = NULL;
    char *det = NULL;
    TsInputSource src;
    int rc = 1;

    if (in == NULL) {
        return 1;
    }
    if (text == NULL) {
        text = "";
    }
    len = strlen(text);

    if (len == 0) {
        snprintf(err, err_sz, "输入文段为空");
        return 1;
    }
    if (max_bytes > 0 && len > (size_t)max_bytes) {
        snprintf(err, err_sz,
                 "文段超过大小上限(%zu 字节)，未截断（实际 %zu 字节）",
                 (size_t)max_bytes, len);
        return 1;
    }
    if (!ts_utf8_valid((const unsigned char *)text, len)) {
        snprintf(err, err_sz, "文段包含无效 UTF-8 编码");
        return 1;
    }

    copy = ts_strdup(text);
    label = make_label(TS_SOURCE_TEXT, in->text_seq + 1);
    det = (detail != NULL && detail[0] != '\0') ? ts_strdup(detail) : ts_strdup(label);
    if (copy == NULL || label == NULL || det == NULL) {
        snprintf(err, err_sz, "内存分配失败");
        goto done;
    }

    src.text = copy;
    src.len = len;
    src.label = label;
    src.detail = det;
    src.kind = TS_SOURCE_TEXT;

    if (inputs_append(in, src, err, err_sz) != 0) {
        goto done;
    }

    in->text_seq++;
    copy = NULL;
    label = NULL;
    det = NULL;
    rc = 0;

done:
    ts_free(copy);
    ts_free(label);
    ts_free(det);
    return rc;
}

/* ---------- 汇总 ---------- */

size_t ts_inputs_total_bytes(const TsInputs *in)
{
    size_t i, total = 0;
    if (in == NULL) {
        return 0;
    }
    for (i = 0; i < in->source_count; i++) {
        total += in->sources[i].len;
    }
    return total;
}

/* ---------- 分析材料组装（来源编号 + 段落编号） ---------- */

static const char *line_scan(const char *p, const char *end,
                             const char **nl_out, int *blank_out)
{
    const char *nl = (const char *)memchr(p, '\n', (size_t)(end - p));
    const char *line_end = (nl != NULL) ? nl : end;
    const char *q;
    int blank = 1;

    while (line_end > p && line_end[-1] == '\r') line_end--;
    for (q = p; q < line_end; q++) {
        if (*q != ' ' && *q != '\t' && *q != '\r') { blank = 0; break; }
    }
    *nl_out = nl;
    *blank_out = blank;
    return line_end;
}

static int material_size_check(const TsBuf *b, long max_bytes, char *err, size_t err_sz)
{
    if (max_bytes > 0 && b->len > (size_t)max_bytes) {
        snprintf(err, err_sz,
                 "分析材料超过输入上限(%ld 字节)，未截断；请减少输入文件或文段", max_bytes);
        return 1;
    }
    return 0;
}

/* 非空连续行构成一个段落；空行分隔段落。段落带 [来源 段落N] 编号。 */
static int append_source_material(TsBuf *b, const TsInputSource *s,
                                  long max_bytes, char *err, size_t err_sz)
{
    const char *p = s->text;
    const char *end = s->text + s->len;
    size_t para_no = 0;

    if (ts_buf_printf(b, "\n===== %s：%s =====\n",
                      s->label, (s->detail != NULL) ? s->detail : s->label) != 0) {
        snprintf(err, err_sz, "内存分配失败");
        return 1;
    }

    while (p < end) {
        const char *nl = NULL;
        const char *line_end;
        int blank = 0;
        const char *block_start;
        const char *block_end;

        line_end = line_scan(p, end, &nl, &blank);
        if (blank) {
            p = (nl != NULL) ? (nl + 1) : end;
            continue;
        }
        block_start = p;
        block_end = line_end;
        p = (nl != NULL) ? (nl + 1) : end;

        while (p < end) {
            line_end = line_scan(p, end, &nl, &blank);
            if (blank) {
                p = (nl != NULL) ? (nl + 1) : end;
                break;
            }
            block_end = line_end;
            p = (nl != NULL) ? (nl + 1) : end;
        }

        para_no++;
        if (ts_buf_printf(b, "\n[%s 段落%zu]\n", s->label, para_no) != 0 ||
            ts_buf_append(b, block_start, (size_t)(block_end - block_start)) != 0 ||
            ts_buf_puts(b, "\n") != 0) {
            snprintf(err, err_sz, "内存分配失败");
            return 1;
        }
        if (material_size_check(b, max_bytes, err, err_sz) != 0) {
            return 1;
        }
    }
    return 0;
}

int ts_inputs_build_material(const TsInputs *in, long max_bytes,
                             char **out, size_t *out_len,
                             char *err, size_t err_sz)
{
    TsBuf b;
    size_t i;

    if (out == NULL) {
        snprintf(err, err_sz, "输出参数为空");
        return 1;
    }
    *out = NULL;
    if (out_len != NULL) *out_len = 0;
    ts_buf_init(&b);

    if (in == NULL || in->source_count == 0) {
        snprintf(err, err_sz, "没有任何输入来源（文件或文段）");
        return 1;
    }

    for (i = 0; i < in->source_count; i++) {
        if (append_source_material(&b, &in->sources[i], max_bytes, err, err_sz) != 0) {
            ts_buf_free(&b);
            return 1;
        }
        if (material_size_check(&b, max_bytes, err, err_sz) != 0) {
            ts_buf_free(&b);
            return 1;
        }
    }

    if (b.len == 0) {
        snprintf(err, err_sz, "分析材料为空");
        ts_buf_free(&b);
        return 1;
    }

    *out = b.data;
    if (out_len != NULL) *out_len = b.len;
    return 0;
}

