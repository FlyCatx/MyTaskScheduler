/*
 * test_phase2.c — 阶段 2 控制台测试。
 *
 * 覆盖：单调时钟、取消状态与请求代号、UTF-8 校验与 UTF-8<->UTF-16 往返、
 *       类型生命周期、文段输入、文件输入（BOM 去除 / 编码 / 扩展名）、模拟响应。
 *
 * 不依赖 cJSON 与 libcurl，可直接编译运行验证。
 */

#include "../src/domain/types.h"
#include "../src/platform/text.h"
#include "../src/platform/runtime.h"
#include "../src/domain/input/input.h"
#include "../src/state/config.h"
#include "../src/domain/analysis/model.h"
#include "../src/util/mem.h"

#include <stdio.h>
#include <string.h>
#include <wchar.h>
#include <stdlib.h>

static int g_fail = 0;

#define CHECK(cond, msg) do {                                   \
    if (cond) { printf("  [PASS] %s\n", msg); }                 \
    else      { printf("  [FAIL] %s\n", msg); g_fail++; }       \
} while (0)

static void test_clock(void)
{
    printf("== 单调时钟 ==\n");
    uint64_t a = ts_clock_ms();
    for (volatile unsigned long i = 0; i < 10000000UL; i++) { }
    uint64_t b = ts_clock_ms();
    CHECK(b >= a, "时钟不回退");
    CHECK(ts_clock_elapsed_ms(a) >= 0, "elapsed 非负");
}

static void test_cancel(void)
{
    printf("== 取消状态与请求代号 ==\n");
    TsCancel c;
    int g1, g2;
    ts_cancel_init(&c);
    CHECK(ts_cancel_gen(&c) == 0, "初始代号为 0");
    g1 = ts_cancel_begin(&c);
    CHECK(g1 == 1, "第一次 begin 返回 1");
    CHECK(!ts_cancel_should_stop(&c, g1), "未取消不应停止");
    ts_cancel_request(&c);
    CHECK(ts_cancel_should_stop(&c, g1), "取消后应停止");
    g2 = ts_cancel_begin(&c);
    CHECK(g2 == 2, "第二次 begin 返回 2");
    CHECK(!ts_cancel_should_stop(&c, g2), "新请求清除取消标志");
    CHECK(ts_cancel_should_stop(&c, g1), "旧代号过期（迟到结果应丢弃）");
}

static void test_utf8(void)
{
    printf("== UTF-8 校验 ==\n");
    static const unsigned char ok_cn[] = { 0xE4, 0xB8, 0xAD, 0xE6, 0x96, 0x87 }; /* "中文" */
    static const unsigned char overlong[] = { 0xC0, 0x80 };      /* 过长编码 */
    static const unsigned char surrogate[] = { 0xED, 0xA0, 0x80 }; /* 代理区 U+D800 */
    static const unsigned char beyond[] = { 0xF4, 0x90, 0x80, 0x80 }; /* > U+10FFFF */
    CHECK(ts_utf8_valid(ok_cn, sizeof(ok_cn)), "合法中文");
    CHECK(ts_utf8_valid((const unsigned char *)"hello", 5), "合法 ASCII");
    CHECK(!ts_utf8_valid(overlong, sizeof(overlong)), "拒绝过长编码");
    CHECK(!ts_utf8_valid(surrogate, sizeof(surrogate)), "拒绝代理区");
    CHECK(!ts_utf8_valid(beyond, sizeof(beyond)), "拒绝超界编码");
}

static void test_wide_roundtrip(void)
{
    printf("== UTF-8 <-> UTF-16 ==\n");
    const char *s = "中文 TaskScheduler 任务分析";
    size_t wlen = 0;
    wchar_t *w = ts_utf8_to_wide(s, strlen(s), &wlen);
    CHECK(w != NULL, "UTF-8 -> UTF-16 成功");
    if (w != NULL) {
        char *back = ts_wide_to_utf8(w, wlen);
        CHECK(back != NULL && strcmp(back, s) == 0, "往返一致");
        ts_free(back);
        ts_free(w);
    }
}

static void test_types(void)
{
    printf("== 类型生命周期 ==\n");
    TsPlan p;
    ts_plan_init(&p);
    p.task_count = 1;
    p.tasks = (TsTask *)ts_calloc(1, sizeof(TsTask));
    CHECK(p.tasks != NULL, "分配任务数组");
    if (p.tasks != NULL) {
        TsTask *t = &p.tasks[0];
        ts_task_init(t);
        t->id = ts_strdup("T1");
        t->name = ts_strdup("测试任务");
        t->depends_on_count = 1;
        t->depends_on = (char **)ts_calloc(1, sizeof(char *));
        if (t->depends_on != NULL) {
            t->depends_on[0] = ts_strdup("T0");
        }
    }
    ts_plan_free(&p);
    CHECK(p.tasks == NULL && p.task_count == 0, "plan free 后归零");
}

