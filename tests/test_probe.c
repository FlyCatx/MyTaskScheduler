/*
 * test_probe.c — 0.0.4 桥接（ABI 2）的端到端测试：真实 DLL + 内置 winsock mock HTTP 服务。
 *
 * 不用 Python、不联网、不需要真实密钥：mock 服务监听 127.0.0.1 的随机端口，
 * 记录收到的每一个请求（方法/路径/头/体），由测试逐项断言。
 *
 * 覆盖 docs/SETTINGS_0_0_4_SPEC.md §11 的第 1–5 组：
 *   1) 请求捕获：模型 ID / URL / thinking / effort 随选择变化；disabled 无 effort
 *   2) 运行中保存配置：旧 job 的请求体不变，新 job 用新配置
 *   3) authMode=none 不发 Authorization；bearer 发且 host 不匹配时拒绝发送
 *   4) 未知 revision 明确失败；删除 profile 不影响运行中的任务
 *   5) 探针（模型发现 / 连通性测试）与错误分类：401/404/429/超时/截断/无效 JSON
 *
 * 本文件只使用明显虚构的密钥 `sk-test-…`，且从不打印密钥内容。
 */

#include <stdio.h>
#include <string.h>
#include <stdlib.h>

#include "ts_bridge.h"

#define WIN32_LEAN_AND_MEAN
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>

#include "../src/platform/credential.h"
#include "../src/state/config.h"   /* ts_secure_free（测试里安全释放读到的假密钥） */
#include "../src/util/mem.h"

static int g_pass = 0;
static int g_fail = 0;

#define CHECK(cond, msg) do {                                          \
    if (cond) { g_pass++; printf("  [PASS] %s\n", msg); }               \
    else { printf("  [FAIL] %s\n", msg); g_fail++; }                    \
} while (0)

static int contains(const char *hay, const char *needle)
{
    return hay != NULL && needle != NULL && strstr(hay, needle) != NULL;
}

/* 大小写不敏感的子串查找（用于检查 HTTP 头，头名大小写不敏感）。 */
static int contains_ci(const char *hay, const char *needle)
{
    size_t hn, nn, i;
    if (hay == NULL || needle == NULL) return 0;
    hn = strlen(hay);
    nn = strlen(needle);
    if (nn == 0 || hn < nn) return 0;
    for (i = 0; i + nn <= hn; i++) {
        size_t j;
        for (j = 0; j < nn; j++) {
            char a = hay[i + j];
            char b = needle[j];
            if (a >= 'A' && a <= 'Z') a = (char)(a - 'A' + 'a');
            if (b >= 'A' && b <= 'Z') b = (char)(b - 'A' + 'a');
            if (a != b) break;
        }
        if (j == nn) return 1;
    }
    return 0;
}

static void write_file(const char *path, const char *text)
{
    FILE *f = fopen(path, "wb");
    if (f != NULL) {
        fwrite(text, 1, strlen(text), f);
        fclose(f);
    }
}

/* 定长复制（MSVC 没有 _strndup）。 */
static char *dup_n(const char *s, size_t n)
{
    char *d = (char *)malloc(n + 1);
    if (d != NULL) {
        memcpy(d, s, n);
        d[n] = '\0';
    }
    return d;
}
/* ================================================================== */
/* 内置 mock HTTP 服务（winsock，仅测试用）                            */
/* ================================================================== */

#define MOCK_MAX_REQS 64

typedef struct MockReq {
    char method[16];
    char path[1024];
    char *headers;     /* 原始头块（含请求行），便于检查 Authorization */
    char *body;
} MockReq;

static CRITICAL_SECTION g_mock_lock;
static int g_mock_lock_ready = 0;
static MockReq g_reqs[MOCK_MAX_REQS];
static int g_req_count = 0;

static SOCKET g_listen = INVALID_SOCKET;
static HANDLE g_mock_thread = NULL;
static volatile LONG g_mock_stop = 0;
static int g_port = 0;

static volatile LONG g_mock_status = 200;
static volatile LONG g_mock_delay_ms = 0;
static char *g_mock_body = NULL;

static void mock_clear_requests(void)
{
    int i;
    EnterCriticalSection(&g_mock_lock);
    for (i = 0; i < g_req_count; i++) {
        free(g_reqs[i].headers);
        free(g_reqs[i].body);
        memset(&g_reqs[i], 0, sizeof(g_reqs[i]));
    }
    g_req_count = 0;
    LeaveCriticalSection(&g_mock_lock);
}

static int mock_request_count(void)
{
    int n;
    EnterCriticalSection(&g_mock_lock);
    n = g_req_count;
    LeaveCriticalSection(&g_mock_lock);
    return n;
}

/* 取第 index 个请求的副本信息（只在测试线程调用）。 */
static void mock_request_snapshot(int index, char *method, size_t method_sz,
                                  char *path, size_t path_sz,
                                  char **headers, char **body)
{
    EnterCriticalSection(&g_mock_lock);
    if (index >= 0 && index < g_req_count) {
        snprintf(method, method_sz, "%s", g_reqs[index].method);
        snprintf(path, path_sz, "%s", g_reqs[index].path);
        if (headers != NULL) *headers = g_reqs[index].headers != NULL
                                            ? _strdup(g_reqs[index].headers) : NULL;
        if (body != NULL) *body = g_reqs[index].body != NULL
                                      ? _strdup(g_reqs[index].body) : NULL;
    } else {
        if (method_sz > 0) method[0] = '\0';
        if (path_sz > 0) path[0] = '\0';
        if (headers != NULL) *headers = NULL;
        if (body != NULL) *body = NULL;
    }
    LeaveCriticalSection(&g_mock_lock);
}

static void mock_set_response(int status, const char *body)
{
    EnterCriticalSection(&g_mock_lock);
    g_mock_status = status;
    free(g_mock_body);
    g_mock_body = (body != NULL) ? _strdup(body) : NULL;
    LeaveCriticalSection(&g_mock_lock);
}

static void mock_set_delay(long ms)
{
    g_mock_delay_ms = ms;
}

/* 某一行是否以给定的头名（大小写不敏感）开头。 */
static int line_starts_with_ci(const char *line, size_t len, const char *name)
{
    size_t i;
    size_t n = strlen(name);
    if (len < n) return 0;
    for (i = 0; i < n; i++) {
        char a = line[i];
        char b = name[i];
        if (a >= 'A' && a <= 'Z') a = (char)(a - 'A' + 'a');
        if (b >= 'A' && b <= 'Z') b = (char)(b - 'A' + 'a');
        if (a != b) return 0;
    }
    return 1;
}

/*
 * 解析 Content-Length（大小写不敏感）。缺失返回 0。
 * 必须**逐行**判断：早期实现在整段剩余文本里搜 "content-length:"，
 * 结果第一个 "Host: 127.0.0.1:端口" 的冒号被当成 Content-Length 的冒号，
 * 请求体被截断成 127 字节，看起来像“请求体不对”。
 */
static long header_content_length(const char *headers)
{
    const char *p;
    if (headers == NULL) return 0;
    p = strstr(headers, "\r\n");
    while (p != NULL) {
        const char *line = p + 2;
        const char *eol = strstr(line, "\r\n");
        if (eol == NULL) break;
        if (eol == line) break;   /* 空行 = 头结束 */
        if (line_starts_with_ci(line, (size_t)(eol - line), "content-length:")) {
            return strtol(line + strlen("content-length:"), NULL, 10);
        }
        p = eol;
    }
    return 0;
}

static void mock_handle_client(SOCKET c)
{
    char buf[131072];
    size_t len = 0;
    char *hend = NULL;
    long clen;
    size_t header_len;
    MockReq req;
    char resp_head[512];
    const char *body;
    const char *reason;
    char body_copy[8192];
    size_t body_len;
    int status;

    memset(&req, 0, sizeof(req));
    memset(buf, 0, sizeof(buf));

    for (;;) {
        int n;
        if (len + 1 >= sizeof(buf)) break;
        n = recv(c, buf + len, (int)(sizeof(buf) - 1 - len), 0);
        if (n <= 0) break;
        len += (size_t)n;
        buf[len] = '\0';
        hend = strstr(buf, "\r\n\r\n");
        if (hend != NULL) break;
    }
    if (hend == NULL) return;

    header_len = (size_t)(hend - buf) + 4;
    clen = header_content_length(buf);
    if (clen > 0) {
        size_t have = len - header_len;
        while ((long)have < clen) {
            int n;
            if (header_len + have + 1 >= sizeof(buf)) break;
            n = recv(c, buf + header_len + have,
                     (int)(sizeof(buf) - 1 - header_len - have), 0);
            if (n <= 0) break;
            have += (size_t)n;
            len += (size_t)n;
            buf[len] = '\0';
        }
    }

    /* 请求行 */
    {
        char *sp1 = strchr(buf, ' ');
        if (sp1 != NULL) {
            size_t m = (size_t)(sp1 - buf);
            if (m >= sizeof(req.method)) m = sizeof(req.method) - 1;
            memcpy(req.method, buf, m);
            req.method[m] = '\0';
            {
                char *sp2 = strchr(sp1 + 1, ' ');
                if (sp2 != NULL) {
                    size_t pl = (size_t)(sp2 - (sp1 + 1));
                    if (pl >= sizeof(req.path)) pl = sizeof(req.path) - 1;
                    memcpy(req.path, sp1 + 1, pl);
                    req.path[pl] = '\0';
                }
            }
        }
    }

    req.headers = dup_n(buf, header_len);
    if (clen > 0) {
        size_t have = len - header_len;
        size_t take = ((size_t)clen < have) ? (size_t)clen : have;
        req.body = dup_n(buf + header_len, take);
    } else {
        req.body = _strdup("");
    }

    EnterCriticalSection(&g_mock_lock);
    if (g_req_count < MOCK_MAX_REQS) {
        g_reqs[g_req_count++] = req;
        memset(&req, 0, sizeof(req));
    }
    status = (int)g_mock_status;
    /* 必须复制一份：主线程可能在响应期间替换 g_mock_body。 */
    snprintf(body_copy, sizeof(body_copy), "%s",
             g_mock_body != NULL ? g_mock_body : "{}");
    LeaveCriticalSection(&g_mock_lock);

    if (g_mock_delay_ms > 0) {
        Sleep((DWORD)g_mock_delay_ms);
    }

    body = body_copy;
    body_len = strlen(body);
    reason = (status == 200) ? "OK"
             : (status == 401) ? "Unauthorized"
             : (status == 404) ? "Not Found"
             : (status == 429) ? "Too Many Requests"
             : (status == 500) ? "Internal Server Error" : "Status";
    snprintf(resp_head, sizeof(resp_head),
             "HTTP/1.1 %d %s\r\n"
             "Content-Type: application/json\r\n"
             "Content-Length: %lu\r\n"
             "Connection: close\r\n\r\n",
             status, reason, (unsigned long)body_len);
    send(c, resp_head, (int)strlen(resp_head), 0);
    if (body_len > 0) {
        send(c, body, (int)body_len, 0);
    }

    free(req.headers);
    free(req.body);

    if (g_mock_delay_ms > 0) {
        /* 让“超时”场景真的有时延；这里没有额外处理。 */
    }
}

static DWORD WINAPI mock_thread(LPVOID param)
{
    (void)param;
    while (g_mock_stop == 0) {
        SOCKET c = accept(g_listen, NULL, NULL);
        if (c == INVALID_SOCKET) break;
        mock_handle_client(c);
        closesocket(c);
    }
    return 0;
}

static int mock_start(void)
{
    WSADATA wsa;
    struct sockaddr_in addr;
    int addr_len = (int)sizeof(addr);
    u_long one = 1;

    if (WSAStartup(MAKEWORD(2, 2), &wsa) != 0) return 1;
    if (!g_mock_lock_ready) {
        InitializeCriticalSection(&g_mock_lock);
        g_mock_lock_ready = 1;
    }

    g_listen = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (g_listen == INVALID_SOCKET) return 1;
    setsockopt(g_listen, SOL_SOCKET, SO_REUSEADDR, (const char *)&one, sizeof(one));

    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = 0;
    if (bind(g_listen, (const struct sockaddr *)&addr, sizeof(addr)) != 0) return 1;
    if (listen(g_listen, 16) != 0) return 1;
    if (getsockname(g_listen, (struct sockaddr *)&addr, &addr_len) != 0) return 1;
    g_port = (int)ntohs(addr.sin_port);

    g_mock_stop = 0;
    g_mock_thread = CreateThread(NULL, 0, mock_thread, NULL, 0, NULL);
    return (g_mock_thread != NULL) ? 0 : 1;
}

static void mock_stop(void)
{
    g_mock_stop = 1;
    if (g_listen != INVALID_SOCKET) {
        closesocket(g_listen);
        g_listen = INVALID_SOCKET;
    }
    if (g_mock_thread != NULL) {
        WaitForSingleObject(g_mock_thread, 5000);
        CloseHandle(g_mock_thread);
        g_mock_thread = NULL;
    }
    mock_clear_requests();
    free(g_mock_body);
    g_mock_body = NULL;
    if (g_mock_lock_ready) {
        DeleteCriticalSection(&g_mock_lock);
        g_mock_lock_ready = 0;
    }
    WSACleanup();
}

/* ================================================================== */
/* 第二个 mock HTTP 服务（“另一个 origin”，只用于跨源 / 数据空间验证） */
/*                                                                     */
/* 与上面的主服务（A）完全独立：自己的监听端口（同样是动态空闲端口，   */
/* 避免与其它测试或系统服务冲突）。用途：当请求“本不该发出去”时，     */
/* 断言它一个字节都没收到；当跨源但无需鉴权时，断言没带 Authorization。*/
/* ================================================================== */

#define MOCK_B_AUTH_MAX 512

typedef struct MockB {
    SOCKET listen;
    HANDLE thread;
    volatile LONG stop;
    CRITICAL_SECTION lock;
    int lock_ready;
    int port;
    int count;                    /* 收到的请求数 */
    char last_auth[MOCK_B_AUTH_MAX]; /* 最后一次请求的 Authorization 头（空 = 没带） */
    char last_path[1024];
    int status;                   /* 响应状态码 */
    char *body;                   /* 响应体（owned） */
} MockB;

static MockB g_b;

