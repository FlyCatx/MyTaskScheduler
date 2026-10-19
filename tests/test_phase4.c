/*
 * test_phase4.c — 阶段 4 控制台测试（不依赖 cJSON / libcurl）。
 *
 * 覆盖“分析材料组装”：来源编号（文件N/文段N）与段落编号、空行分隔段落、
 * CRLF 处理、输入上限（不静默截断）、空输入报错。
 *
 * 提示词正文与请求构造（依赖 cJSON）由 tests/validate_prompt.py 做静态校验。
 */

#include "../src/domain/types.h"
#include "../src/platform/text.h"
#include "../src/domain/input/input.h"
#include "../src/util/mem.h"

#include <stdio.h>
#include <string.h>
#include <wchar.h>

static int g_fail = 0;

#define CHECK(cond, msg) do {                                   \
    if (cond) { printf("  [PASS] %s\n", msg); }                 \
    else      { printf("  [FAIL] %s\n", msg); g_fail++; }       \
} while (0)

static int write_file_utf8(const char *path, const char *content)
{
    wchar_t *wp = ts_utf8_to_wide(path, strlen(path), NULL);
    FILE *f;
    int ok = 0;
    if (wp == NULL) return 0;
    f = _wfopen(wp, L"wb");
    if (f != NULL) {
        fputs(content, f);
        fclose(f);
        ok = 1;
    }
    ts_free(wp);
    return ok;
}

static void test_text_material(void)
{
    printf("== 材料组装：文段与段落编号 ==\n");
    TsInputs in;
    char err[256];
    char *mat = NULL;
    size_t mat_len = 0;
    int rc;

    ts_inputs_init(&in);
    CHECK(ts_inputs_add_text(&in, "第一段第一行\n第一段第二行\n\n第二段内容", NULL,
                             4096, err, sizeof(err)) == 0, "添加文段1");
    CHECK(ts_inputs_add_text(&in, "甲\r\n\r\n乙\r\n", "第二份材料",
                             4096, err, sizeof(err)) == 0, "添加文段2(CRLF)");

    rc = ts_inputs_build_material(&in, 4096, &mat, &mat_len, err, sizeof(err));
    CHECK(rc == 0, "组装材料成功");
    if (rc == 0) {
        CHECK(strstr(mat, "===== 文段1：文段1 =====") != NULL, "含文段1 标题");
        CHECK(strstr(mat, "[文段1 段落1]") != NULL, "含 [文段1 段落1]");
        CHECK(strstr(mat, "[文段1 段落2]") != NULL, "含 [文段1 段落2]");
        CHECK(strstr(mat, "第一段第二行") != NULL, "保留段落内所有行");
        CHECK(strstr(mat, "[文段2 段落1]") != NULL, "含 [文段2 段落1]");
        CHECK(strstr(mat, "[文段2 段落2]") != NULL, "含 [文段2 段落2]");
        CHECK(strstr(mat, "第二份材料") != NULL, "含来源说明");
        CHECK(strchr(mat, '\r') == NULL, "已去除 CRLF 的回车符");
        /* 不应出现第三个段落标记 */
        CHECK(strstr(mat, "[文段1 段落3]") == NULL, "段落数正确（无多余段落）");
        CHECK(mat_len == strlen(mat), "mat_len 与字符串长度一致");
    }
    ts_free(mat);
    ts_inputs_free(&in);
}

