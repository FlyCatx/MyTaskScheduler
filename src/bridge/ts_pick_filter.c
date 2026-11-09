/*
 * ts_pick_filter.c — 三种文件筛选器的唯一定义（见 ts_pick_filter.h）。
 *
 * kind 0 的字符串与 0.4.0 完全一致（旧调用方行为不变）；
 * kind 1 的显示名明确列出 PDF / PNG / JPEG，扩展名大小写由 Windows 对话框按
 * 扩展名匹配（NTFS 不区分大小写），应用入口仍要再用不区分大小写的扩展名校验。
 */

#include "ts_pick_filter.h"

#include <stddef.h>

/*
 * GetOpenFileNameW 的 lpstrFilter 格式：
 *   显示名\0扩展名列表\0 显示名\0扩展名列表\0 ... \0
 * 最后一个空字符串（即整个字符串以两个 NUL 结尾）表示结束。
 * C 字面量里的 "\0" 是编译期常量，不会产生宽字符串终止歧义。
 */

static const wchar_t kFilterDocument[] =
    L"文档 (*.txt;*.md;*.pdf;*.docx;*.pptx)\0"
    L"*.txt;*.md;*.pdf;*.docx;*.pptx\0"
    L"日历文件 (*.ics;*.ical)\0"
    L"*.ics;*.ical\0"
    L"所有文件 (*.*)\0"
    L"*.*\0"
    L"\0";

/*
 * OCR：第一项就是应用支持的完整集合（默认显示“支持的文件”），
 * 后面再按格式分项列出，方便用户直接切换到一个具体格式。
 * 显示名里保留大写 PDF / PNG / JPEG，和 OCR 窗口的文案一致。
 */
static const wchar_t kFilterOcr[] =
    L"PDF / PNG / JPEG (*.pdf;*.png;*.jpg;*.jpeg)\0"
    L"*.pdf;*.png;*.jpg;*.jpeg\0"
    L"PDF 文档 (*.pdf)\0"
    L"*.pdf\0"
    L"PNG 图片 (*.png)\0"
    L"*.png\0"
    L"JPG / JPEG 图片 (*.jpg;*.jpeg)\0"
    L"*.jpg;*.jpeg\0"
    L"所有文件 (*.*)\0"
    L"*.*\0"
    L"\0";

static const wchar_t kFilterCalendar[] =
    L"日历文件 (*.ics;*.ical)\0"
    L"*.ics;*.ical\0"
    L"所有文件 (*.*)\0"
    L"*.*\0"
    L"\0";

static const TsPickFilterSpec kSpecDocument = {
    kFilterDocument, L"txt", L"选择文本文件", TS_PICK_FILTER_DOCUMENT
};
static const TsPickFilterSpec kSpecOcr = {
    kFilterOcr, L"pdf", L"选择扫描件或图片（PDF / PNG / JPEG）", TS_PICK_FILTER_OCR
};
static const TsPickFilterSpec kSpecCalendar = {
    kFilterCalendar, L"ics", L"选择日历文件（.ics / .ical）", TS_PICK_FILTER_CALENDAR
};

const TsPickFilterSpec *ts_pick_filter_spec(int filter_kind)
{
    switch (filter_kind) {
    case TS_PICK_FILTER_DOCUMENT:
        return &kSpecDocument;
    case TS_PICK_FILTER_OCR:
        return &kSpecOcr;
    case TS_PICK_FILTER_CALENDAR:
        return &kSpecCalendar;
    default:
        return NULL;
    }
}