static void mock_b_clear(void)
{
    if (!g_b.lock_ready) return;
    EnterCriticalSection(&g_b.lock);
    g_b.count = 0;
    g_b.last_auth[0] = '\0';
    g_b.last_path[0] = '\0';
    LeaveCriticalSection(&g_b.lock);
}

static int mock_b_count(void)
{
    int n;
    EnterCriticalSection(&g_b.lock);
    n = g_b.count;
    LeaveCriticalSection(&g_b.lock);
    return n;
}

static int mock_b_auth_present(void)
{
    int present;
    EnterCriticalSection(&g_b.lock);
    present = (g_b.last_auth[0] != '\0') ? 1 : 0;
    LeaveCriticalSection(&g_b.lock);
    return present;
}

static void mock_b_auth_copy(char *out, size_t out_sz)
{
    if (out == NULL || out_sz == 0) return;
    out[0] = '\0';
    EnterCriticalSection(&g_b.lock);
    snprintf(out, out_sz, "%s", g_b.last_auth);
    LeaveCriticalSection(&g_b.lock);
}

static void mock_b_set_response(int status, const char *body)
{
    EnterCriticalSection(&g_b.lock);
    g_b.status = status;
    free(g_b.body);
    g_b.body = (body != NULL) ? _strdup(body) : NULL;
    LeaveCriticalSection(&g_b.lock);
}

static void mock_b_handle_client(SOCKET c)
{
    char buf[32768];
    size_t len = 0;
    char *hend = NULL;
    long clen;
    size_t header_len;
    char resp_head[512];
    char body_copy[8192];
    const char *reason;
    int status;

    memset(buf, 0, sizeof(buf));
    for (;;) {
        int n;
        if (len + 1 >= sizeof(buf)) break;
        n = recv(c, buf + len, (int)(sizeof(buf) - 1 - len), 0);
        if (n <= 0) break;
        len += (size_t)n;
        buf[len] = '\0';
        hend = strstr(buf, "\r\n\r\n");
        if (hend != NULL) break;
    }
    if (hend == NULL) return;

    header_len = (size_t)(hend - buf) + 4;
    clen = header_content_length(buf);
    if (clen > 0) {
        size_t have = len - header_len;
        while ((long)have < clen && header_len + have + 1 < sizeof(buf)) {
            int n = recv(c, buf + header_len + have,
                         (int)(sizeof(buf) - 1 - header_len - have), 0);
            if (n <= 0) break;
            have += (size_t)n;
            len += (size_t)n;
            buf[len] = '\0';
        }
    }

    EnterCriticalSection(&g_b.lock);
    g_b.count++;
    g_b.last_auth[0] = '\0';
    g_b.last_path[0] = '\0';
    /* 请求行里的路径 */
    {
        char *sp1 = strchr(buf, ' ');
        if (sp1 != NULL) {
            char *sp2 = strchr(sp1 + 1, ' ');
            if (sp2 != NULL) {
                size_t pl = (size_t)(sp2 - (sp1 + 1));
                if (pl >= sizeof(g_b.last_path)) pl = sizeof(g_b.last_path) - 1;
                memcpy(g_b.last_path, sp1 + 1, pl);
                g_b.last_path[pl] = '\0';
            }
        }
    }
    /* Authorization 头（逐行判断，避免把别的头误当它） */
    {
        const char *p = strstr(buf, "\r\n");
        while (p != NULL) {
            const char *line = p + 2;
            const char *eol = strstr(line, "\r\n");
            if (eol == NULL || eol == line) break;
            if (line_starts_with_ci(line, (size_t)(eol - line), "authorization:")) {
                size_t n = (size_t)(eol - line);
                if (n >= sizeof(g_b.last_auth)) n = sizeof(g_b.last_auth) - 1;
                memcpy(g_b.last_auth, line, n);
                g_b.last_auth[n] = '\0';
                break;
            }
            p = eol;
        }
    }
    status = g_b.status;
    snprintf(body_copy, sizeof(body_copy), "%s", g_b.body != NULL ? g_b.body : "{}");
    LeaveCriticalSection(&g_b.lock);

    reason = (status == 200) ? "OK" : (status == 404) ? "Not Found" : "Status";
    snprintf(resp_head, sizeof(resp_head),
             "HTTP/1.1 %d %s\r\n"
             "Content-Type: application/json\r\n"
             "Content-Length: %lu\r\n"
             "Connection: close\r\n\r\n",
             status, reason, (unsigned long)strlen(body_copy));
    send(c, resp_head, (int)strlen(resp_head), 0);
    if (body_copy[0] != '\0') {
        send(c, body_copy, (int)strlen(body_copy), 0);
    }
}

static DWORD WINAPI mock_b_thread(LPVOID param)
{
    (void)param;
    while (g_b.stop == 0) {
        SOCKET c = accept(g_b.listen, NULL, NULL);
        if (c == INVALID_SOCKET) break;
        mock_b_handle_client(c);
        closesocket(c);
    }
    return 0;
}

static int mock_b_start(void)
{
    WSADATA wsa;
    struct sockaddr_in addr;
    int addr_len = (int)sizeof(addr);
    u_long one = 1;

    if (WSAStartup(MAKEWORD(2, 2), &wsa) != 0) return 1;
    if (!g_b.lock_ready) {
        InitializeCriticalSection(&g_b.lock);
        g_b.lock_ready = 1;
    }
    g_b.listen = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (g_b.listen == INVALID_SOCKET) return 1;
    setsockopt(g_b.listen, SOL_SOCKET, SO_REUSEADDR, (const char *)&one, sizeof(one));

    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = 0;                 /* 动态空闲端口 */
    if (bind(g_b.listen, (const struct sockaddr *)&addr, sizeof(addr)) != 0) return 1;
    if (listen(g_b.listen, 16) != 0) return 1;
    if (getsockname(g_b.listen, (struct sockaddr *)&addr, &addr_len) != 0) return 1;
    g_b.port = (int)ntohs(addr.sin_port);

    g_b.stop = 0;
    g_b.count = 0;
    g_b.last_auth[0] = '\0';
    g_b.last_path[0] = '\0';
    g_b.status = 200;
    g_b.body = _strdup("{\"data\":[{\"id\":\"b-model-1\"}]}");
    g_b.thread = CreateThread(NULL, 0, mock_b_thread, NULL, 0, NULL);
    return (g_b.thread != NULL) ? 0 : 1;
}

static void mock_b_stop(void)
{
    g_b.stop = 1;
    if (g_b.listen != INVALID_SOCKET) {
        closesocket(g_b.listen);
        g_b.listen = INVALID_SOCKET;
    }
    if (g_b.thread != NULL) {
        WaitForSingleObject(g_b.thread, 5000);
        CloseHandle(g_b.thread);
        g_b.thread = NULL;
    }
    if (g_b.lock_ready) {
        EnterCriticalSection(&g_b.lock);
        free(g_b.body);
        g_b.body = NULL;
        LeaveCriticalSection(&g_b.lock);
        DeleteCriticalSection(&g_b.lock);
        g_b.lock_ready = 0;
    }
    WSACleanup();
}

/* ================================================================== */
/* 测试用计划与响应                                                    */
/* ================================================================== */

/* 一份能通过 ts_plan_parse 校验的最小计划（作为模型正文）。 */
static const char *PLAN_CONTENT =
    "{\"schema_version\":\"1.0\",\"tasks\":[{"
    "\"id\":\"T1\",\"name\":\"整理材料\",\"depends_on\":[],\"preconditions\":[],"
    "\"steps\":[\"通读材料\"],\"urgency\":3,\"urgency_reason\":\"一般\","
    "\"impact\":4,\"impact_reason\":\"影响后续\",\"estimated_hours\":2.0,"
    "\"estimate_reason\":\"经验估计\",\"deadline\":null,"
    "\"source_refs\":[\"文段1:段落1\"]}]}";

/* 把文本转义成 JSON 字符串内容。 */
static void json_escape_into(const char *in, char *out, size_t sz)
{
    size_t o = 0;
    const char *p = in != NULL ? in : "";
    while (*p != '\0' && o + 2 < sz) {
        unsigned char ch = (unsigned char)*p++;
        if (ch == '"' || ch == '\\') {
            out[o++] = '\\';
            out[o++] = (char)ch;
        } else if (ch == '\n') {
            out[o++] = '\\';
            out[o++] = 'n';
        } else if (ch == '\r') {
            out[o++] = '\\';
            out[o++] = 'r';
        } else if (ch == '\t') {
            out[o++] = '\\';
            out[o++] = 't';
        } else if (ch < 0x20) {
            /* 丢掉控制字符 */
        } else {
            out[o++] = (char)ch;
        }
    }
    out[o] = '\0';
}

/* 构造一份 OpenAI 兼容的 Chat Completions 响应（owned）。 */
static char *chat_response(const char *content, const char *finish_reason)
{
    char esc[16384];
    char body[20480];
    json_escape_into(content, esc, sizeof(esc));
    snprintf(body, sizeof(body),
             "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"%s\"},"
             "\"finish_reason\":\"%s\"}],"
             "\"usage\":{\"prompt_tokens\":11,\"completion_tokens\":22,"
             "\"total_tokens\":33}}",
             esc, finish_reason != NULL ? finish_reason : "stop");
    return _strdup(body);
}

/* 模型列表响应（owned）。 */
static char *models_response(void)
{
    return _strdup("{\"data\":[{\"id\":\"mock-model-a\"},"
                   "{\"id\":\"mock-model-b\"},\"mock-model-c\"]}");
}

/* ================================================================== */
/* 桥接辅助                                                            */
/* ================================================================== */

static char g_dir[MAX_PATH];
static char g_cfg_path[MAX_PATH * 2];

static void join_path(char *out, size_t sz, const char *name)
{
    snprintf(out, sz, "%s\\%s", g_dir, name);
}

static int write_config(void)
{
    char buf[4096];
    snprintf(buf, sizeof(buf),
             "{\n"
             "  \"endpoint_url\": \"http://127.0.0.1:%d/base/chat/completions\",\n"
             "  \"model\": \"base-model\",\n"
             "  \"api_key_env\": \"\",\n"
             "  \"mock_mode\": false,\n"
             "  \"connect_timeout_ms\": 5000,\n"
             "  \"wait_prompt_ms\": 120000,\n"
             "  \"request_timeout_ms\": 0,\n"
             "  \"probe_timeout_ms\": 30000,\n"
             "  \"max_retry_attempts\": 0,\n"
             "  \"json_mode\": true,\n"
             "  \"max_input_bytes\": 262144,\n"
             "  \"max_response_bytes\": 2097152\n"
             "}\n",
             g_port);
    write_file(g_cfg_path, buf);
    return 0;
}

static void clear_settings_files(void)
{
    char p[MAX_PATH * 2];
    join_path(p, sizeof(p), "settings.json");
    DeleteFileA(p);
    join_path(p, sizeof(p), "settings.json.bak");
    DeleteFileA(p);
    join_path(p, sizeof(p), "settings.json.tmp");
    DeleteFileA(p);
}

static int file_exists_any(const char *path)
{
    DWORD a = GetFileAttributesA(path);
    return (a != INVALID_FILE_ATTRIBUTES && (a & FILE_ATTRIBUTE_DIRECTORY) == 0) ? 1 : 0;
}

static void free_buffer(TsBridgeBuffer *b)
{
    ts_bridge_free(b);
}

/* 调用 settings_save 并把返回 JSON 交给调用方（成功/失败都写 out）。 */
static int save_settings_capture(TsBridge *bridge, const char *profiles_json,
                                 const char *default_id, const char *default_model,
                                 const char *deleted_ids_json, TsBridgeBuffer *out)
{
    char *json;
    size_t need;
    int rc;

    need = strlen(profiles_json) + 512 +
           (default_id ? strlen(default_id) : 0) +
           (default_model ? strlen(default_model) : 0) +
           (deleted_ids_json ? strlen(deleted_ids_json) : 0);
    json = (char *)malloc(need);
    if (json == NULL) return 1;
    snprintf(json, need,
             "{\"schemaVersion\":2,\"defaultProfileId\":\"%s\",\"defaultModelId\":\"%s\","
             "\"defaultThinking\":\"disabled\",\"profiles\":[%s]%s%s%s}",
             default_id != NULL ? default_id : "",
             default_model != NULL ? default_model : "",
             profiles_json,
             deleted_ids_json != NULL ? ",\"deletedProfileIds\":" : "",
             deleted_ids_json != NULL ? deleted_ids_json : "",
             "");
    rc = ts_bridge_settings_save(bridge, json, strlen(json), out);
    free(json);
    return rc;
}

/* 调用 settings_save；成功返回 0。 */
static int save_settings(TsBridge *bridge, const char *profiles_json,
                         const char *default_id, const char *default_model,
                         const char *deleted_ids_json)
{
    TsBridgeBuffer out;
    int rc;

    memset(&out, 0, sizeof(out));
    rc = save_settings_capture(bridge, profiles_json, default_id, default_model,
                               deleted_ids_json, &out);
    if (rc != 0) {
        printf("    保存设置失败：%s\n", out.data != NULL ? out.data : "(无信息)");
    }
    free_buffer(&out);
    return rc;
}

/*
 * 新建一个干净的桥接实例：
 *   清掉 settings.json → create_ex（会先做一次旧配置迁移）
 *   → 用给定 profiles 覆盖设置（并删除迁移出来的 legacy-config）。
 * 每个 profile 的 revision 因此都从 1 开始，测试可预测。
 */
static TsBridge *new_bridge(const char *profiles_json, const char *default_id,
                            const char *default_model, TsBridgeBuffer *out_err)
{
    TsBridge *bridge = NULL;
    int rc;

    clear_settings_files();
    if (write_config() != 0) return NULL;
    rc = ts_bridge_create_ex(g_cfg_path, g_dir, &bridge, out_err);
    if (rc != 0) {
        printf("    创建桥接失败：%s\n",
               (out_err != NULL && out_err->data != NULL) ? out_err->data : "(无信息)");
        return NULL;
    }
    if (profiles_json != NULL) {
        if (save_settings(bridge, profiles_json, default_id, default_model,
                          "[\"legacy-config\"]") != 0) {
            ts_bridge_shutdown_begin(bridge);
            ts_bridge_destroy(bridge);
            return NULL;
        }
    }
    return bridge;
}

