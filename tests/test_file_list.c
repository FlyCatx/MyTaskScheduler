/*
 * 多选文件对话框的路径还原测试（不需要真的弹对话框）。
 *
 * 覆盖 GetOpenFileNameW 在 OFN_ALLOWMULTISELECT 下可能给出的两种缓冲格式，
 * 以及以前会踩的坑：多选时把目录当成路径、把相邻文件名粘在一起。
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "bridge/ts_file_list.h"

static int failures = 0;
static int checks = 0;

static void check(int cond, const char *what)
{
    ++checks;
    if (cond) {
        printf("PASS: %s\n", what);
    } else {
        printf("FAIL: %s\n", what);
        ++failures;
    }
}

/* 把若干宽字符段拼成对话框缓冲（每段以 '\0' 结尾，整体再补一个 '\0'）。 */
static void build_buf(wchar_t *dst, size_t cap, const wchar_t **parts, size_t count)
{
    size_t used = 0;
    size_t i;
    memset(dst, 0, cap * sizeof(wchar_t));
    for (i = 0; i < count; i++) {
        size_t n = wcslen(parts[i]);
        if (used + n + 1 >= cap) break;
        memcpy(dst + used, parts[i], n * sizeof(wchar_t));
        used += n + 1;
    }
}

int main(void)
{
    wchar_t buf[1024];
    char *out = NULL;
    int rc;

    /* 1) 单选：整个缓冲就是一条完整路径。 */
    {
        const wchar_t *parts[] = { L"C:\\docs\\exp1.txt" };
        build_buf(buf, 1024, parts, 1);
        rc = ts_file_list_join(buf, 1024, &out);
        check(rc == TS_FILE_LIST_OK, "单选：返回成功");
        check(out != NULL && strcmp(out, "C:\\docs\\exp1.txt") == 0,
              "单选：路径保持原样");
        check(out != NULL && strchr(out, '\n') == NULL, "单选：没有多余换行");
        free(out);
        out = NULL;
    }

    /* 2) 多选：目录 + 文件名…，应还原成两条完整路径。 */
    {
        const wchar_t *parts[] = { L"C:\\docs", L"exp1.txt", L"notes.md" };
        build_buf(buf, 1024, parts, 3);
        rc = ts_file_list_join(buf, 1024, &out);
        check(rc == TS_FILE_LIST_OK, "多选：返回成功");
        check(out != NULL &&
                  strcmp(out, "C:\\docs\\exp1.txt\nC:\\docs\\notes.md") == 0,
              "多选：目录与文件名被正确拼接（换行分隔）");
        free(out);
        out = NULL;
    }

    /* 3) 多选且目录带尾部分隔符时不要出现双反斜杠。 */
    {
        const wchar_t *parts[] = { L"C:\\docs\\", L"a.txt", L"b.txt" };
        build_buf(buf, 1024, parts, 3);
        rc = ts_file_list_join(buf, 1024, &out);
        check(rc == TS_FILE_LIST_OK, "尾部分隔符：返回成功");
        check(out != NULL && strstr(out, "\\\\") == NULL,
              "尾部分隔符：不会拼出双反斜杠");
        check(out != NULL && strcmp(out, "C:\\docs\\a.txt\nC:\\docs\\b.txt") == 0,
              "尾部分隔符：两条路径都完整");
        free(out);
        out = NULL;
    }

    /* 4) 多选含中文与空格。 */
    {
        const wchar_t *parts[] = { L"D:\\实验 报告", L"实验1.txt", L"设计 文档.md" };
        build_buf(buf, 1024, parts, 3);
        rc = ts_file_list_join(buf, 1024, &out);
        check(rc == TS_FILE_LIST_OK, "中文路径：返回成功");
        check(out != NULL && strcmp(out, "D:\\实验 报告\\实验1.txt\nD:\\实验 报告\\设计 文档.md") == 0,
              "中文路径：UTF-8 编码与换行都正确");
        free(out);
        out = NULL;
    }

    /* 5) 单个文件但目录段为空的异常输入：不应崩溃。 */
    {
        build_buf(buf, 1024, (const wchar_t *[]){ L"" }, 1);
        rc = ts_file_list_join(buf, 1024, &out);
        check(rc == TS_FILE_LIST_OK && out != NULL && out[0] == '\0',
              "空输入：返回空串而不是崩溃");
        free(out);
        out = NULL;
    }

    /* 6) 参数保护。 */
    check(ts_file_list_join(NULL, 10, &out) == TS_FILE_LIST_INVALID,
          "空缓冲：拒绝并返回 INVALID");
    check(ts_file_list_join(buf, 1024, NULL) == TS_FILE_LIST_INVALID,
          "空输出指针：拒绝并返回 INVALID");

    printf("\n结果：%d 通过，%d 失败\n", checks - failures, failures);
    return failures == 0 ? 0 : 1;
}