static void test_input_text(void)
{
    printf("== 文段输入 ==\n");
    TsInputs in;
    char err[256];
    int rc;
    static const unsigned char bad_utf8[] = { 0xFF, 0xFE, 'a', 0x00 };

    ts_inputs_init(&in);
    rc = ts_inputs_add_text(&in, "这是一段中文要求", NULL, 1024, err, sizeof(err));
    CHECK(rc == 0, "添加文段成功");
    CHECK(in.source_count == 1, "来源数量为 1");
    if (rc == 0) {
        CHECK(in.sources[0].kind == TS_SOURCE_TEXT, "来源类型为文段");
        CHECK(strcmp(in.sources[0].label, "文段1") == 0, "文段标签为 文段1");
    }
    rc = ts_inputs_add_text(&in, (const char *)bad_utf8, NULL, 1024, err, sizeof(err));
    CHECK(rc != 0, "拒绝非法 UTF-8 文段");
    rc = ts_inputs_add_text(&in, "abc", NULL, 2, err, sizeof(err));
    CHECK(rc != 0, "拒绝超限文段");
    CHECK(ts_inputs_total_bytes(&in) > 0, "总字节数 > 0");
    ts_inputs_free(&in);
}

static int write_bom_file(const char *path)
{
    static const unsigned char bom[3] = { 0xEF, 0xBB, 0xBF };
    wchar_t *wp = ts_utf8_to_wide(path, strlen(path), NULL);
    FILE *f;
    int ok = 0;
    if (wp == NULL) {
        return 0;
    }
    f = _wfopen(wp, L"wb");
    if (f != NULL) {
        fwrite(bom, 1, 3, f);
        fputs("第一行内容\n第二行内容\n", f);
        fclose(f);
        ok = 1;
    }
    ts_free(wp);
    return ok;
}

static void test_input_file(void)
{
    printf("== 文件输入 ==\n");
    TsInputs in;
    char err[256];
    const char *path = "ts_test_tmp_utf8bom.txt";
    int wok = write_bom_file(path);
    int rc;

    ts_inputs_init(&in);
    CHECK(wok, "写入测试文件");
    if (!wok) {
        ts_inputs_free(&in);
        return;
    }

    rc = ts_inputs_add_file(&in, path, 1024, err, sizeof(err));
    CHECK(rc == 0, "读取 UTF-8(BOM) 文件成功");
    if (rc == 0) {
        CHECK(in.source_count == 1, "文件来源数量为 1");
        CHECK(in.sources[0].kind == TS_SOURCE_FILE, "来源类型为文件");
        CHECK(strcmp(in.sources[0].label, "文件1") == 0, "文件标签为 文件1");
        /* UTF-8 BOM 应被去除：首字节应为 0xE7（"第"） */
        CHECK(in.sources[0].len > 0 &&
              (unsigned char)in.sources[0].text[0] == 0xE7, "UTF-8 BOM 已去除");
    }
    rc = ts_inputs_add_file(&in, "test.pdf", 1024, err, sizeof(err));
    CHECK(rc != 0, "拒绝 pdf 扩展名");
    ts_inputs_free(&in);
    remove(path);
}

static void test_model_mock(void)
{
    printf("== 模拟分析响应 ==\n");
    TsConfig cfg;
    TsModelResult r;
    int rc;

    memset(&cfg, 0, sizeof(cfg));
    cfg.mock_mode = 1;
    ts_model_result_init(&r);
    rc = ts_model_call(&cfg, NULL, 0, NULL, 0, &r);
    CHECK(rc == 0 && r.ok == 1, "mock 调用成功");
    CHECK(r.body != NULL && r.body_len > 0, "mock 返回非空正文");
    if (r.body != NULL) {
        CHECK(strstr(r.body, "\"schema_version\"") != NULL, "正文含 schema_version");
        CHECK(strstr(r.body, "\"T6\"") != NULL, "正文含任务 T6");
    }
    ts_model_result_free(&r);
}

int main(void)
{
    printf("=== TaskScheduler 阶段2 测试 ===\n\n");
    test_clock();
    test_cancel();
    test_utf8();
    test_wide_roundtrip();
    test_types();
    test_input_text();
    test_input_file();
    test_model_mock();
    printf("\n=== 结果：%s（失败 %d 项）===\n",
           g_fail == 0 ? "全部通过" : "存在失败", g_fail);
    return g_fail == 0 ? 0 : 1;
}