static int poll_terminal(TsBridge *bridge, TsJobId job, int max_ms)
{
    int waited = 0;
    while (waited < max_ms) {
        TsBridgeBuffer ev;
        int done = 0;
        memset(&ev, 0, sizeof(ev));
        if (ts_bridge_poll(bridge, job, &ev) != 0) {
            free_buffer(&ev);
            return 0;
        }
        if (ev.data != NULL && contains(ev.data, "\"terminal\":true")) done = 1;
        free_buffer(&ev);
        if (done) return 1;
        Sleep(20);
        waited += 20;
    }
    return 0;
}

static int get_result(TsBridge *bridge, TsJobId job, TsBridgeBuffer *out)
{
    memset(out, 0, sizeof(*out));
    return ts_bridge_result(bridge, job, out);
}

/* 启动一次分析；要求成功。 */
static int start_analyze(TsBridge *bridge, const char *selection_json, TsJobId *out_job)
{
    char req[4096];
    TsBridgeBuffer err;
    int rc;

    if (selection_json != NULL) {
        snprintf(req, sizeof(req),
                 "{\"conversationId\":\"c-1\",\"requestId\":\"r-1\","
                 "\"baseVersionId\":null,\"baseRevision\":0,"
                 "\"userRequest\":\"测试请求\","
                 "\"sources\":[{\"kind\":\"text\",\"label\":\"文段1\","
                 "\"text\":\"这是一段用于测试的文本材料。\"}],"
                 "\"modelSelection\":%s}", selection_json);
    } else {
        snprintf(req, sizeof(req),
                 "{\"conversationId\":\"c-1\",\"requestId\":\"r-1\","
                 "\"baseVersionId\":null,\"baseRevision\":0,"
                 "\"userRequest\":\"测试请求\","
                 "\"sources\":[{\"kind\":\"text\",\"label\":\"文段1\","
                 "\"text\":\"这是一段用于测试的文本材料。\"}]}");
    }
    memset(&err, 0, sizeof(err));
    rc = ts_bridge_analyze_async(bridge, req, strlen(req), out_job, &err);
    if (rc != 0) {
        printf("    启动分析失败：%s\n", err.data != NULL ? err.data : "(无信息)");
    }
    free_buffer(&err);
    return rc;
}

/* 一次完整的分析：启动 → 等终态 → 取结果 → 释放。 */
static int run_analyze(TsBridge *bridge, const char *selection_json,
                       TsBridgeBuffer *out_result, char *err, size_t err_sz)
{
    TsJobId job = 0;
    int rc;

    if (err != NULL && err_sz > 0) err[0] = '\0';
    if (out_result != NULL) { out_result->data = NULL; out_result->length = 0; }
    if (start_analyze(bridge, selection_json, &job) != 0) return 1;
    if (!poll_terminal(bridge, job, 20000)) {
        if (err != NULL) snprintf(err, err_sz, "分析未在超时前进入终态");
        ts_bridge_release_job(bridge, job);
        return 1;
    }
    rc = get_result(bridge, job, out_result);
    ts_bridge_release_job(bridge, job);
    return rc;
}

static int start_probe(TsBridge *bridge, const char *probe_json, TsJobId *out_job)
{
    TsBridgeBuffer err;
    int rc;
    memset(&err, 0, sizeof(err));
    rc = ts_bridge_probe_async(bridge, probe_json, strlen(probe_json), out_job, &err);
    if (rc != 0) {
        printf("    启动探针失败：%s\n", err.data != NULL ? err.data : "(无信息)");
    }
    free_buffer(&err);
    return rc;
}

static int run_probe(TsBridge *bridge, const char *probe_json, TsBridgeBuffer *out)
{
    TsJobId job = 0;
    int rc;
    memset(out, 0, sizeof(*out));
    if (start_probe(bridge, probe_json, &job) != 0) return 1;
    if (!poll_terminal(bridge, job, 30000)) {
        ts_bridge_release_job(bridge, job);
        return 1;
    }
    rc = get_result(bridge, job, out);
    ts_bridge_release_job(bridge, job);
    return rc;
}

/* 当前记录的第 index 个请求体（owned）。 */
static char *req_body(int index)
{
    char m[16], p[1024], *h = NULL, *b = NULL;
    mock_request_snapshot(index, m, sizeof(m), p, sizeof(p), &h, &b);
    free(h);
    return b;
}

static char *req_path(int index)
{
    char m[16], p[1024], *h = NULL, *b = NULL;
    char *out;
    mock_request_snapshot(index, m, sizeof(m), p, sizeof(p), &h, &b);
    free(h);
    free(b);
    out = _strdup(p);
    return out;
}

static char *req_headers(int index)
{
    char m[16], p[1024], *h = NULL, *b = NULL;
    char *out;
    mock_request_snapshot(index, m, sizeof(m), p, sizeof(p), &h, &b);
    free(b);
    out = h;
    return out;
}

/* 用端口替换 profiles JSON 里的 ${PORT} 占位符。 */
static void expand_port(const char *in, char *out, size_t out_sz)
{
    char port[16];
    const char *p = in;
    size_t o = 0;
    snprintf(port, sizeof(port), "%d", g_port);
    while (*p != '\0' && o + 1 < out_sz) {
        if (p[0] == '$' && p[1] == '{' && strncmp(p + 2, "PORT}", 5) == 0) {
            size_t n = strlen(port);
            if (o + n >= out_sz) break;
            memcpy(out + o, port, n);
            o += n;
            p += 7;
        } else {
            out[o++] = *p++;
        }
    }
    out[o] = '\0';
}

/* 单个 profile 的 JSON 片段（revision 由调用方给）。 */
static void profile_json(char *out, size_t out_sz, const char *id, const char *name,
                         long revision, const char *protocol, const char *base_path,
                         const char *auth_mode, const char *model_id,
                         const char *thinking, const char *effort, int json_mode)
{
    snprintf(out, out_sz,
             "{\"id\":\"%s\",\"name\":\"%s\",\"revision\":%ld,\"protocol\":\"%s\","
             "\"baseUrl\":\"http://127.0.0.1:${PORT}\","
             "\"chatUrl\":\"http://127.0.0.1:${PORT}%s/chat/completions\","
             "\"modelsUrl\":\"http://127.0.0.1:${PORT}%s/models\","
             "\"authMode\":\"%s\",\"apiKeyEnv\":\"\",\"modelId\":\"%s\","
             "\"thinking\":\"%s\",%s%s%s\"jsonMode\":%s}",
             id, name != NULL ? name : id, revision, protocol, base_path, base_path,
             auth_mode, model_id, thinking,
             (effort != NULL) ? "\"reasoningEffort\":\"" : "",
             (effort != NULL) ? effort : "",
             (effort != NULL) ? "\"," : "",
             json_mode ? "true" : "false");
}

/*
 * 单个 profile 的 JSON 片段：chatUrl / modelsUrl / 认证方式 / 环境变量
 * 完全由调用方给出（用于构造 A/B 两个 origin、旧式 settings.json 等场景）。
 */
static void profile_json_full(char *out, size_t out_sz, const char *id, long revision,
                              const char *chat_url, const char *models_url,
                              const char *auth_mode, const char *api_key_env,
                              const char *model_id)
{
    snprintf(out, out_sz,
             "{\"id\":\"%s\",\"name\":\"%s\",\"revision\":%ld,"
             "\"protocol\":\"deepseek-chat\",\"baseUrl\":\"\","
             "\"chatUrl\":\"%s\",\"modelsUrl\":\"%s\","
             "\"authMode\":\"%s\",\"apiKeyEnv\":\"%s\",\"modelId\":\"%s\","
             "\"thinking\":\"disabled\",\"jsonMode\":true}",
             id, id, revision, chat_url, models_url,
             (auth_mode != NULL) ? auth_mode : "bearer",
             (api_key_env != NULL) ? api_key_env : "",
             model_id);
}

/* 读整个文件（malloc 的文本；失败返回 NULL）。 */
static char *read_text(const char *path)
{
    FILE *f = fopen(path, "rb");
    long sz;
    char *data;

    if (f == NULL) return NULL;
    fseek(f, 0, SEEK_END);
    sz = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (sz < 0) { fclose(f); return NULL; }
    data = (char *)malloc((size_t)sz + 1);
    if (data == NULL) { fclose(f); return NULL; }
    if (fread(data, 1, (size_t)sz, f) != (size_t)sz) {
        free(data);
        fclose(f);
        return NULL;
    }
    data[sz] = '\0';
    fclose(f);
    return data;
}

/* 建一个测试用子目录并清掉其中可能残留的设置文件。 */
static void prepare_dir(const char *dir)
{
    char p[MAX_PATH * 2];
    CreateDirectoryA(dir, NULL);
    snprintf(p, sizeof(p), "%s\\settings.json", dir);
    DeleteFileA(p);
    snprintf(p, sizeof(p), "%s\\settings.json.bak", dir);
    DeleteFileA(p);
    snprintf(p, sizeof(p), "%s\\settings.json.tmp", dir);
    DeleteFileA(p);
    RemoveDirectoryA(p);   /* 万一上次测试把 .tmp 建成了目录 */
}

/* 删除测试子目录（只删设置文件与目录本身，绝不递归删别的东西）。 */
static void cleanup_dir(const char *dir)
{
    char p[MAX_PATH * 2];
    snprintf(p, sizeof(p), "%s\\settings.json", dir);
    DeleteFileA(p);
    snprintf(p, sizeof(p), "%s\\settings.json.bak", dir);
    DeleteFileA(p);
    snprintf(p, sizeof(p), "%s\\settings.json.tmp", dir);
    DeleteFileA(p);
    RemoveDirectoryA(p);
    RemoveDirectoryA(dir);
}

/* 当前 settings.json 的绝对路径（g_dir 下）。 */
static void settings_path(char *out, size_t out_sz)
{
    snprintf(out, out_sz, "%s\\settings.json", g_dir);
}

/* ================================================================== */
/* 1. 请求捕获：模型 / URL / thinking / effort 随选择变化              */
/* ================================================================== */

static void test_request_capture(void)
{
    char raw[4096];
    char profiles[4096];
    char p1[1200], p2[1200], p3[1200];
    TsBridge *bridge;
    TsBridgeBuffer err;
    TsBridgeBuffer res;
    int rc;
    int base;

    printf("\n== 1. 请求捕获（模型 / URL / thinking / effort）==\n");

    profile_json(p1, sizeof(p1), "ds-on", "DS 思考开", 0, "deepseek-chat",
                 "/v1/dson", "none", "model-ds-on", "enabled", "high", 1);
    profile_json(p2, sizeof(p2), "ds-off", "DS 思考关", 0, "deepseek-chat",
                 "/v1/dsoff", "none", "model-ds-off", "disabled", NULL, 1);
    profile_json(p3, sizeof(p3), "oa", "OpenAI 兼容", 0, "openai-chat",
                 "/v1/oa", "none", "model-oa", "unsupported", NULL, 0);
    snprintf(profiles, sizeof(profiles), "%s,%s,%s", p1, p2, p3);
    expand_port(profiles, raw, sizeof(raw));

    memset(&err, 0, sizeof(err));
    bridge = new_bridge(raw, "ds-on", "model-ds-on", &err);
    free_buffer(&err);
    CHECK(bridge != NULL, "1 桥接创建成功并写入 3 个 profile");
    if (bridge == NULL) return;

    /* 准备响应：一份合法计划 */
    {
        char *resp = chat_response(PLAN_CONTENT, "stop");
        mock_set_response(200, resp);
        free(resp);
    }

    /* 1a. deepseek-chat + thinking=enabled + effort=high */
    mock_clear_requests();
    base = mock_request_count();
    rc = run_analyze(bridge,
                     "{\"profileId\":\"ds-on\",\"profileRevision\":1,"
                     "\"modelId\":\"model-ds-on\",\"thinking\":\"enabled\","
                     "\"reasoningEffort\":\"high\"}",
                     &res, NULL, 0);
    CHECK(rc == 0 && res.data != NULL && contains(res.data, "\"ok\":true"),
          "1a 分析成功（mock 服务返回合法计划）");
    {
        char *path = req_path(base);
        char *body = req_body(base);
        CHECK(path != NULL && strcmp(path, "/v1/dson/chat/completions") == 0,
              "1a 请求打到所选 profile 的完整 chatUrl（不拼 /v1）");
        CHECK(body != NULL && contains(body, "\"model\":\"model-ds-on\""),
              "1a 请求体使用所选的模型 ID");

        CHECK(body != NULL && contains(body, "\"thinking\":{\"type\":\"enabled\"}"),
              "1a 请求体带 thinking.type=enabled");
        CHECK(body != NULL && contains(body, "\"reasoning_effort\":\"high\""),
              "1a 请求体带 reasoning_effort=high");
        free(path);
        free(body);
    }
    free_buffer(&res);

    /* 1b. deepseek-chat + thinking=disabled → 无 effort */
    mock_clear_requests();
    base = mock_request_count();
    rc = run_analyze(bridge,
                     "{\"profileId\":\"ds-off\",\"profileRevision\":1,"
                     "\"modelId\":\"model-ds-off\",\"thinking\":\"disabled\"}",
                     &res, NULL, 0);
    CHECK(rc == 0 && res.data != NULL && contains(res.data, "\"ok\":true"),
          "1b 关闭思考的分析成功");
    {
        char *path = req_path(base);
        char *body = req_body(base);
        CHECK(path != NULL && strcmp(path, "/v1/dsoff/chat/completions") == 0,
              "1b 请求 URL 随 profile 变化");
        CHECK(body != NULL && contains(body, "\"thinking\":{\"type\":\"disabled\"}"),
              "1b 请求体带 thinking.type=disabled");
        CHECK(body != NULL && !contains(body, "reasoning_effort"),
              "1b 关闭思考时请求体**没有** reasoning_effort（无残留）");
        free(path);
        free(body);
    }
    free_buffer(&res);

    /* 1c. openai-chat → 绝不发送 thinking / reasoning_effort */
    mock_clear_requests();
    base = mock_request_count();
    rc = run_analyze(bridge,
                     "{\"profileId\":\"oa\",\"profileRevision\":1,"
                     "\"modelId\":\"model-oa\",\"thinking\":\"unsupported\"}",
                     &res, NULL, 0);
    CHECK(rc == 0 && res.data != NULL && contains(res.data, "\"ok\":true"),
          "1c openai-chat 分析成功");
    {
        char *body = req_body(base);
        CHECK(body != NULL && contains(body, "\"model\":\"model-oa\""),
              "1c 请求体使用 openai-chat 的模型 ID");
        CHECK(body != NULL && !contains(body, "thinking"),
              "1c openai-chat 请求体不含 thinking");
        CHECK(body != NULL && !contains(body, "reasoning_effort"),
              "1c openai-chat 请求体不含 reasoning_effort");
        free(body);
    }
    free_buffer(&res);

    /* 1d. 结果里带 source（无密钥） */
    mock_clear_requests();
    rc = run_analyze(bridge,
                     "{\"profileId\":\"ds-on\",\"profileRevision\":1,"
                     "\"modelId\":\"model-ds-on\",\"thinking\":\"enabled\","
                     "\"reasoningEffort\":\"high\"}",
                     &res, NULL, 0);
    CHECK(rc == 0 && res.data != NULL && contains(res.data, "\"source\""),
          "1d 成功结果带 source");
    CHECK(res.data != NULL && contains(res.data, "\"protocol\":\"deepseek-chat\"") &&
          contains(res.data, "\"profileRevision\":1"),
          "1d source 含 protocol / profileRevision");
    CHECK(res.data != NULL && contains(res.data, "\"endpointHost\":\"127.0.0.1\""),
          "1d source 含 endpointHost");
    CHECK(res.data != NULL && !contains(res.data, "sk-"),
          "1d source 不含任何密钥");
    free_buffer(&res);

    ts_bridge_shutdown_begin(bridge);
    ts_bridge_destroy(bridge);
}

