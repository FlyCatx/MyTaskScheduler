/*
 * ts_activation.c — 可操作通知的纯逻辑实现（URI 解析/构造、Toast XML、动作队列、
 * 待处理激活文件）。不依赖 WinRT/COM，可在 C 测试里离线验证（见 ts_activation.h）。
 *
 * 安全边界：
 *   - 所有输入长度有界（队列 16 条、单条 URI 8KB、待处理文件 64KB）；
 *   - URI 解析对非本协议、未知动作、缺身份参数一律返回 NULL，绝不“猜”目标；
 *   - deadline 只作为不透明字符串原样拼进 URI / 取回 JSON，不做时区换算。
 */

#include "ts_activation.h"

#include "mem.h"
#include "text.h"

#include "cJSON.h"

#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include <string.h>
#include <wchar.h>

/* 待处理激活文件一次最多读入的字节数（防恶意/损坏文件无限增长）。 */
#define TS_ACTIVATION_MAX_PENDING_BYTES (64u * 1024u)

struct TsActivationQueue {
    CRITICAL_SECTION lock;
    int lock_ready;
    char *items[TS_ACTIVATION_MAX_QUEUE];
    size_t count;
};

/* ------------------------------------------------------------------ */
/* 小工具                                                              */
/* ------------------------------------------------------------------ */

static int ts_ci_equal(const char *a, const char *b)
{
    return a != NULL && b != NULL && _stricmp(a, b) == 0;
}

static int ts_ci_prefix(const char *s, const char *prefix)
{
    size_t n;
    if (s == NULL || prefix == NULL) return 0;
    n = strlen(prefix);
    return _strnicmp(s, prefix, n) == 0;
}

static wchar_t *ts_u8_to_wide(const char *s)
{
    if (s == NULL) return NULL;
    return ts_utf8_to_wide(s, strlen(s), NULL);
}

static char *ts_wide_to_u8(const wchar_t *s)
{
    if (s == NULL) return NULL;
    return ts_wide_to_utf8(s, wcslen(s));
}