static void test_file_material(void)
{
    printf("== 材料组装：文件来源编号 ==\n");
    TsInputs in;
    char err[256];
    char *mat = NULL;
    size_t mat_len = 0;
    const char *path = "ts_test_p4_sample.txt";
    int ok = write_file_utf8(path, "文件第一段\n\n文件第二段\n");
    int rc;

    CHECK(ok, "写入测试文件");
    ts_inputs_init(&in);
    if (!ok) { ts_inputs_free(&in); return; }

    CHECK(ts_inputs_add_file(&in, path, 4096, err, sizeof(err)) == 0, "添加文件来源");
    rc = ts_inputs_build_material(&in, 4096, &mat, &mat_len, err, sizeof(err));
    CHECK(rc == 0, "组装材料成功");
    if (rc == 0) {
        CHECK(strstr(mat, "[文件1 段落1]") != NULL, "含 [文件1 段落1]");
        CHECK(strstr(mat, "[文件1 段落2]") != NULL, "含 [文件1 段落2]");
        CHECK(strstr(mat, "文件第二段") != NULL, "含文件内容");
    }
    ts_free(mat);
    ts_inputs_free(&in);
    remove(path);
}

static void test_limits(void)
{
    printf("== 材料组装：上限与空输入 ==\n");
    TsInputs in;
    char err[256];
    char *mat = NULL;
    size_t mat_len = 0;
    int rc;

    /* 空输入应报错 */
    ts_inputs_init(&in);
    rc = ts_inputs_build_material(&in, 4096, &mat, &mat_len, err, sizeof(err));
    CHECK(rc != 0, "空输入被拒绝");
    CHECK(strstr(err, "没有") != NULL, "给出明确原因");
    ts_free(mat);
    mat = NULL;
    ts_inputs_free(&in);

    /* 超过上限应报错且不截断 */
    ts_inputs_init(&in);
    CHECK(ts_inputs_add_text(&in, "这是一段比较长的内容用于触发上限", NULL,
                             4096, err, sizeof(err)) == 0, "添加文段");
    rc = ts_inputs_build_material(&in, 10, &mat, &mat_len, err, sizeof(err));
    CHECK(rc != 0, "超过上限被拒绝");
    CHECK(strstr(err, "上限") != NULL, "提示超过上限");
    ts_free(mat);
    ts_inputs_free(&in);
}

/* 大小上限必须在“分配缓冲之前”按文件大小生效（审查报告 P2）。 */
static void test_size_limit_before_read(void)
{
    printf("== 文件大小上限（读取前检查） ==\n");
    TsInputs in;
    char err[512];
    const char *path = "ts_test_p4_big.txt";
    wchar_t *wp;
    FILE *f;
    size_t i;
    int rc;

    wp = ts_utf8_to_wide(path, strlen(path), NULL);
    CHECK(wp != NULL, "路径转换");
    f = (wp != NULL) ? _wfopen(wp, L"wb") : NULL;
    ts_free(wp);
    CHECK(f != NULL, "创建 512 KiB 测试文件");
    if (f != NULL) {
        char chunk[1024];
        memset(chunk, 'A', sizeof(chunk));
        for (i = 0; i < 512; i++) {
            if (fwrite(chunk, 1, sizeof(chunk), f) != sizeof(chunk)) break;
        }
        fclose(f);
    }

    ts_inputs_init(&in);
    rc = ts_inputs_add_file(&in, path, 4096, err, sizeof(err));
    CHECK(rc != 0, "超过上限的文件被拒绝");
    CHECK(strstr(err, "上限") != NULL, "错误信息说明超过上限");
    CHECK(strstr(err, "524288") != NULL,
          "错误信息给出实际字节数（说明是读前测量大小、而非读完后才发现）");
    CHECK(in.source_count == 0, "被拒绝的文件未加入来源列表");
    CHECK(strstr(err, "未读取") != NULL, "明确说明未读取也未截断");
    ts_inputs_free(&in);
    remove(path);
}

int main(void)
{
    setvbuf(stdout, NULL, _IONBF, 0);
    printf("=== TaskScheduler 阶段4 测试（材料组装） ===\n\n");
    test_text_material();
    test_file_material();
    test_limits();
    test_size_limit_before_read();
    printf("\n=== 结果：%s（失败 %d 项）===\n",
           g_fail == 0 ? "全部通过" : "存在失败", g_fail);
    return g_fail == 0 ? 0 : 1;
}