/* ================================================================== */
/* 2. 运行中保存配置：旧 job 不受影响，新 job 用新配置                 */
/* ================================================================== */

static void test_snapshot_isolation(void)
{
    char profiles[1024];
    char p1[1200];
    char *resp;
    TsBridge *bridge;
    TsBridgeBuffer err;
    TsBridgeBuffer res;
    TsJobId job = 0;
    int base;

    printf("\n== 2. 运行中保存配置（快照隔离）==\n");

    profile_json(p1, sizeof(p1), "p-main", "主连接", 0, "deepseek-chat",
                 "/v1/main", "none", "model-old", "disabled", NULL, 1);
    expand_port(p1, profiles, sizeof(profiles));

    memset(&err, 0, sizeof(err));
    bridge = new_bridge(profiles, "p-main", "model-old", &err);
    free_buffer(&err);
    CHECK(bridge != NULL, "2 桥接创建成功");
    if (bridge == NULL) return;

    resp = chat_response(PLAN_CONTENT, "stop");
    mock_set_response(200, resp);
    free(resp);

    /* 让服务端慢一点，确保“保存设置”发生在任务运行期间。 */
    mock_set_delay(1200);
    mock_clear_requests();
    base = mock_request_count();
    CHECK(start_analyze(bridge,
                        "{\"profileId\":\"p-main\",\"profileRevision\":1,"
                        "\"modelId\":\"model-old\",\"thinking\":\"disabled\"}",
                        &job) == 0, "2 启动分析（使用旧配置）");
    Sleep(250);

    /* 运行中保存：模型改名 → revision 1 → 2 */
    {
        char p1b[1200];
        char profiles2[1024];
        profile_json(p1b, sizeof(p1b), "p-main", "主连接", 1, "deepseek-chat",
                     "/v1/main", "none", "model-new", "disabled", NULL, 1);
        expand_port(p1b, profiles2, sizeof(profiles2));
        CHECK(save_settings(bridge, profiles2, "p-main", "model-new", NULL) == 0,
              "2 运行中保存设置成功（模型已改）");
    }

    CHECK(poll_terminal(bridge, job, 20000), "2 旧任务仍能正常结束");
    CHECK(get_result(bridge, job, &res) == 0 && res.data != NULL &&
          contains(res.data, "\"ok\":true"), "2 旧任务结果成功");
    CHECK(res.data != NULL && contains(res.data, "\"profileRevision\":1"),
          "2 旧任务的结果 source 仍是 revision 1（快照）");
    free_buffer(&res);

    {
        char *body = req_body(base);
        CHECK(body != NULL && contains(body, "\"model\":\"model-old\""),
              "2 旧任务的请求体仍是旧模型（保存配置不影响运行中任务）");
        free(body);
    }
    CHECK(ts_bridge_release_job(bridge, job) == 0, "2 旧任务可释放");

    /* 新任务必须用新配置 */
    mock_set_delay(0);
    mock_clear_requests();
    base = mock_request_count();
    CHECK(run_analyze(bridge,
                      "{\"profileId\":\"p-main\",\"profileRevision\":2,"
                      "\"modelId\":\"model-new\",\"thinking\":\"disabled\"}",
                      &res, NULL, 0) == 0 && res.data != NULL &&
          contains(res.data, "\"ok\":true"), "2 新任务分析成功");
    {
        char *body = req_body(base);
        CHECK(body != NULL && contains(body, "\"model\":\"model-new\""),
              "2 新任务的请求体使用新模型");
        free(body);
    }
    free_buffer(&res);

    ts_bridge_shutdown_begin(bridge);
    ts_bridge_destroy(bridge);
}

/* ================================================================== */
/* 3. 鉴权：authMode=none / bearer / 主机变更拒绝                      */
/* ================================================================== */

static void test_auth_modes(void)
{
    char raw[4096];
    char profiles[3072];
    char p1[1200], p2[1200];
    TsBridge *bridge;
    TsBridgeBuffer err;
    TsBridgeBuffer res;
    int base;
    int rc;

    printf("\n== 3. authMode=none / bearer / 主机变更 ==\n");

    profile_json(p1, sizeof(p1), "p-none", "无鉴权", 0, "deepseek-chat",
                 "/v1/none", "none", "model-none", "disabled", NULL, 1);
    profile_json(p2, sizeof(p2), "p-bearer", "有鉴权", 0, "deepseek-chat",
                 "/v1/bearer", "bearer", "model-bearer", "disabled", NULL, 1);
    snprintf(profiles, sizeof(profiles), "%s,%s", p1, p2);
    expand_port(profiles, raw, sizeof(raw));

    memset(&err, 0, sizeof(err));
    bridge = new_bridge(raw, "p-none", "model-none", &err);
    free_buffer(&err);
    CHECK(bridge != NULL, "3 桥接创建成功");
    if (bridge == NULL) return;

    {
        char *resp = chat_response(PLAN_CONTENT, "stop");
        mock_set_response(200, resp);
        free(resp);
    }

    /* 3a. authMode=none：不发 Authorization */
    mock_clear_requests();
    base = mock_request_count();
    rc = run_analyze(bridge,
                     "{\"profileId\":\"p-none\",\"profileRevision\":1,"
                     "\"modelId\":\"model-none\",\"thinking\":\"disabled\"}",
                     &res, NULL, 0);
    CHECK(rc == 0 && res.data != NULL && contains(res.data, "\"ok\":true"),
          "3a authMode=none 分析成功");
    {
        char *h = req_headers(base);
        CHECK(h != NULL && !contains_ci(h, "authorization"),
              "3a authMode=none 时**不**发送 Authorization 头");
        CHECK(h != NULL && !contains_ci(h, "bearer"),
              "3a authMode=none 时头里没有 Bearer");
        free(h);
    }
    free_buffer(&res);

    /* 3b. bearer + 已保存凭据：发 Authorization */
    {
        TsBridgeBuffer cerr;
        memset(&cerr, 0, sizeof(cerr));
        CHECK(ts_bridge_credential_set(bridge, "p-bearer", "sk-test-probe-bearer-0001",
                                       strlen("sk-test-probe-bearer-0001"), &cerr) == 0,
              "3b 保存凭据成功");
        CHECK(cerr.data != NULL && contains(cerr.data, "\"ok\":true"), "3b 凭据接口返回 ok");
        CHECK(cerr.data != NULL && !contains(cerr.data, "sk-test-probe-bearer-0001"),
              "3b 凭据接口不返回密钥内容");
        free_buffer(&cerr);
    }
    mock_clear_requests();
    base = mock_request_count();
    rc = run_analyze(bridge,
                     "{\"profileId\":\"p-bearer\",\"profileRevision\":1,"
                     "\"modelId\":\"model-bearer\",\"thinking\":\"disabled\"}",
                     &res, NULL, 0);
    CHECK(rc == 0 && res.data != NULL && contains(res.data, "\"ok\":true"),
          "3b bearer 分析成功");
    {
        char *h = req_headers(base);
        CHECK(h != NULL && contains_ci(h, "authorization: bearer sk-test-probe-bearer"),
              "3b bearer 时发送 Authorization: Bearer …（内容不外泄到结果里）");
        free(h);
    }
    CHECK(res.data != NULL && !contains(res.data, "sk-test-probe-bearer"),
          "3b 结果 JSON 不含密钥");
    free_buffer(&res);

    /* settings_get 也不能泄露密钥 */
    {
        TsBridgeBuffer s;
        memset(&s, 0, sizeof(s));
        CHECK(ts_bridge_settings_get(bridge, &s) == 0 && s.data != NULL,
              "3b settings_get 可读");
        CHECK(s.data != NULL && !contains(s.data, "sk-test-probe-bearer"),
              "3b settings_get 不含密钥");
        CHECK(s.data != NULL && contains(s.data, "\"credentialConfigured\":true"),
              "3b settings_get 报告凭据已配置");
        free_buffer(&s);
    }

    /* 3c. 主机变更：旧凭据不得发到新地址 */
    {
        char p2b[1200];
        char profiles2[2048];
        profile_json(p2b, sizeof(p2b), "p-bearer", "有鉴权", 1, "deepseek-chat",
                     "/v1/bearer", "bearer", "model-bearer", "disabled", NULL, 1);
        /* 把 127.0.0.1 换成 localhost：同一服务、同一端口，但 host 不同 */
        {
            char expanded[2048];
            char out2[2048];
            size_t o = 0;
            const char *src;
            expand_port(p2b, expanded, sizeof(expanded));
            src = expanded;
            while (*src != '\0' && o + 16 < sizeof(out2)) {
                if (strncmp(src, "127.0.0.1", 9) == 0) {
                    memcpy(out2 + o, "localhost", 9);
                    o += 9;
                    src += 9;
                } else {
                    out2[o++] = *src++;
                }
            }
            out2[o] = '\0';
            snprintf(profiles2, sizeof(profiles2), "%s", out2);
        }
        CHECK(save_settings(bridge, profiles2, "p-bearer", "model-bearer", NULL) == 0,
              "3c 修改连接地址（同端口不同 host）成功");
    }
    mock_clear_requests();
    base = mock_request_count();
    {
        TsBridgeBuffer e;
        TsJobId j = 0;
        char req[2048];
        snprintf(req, sizeof(req),
                 "{\"conversationId\":\"c\",\"requestId\":\"r\","
                 "\"userRequest\":\"x\",\"sources\":[],"
                 "\"modelSelection\":{\"profileId\":\"p-bearer\","
                 "\"profileRevision\":2,\"modelId\":\"model-bearer\","
                 "\"thinking\":\"disabled\"}}");
        memset(&e, 0, sizeof(e));
        rc = ts_bridge_analyze_async(bridge, req, strlen(req), &j, &e);
        CHECK(rc != 0 && e.data != NULL && contains(e.data, "\"ok\":false"),
              "3c 主机变更后请求被拒绝（不发送）");
        CHECK(e.data != NULL && contains(e.data, "\"errorKind\":\"config\""),
              "3c 错误分类为配置错误");
        CHECK(e.data != NULL && contains(e.data, "连接地址已更换"),
              "3c 提示“连接地址已更换…请重新输入 API Key”");
        CHECK(e.data != NULL && !contains(e.data, "sk-test-probe-bearer"),
              "3c 错误信息不含旧密钥");
        free_buffer(&e);
    }
    CHECK(mock_request_count() == base, "3c 拒绝时**没有**发出任何请求（旧密钥不外发）");

    ts_bridge_shutdown_begin(bridge);
    ts_bridge_destroy(bridge);

    /* 清理测试凭据（测试后必须删掉 Windows 凭据管理器里的测试条目）。 */
    {
        char cerr[512];
        char space[TS_CREDENTIAL_SPACE_MAX];
        cerr[0] = '\0';
        /*
         * bridge 现在把凭据写在“数据空间”目标名下
         * （TaskScheduler/model/<space>/<profileId>），所以清理必须用 scoped 接口
         * （它同时删除旧目标，不会留下孤儿条目）。
         */
        ts_credential_space_id(g_dir, space, sizeof(space));
        CHECK(ts_credential_delete_scoped(space, "p-bearer", cerr, sizeof(cerr)) == 0,
              "3c 测试凭据已从凭据管理器删除");
        CHECK(!ts_credential_exists_scoped(space, "p-bearer"), "3c 测试凭据确认不存在");
        CHECK(!ts_credential_exists("p-bearer"), "3c 旧目标也没有残留");
    }
}

/* ================================================================== */
/* 4. 未知 revision / 删除 profile                                     */
/* ================================================================== */