/* 解析十六进制半字节；非法返回 -1。 */
static int ts_hex_digit(char c)
{
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

/* RFC 3986 unreserved 之外全部 percent-encode。返回 malloc 字符串。 */
char *ts_activation_uri_encode(const char *s)
{
    static const char kHex[] = "0123456789ABCDEF";
    TsBuf b;
    const unsigned char *p;
    if (s == NULL) return NULL;
    ts_buf_init(&b);
    for (p = (const unsigned char *)s; *p != 0; p++) {
        unsigned char c = *p;
        int plain = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
                    (c >= '0' && c <= '9') || c == '-' || c == '.' || c == '_' || c == '~';
        if (plain) {
            if (ts_buf_append(&b, (const char *)&c, 1)) {
                ts_buf_free(&b);
                return NULL;
            }
        } else {
            char enc[3];
            enc[0] = '%';
            enc[1] = kHex[c >> 4];
            enc[2] = kHex[c & 0x0F];
            if (ts_buf_append(&b, enc, 3)) {
                ts_buf_free(&b);
                return NULL;
            }
        }
    }
    if (b.data == NULL) {
        return ts_strdup("");
    }
    return b.data;  /* 所有权转交调用方 */
}

/* percent-decode [s, s+len)。'+' 按字面量处理（构造端不会产生 '+' 表示空格）。 */
static char *ts_percent_decode(const char *s, size_t len)
{
    TsBuf b;
    size_t i = 0;
    if (s == NULL) return NULL;
    ts_buf_init(&b);
    while (i < len) {
        if (s[i] == '%') {
            int hi, lo;
            if (i + 2 < len && (hi = ts_hex_digit(s[i + 1])) >= 0 &&
                (lo = ts_hex_digit(s[i + 2])) >= 0) {
                char c = (char)((hi << 4) | lo);
                if (ts_buf_append(&b, &c, 1)) {
                    ts_buf_free(&b);
                    return NULL;
                }
                i += 3;
                continue;
            }
        }
        if (ts_buf_append(&b, s + i, 1)) {
            ts_buf_free(&b);
            return NULL;
        }
        i++;
    }
    if (b.data == NULL) return ts_strdup("");
    return b.data;
}

static char *ts_xml_escape(const char *s)
{
    TsBuf b;
    const char *p;
    if (s == NULL) return NULL;
    ts_buf_init(&b);
    for (p = s; *p != 0; p++) {
        const char *rep = NULL;
        switch (*p) {
        case '&': rep = "&amp;"; break;
        case '<': rep = "&lt;"; break;
        case '>': rep = "&gt;"; break;
        case '"': rep = "&quot;"; break;
        case '\'': rep = "&apos;"; break;
        default: break;
        }
        if (rep != NULL) {
            if (ts_buf_puts(&b, rep)) { ts_buf_free(&b); return NULL; }
        } else {
            if (ts_buf_append(&b, p, 1)) { ts_buf_free(&b); return NULL; }
        }
    }
    if (b.data == NULL) return ts_strdup("");
    return b.data;
}

char *ts_activation_escape_xml(const char *s)
{
    if (s == NULL) return NULL;
    return ts_xml_escape(s);
}

/* ------------------------------------------------------------------ */
/* URI 构造                                                            */
/* ------------------------------------------------------------------ */

/* 取 JSON 标量（字符串 / 数字 / 布尔）的字符串形式；对象/数组/null 返回 NULL。 */
static char *ts_json_scalar_string(const cJSON *item)
{
    if (item == NULL) return NULL;
    if (cJSON_IsString(item)) {
        return item->valuestring != NULL ? ts_strdup(item->valuestring) : NULL;
    }
    if (cJSON_IsNumber(item) || cJSON_IsBool(item)) {
        char *printed = cJSON_PrintUnformatted((cJSON *)item);
        return printed;   /* cJSON 的 malloc，与 ts_free/free 兼容 */
    }
    return NULL;
}

/*
 * payload 解析为三个身份字符串。成功返回 0 并写 out_*（owned）；
 * 缺字段/类型不对返回非 0，已写出的部分由本函数释放。
 */
static int ts_identity_from_payload(const char *payload_json,
                                    char **out_task, char **out_execution,
                                    char **out_deadline)
{
    cJSON *root;
    char *task = NULL;
    char *execution = NULL;
    char *deadline = NULL;

    *out_task = NULL;
    *out_execution = NULL;
    *out_deadline = NULL;
    if (payload_json == NULL) return 1;
    root = cJSON_Parse(payload_json);
    if (root == NULL) return 1;
    task = ts_json_scalar_string(cJSON_GetObjectItemCaseSensitive(root, "taskId"));
    execution = ts_json_scalar_string(cJSON_GetObjectItemCaseSensitive(root, "executionId"));
    deadline = ts_json_scalar_string(cJSON_GetObjectItemCaseSensitive(root, "deadline"));
    cJSON_Delete(root);
    if (task == NULL || task[0] == '\0' ||
        execution == NULL || execution[0] == '\0' ||
        deadline == NULL || deadline[0] == '\0') {
        ts_free(task);
        ts_free(execution);
        ts_free(deadline);
        return 1;
    }
    *out_task = task;
    *out_execution = execution;
    *out_deadline = deadline;
    return 0;
}

static int ts_action_valid(const char *action)
{
    return ts_ci_equal(action, "open") || ts_ci_equal(action, "extend") ||
           ts_ci_equal(action, "finish");
}

/* 内部：由已解码的身份字符串构造 URI。 */
static char *ts_build_uri_parts(const char *action, const char *task,
                                const char *execution, const char *deadline)
{
    char *e_action = NULL;
    char *e_task = NULL;
    char *e_exec = NULL;
    char *e_deadline = NULL;
    char *uri = NULL;
    TsBuf b;

    if (action == NULL || !ts_action_valid(action)) return NULL;
    if (task == NULL || execution == NULL || deadline == NULL) return NULL;

    e_action = ts_activation_uri_encode(action);
    e_task = ts_activation_uri_encode(task);
    e_exec = ts_activation_uri_encode(execution);
    e_deadline = ts_activation_uri_encode(deadline);
    if (e_action == NULL || e_task == NULL || e_exec == NULL || e_deadline == NULL) {
        ts_free(e_action);
        ts_free(e_task);
        ts_free(e_exec);
        ts_free(e_deadline);
        return NULL;
    }

    ts_buf_init(&b);
    if (ts_buf_printf(&b, "%s://%s?taskId=%s&executionId=%s&deadline=%s",
                      TS_ACTIVATION_SCHEME, e_action, e_task, e_exec, e_deadline)) {
        ts_buf_free(&b);
    } else {
        uri = b.data;
    }
    ts_free(e_action);
    ts_free(e_task);
    ts_free(e_exec);
    ts_free(e_deadline);
    return uri;
}

char *ts_activation_build_uri(const char *action, const char *payload_json)
{
    char *task = NULL;
    char *execution = NULL;
    char *deadline = NULL;
    char *uri;
    if (action == NULL || !ts_action_valid(action)) return NULL;
    if (ts_identity_from_payload(payload_json, &task, &execution, &deadline) != 0) {
        return NULL;
    }
    uri = ts_build_uri_parts(action, task, execution, deadline);
    ts_free(task);
    ts_free(execution);
    ts_free(deadline);
    return uri;
}

char *ts_activation_build_toast_xml(const char *title_utf8, const char *body_utf8,
                                    const char *payload_json,
                                    const char *extend_label_utf8,
                                    const char *finish_label_utf8)
{
    char *task = NULL;
    char *execution = NULL;
    char *deadline = NULL;
    char *uri_open = NULL;
    char *uri_extend = NULL;
    char *uri_finish = NULL;
    char *xml_open = NULL;
    char *xml_extend = NULL;
    char *xml_finish = NULL;
    char *xml_title = NULL;
    char *xml_body = NULL;
    char *xml_ext_label = NULL;
    char *xml_fin_label = NULL;
    char *xml = NULL;
    const char *extend_label = (extend_label_utf8 != NULL) ? extend_label_utf8 : "延长时间";
    const char *finish_label = (finish_label_utf8 != NULL) ? finish_label_utf8 : "结束任务";
    TsBuf b;

    if (ts_identity_from_payload(payload_json, &task, &execution, &deadline) != 0) {
        return NULL;
    }
    uri_open = ts_build_uri_parts("open", task, execution, deadline);
    uri_extend = ts_build_uri_parts("extend", task, execution, deadline);
    uri_finish = ts_build_uri_parts("finish", task, execution, deadline);
    if (uri_open == NULL || uri_extend == NULL || uri_finish == NULL) goto done;

    xml_open = ts_xml_escape(uri_open);
    xml_extend = ts_xml_escape(uri_extend);
    xml_finish = ts_xml_escape(uri_finish);
    xml_title = ts_xml_escape(title_utf8 != NULL ? title_utf8 : "");
    xml_body = ts_xml_escape(body_utf8 != NULL ? body_utf8 : "");
    xml_ext_label = ts_xml_escape(extend_label);
    xml_fin_label = ts_xml_escape(finish_label);
    if (xml_open == NULL || xml_extend == NULL || xml_finish == NULL ||
        xml_title == NULL || xml_body == NULL || xml_ext_label == NULL ||
        xml_fin_label == NULL) {
        goto done;
    }

    ts_buf_init(&b);
    if (ts_buf_printf(&b,
            "<toast activationType=\"protocol\" launch=\"%s\">"
            "<visual><binding template=\"ToastGeneric\">"
            "<text>%s</text><text>%s</text>"
            "</binding></visual>"
            "<actions>"
            "<action content=\"%s\" activationType=\"protocol\" arguments=\"%s\"/>"
            "<action content=\"%s\" activationType=\"protocol\" arguments=\"%s\"/>"
            "</actions>"
            "</toast>",
            xml_open, xml_title, xml_body,
            xml_ext_label, xml_extend, xml_fin_label, xml_finish)) {
        ts_buf_free(&b);
    } else {
        xml = b.data;
    }

done:
    ts_free(task);
    ts_free(execution);
    ts_free(deadline);
    ts_free(uri_open);
    ts_free(uri_extend);
    ts_free(uri_finish);
    ts_free(xml_open);
    ts_free(xml_extend);
    ts_free(xml_finish);
    ts_free(xml_title);
    ts_free(xml_body);
    ts_free(xml_ext_label);
    ts_free(xml_fin_label);
    return xml;
}

/* ------------------------------------------------------------------ */
/* URI 解析                                                            */
/* ------------------------------------------------------------------ */

/* 在 "key=value" 列表中查找 key（大小写不敏感），返回 percent-decode 后的值。 */
static char *ts_query_get(const char *query, size_t query_len, const char *key)
{
    size_t pos = 0;
    size_t key_len = strlen(key);
    while (pos < query_len) {
        size_t end = pos;
        size_t eq;
        size_t klen;
        while (end < query_len && query[end] != '&') end++;
        eq = pos;
        while (eq < end && query[eq] != '=') eq++;
        klen = eq - pos;
        if (eq < end && klen == key_len &&
            _strnicmp(query + pos, key, klen) == 0) {
            return ts_percent_decode(query + eq + 1, end - eq - 1);
        }
        pos = (end < query_len) ? end + 1 : end;
    }
    return NULL;
}

/* 从 action 起点取动作名并规范化小写。成功返回 0。 */
static int ts_parse_action(const char *p, const char *end, char out[16])
{
    size_t n = (size_t)(end - p);
    size_t i;
    /* Windows 有时会给 taskscheduler:///open?...（多一个斜杠），已在外层跳过。 */
    while (n > 0 && *p == '/') { p++; n--; }
    while (n > 0 && (p[n - 1] == '/' || p[n - 1] == ' ' || p[n - 1] == '\t')) n--;
    if (n == 0 || n >= 16) return 1;
    for (i = 0; i < n; i++) {
        char c = p[i];
        if (c >= 'A' && c <= 'Z') c = (char)(c - 'A' + 'a');
        out[i] = c;
    }
    out[n] = '\0';
    return ts_action_valid(out) ? 0 : 1;
}

char *ts_activation_parse_uri(const char *uri_utf8)
{
    const char *p;
    const char *action_start;
    const char *action_end;
    const char *query = NULL;
    size_t query_len = 0;
    char action[16];
    char *task = NULL;
    char *execution = NULL;
    char *deadline = NULL;
    char *json = NULL;
    cJSON *root = NULL;
    size_t scheme_len = sizeof(TS_ACTIVATION_SCHEME) - 1;

    if (uri_utf8 == NULL) return NULL;
    if (!ts_ci_prefix(uri_utf8, TS_ACTIVATION_SCHEME)) return NULL;
    p = uri_utf8 + scheme_len;
    if (*p == ':') p++;
    if (p[0] == '/' && p[1] == '/') p += 2;
    while (*p == '/') p++;
    action_start = p;
    /* action 到 '?' / '#' / 结尾 */
    while (*p != 0 && *p != '?' && *p != '#') p++;
    action_end = p;
    if (*p == '?') {
        const char *q = p + 1;
        while (*q != 0 && *q != '#') q++;
        query = p + 1;
        query_len = (size_t)(q - query);
    }
    if (ts_parse_action(action_start, action_end, action) != 0) return NULL;

    if (query != NULL) {
        task = ts_query_get(query, query_len, "taskId");
        execution = ts_query_get(query, query_len, "executionId");
        deadline = ts_query_get(query, query_len, "deadline");
    }
    if (task == NULL || task[0] == '\0' ||
        execution == NULL || execution[0] == '\0' ||
        deadline == NULL || deadline[0] == '\0') {
        ts_free(task);
        ts_free(execution);
        ts_free(deadline);
        return NULL;
    }

    root = cJSON_CreateObject();
    if (root != NULL &&
        cJSON_AddStringToObject(root, "action", action) != NULL &&
        cJSON_AddStringToObject(root, "taskId", task) != NULL &&
        cJSON_AddStringToObject(root, "executionId", execution) != NULL &&
        cJSON_AddStringToObject(root, "deadline", deadline) != NULL) {
        json = cJSON_PrintUnformatted(root);
    }
    if (root != NULL) cJSON_Delete(root);
    ts_free(task);
    ts_free(execution);
    ts_free(deadline);
    return json;
}

/* ------------------------------------------------------------------ */
/* 动作队列                                                            */
/* ------------------------------------------------------------------ */

TsActivationQueue *ts_activation_queue_create(void)
{
    TsActivationQueue *q = (TsActivationQueue *)ts_calloc(1, sizeof(*q));
    if (q == NULL) return NULL;
    InitializeCriticalSection(&q->lock);
    q->lock_ready = 1;
    return q;
}

void ts_activation_queue_destroy(TsActivationQueue *queue)
{
    size_t i;
    if (queue == NULL) return;
    if (queue->lock_ready) EnterCriticalSection(&queue->lock);
    for (i = 0; i < queue->count; i++) {
        ts_free(queue->items[i]);
        queue->items[i] = NULL;
    }
    queue->count = 0;
    if (queue->lock_ready) {
        LeaveCriticalSection(&queue->lock);
        DeleteCriticalSection(&queue->lock);
    }
    ts_free(queue);
}

int ts_activation_queue_push_json(TsActivationQueue *queue, char *json_owned)
{
    if (queue == NULL || json_owned == NULL) return 1;
    EnterCriticalSection(&queue->lock);
    if (queue->count >= TS_ACTIVATION_MAX_QUEUE) {
        /* 满：丢弃最旧一条，保留最近动作。 */
        ts_free(queue->items[0]);
        memmove(&queue->items[0], &queue->items[1],
                sizeof(queue->items[0]) * (TS_ACTIVATION_MAX_QUEUE - 1));
        queue->count = TS_ACTIVATION_MAX_QUEUE - 1;
    }
    queue->items[queue->count++] = json_owned;
    LeaveCriticalSection(&queue->lock);
    return 0;
}

int ts_activation_queue_push_uri(TsActivationQueue *queue, const char *uri_utf8)
{
    char *json;
    if (queue == NULL || uri_utf8 == NULL) return 1;
    if (strlen(uri_utf8) > TS_ACTIVATION_MAX_URI_BYTES) return 1;
    json = ts_activation_parse_uri(uri_utf8);
    if (json == NULL) return 1;
    if (ts_activation_queue_push_json(queue, json) != 0) {
        ts_free(json);
        return 1;
    }
    return 0;
}

char *ts_activation_queue_take(TsActivationQueue *queue)
{
    char *json = NULL;
    if (queue == NULL) return NULL;
    EnterCriticalSection(&queue->lock);
    if (queue->count > 0) {
        json = queue->items[0];
        if (queue->count > 1) {
            memmove(&queue->items[0], &queue->items[1],
                    sizeof(queue->items[0]) * (queue->count - 1));
        }
        queue->count--;
        queue->items[queue->count] = NULL;
    }
    LeaveCriticalSection(&queue->lock);
    return json;
}

/* ------------------------------------------------------------------ */
/* 待处理激活文件                                                      */
/* ------------------------------------------------------------------ */

/* 创建目录（已存在不算错）。 */
static void ts_ensure_dir_w(const wchar_t *dir)
{
    if (dir == NULL || dir[0] == L'\0') return;
    if (CreateDirectoryW(dir, NULL)) return;
    /* 父目录可能也不存在：逐级创建（只处理绝对路径）。 */
    {
        wchar_t *copy = (wchar_t *)ts_calloc(wcslen(dir) + 1, sizeof(wchar_t));
        wchar_t *p;
        if (copy == NULL) return;
        wcscpy(copy, dir);
        for (p = copy; *p != 0; p++) {
            if (*p == L'\\' && p != copy) {
                *p = L'\0';
                CreateDirectoryW(copy, NULL);
                *p = L'\\';
            }
        }
        CreateDirectoryW(copy, NULL);
        ts_free(copy);
    }
}

/*
 * 计算待处理文件路径（宽字符，malloc）。
 * override_dir_utf8 可为 NULL/空：默认 %LOCALAPPDATA%\TaskScheduler。
 */
static wchar_t *ts_pending_path_wide(const char *override_dir_utf8)
{
    wchar_t *dir = NULL;
    wchar_t base[MAX_PATH];
    wchar_t combined[2 * MAX_PATH];
    const wchar_t *suffix = L"\\" TS_ACTIVATION_PENDING_FILE;
    size_t dir_len;
    wchar_t *out;

    if (override_dir_utf8 != NULL && override_dir_utf8[0] != '\0') {
        dir = ts_u8_to_wide(override_dir_utf8);
        if (dir == NULL) return NULL;
    } else {
        DWORD n = GetEnvironmentVariableW(L"LOCALAPPDATA", base, MAX_PATH);
        if (n == 0 || n >= MAX_PATH) {
            DWORD t = GetTempPathW(MAX_PATH, base);
            if (t == 0 || t >= MAX_PATH) return NULL;
            /* GetTempPathW 已带结尾反斜杠：去掉后再拼 TaskScheduler。 */
            if (t > 1 && base[t - 1] == L'\\') base[t - 1] = L'\0';
        }
        dir_len = wcslen(base);
        if (dir_len + 1 + wcslen(L"TaskScheduler") + 1 > 2 * MAX_PATH) return NULL;
        swprintf(combined, 2 * MAX_PATH, L"%s\\TaskScheduler", base);
        dir = (wchar_t *)ts_calloc(wcslen(combined) + 1, sizeof(wchar_t));
        if (dir == NULL) return NULL;
        wcscpy(dir, combined);
    }

    ts_ensure_dir_w(dir);
    dir_len = wcslen(dir);
    if (dir_len + wcslen(suffix) + 1 > 2 * MAX_PATH) {
        ts_free(dir);
        return NULL;
    }
    swprintf(combined, 2 * MAX_PATH, L"%s%s", dir, suffix);
    ts_free(dir);
    out = (wchar_t *)ts_calloc(wcslen(combined) + 1, sizeof(wchar_t));
    if (out == NULL) return NULL;
    wcscpy(out, combined);
    return out;
}

char *ts_activation_pending_path(const char *override_dir_utf8)
{
    wchar_t *wide = ts_pending_path_wide(override_dir_utf8);
    char *utf8;
    if (wide == NULL) return NULL;
    utf8 = ts_wide_to_u8(wide);
    ts_free(wide);
    return utf8;
}

/* 取跨进程待处理文件互斥体；失败返回 NULL（调用方仍可继续，只降级并发保护）。 */
static HANDLE ts_pending_mutex_acquire(void)
{
    HANDLE m = CreateMutexW(NULL, FALSE, TS_ACTIVATION_PENDING_MUTEX_NAME);
    if (m == NULL) return NULL;
    if (WaitForSingleObject(m, 3000) != WAIT_OBJECT_0) {
        CloseHandle(m);
        return NULL;
    }
    return m;
}

static void ts_pending_mutex_release(HANDLE m)
{
    if (m == NULL) return;
    ReleaseMutex(m);
    CloseHandle(m);
}

int ts_activation_append_pending(const char *path_utf8, const char *uri_utf8)
{
    wchar_t *path;
    HANDLE file;
    HANDLE mutex;
    DWORD written = 0;
    size_t len;
    char *line;
    int rc = 0;

    if (path_utf8 == NULL || uri_utf8 == NULL) return 1;
    if (uri_utf8[0] == '\0' || strlen(uri_utf8) > TS_ACTIVATION_MAX_URI_BYTES) return 1;
    path = ts_u8_to_wide(path_utf8);
    if (path == NULL) return 1;
    mutex = ts_pending_mutex_acquire();
    file = CreateFileW(path, FILE_APPEND_DATA,
                       FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                       NULL, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (file == INVALID_HANDLE_VALUE) {
        ts_free(path);
        ts_pending_mutex_release(mutex);
        return 1;
    }
    len = strlen(uri_utf8);
    line = (char *)ts_malloc(len + 2);
    if (line == NULL) {
        CloseHandle(file);
        ts_free(path);
        ts_pending_mutex_release(mutex);
        return 1;
    }
    memcpy(line, uri_utf8, len);
    line[len] = '\n';
    if (!WriteFile(file, line, (DWORD)(len + 1), &written, NULL) ||
        written != (DWORD)(len + 1)) {
        rc = 1;
    }
    ts_free(line);
    CloseHandle(file);
    ts_free(path);
    ts_pending_mutex_release(mutex);
    return rc;
}

int ts_activation_drain_pending(TsActivationQueue *queue, const char *path_utf8)
{
    wchar_t *path;
    HANDLE file;
    HANDLE mutex;
    char *buffer;
    DWORD read_bytes = 0;
    int queued = 0;
    size_t pos;
    int rc = 0;

    if (queue == NULL || path_utf8 == NULL) return -1;
    path = ts_u8_to_wide(path_utf8);
    if (path == NULL) return -1;
    mutex = ts_pending_mutex_acquire();
    file = CreateFileW(path, GENERIC_READ | GENERIC_WRITE,
                       FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                       NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
    if (file == INVALID_HANDLE_VALUE) {
        ts_free(path);
        ts_pending_mutex_release(mutex);
        /* 文件不存在 = 没有待处理激活，不是错误。 */
        return (GetLastError() == ERROR_FILE_NOT_FOUND) ? 0 : -1;
    }
    buffer = (char *)ts_malloc(TS_ACTIVATION_MAX_PENDING_BYTES + 1);
    if (buffer == NULL) {
        CloseHandle(file);
        ts_free(path);
        ts_pending_mutex_release(mutex);
        return -1;
    }
    if (!ReadFile(file, buffer, TS_ACTIVATION_MAX_PENDING_BYTES, &read_bytes, NULL)) {
        rc = -1;
        read_bytes = 0;
    }
    buffer[read_bytes] = '\0';
    /* 先截断再解析：即使解析失败也不会重复投递同一条激活。 */
    if (SetFilePointer(file, 0, NULL, FILE_BEGIN) != INVALID_SET_FILE_POINTER) {
        SetEndOfFile(file);
    }
    CloseHandle(file);

    if (rc == 0) {
        pos = 0;
        while (pos < read_bytes) {
            size_t start = pos;
            size_t end;
            while (pos < read_bytes && buffer[pos] != '\n' && buffer[pos] != '\r') pos++;
            end = pos;
            while (pos < read_bytes && (buffer[pos] == '\n' || buffer[pos] == '\r')) pos++;
            if (end > start) {
                char saved = buffer[end];
                buffer[end] = '\0';
                if (ts_activation_queue_push_uri(queue, buffer + start) == 0) queued++;
                buffer[end] = saved;
            }
        }
    }
    ts_free(buffer);
    ts_free(path);
    ts_pending_mutex_release(mutex);
    return (rc == 0) ? queued : -1;
}