static void test_revision_and_delete(void)
{
    char raw[2048];
    char profiles[2048];
    char p1[1200], p2[1200];
    TsBridge *bridge;
    TsBridgeBuffer err;
    TsBridgeBuffer res;
    TsJobId job = 0;
    int rc;

    printf("\n== 4. 未知 revision / 删除 profile ==\n");

    profile_json(p1, sizeof(p1), "p-a", "连接 A", 0, "deepseek-chat",
                 "/v1/a", "none", "model-a", "disabled", NULL, 1);
    profile_json(p2, sizeof(p2), "p-b", "连接 B", 0, "deepseek-chat",
                 "/v1/b", "none", "model-b", "disabled", NULL, 1);
    snprintf(profiles, sizeof(profiles), "%s,%s", p1, p2);
    expand_port(profiles, raw, sizeof(raw));

    memset(&err, 0, sizeof(err));
    bridge = new_bridge(raw, "p-a", "model-a", &err);
    free_buffer(&err);
    CHECK(bridge != NULL, "4 桥接创建成功");
    if (bridge == NULL) return;

    {
        char *resp = chat_response(PLAN_CONTENT, "stop");
        mock_set_response(200, resp);
        free(resp);
    }

    /* 4a. 未知 revision：立即失败，不创建 job */
    {
        TsBridgeBuffer e;
        TsJobId j = 12345;
        char req[2048];
        snprintf(req, sizeof(req),
                 "{\"conversationId\":\"c\",\"requestId\":\"r\","
                 "\"userRequest\":\"x\",\"sources\":[],"
                 "\"modelSelection\":{\"profileId\":\"p-a\",\"profileRevision\":999,"
                 "\"modelId\":\"model-a\",\"thinking\":\"disabled\"}}");
        memset(&e, 0, sizeof(e));
        rc = ts_bridge_analyze_async(bridge, req, strlen(req), &j, &e);
        CHECK(rc != 0, "4a 未知 revision 明确失败");
        CHECK(j == 0, "4a 失败时没有创建 job（job id 为 0）");
        CHECK(e.data != NULL && contains(e.data, "\"ok\":false"),
              "4a 返回 ok=false");
        free_buffer(&e);
    }

    /* 4b. 不存在的 profile：profileDeleted */
    {
        TsBridgeBuffer e;
        TsJobId j = 0;
        char req[2048];
        snprintf(req, sizeof(req),
                 "{\"conversationId\":\"c\",\"requestId\":\"r\","
                 "\"userRequest\":\"x\",\"sources\":[],"
                 "\"modelSelection\":{\"profileId\":\"not-exist\","
                 "\"profileRevision\":1,\"modelId\":\"m\",\"thinking\":\"disabled\"}}");
        memset(&e, 0, sizeof(e));
        rc = ts_bridge_analyze_async(bridge, req, strlen(req), &j, &e);
        CHECK(rc != 0 && e.data != NULL &&
              contains(e.data, "\"errorKind\":\"profileDeleted\""),
              "4b 引用不存在的 profile 返回 profileDeleted");
        free_buffer(&e);
    }

    /* 4c. 删除 profile 不影响运行中的任务 */
    mock_set_delay(1200);
    mock_clear_requests();
    CHECK(start_analyze(bridge,
                        "{\"profileId\":\"p-a\",\"profileRevision\":1,"
                        "\"modelId\":\"model-a\",\"thinking\":\"disabled\"}",
                        &job) == 0, "4c 启动分析（使用连接 A）");
    Sleep(250);
    {
        char p2b[1200];
        char profiles2[2048];
        profile_json(p2b, sizeof(p2b), "p-b", "连接 B", 1, "deepseek-chat",
                     "/v1/b", "none", "model-b", "disabled", NULL, 1);
        expand_port(p2b, profiles2, sizeof(profiles2));
        CHECK(save_settings(bridge, profiles2, "p-b", "model-b", "[\"p-a\"]") == 0,
              "4c 运行中删除连接 A 成功");
    }
    CHECK(poll_terminal(bridge, job, 20000), "4c 被删除连接的运行中任务仍进入终态");
    memset(&res, 0, sizeof(res));
    CHECK(get_result(bridge, job, &res) == 0 && res.data != NULL &&
          contains(res.data, "\"ok\":true"),
          "4c 运行中任务正常完成（删除不影响快照）");
    free_buffer(&res);
    CHECK(ts_bridge_release_job(bridge, job) == 0, "4c 任务可释放");

    /* 4d. 之后引用被删除的 profile → profileDeleted */
    mock_set_delay(0);
    {
        TsBridgeBuffer e;
        TsJobId j = 0;
        char req[2048];
        snprintf(req, sizeof(req),
                 "{\"conversationId\":\"c\",\"requestId\":\"r\","
                 "\"userRequest\":\"x\",\"sources\":[],"
                 "\"modelSelection\":{\"profileId\":\"p-a\",\"profileRevision\":1,"
                 "\"modelId\":\"model-a\",\"thinking\":\"disabled\"}}");
        memset(&e, 0, sizeof(e));
        rc = ts_bridge_analyze_async(bridge, req, strlen(req), &j, &e);
        CHECK(rc != 0, "4d 删除后再引用明确失败");
        CHECK(e.data != NULL && contains(e.data, "\"errorKind\":\"profileDeleted\""),
              "4d 错误分类为 profileDeleted");
        free_buffer(&e);
    }

    ts_bridge_shutdown_begin(bridge);
    ts_bridge_destroy(bridge);
}

/* ================================================================== */
/* 5. 探针：模型发现 / 连通性测试 / 错误分类                           */
/* ================================================================== */

static void probe_json_str(char *out, size_t out_sz, const char *kind,
                           const char *profile_id, long revision,
                           const char *model_id, long timeout_ms)
{
    if (timeout_ms > 0) {
        snprintf(out, out_sz,
                 "{\"kind\":\"%s\",\"profileId\":\"%s\",\"profileRevision\":%ld,"
                 "\"modelId\":\"%s\",\"thinking\":\"disabled\",\"timeoutMs\":%ld}",
                 kind, profile_id, revision, model_id, timeout_ms);
    } else {
        snprintf(out, out_sz,
                 "{\"kind\":\"%s\",\"profileId\":\"%s\",\"profileRevision\":%ld,"
                 "\"modelId\":\"%s\",\"thinking\":\"disabled\"}",
                 kind, profile_id, revision, model_id);
    }
}

static void test_probe_and_errors(void)
{
    char profiles[1024];
    char p1[1200];
    char pj[512];
    TsBridge *bridge;
    TsBridgeBuffer err;
    TsBridgeBuffer res;
    int base;

    printf("\n== 5. 探针：模型发现 / 连通性测试 / 错误分类 ==\n");

    profile_json(p1, sizeof(p1), "p-probe", "探针连接", 0, "deepseek-chat",
                 "/v1/probe", "none", "model-probe", "disabled", NULL, 1);
    expand_port(p1, profiles, sizeof(profiles));

    memset(&err, 0, sizeof(err));
    bridge = new_bridge(profiles, "p-probe", "model-probe", &err);
    free_buffer(&err);
    CHECK(bridge != NULL, "5 桥接创建成功");
    if (bridge == NULL) return;

    /* 5a. 模型发现：GET 完整 modelsUrl */
    {
        char *mr = models_response();
        mock_set_response(200, mr);
        free(mr);
    }
    mock_clear_requests();
    base = mock_request_count();
    probe_json_str(pj, sizeof(pj), "models", "p-probe", 1, "model-probe", 0);
    CHECK(run_probe(bridge, pj, &res) == 0 && res.data != NULL,
          "5a 模型发现探针结束");
    CHECK(res.data != NULL && contains(res.data, "\"ok\":true"), "5a 模型发现成功");
    CHECK(res.data != NULL && contains(res.data, "\"jobType\":\"probe\""),
          "5a 探针结果带 jobType=probe（Dart 不得提交为计划）");
    CHECK(res.data != NULL && contains(res.data, "\"kind\":\"models\""), "5a kind=models");
    CHECK(res.data != NULL && contains(res.data, "\"models\""), "5a 返回 models 列表");
    CHECK(res.data != NULL && contains(res.data, "mock-model-a") &&
          contains(res.data, "mock-model-c"), "5a 模型 id 被解析出来");
    CHECK(res.data != NULL && contains(res.data, "\"httpStatus\":200"),
          "5a 回带 HTTP 状态码");
    {
        char *path = req_path(base);
        CHECK(path != NULL && strcmp(path, "/v1/probe/models") == 0,
              "5a GET 的是 profile 的完整 modelsUrl");
        free(path);
    }
    free_buffer(&res);

    /* 5b. 连通性测试：POST 完整 chatUrl + 固定小型请求 + 无用户文件 */
    {
        char *resp = chat_response("{\"ok\":true}", "stop");
        mock_set_response(200, resp);
        free(resp);
    }
    mock_clear_requests();
    base = mock_request_count();
    probe_json_str(pj, sizeof(pj), "chat", "p-probe", 1, "model-probe", 0);
    CHECK(run_probe(bridge, pj, &res) == 0 && res.data != NULL, "5b 连通性测试结束");
    CHECK(res.data != NULL && contains(res.data, "\"ok\":true"), "5b 连通性测试成功");
    CHECK(res.data != NULL && contains(res.data, "\"contentIsJson\":true"),
          "5b 报告正文是否为 JSON");
    CHECK(res.data != NULL && contains(res.data, "\"usage\""), "5b 带 token 用量");
    {
        char *body = req_body(base);
        char *h = req_headers(base);
        CHECK(body != NULL && contains(body, "\"model\":\"model-probe\""),
              "5b 探针请求体使用所选模型");

        CHECK(body != NULL && contains(body, "connectivity") &&
              contains(body, "连通性测试助手"),
              "5b 探针请求体是固定的小型连通性请求");
        CHECK(body != NULL && !contains(body, "这是一段用于测试的文本材料"),
              "5b 探针请求**不**包含任何用户材料");
        CHECK(h != NULL && contains_ci(h, "POST "), "5b 探针使用 POST");
        free(h);
        free(body);
    }
    free_buffer(&res);

    /* 5c. 401 → auth */
    mock_set_response(401, "{\"error\":{\"message\":\"invalid key\"}}");
    probe_json_str(pj, sizeof(pj), "models", "p-probe", 1, "model-probe", 0);
    CHECK(run_probe(bridge, pj, &res) == 0 && res.data != NULL &&
          contains(res.data, "\"errorKind\":\"auth\""),
          "5c 401 分类为 auth");
    CHECK(res.data != NULL && !contains(res.data, "\"ok\":true"), "5c 401 结果为失败");
    free_buffer(&res);

    /* 5d. 404 → config */
    mock_set_response(404, "{\"error\":\"not found\"}");
    CHECK(run_probe(bridge, pj, &res) == 0 && res.data != NULL &&
          contains(res.data, "\"errorKind\":\"config\""),
          "5d 404 分类为 config");
    free_buffer(&res);

    /* 5e. 429 → rateLimit */
    mock_set_response(429, "{\"error\":\"slow down\"}");
    CHECK(run_probe(bridge, pj, &res) == 0 && res.data != NULL &&
          contains(res.data, "\"errorKind\":\"rateLimit\""),
          "5e 429 分类为 rateLimit");
    free_buffer(&res);

    /* 5f. 无效 JSON → protocol */
    mock_set_response(200, "not-a-json-response");
    CHECK(run_probe(bridge, pj, &res) == 0 && res.data != NULL &&
          contains(res.data, "\"errorKind\":\"protocol\""),
          "5f 模型列表不是合法 JSON 时分类为 protocol");
    free_buffer(&res);

    /* 5g. 截断（空/不完整 JSON）→ protocol，而不是崩溃 */
    mock_set_response(200, "{\"data\":[{\"id\":\"m1\"}");
    CHECK(run_probe(bridge, pj, &res) == 0 && res.data != NULL &&
          contains(res.data, "\"errorKind\":\"protocol\""),
          "5g 截断的 JSON 分类为 protocol");
    free_buffer(&res);

    /* 5h. 超时 → network */
    {
        char *mr = models_response();
        mock_set_response(200, mr);
        free(mr);
    }
    mock_set_delay(5000);
    probe_json_str(pj, sizeof(pj), "models", "p-probe", 1, "model-probe", 3000);
    CHECK(run_probe(bridge, pj, &res) == 0 && res.data != NULL &&
          contains(res.data, "\"errorKind\":\"network\""),
          "5h 探针短超时触发并分类为 network");
    CHECK(res.data != NULL && contains(res.data, "超时"),
          "5h 错误信息说明是超时（可读原因）");
    free_buffer(&res);
    mock_set_delay(0);

    /* 5i. 探针并发上限：同时最多 4 个 */
    {
        TsJobId jobs[6];
        int i;
        int started = 0;
        TsBridgeBuffer e;
        mock_set_delay(1500);
        probe_json_str(pj, sizeof(pj), "models", "p-probe", 1, "model-probe", 20000);
        for (i = 0; i < 6; i++) {
            TsBridgeBuffer one;
            memset(&one, 0, sizeof(one));
            if (ts_bridge_probe_async(bridge, pj, strlen(pj), &jobs[i], &one) == 0) {
                started++;
            }
            free_buffer(&one);
        }
        CHECK(started == TS_BRIDGE_MAX_PROBE_JOBS,
              "5i 同时最多只能启动 4 个探针（第 5、6 个被拒绝）");
        for (i = 0; i < started; i++) {
            poll_terminal(bridge, jobs[i], 30000);
            ts_bridge_release_job(bridge, jobs[i]);
        }
        memset(&e, 0, sizeof(e));
        free_buffer(&e);
        mock_set_delay(0);
    }

    /* 5j. 探针错误不能影响分析：之后仍能正常分析 */
    {
        char *resp = chat_response(PLAN_CONTENT, "stop");
        mock_set_response(200, resp);
        free(resp);
        CHECK(run_analyze(bridge,
                          "{\"profileId\":\"p-probe\",\"profileRevision\":1,"
                          "\"modelId\":\"model-probe\",\"thinking\":\"disabled\"}",
                          &res, NULL, 0) == 0 && res.data != NULL &&
              contains(res.data, "\"ok\":true"),
              "5j 探针之后分析仍可用（job 表互不干扰）");
        CHECK(res.data != NULL && contains(res.data, "\"jobType\":\"analyze\""),
              "5j 分析结果带 jobType=analyze（与探针区分）");
        free_buffer(&res);
    }

    ts_bridge_shutdown_begin(bridge);
    ts_bridge_destroy(bridge);
}

/* ================================================================== */
/* 7. settings 持久化（桥接层 revision / conflict / .bak）              */
/* ================================================================== */

static void test_settings_persistence(void)
{
    char profiles[1024];
    char p1[1200];
    char json[4096];
    char sfile[MAX_PATH * 2];
    char bfile[MAX_PATH * 2];
    TsBridge *bridge;
    TsBridgeBuffer err;
    TsBridgeBuffer buf;

    printf("\n== 7. settings 持久化（revision / conflict / .bak）==\n");

    profile_json(p1, sizeof(p1), "p-set", "设置连接", 0, "deepseek-chat",
                 "/v1/set", "none", "model-set", "disabled", NULL, 1);
    expand_port(p1, profiles, sizeof(profiles));

    memset(&err, 0, sizeof(err));
    bridge = new_bridge(profiles, "p-set", "model-set", &err);
    free_buffer(&err);
    CHECK(bridge != NULL, "7 桥接创建成功");
    if (bridge == NULL) return;

    join_path(sfile, sizeof(sfile), "settings.json");
    join_path(bfile, sizeof(bfile), "settings.json.bak");
    CHECK(file_exists_any(sfile), "7 settings.json 已落盘");
    CHECK(file_exists_any(bfile), "7 旧设置被保留为 settings.json.bak");

    memset(&buf, 0, sizeof(buf));
    CHECK(ts_bridge_settings_get(bridge, &buf) == 0 && buf.data != NULL,
          "7 settings_get 成功");
    CHECK(buf.data != NULL && contains(buf.data, "\"schemaVersion\":2"),
          "7 settings_get 含 schemaVersion=2");
    CHECK(buf.data != NULL && contains(buf.data, "\"abiVersion\":2"),
          "7 settings_get 含 abiVersion=2");
    CHECK(buf.data != NULL && contains(buf.data, "settings.json"),
          "7 settings_get 含 settingsPath");
    CHECK(buf.data != NULL && contains(buf.data, "\"revision\":1"),
          "7 新建 profile 的 revision 为 1");
    CHECK(buf.data != NULL && !contains(buf.data, "sk-"),
          "7 settings_get 不含密钥");
    free_buffer(&buf);

    /* 7a. 过期 revision → conflict，并回带 current */
    snprintf(json, sizeof(json),
             "{\"schemaVersion\":2,\"defaultProfileId\":\"p-set\","
             "\"defaultModelId\":\"model-set\",\"profiles\":[{\"id\":\"p-set\","
             "\"name\":\"设置连接\",\"revision\":0,\"protocol\":\"deepseek-chat\","
             "\"chatUrl\":\"http://127.0.0.1:%d/v1/set/chat/completions\","
             "\"authMode\":\"none\",\"modelId\":\"model-set\","
             "\"thinking\":\"disabled\",\"jsonMode\":true}]}",
             g_port);
    memset(&buf, 0, sizeof(buf));
    CHECK(ts_bridge_settings_save(bridge, json, strlen(json), &buf) != 0,
          "7a 过期 revision 保存失败");
    CHECK(buf.data != NULL && contains(buf.data, "\"errorKind\":\"conflict\""),
          "7a 错误分类为 conflict");
    CHECK(buf.data != NULL && contains(buf.data, "请刷新后重试"),
          "7a 提示“请刷新后重试”");
    CHECK(buf.data != NULL && contains(buf.data, "\"current\""),
          "7a 回带 current（磁盘现状）");
    CHECK(buf.data != NULL && !contains(buf.data, "sk-"), "7a 回带内容不含密钥");
    free_buffer(&buf);

    /* 7b. 缺失 revision → invalidRevision */
    snprintf(json, sizeof(json),
             "{\"schemaVersion\":2,\"defaultProfileId\":\"p-set\","
             "\"defaultModelId\":\"model-set\",\"profiles\":[{\"id\":\"p-set\","
             "\"name\":\"设置连接\",\"protocol\":\"deepseek-chat\","
             "\"chatUrl\":\"http://127.0.0.1:%d/v1/set/chat/completions\","
             "\"authMode\":\"none\",\"modelId\":\"model-set\","
             "\"thinking\":\"disabled\",\"jsonMode\":true}]}",
             g_port);
    memset(&buf, 0, sizeof(buf));
    CHECK(ts_bridge_settings_save(bridge, json, strlen(json), &buf) != 0,
          "7b 缺失 revision 保存失败");
    CHECK(buf.data != NULL &&
          contains(buf.data, "\"errorKind\":\"invalidRevision\""),
          "7b 错误分类为 invalidRevision（不静默用最新配置）");
    free_buffer(&buf);

    /* 7c. 正常修改：revision 递增到 2 */
    snprintf(json, sizeof(json),
             "{\"schemaVersion\":2,\"defaultProfileId\":\"p-set\","
             "\"defaultModelId\":\"model-set2\",\"profiles\":[{\"id\":\"p-set\","
             "\"name\":\"设置连接\",\"revision\":1,\"protocol\":\"deepseek-chat\","
             "\"chatUrl\":\"http://127.0.0.1:%d/v1/set/chat/completions\","
             "\"authMode\":\"none\",\"modelId\":\"model-set2\","
             "\"thinking\":\"disabled\",\"jsonMode\":true}]}",
             g_port);
    memset(&buf, 0, sizeof(buf));
    CHECK(ts_bridge_settings_save(bridge, json, strlen(json), &buf) == 0,
          "7c 正常修改保存成功");
    CHECK(buf.data != NULL && contains(buf.data, "\"ok\":true"), "7c 返回 ok=true");
    CHECK(buf.data != NULL && contains(buf.data, "\"revision\":2"),
          "7c 字段变化后 revision 递增为 2");
    free_buffer(&buf);

    memset(&buf, 0, sizeof(buf));
    CHECK(ts_bridge_settings_get(bridge, &buf) == 0 && buf.data != NULL,
          "7d 重新读取设置成功");
    CHECK(buf.data != NULL && contains(buf.data, "model-set2"),
          "7d 内存态已替换为新模型");
    free_buffer(&buf);

    /* 7e. 重载（新桥接实例）后仍是新值 */
    ts_bridge_shutdown_begin(bridge);
    ts_bridge_destroy(bridge);
    {
        TsBridgeBuffer e2;
        TsBridge *b2;
        memset(&e2, 0, sizeof(e2));
        b2 = NULL;
        if (ts_bridge_create_ex(g_cfg_path, g_dir, &b2, &e2) == 0 && b2 != NULL) {
            TsBridgeBuffer s2;
            memset(&s2, 0, sizeof(s2));
            CHECK(ts_bridge_settings_get(b2, &s2) == 0 && s2.data != NULL,
                  "7e 新实例可读设置");
            CHECK(s2.data != NULL && contains(s2.data, "model-set2") &&
                  contains(s2.data, "\"revision\":2"),
                  "7e 重载后仍是 revision 2 / 新模型（持久化生效）");
            free_buffer(&s2);
            ts_bridge_shutdown_begin(b2);
            ts_bridge_destroy(b2);
        } else {
            CHECK(0, "7e 新实例创建失败");
        }
        free_buffer(&e2);
    }
}
/* ================================================================== */
/* 6. 默认选择与 ABI 版本                                              */
/* ================================================================== */

static void test_defaults_and_abi(void)
{
    char profiles[1024];
    char p1[1200];
    TsBridge *bridge;
    TsBridgeBuffer err;
    TsBridgeBuffer res;
    TsBridgeBuffer info;

    printf("\n== 6. ABI 版本 / 缺省使用全局默认连接 ==\n");

    profile_json(p1, sizeof(p1), "p-def", "默认连接", 0, "deepseek-chat",
                 "/v1/def", "none", "model-def", "disabled", NULL, 1);
    expand_port(p1, profiles, sizeof(profiles));

    memset(&err, 0, sizeof(err));
    bridge = new_bridge(profiles, "p-def", "model-def", &err);
    free_buffer(&err);
    CHECK(bridge != NULL, "6 桥接创建成功");
    if (bridge == NULL) return;

    memset(&info, 0, sizeof(info));
    CHECK(ts_bridge_info(bridge, &info) == 0 && info.data != NULL, "6 info 可读");
    CHECK(info.data != NULL && contains(info.data, "\"abiVersion\":2"),
          "6 info 报告 ABI=2");
    free_buffer(&info);

    {
        char *resp = chat_response(PLAN_CONTENT, "stop");
        mock_set_response(200, resp);
        free(resp);
    }
    mock_clear_requests();
    CHECK(run_analyze(bridge, NULL, &res, NULL, 0) == 0 && res.data != NULL &&
          contains(res.data, "\"ok\":true"),
          "6 不带 modelSelection 时使用全局默认连接");
    {
        char *body = req_body(0);
        CHECK(body != NULL && contains(body, "\"model\":\"model-def\""),
              "6 缺省请求使用默认连接的模型");
        free(body);
    }
    CHECK(res.data != NULL && contains(res.data, "\"profileId\":\"p-def\""),
          "6 结果 source 记录默认连接");
    free_buffer(&res);

    ts_bridge_shutdown_begin(bridge);
    ts_bridge_destroy(bridge);
}

/* ================================================================== */
/* 8. 凭据授权范围按“最终请求 URL”校验（0.0.4 验收缺陷修复 1）          */
/* ================================================================== */

static int is_lower_hex16(const char *s)
{
    size_t i;
    if (s == NULL || strlen(s) != 16) return 0;
    for (i = 0; i < 16; i++) {
        char c = s[i];
        if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) return 0;
    }
    return 1;
}

/* A 的 origin（主 mock 服务）。 */
static void origin_a(char *out, size_t sz)
{
    snprintf(out, sz, "http://127.0.0.1:%d", g_port);
}

/* B 的 origin（第二个 mock 服务，另一个端口 = 另一个 origin）。 */
static void origin_b(char *out, size_t sz)
{
    snprintf(out, sz, "http://127.0.0.1:%d", g_b.port);
}

/* 8a：保存阶段拒绝“bearer + 跨源 modelsUrl”，且不写盘。 */
static void test_cross_origin_save(void)
{
    char ca[128];
    char cb[128];
    char chat[300];
    char models[300];
    char p[1600];
    char sfile[MAX_PATH * 2];
    char *before;
    char *after;
    TsBridge *bridge = NULL;
    TsBridgeBuffer err;
    TsBridgeBuffer res;
    int rc;

    printf("\n== 8a. 保存时拒绝跨源 modelsUrl（有凭据来源）==\n");

    clear_settings_files();
    write_config();
    memset(&err, 0, sizeof(err));
    rc = ts_bridge_create_ex(g_cfg_path, g_dir, &bridge, &err);
    free_buffer(&err);
    CHECK(rc == 0 && bridge != NULL, "8a 桥接创建成功");
    if (bridge == NULL) return;

    origin_a(ca, sizeof(ca));
    origin_b(cb, sizeof(cb));
    snprintf(chat, sizeof(chat), "%s/cross/chat/completions", ca);
    snprintf(models, sizeof(models), "%s/cross/models", cb);

    settings_path(sfile, sizeof(sfile));
    before = read_text(sfile);
    CHECK(before != NULL, "8a 已存在 settings.json（旧配置迁移写入）");

    profile_json_full(p, sizeof(p), "p-cross", 0, chat, models, "bearer", "", "model-cross");
    memset(&res, 0, sizeof(res));
    rc = save_settings_capture(bridge, p, "p-cross", "model-cross",
                               "[\"legacy-config\"]", &res);
    CHECK(rc != 0, "8a bearer + 跨源 modelsUrl 的保存被拒绝");
    CHECK(res.data != NULL && contains(res.data, "\"ok\":false"), "8a 返回 ok=false");
    CHECK(res.data != NULL && contains(res.data,
          "模型列表地址必须与对话地址同源"),
          "8a 文案：模型列表地址必须与对话地址同源");
    CHECK(res.data != NULL && contains(res.data, "需要跨源请新建独立连接"),
          "8a 文案：需要跨源请新建独立连接");
    CHECK(res.data != NULL && contains(res.data, ca) && contains(res.data, cb),
          "8a 文案带出“本次是 A → B”两个 origin");
    free_buffer(&res);

    after = read_text(sfile);
    CHECK(before != NULL && after != NULL && strcmp(before, after) == 0,
          "8a 拒绝时不写盘（settings.json 一字未变）");
    free(before);
    free(after);

    /* 对照：authMode=none 时允许跨源（但运行时绝不带凭据，见 8c）。 */
    profile_json_full(p, sizeof(p), "p-cross-none", 0, chat, models, "none", "",
                      "model-cross");
    memset(&res, 0, sizeof(res));
    rc = save_settings_capture(bridge, p, "p-cross-none", "model-cross", NULL, &res);
    CHECK(rc == 0, "8a authMode=none 的跨源 modelsUrl 允许保存");
    free_buffer(&res);

    ts_bridge_shutdown_begin(bridge);
    ts_bridge_destroy(bridge);
    clear_settings_files();
}

/* 8b/8c/8d：旧式 settings.json 在运行时被拦截；none 允许跨源但不带凭据。 */
static void test_cross_origin_runtime(void)
{
    char ca[128];
    char cb[128];
    char chat[300];
    char models[300];
    char same_models[300];
    char p[1600];
    char sj[4096];
    char sfile[MAX_PATH * 2];
    char pj[512];
    TsBridge *bridge = NULL;
    TsBridgeBuffer err;
    TsBridgeBuffer res;
    TsBridgeBuffer e;
    TsJobId job = 0;
    int rc;

    printf("\n== 8b. 旧式 settings.json（chat=A / models=B）运行时被拦截 ==\n");

    clear_settings_files();
    write_config();
    origin_a(ca, sizeof(ca));
    origin_b(cb, sizeof(cb));
    snprintf(chat, sizeof(chat), "%s/legacy/chat/completions", ca);
    snprintf(models, sizeof(models), "%s/legacy/models", cb);

    /*
     * 直接写一份“旧版本可能留下”的 settings.json：
     *   authMode=bearer、chatUrl=A、modelsUrl=B、apiKeyEnv=假环境变量。
     * 它不会经过保存校验，因此**必须**在运行时被拦住。
     */
    snprintf(sj, sizeof(sj),
             "{\"schemaVersion\":2,\"defaultProfileId\":\"p-legacy-cross\","
             "\"defaultModelId\":\"model-cross\",\"defaultThinking\":\"disabled\","
             "\"profiles\":[{\"id\":\"p-legacy-cross\",\"name\":\"旧式跨源\","
             "\"revision\":1,\"protocol\":\"deepseek-chat\",\"baseUrl\":\"%s\","
             "\"chatUrl\":\"%s\",\"modelsUrl\":\"%s\",\"authMode\":\"bearer\","
             "\"apiKeyEnv\":\"TS_TEST_PROBE_CROSS_ENV\",\"modelId\":\"model-cross\","
             "\"thinking\":\"disabled\",\"jsonMode\":true}]}",
             ca, chat, models);
    settings_path(sfile, sizeof(sfile));
    write_file(sfile, sj);
    _putenv_s("TS_TEST_PROBE_CROSS_ENV", "sk-test-cross-origin-env-0001");

    memset(&err, 0, sizeof(err));
    rc = ts_bridge_create_ex(g_cfg_path, g_dir, &bridge, &err);
    free_buffer(&err);
    CHECK(rc == 0 && bridge != NULL,
          "8b 旧式 settings.json 仍可加载（跨源不是启动错误）");
    if (bridge == NULL) {
        _putenv_s("TS_TEST_PROBE_CROSS_ENV", "");
        return;
    }

    /* 8b-1：models 探针的目标是 B → 必须在请求前失败，B 收到 0 个请求。 */
    mock_clear_requests();
    mock_b_clear();
    probe_json_str(pj, sizeof(pj), "models", "p-legacy-cross", 1, "model-cross", 0);
    memset(&e, 0, sizeof(e));
    job = 12345;
    rc = ts_bridge_probe_async(bridge, pj, strlen(pj), &job, &e);
    CHECK(rc != 0, "8b models 探针在请求前失败");
    CHECK(job == 0, "8b 失败时没有创建 job（job id 为 0）");
    CHECK(e.data != NULL && contains(e.data, "\"errorKind\":\"config\""),
          "8b 错误分类为 config");
    CHECK(e.data != NULL && contains(e.data, "不同源"),
          "8b 文案说明请求目标与对话地址不同源");
    CHECK(e.data != NULL && contains(e.data, "需要跨源请新建独立连接"),
          "8b 文案给出处理建议");
    CHECK(e.data != NULL && !contains(e.data, "sk-test-cross-origin-env-0001"),
          "8b 错误信息不含密钥");
    free_buffer(&e);
    CHECK(mock_request_count() == 0, "8b A 收到 0 个请求");
    CHECK(mock_b_count() == 0, "8b B 收到 0 个请求（凭据没有外发）");

    /* 8b-2：分析仍然打到 chatUrl=A，并照样带 Authorization（环境变量凭据）。 */
    {
        char *resp = chat_response(PLAN_CONTENT, "stop");
        mock_set_response(200, resp);
        free(resp);
    }
    mock_clear_requests();
    mock_b_clear();
    rc = run_analyze(bridge,
                     "{\"profileId\":\"p-legacy-cross\",\"profileRevision\":1,"
                     "\"modelId\":\"model-cross\",\"thinking\":\"disabled\"}",
                     &res, NULL, 0);
    CHECK(rc == 0 && res.data != NULL && contains(res.data, "\"ok\":true"),
          "8b 分析（chat=A）仍然成功");
    {
        char *h = req_headers(0);
        char *path = req_path(0);
        CHECK(path != NULL && strcmp(path, "/legacy/chat/completions") == 0,
              "8b 分析打到 A 的 chatUrl");
        CHECK(h != NULL &&
              contains_ci(h, "authorization: bearer sk-test-cross-origin-env-0001"),
              "8b 分析 chat=A 时带上环境变量里的 Authorization");
        free(h);
        free(path);
    }
    CHECK(mock_b_count() == 0, "8b 分析没有发往 B");
    free_buffer(&res);

    /* 8c：authMode=none 跨源 → 模型发现正常，但绝不带 Authorization。 */
    profile_json_full(p, sizeof(p), "p-none-cross", 0, chat, models, "none", "",
                      "model-cross");
    /*
     * 注意：旧式跨源 profile 仍在列表里时，**整份设置**都不能通过校验
     * （校验作用于合并后的完整列表）。这里模拟用户“删掉旧连接、新建
     * 无需鉴权的跨源连接”的正常流程。
     */
    CHECK(save_settings(bridge, p, "p-none-cross", "model-cross",
                        "[\"p-legacy-cross\"]") == 0,
          "8c authMode=none 的跨源 modelsUrl 允许保存");

    mock_clear_requests();
    mock_b_clear();
    mock_b_set_response(200, "{\"data\":[{\"id\":\"b-model-1\"}]}");
    probe_json_str(pj, sizeof(pj), "models", "p-none-cross", 1, "model-cross", 0);
    memset(&res, 0, sizeof(res));
    CHECK(run_probe(bridge, pj, &res) == 0 && res.data != NULL &&
          contains(res.data, "\"ok\":true"),
          "8c authMode=none 跨源模型发现成功");
    CHECK(res.data != NULL && contains(res.data, "b-model-1"),
          "8c 模型列表来自 B");
    CHECK(mock_b_count() == 1, "8c B 收到这次模型发现请求");
    CHECK(!mock_b_auth_present(),
          "8c B 收到的请求**没有** Authorization（跨源绝不带凭据）");
    CHECK(mock_request_count() == 0, "8c A 没有收到该请求");
    free_buffer(&res);

    /* 8d：环境变量凭据在**同源**时正常发送。 */
    snprintf(same_models, sizeof(same_models), "%s/legacy/models", ca);
    profile_json_full(p, sizeof(p), "p-env-same", 0, chat, same_models, "bearer",
                      "TS_TEST_PROBE_CROSS_ENV", "model-cross");
    CHECK(save_settings(bridge, p, "p-env-same", "model-cross",
                        "[\"p-none-cross\"]") == 0,
          "8d 同源 bearer + apiKeyEnv 的 profile 可保存");

    mock_clear_requests();
    mock_b_clear();
    {
        char *mr = models_response();
        mock_set_response(200, mr);
        free(mr);
    }
    probe_json_str(pj, sizeof(pj), "models", "p-env-same", 1, "model-cross", 0);
    memset(&res, 0, sizeof(res));
    CHECK(run_probe(bridge, pj, &res) == 0 && res.data != NULL &&
          contains(res.data, "\"ok\":true"),
          "8d 同源模型发现成功");
    {
        char *h = req_headers(0);
        CHECK(h != NULL &&
              contains_ci(h, "authorization: bearer sk-test-cross-origin-env-0001"),
              "8d 同源时正常发送环境变量凭据");
        free(h);
    }
    CHECK(mock_b_count() == 0, "8d 同源探针不涉及 B");
    free_buffer(&res);

    ts_bridge_shutdown_begin(bridge);
    ts_bridge_destroy(bridge);

    /* 测试结束清理自己设置的环境变量与 settings.json。 */
    _putenv_s("TS_TEST_PROBE_CROSS_ENV", "");
    clear_settings_files();
}

/* ================================================================== */
/* 9. 凭据按数据空间隔离（修复 2）                                      */
/* ================================================================== */

static void test_credential_space_isolation(void)
{
    char dir_a[MAX_PATH * 2];
    char dir_b[MAX_PATH * 2];
    char space_a[TS_CREDENTIAL_SPACE_MAX];
    char space_b[TS_CREDENTIAL_SPACE_MAX];
    char ca[128];
    char chat[300];
    char models[300];
    char p[1600];
    TsBridge *b1 = NULL;
    TsBridge *b2 = NULL;
    TsBridgeBuffer err;
    TsBridgeBuffer ce;
    TsBridgeBuffer res;
    int rc;

    printf("\n== 9. 凭据按数据空间隔离（同一 profileId 两个数据目录）==\n");

    snprintf(dir_a, sizeof(dir_a), "%s\\ts_space_a", g_dir);
    snprintf(dir_b, sizeof(dir_b), "%s\\ts_space_b", g_dir);
    prepare_dir(dir_a);
    prepare_dir(dir_b);

    ts_credential_space_id(dir_a, space_a, sizeof(space_a));
    ts_credential_space_id(dir_b, space_b, sizeof(space_b));
    CHECK(is_lower_hex16(space_a) && is_lower_hex16(space_b),
          "9 space id 是 16 位小写十六进制");
    CHECK(strcmp(space_a, space_b) != 0, "9 不同数据目录得到不同 space id");
    {
        char variant[MAX_PATH * 2];
        char vspace[TS_CREDENTIAL_SPACE_MAX];
        snprintf(variant, sizeof(variant), "%s\\TS_SPACE_A\\", g_dir);
        ts_credential_space_id(variant, vspace, sizeof(vspace));
        CHECK(strcmp(vspace, space_a) == 0,
              "9 大小写/分隔符/结尾分隔符不影响 space id（路径已规范化）");
    }

    origin_a(ca, sizeof(ca));
    snprintf(chat, sizeof(chat), "%s/space/chat/completions", ca);
    snprintf(models, sizeof(models), "%s/space/models", ca);
    profile_json_full(p, sizeof(p), "p-space", 0, chat, models, "bearer", "",
                      "model-sp");
    write_config();

    /* 数据目录 A：写入 keyA */
    memset(&err, 0, sizeof(err));
    rc = ts_bridge_create_ex(g_cfg_path, dir_a, &b1, &err);
    free_buffer(&err);
    CHECK(rc == 0 && b1 != NULL, "9 A 桥接创建成功");
    if (b1 == NULL) goto cleanup;

    CHECK(save_settings(b1, p, "p-space", "model-sp", "[\"legacy-config\"]") == 0,
          "9 A 保存 profile 成功");
    memset(&ce, 0, sizeof(ce));
    rc = ts_bridge_credential_set(b1, "p-space", "sk-test-space-a-0001",
                                  strlen("sk-test-space-a-0001"), &ce);
    CHECK(rc == 0 && ce.data != NULL && contains(ce.data, "\"ok\":true"),
          "9 A 写入密钥成功");
    free_buffer(&ce);
    ts_bridge_shutdown_begin(b1);
    ts_bridge_destroy(b1);
    b1 = NULL;

    /* 数据目录 B：同名 profileId，写入 keyB */
    memset(&err, 0, sizeof(err));
    rc = ts_bridge_create_ex(g_cfg_path, dir_b, &b2, &err);
    free_buffer(&err);
    CHECK(rc == 0 && b2 != NULL, "9 B 桥接创建成功");
    if (b2 == NULL) goto cleanup;

    CHECK(save_settings(b2, p, "p-space", "model-sp", "[\"legacy-config\"]") == 0,
          "9 B 保存同名 profile 成功");
    memset(&ce, 0, sizeof(ce));
    rc = ts_bridge_credential_set(b2, "p-space", "sk-test-space-b-0002",
                                  strlen("sk-test-space-b-0002"), &ce);
    CHECK(rc == 0 && ce.data != NULL && contains(ce.data, "\"ok\":true"),
          "9 B 写入同名 profile 的另一把密钥成功");
    free_buffer(&ce);
    ts_bridge_shutdown_begin(b2);
    ts_bridge_destroy(b2);
    b2 = NULL;

    /* A 的 scoped 读取：只能读到 keyA */
    {
        char *key = NULL;
        char *host = NULL;
        char cerr[512];
        cerr[0] = '\0';
        CHECK(ts_credential_load_scoped(space_a, "p-space", &key, &host, NULL,
                                        cerr, sizeof(cerr)) == 0,
              "9 A 空间能读到凭据");
        CHECK(key != NULL && strcmp(key, "sk-test-space-a-0001") == 0,
              "9 A 空间读到的是自己的密钥");
        ts_secure_free(&key);
        free(host);
    }
    {
        char *key = NULL;
        char *host = NULL;
        char cerr[512];
        cerr[0] = '\0';
        CHECK(ts_credential_load_scoped(space_b, "p-space", &key, &host, NULL,
                                        cerr, sizeof(cerr)) == 0,
              "9 B 空间能读到凭据");
        CHECK(key != NULL && strcmp(key, "sk-test-space-b-0002") == 0,
              "9 B 空间读到的是自己那把（互不覆盖）");
        ts_secure_free(&key);
        free(host);
    }

    /* 重启 A（destroy / create）：同一 space 仍能读到自己的密钥 */
    {
        char *resp = chat_response(PLAN_CONTENT, "stop");
        mock_set_response(200, resp);
        free(resp);
    }
    memset(&err, 0, sizeof(err));
    rc = ts_bridge_create_ex(g_cfg_path, dir_a, &b1, &err);
    free_buffer(&err);
    CHECK(rc == 0 && b1 != NULL, "9 A 桥接重启成功（settings.json 从 A 目录加载）");
    if (b1 != NULL) {
        mock_clear_requests();
        rc = run_analyze(b1,
                         "{\"profileId\":\"p-space\",\"profileRevision\":1,"
                         "\"modelId\":\"model-sp\",\"thinking\":\"disabled\"}",
                         &res, NULL, 0);
        CHECK(rc == 0 && res.data != NULL && contains(res.data, "\"ok\":true"),
              "9 A 重启后分析成功（凭据仍可读）");
        {
            char *h = req_headers(0);
            CHECK(h != NULL && contains_ci(h, "authorization: bearer sk-test-space-a-0001"),
                  "9 A 重启后发送的是 A 空间的密钥");
            CHECK(h != NULL && !contains_ci(h, "sk-test-space-b-0002"),
                  "9 A 绝不会用到 B 空间的密钥");
            free(h);
        }
        free_buffer(&res);
        ts_bridge_shutdown_begin(b1);
        ts_bridge_destroy(b1);
        b1 = NULL;
    }

    /* B 空间同样只用自己的密钥 */
    memset(&err, 0, sizeof(err));
    rc = ts_bridge_create_ex(g_cfg_path, dir_b, &b2, &err);
    free_buffer(&err);
    CHECK(rc == 0 && b2 != NULL, "9 B 桥接重启成功");
    if (b2 != NULL) {
        mock_clear_requests();
        rc = run_analyze(b2,
                         "{\"profileId\":\"p-space\",\"profileRevision\":1,"
                         "\"modelId\":\"model-sp\",\"thinking\":\"disabled\"}",
                         &res, NULL, 0);
        CHECK(rc == 0 && res.data != NULL && contains(res.data, "\"ok\":true"),
              "9 B 重启后分析成功");
        {
            char *h = req_headers(0);
            CHECK(h != NULL && contains_ci(h, "authorization: bearer sk-test-space-b-0002"),
                  "9 B 重启后发送的是 B 空间的密钥");
            CHECK(h != NULL && !contains_ci(h, "sk-test-space-a-0001"),
                  "9 B 绝不会用到 A 空间的密钥");
            free(h);
        }
        free_buffer(&res);

        /* 旧目标兼容：在旧目标写入后，新 space 首次 load 能迁移读取（不删旧目标） */
        {
            char *key = NULL;
            char *host = NULL;
            char cerr[512];
            char space_c[TS_CREDENTIAL_SPACE_MAX];
            int migrated = 0;
            cerr[0] = '\0';
            CHECK(ts_credential_set("p-space-legacy", "127.0.0.1",
                                    "sk-test-space-legacy-0003",
                                    strlen("sk-test-space-legacy-0003"),
                                    cerr, sizeof(cerr)) == 0,
                  "9 旧目标写入成功（模拟上一版本留下的凭据）");
            ts_credential_space_id(dir_b, space_c, sizeof(space_c));
            CHECK(ts_credential_load_scoped(space_c, "p-space-legacy", &key, &host,
                                            &migrated, cerr, sizeof(cerr)) == 0,
                  "9 旧目标在新 space 下可被读取（兼容）");
            CHECK(migrated == 1, "9 报告本次是从旧目标迁移读取的");
            CHECK(key != NULL && strcmp(key, "sk-test-space-legacy-0003") == 0,
                  "9 迁移读取到的密钥正确");
            ts_secure_free(&key);
            free(host);

            /* 删掉旧目标后仍能读到 → 说明已经复制到新目标（旧目标没被删之前也还在）。 */
            CHECK(ts_credential_delete("p-space-legacy", cerr, sizeof(cerr)) == 0,
                  "9 单独删除旧目标成功");
            key = NULL;
            host = NULL;
            CHECK(ts_credential_load_scoped(space_c, "p-space-legacy", &key, &host,
                                            NULL, cerr, sizeof(cerr)) == 0,
                  "9 旧目标删掉后新目标仍可读（已复制而非移动）");
            ts_secure_free(&key);
            free(host);
            (void)ts_credential_delete_scoped(space_c, "p-space-legacy",
                                              cerr, sizeof(cerr));
        }

        ts_bridge_shutdown_begin(b2);
        ts_bridge_destroy(b2);
        b2 = NULL;
    }

cleanup:
    if (b1 != NULL) {
        ts_bridge_shutdown_begin(b1);
        ts_bridge_destroy(b1);
    }
    if (b2 != NULL) {
        ts_bridge_shutdown_begin(b2);
        ts_bridge_destroy(b2);
    }
    {
        char cerr[512];
        cerr[0] = '\0';
        (void)ts_credential_delete_scoped(space_a, "p-space", cerr, sizeof(cerr));
        (void)ts_credential_delete_scoped(space_b, "p-space", cerr, sizeof(cerr));
        (void)ts_credential_delete("p-space", cerr, sizeof(cerr));
        CHECK(!ts_credential_exists_scoped(space_a, "p-space"), "9 已清理 A 空间测试凭据");
        CHECK(!ts_credential_exists_scoped(space_b, "p-space"), "9 已清理 B 空间测试凭据");
    }
    cleanup_dir(dir_a);
    cleanup_dir(dir_b);
    clear_settings_files();
}

/* ================================================================== */
/* 10. 凭据已生效但 settings.json 写失败 → 结构化 partial（修复 3）      */
/* ================================================================== */

/* 让 <dir> 里的原子写盘第一步必然失败：settings.json.tmp 被占成目录。 */
static int block_settings_tmp(const char *dir, char *blocker, size_t blocker_sz)
{
    snprintf(blocker, blocker_sz, "%s\\settings.json.tmp", dir);
    if (CreateDirectoryA(blocker, NULL)) return 0;
    return (GetLastError() == ERROR_ALREADY_EXISTS) ? 0 : 1;
}

static void test_partial_credential_persist(void)
{
    char dir[MAX_PATH * 2];
    char blocker[MAX_PATH * 2];
    char sfile[MAX_PATH * 2];
    char space[TS_CREDENTIAL_SPACE_MAX];
    char ca[128];
    char chat[300];
    char models[300];
    char p_new[1600];
    char p_rev1[1600];
    char *key = NULL;
    char *host = NULL;
    char *text;
    char cerr[512];
    TsBridge *bridge = NULL;
    TsBridgeBuffer err;
    TsBridgeBuffer ce;
    TsBridgeBuffer res;
    TsBridgeBuffer get;
    int rc;

    printf("\n== 10. 凭据已生效但 settings.json 写失败（partial=true）==\n");

    snprintf(dir, sizeof(dir), "%s\\ts_partial_dir", g_dir);
    prepare_dir(dir);
    write_config();

    origin_a(ca, sizeof(ca));
    snprintf(chat, sizeof(chat), "%s/partial/chat/completions", ca);
    snprintf(models, sizeof(models), "%s/partial/models", ca);
    profile_json_full(p_new, sizeof(p_new), "p-partial", 0, chat, models, "bearer",
                      "", "model-partial");
    profile_json_full(p_rev1, sizeof(p_rev1), "p-partial", 1, chat, models, "bearer",
                      "", "model-partial");
    ts_credential_space_id(dir, space, sizeof(space));

    memset(&err, 0, sizeof(err));
    rc = ts_bridge_create_ex(g_cfg_path, dir, &bridge, &err);
    free_buffer(&err);
    CHECK(rc == 0 && bridge != NULL, "10 桥接创建成功（独立数据目录）");
    if (bridge == NULL) {
        cleanup_dir(dir);
        return;
    }

    CHECK(save_settings(bridge, p_new, "p-partial", "model-partial",
                        "[\"legacy-config\"]") == 0,
          "10 先正常保存 profile");
    snprintf(sfile, sizeof(sfile), "%s\\settings.json", dir);
    CHECK(file_exists_any(sfile), "10 settings.json 已落盘");

    /* 故障注入：把 settings.json.tmp 变成目录，原子写盘第一步必然失败。 */
    if (block_settings_tmp(dir, blocker, sizeof(blocker)) != 0) {
        CHECK(0, "10 无法注入写盘故障（settings.json.tmp 目录创建失败）");
    } else {
        CHECK(1, "10 已注入写盘故障（settings.json.tmp 被目录占用）");

        memset(&ce, 0, sizeof(ce));
        rc = ts_bridge_credential_set(bridge, "p-partial", "sk-test-partial-0001",
                                      strlen("sk-test-partial-0001"), &ce);
        CHECK(rc != 0, "10 元数据落盘失败时返回非 0");
        CHECK(ce.data != NULL && contains(ce.data, "\"ok\":false"), "10 返回 ok=false");
        CHECK(ce.data != NULL && contains(ce.data, "\"errorKind\":\"writeFailed\""),
              "10 errorKind=writeFailed（不是笼统失败）");
        CHECK(ce.data != NULL && contains(ce.data, "\"partial\":true"),
              "10 结构化字段 partial=true（凭据已生效）");
        CHECK(ce.data != NULL && contains(ce.data, "\"credentialConfigured\":true"),
              "10 结构化字段 credentialConfigured=true");
        CHECK(ce.data != NULL && contains(ce.data, "\"credentialHost\":\"127.0.0.1\""),
              "10 结构化字段 credentialHost（主机，不含密钥）");
        CHECK(ce.data != NULL && contains(ce.data, "请重新保存设置"),
              "10 文案说明“请重新保存设置”");
        CHECK(ce.data != NULL && !contains(ce.data, "sk-test-partial-0001"),
              "10 错误信息不含密钥");
        free_buffer(&ce);

        /* 凭据确实已经生效（partial 的含义：只需要重新保存元数据）。 */
        cerr[0] = '\0';
        key = NULL;
        host = NULL;
        CHECK(ts_credential_load_scoped(space, "p-partial", &key, &host, NULL,
                                        cerr, sizeof(cerr)) == 0,
              "10 凭据确实已写入凭据管理器（可读）");
        CHECK(key != NULL && strcmp(key, "sk-test-partial-0001") == 0,
              "10 读回的密钥内容正确");
        ts_secure_free(&key);
        free(host);
    }

    /* 恢复可写 → 重新保存设置即可修复元数据（不需要重新输入密钥）。 */
    RemoveDirectoryA(blocker);
    memset(&res, 0, sizeof(res));
    rc = save_settings_capture(bridge, p_rev1, "p-partial", "model-partial",
                               NULL, &res);
    CHECK(rc == 0, "10 恢复可写后重新保存设置成功");
    free_buffer(&res);

    memset(&get, 0, sizeof(get));
    CHECK(ts_bridge_settings_get(bridge, &get) == 0 && get.data != NULL,
          "10 settings_get 可读");
    CHECK(get.data != NULL && contains(get.data, "\"credentialConfigured\":true"),
          "10 内存态报告凭据已配置");
    free_buffer(&get);
    text = read_text(sfile);
    CHECK(text != NULL && contains(text, "\"credentialConfigured\":true"),
          "10 settings.json 已重新写入凭据元信息（修复完成）");
    free(text);

    /* 成功路径仍然只返回 {ok:true}，且不返回密钥。 */
    memset(&ce, 0, sizeof(ce));
    rc = ts_bridge_credential_set(bridge, "p-partial", "sk-test-partial-0002",
                                  strlen("sk-test-partial-0002"), &ce);
    CHECK(rc == 0 && ce.data != NULL && contains(ce.data, "\"ok\":true"),
          "10 可写时 credential_set 成功路径返回 {ok:true}");
    CHECK(ce.data != NULL && !contains(ce.data, "sk-test-partial-0002"),
          "10 成功路径不返回密钥");
    free_buffer(&ce);

    /* 删除路径的部分成功同样结构化（credentialConfigured=false）。 */
    if (block_settings_tmp(dir, blocker, sizeof(blocker)) == 0) {
        memset(&ce, 0, sizeof(ce));
        rc = ts_bridge_credential_delete(bridge, "p-partial", &ce);
        CHECK(rc != 0, "10 删除时元数据落盘失败返回非 0");
        CHECK(ce.data != NULL && contains(ce.data, "\"errorKind\":\"writeFailed\""),
              "10 删除路径 errorKind=writeFailed");
        CHECK(ce.data != NULL && contains(ce.data, "\"partial\":true"),
              "10 删除路径 partial=true");
        CHECK(ce.data != NULL && contains(ce.data, "\"credentialConfigured\":false"),
              "10 删除路径 credentialConfigured=false");
        CHECK(ce.data != NULL && contains(ce.data, "\"credentialHost\":\"127.0.0.1\""),
              "10 删除路径仍回带 credentialHost（删除前绑定的主机）");
        CHECK(ce.data != NULL && !contains(ce.data, "sk-test-partial"),
              "10 删除路径错误信息不含密钥");
        free_buffer(&ce);
        CHECK(!ts_credential_exists_scoped(space, "p-partial"),
              "10 凭据确实已删除（partial 的含义）");
        RemoveDirectoryA(blocker);

        memset(&ce, 0, sizeof(ce));
        rc = ts_bridge_credential_delete(bridge, "p-partial", &ce);
        CHECK(rc == 0 && ce.data != NULL && contains(ce.data, "\"ok\":true"),
              "10 恢复可写后重复删除返回 {ok:true}（幂等）");
        free_buffer(&ce);
    }

    ts_bridge_shutdown_begin(bridge);
    ts_bridge_destroy(bridge);

    /* 清理：删除自己创建的凭据与临时目录。 */
    cerr[0] = '\0';
    (void)ts_credential_delete_scoped(space, "p-partial", cerr, sizeof(cerr));
    (void)ts_credential_delete("p-partial", cerr, sizeof(cerr));
    CHECK(!ts_credential_exists_scoped(space, "p-partial"), "10 已清理测试凭据");
    cleanup_dir(dir);
    clear_settings_files();
}

/* ================================================================== */

int main(void)
{
    TsBridgeBuffer err;
    int rc;

    setvbuf(stdout, NULL, _IONBF, 0);
    printf("=== TaskScheduler 桥接 ABI 2 / 探针（内置 mock HTTP 服务）测试 ===\n\n");

    {
        char module[MAX_PATH];
        DWORD n = GetModuleFileNameA(NULL, module, MAX_PATH);
        if (n == 0 || n >= MAX_PATH) {
            printf("无法确定测试程序目录\n");
            return 1;
        }
        while (n > 0 && module[n - 1] != '\\') n--;
        if (n > 0) module[n - 1] = '\0';
        snprintf(g_dir, sizeof(g_dir), "%s", module);
        snprintf(g_cfg_path, sizeof(g_cfg_path), "%s\\ts_probe_config.json", g_dir);
    }
    printf("测试目录：%s\n", g_dir);

    if (mock_start() != 0) {
        printf("无法启动内置 mock HTTP 服务\n");
        return 1;
    }
    printf("mock HTTP 服务端口：%d\n", g_port);
    /* 第二个 origin（跨源 / 数据空间验证用）。端口同样由系统动态分配。 */
    if (mock_b_start() != 0) {
        printf("无法启动第二个 mock HTTP 服务\n");
        mock_stop();
        return 1;
    }
    printf("第二个 mock HTTP 服务端口：%d\n", g_b.port);

    /* ABI 版本常量必须与 Dart 侧一致 */
    CHECK(TS_BRIDGE_ABI_VERSION == 2, "编译期 ABI 版本为 2");

    /* 空参数保护 */
    memset(&err, 0, sizeof(err));
    rc = ts_bridge_create_ex("C:\\definitely\\not\\here.json", g_dir, NULL, &err);
    CHECK(rc != 0, "create_ex：输出指针为空时失败");
    free_buffer(&err);

    test_request_capture();
    test_snapshot_isolation();
    test_auth_modes();
    test_revision_and_delete();
    test_probe_and_errors();
    test_settings_persistence();
    test_defaults_and_abi();
    test_cross_origin_save();
    test_cross_origin_runtime();
    test_credential_space_isolation();
    test_partial_credential_persist();

    mock_b_stop();
    mock_stop();
    DeleteFileA(g_cfg_path);
    clear_settings_files();

    printf("\n=== 结果：%s（通过 %d 项，失败 %d 项）===\n",
           g_fail == 0 ? "全部通过" : "存在失败", g_pass, g_fail);
    return g_fail == 0 ? 0 : 1;
}

