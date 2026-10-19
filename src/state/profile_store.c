/*
 * profile_store.c — settings.json 原子写入（tmp → .bak → 提升）、迁移与乐观 revision 合并。
 *
 * 主要函数：ts_settings_load、ts_settings_write_atomic、ts_settings_merge、ts_settings_migrate_legacy。
 */

#include "profile_store.h"

#include "config.h"
#include "credential.h"
#include "mem.h"
#include "text.h"

#include <stdio.h>
#include <string.h>

#define WIN32_LEAN_AND_MEAN
#include <windows.h>

/* settings.json 的大小上限：远小于配置文件上限，避免误读大文件。 */
#define TS_SETTINGS_MAX_BYTES (4u * 1024u * 1024u)

static int ps_fail(char *err, size_t err_sz, const char *msg)
{
    if (err != NULL && err_sz > 0) {
        snprintf(err, err_sz, "%s", msg);
    }
    return TS_SETTINGS_ERR;
}

/* 带格式的可读错误（避免在 err 为 NULL 时调用 snprintf）。 */
static int ps_failf(char *err, size_t err_sz, const char *fmt, ...)
{
    va_list ap;
    if (err != NULL && err_sz > 0) {
        va_start(ap, fmt);
        vsnprintf(err, err_sz, fmt, ap);
        va_end(ap);
    }
    return TS_SETTINGS_ERR;
}

/* 删除文件（UTF-8 路径）。仅用于清理临时文件，失败不报错。 */
static void delete_file_utf8(const char *path)
{
    wchar_t *w;
    if (path == NULL || path[0] == '\0') return;
    w = ts_utf8_to_wide(path, strlen(path), NULL);
    if (w != NULL) {
        DeleteFileW(w);
        ts_free(w);
    }
}

/* ------------------------------------------------------------------ */
/* 路径                                                                */
/* ------------------------------------------------------------------ */

int ts_settings_path(const char *data_dir, int kind, char *out, size_t out_sz)
{
    const char *suffix;
    int n;

    if (out == NULL || out_sz == 0) return 1;
    out[0] = '\0';
    if (data_dir == NULL || data_dir[0] == '\0') return 1;

    suffix = (kind == 1) ? TS_SETTINGS_BAK_SUFFIX
             : (kind == 2) ? TS_SETTINGS_TMP_SUFFIX : "";

    /* 只在需要时补反斜杠，避免出现双反斜杠影响可比性。 */
    if (data_dir[strlen(data_dir) - 1] == '\\' || data_dir[strlen(data_dir) - 1] == '/') {
        n = snprintf(out, out_sz, "%s%s%s", data_dir, TS_SETTINGS_FILE_NAME, suffix);
    } else {
        n = snprintf(out, out_sz, "%s\\%s%s", data_dir, TS_SETTINGS_FILE_NAME, suffix);
    }
    if (n < 0 || (size_t)n >= out_sz) {
        out[0] = '\0';
        return 1;
    }
    return 0;
}

/* ------------------------------------------------------------------ */
/* 读文件（UTF-8 原始字节）                                            */
/* ------------------------------------------------------------------ */

static int read_all(const char *path, char **out, size_t *out_len, int *exists,
                    char *err, size_t err_sz)
{
    wchar_t *wpath;
    HANDLE h;
    LARGE_INTEGER size;
    char *buf;
    DWORD got = 0;
    DWORD want;
    size_t off = 0;

    *out = NULL;
    if (out_len != NULL) *out_len = 0;
    if (exists != NULL) *exists = 0;

    wpath = ts_utf8_to_wide(path, strlen(path), NULL);
    if (wpath == NULL) {
        return ps_fail(err, err_sz, "无法转换文件路径");
    }
    h = CreateFileW(wpath, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING,
                    FILE_ATTRIBUTE_NORMAL, NULL);
    ts_free(wpath);
    if (h == INVALID_HANDLE_VALUE) {
        DWORD code = GetLastError();
        if (code == ERROR_FILE_NOT_FOUND || code == ERROR_PATH_NOT_FOUND) {
            return 0;   /* 不存在：不是错误 */
        }
        ps_failf(err, err_sz, "无法打开设置文件（Windows 错误码 %lu）", (unsigned long)code);
        return TS_SETTINGS_ERR;
    }
    if (exists != NULL) *exists = 1;

    if (!GetFileSizeEx(h, &size)) {
        CloseHandle(h);
        return ps_fail(err, err_sz, "无法读取设置文件大小");
    }
    if (size.QuadPart < 0 || (unsigned long long)size.QuadPart > TS_SETTINGS_MAX_BYTES) {
        CloseHandle(h);
        return ps_fail(err, err_sz, "设置文件过大，已拒绝读取（不删除、不覆盖）");
    }
    want = (DWORD)size.QuadPart;
    buf = (char *)malloc((size_t)want + 1);
    if (buf == NULL) {
        CloseHandle(h);
        return ps_fail(err, err_sz, "内存分配失败");
    }
    while (off < (size_t)want) {
        DWORD chunk = (DWORD)((size_t)want - off);
        if (!ReadFile(h, buf + off, chunk, &got, NULL)) {
            ts_free(buf);
            CloseHandle(h);
            return ps_fail(err, err_sz, "读取设置文件失败");
        }
        if (got == 0) break;
        off += (size_t)got;
    }
    CloseHandle(h);
    buf[off] = '\0';
    *out = buf;
    if (out_len != NULL) *out_len = off;
    return 0;
}

/* ------------------------------------------------------------------ */
/* 原子写                                                              */
/* ------------------------------------------------------------------ */

static int move_file(const char *from, const char *to, DWORD flags)
{
    wchar_t *wf = ts_utf8_to_wide(from, strlen(from), NULL);
    wchar_t *wt = ts_utf8_to_wide(to, strlen(to), NULL);
    int ok = 0;
    if (wf != NULL && wt != NULL) {
        ok = MoveFileExW(wf, wt, flags) ? 1 : 0;
    }
    ts_free(wf);
    ts_free(wt);
    return ok;
}

int ts_settings_write_atomic(const char *data_dir, const TsProfileList *list,
                             char *err, size_t err_sz)
{
    char path[2048];
    char bak[2048];
    char tmp[2048];
    char *json = NULL;
    size_t json_len = 0;
    wchar_t *wtmp = NULL;
    HANDLE h = INVALID_HANDLE_VALUE;
    DWORD written = 0;
    size_t off = 0;
    int had_old = 0;
    int rc = TS_SETTINGS_ERR;

    if (err != NULL && err_sz > 0) err[0] = '\0';

    if (ts_settings_path(data_dir, 0, path, sizeof(path)) != 0 ||
        ts_settings_path(data_dir, 1, bak, sizeof(bak)) != 0 ||
        ts_settings_path(data_dir, 2, tmp, sizeof(tmp)) != 0) {
        return ps_fail(err, err_sz, "设置文件路径无法构造（data_dir 为空或过长）");
    }

    json = ts_profile_list_print(list);
    if (json == NULL) {
        return ps_fail(err, err_sz, "设置序列化失败（内存分配失败）");
    }
    json_len = strlen(json);

    /* 让 .json 目录先存在（data_dir 由调用方保证，这里只做兜底提示）。 */
    wtmp = ts_utf8_to_wide(tmp, strlen(tmp), NULL);
    if (wtmp == NULL) {
        ts_free(json);
        return ps_fail(err, err_sz, "无法转换设置文件路径");
    }
    h = CreateFileW(wtmp, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS,
                    FILE_ATTRIBUTE_NORMAL, NULL);
    ts_free(wtmp);
    if (h == INVALID_HANDLE_VALUE) {
        ts_free(json);
        ps_failf(err, err_sz, "无法写入临时设置文件（Windows 错误码 %lu）",
                 (unsigned long)GetLastError());
        return TS_SETTINGS_ERR;
    }
    while (off < json_len) {
        DWORD chunk = (DWORD)((json_len - off) > 0x10000u ? 0x10000u : (json_len - off));
        if (!WriteFile(h, json + off, chunk, &written, NULL) || written == 0) {
            CloseHandle(h);
            delete_file_utf8(tmp);
            ts_free(json);
            return ps_fail(err, err_sz, "写入临时设置文件失败（旧设置未被修改）");
        }
        off += (size_t)written;
    }
    /* 落盘后再替换：掉电时不会留下半截 settings.json。 */
    FlushFileBuffers(h);
    CloseHandle(h);
    ts_free(json);

    /*
     * 第二步：把现有 settings.json 改名为 .bak。
     * 只有确实存在旧文件时才做；不存在就不创建空 .bak（避免误导）。
     */
    {
        wchar_t *wp = ts_utf8_to_wide(path, strlen(path), NULL);
        if (wp != NULL) {
            DWORD attr = GetFileAttributesW(wp);
            had_old = (attr != INVALID_FILE_ATTRIBUTES &&
                       (attr & FILE_ATTRIBUTE_DIRECTORY) == 0) ? 1 : 0;
            ts_free(wp);
        }
    }
    if (had_old) {
        if (!move_file(path, bak, MOVEFILE_REPLACE_EXISTING)) {
            delete_file_utf8(tmp);
            return ps_fail(err, err_sz, "无法备份现有设置文件（旧设置保持不变）");
        }
    }

    /* 第三步：提升 .tmp 为主文件。 */
    if (!move_file(tmp, path, MOVEFILE_REPLACE_EXISTING)) {
        /* 尽力恢复：把 .bak 改回去，绝不留下“没有 settings.json”的状态。 */
        if (had_old) {
            move_file(bak, path, MOVEFILE_REPLACE_EXISTING);
        }
        delete_file_utf8(tmp);
        return ps_fail(err, err_sz, "替换设置文件失败（已尝试恢复旧设置）");
    }

    rc = TS_SETTINGS_OK;
    return rc;
}

/* ------------------------------------------------------------------ */
/* 加载                                                                */
/* ------------------------------------------------------------------ */

int ts_settings_load(const char *data_dir, TsProfileList *out,
                     int *out_loaded_from_disk,
                     char *warning, size_t warning_sz,
                     char *err, size_t err_sz)
{
    char path[2048];
    char *raw = NULL;
    size_t raw_len = 0;
    int exists = 0;
    int rc;

    if (out == NULL) return ps_fail(err, err_sz, "输出参数为空");
    ts_profile_list_init(out);
    if (out_loaded_from_disk != NULL) *out_loaded_from_disk = 0;
    if (warning != NULL && warning_sz > 0) warning[0] = '\0';
    if (err != NULL && err_sz > 0) err[0] = '\0';

    if (ts_settings_path(data_dir, 0, path, sizeof(path)) != 0) {
        return ps_fail(err, err_sz, "设置文件路径无法构造（data_dir 为空或过长）");
    }

    rc = read_all(path, &raw, &raw_len, &exists, err, err_sz);
    if (rc != TS_SETTINGS_OK) {
        ts_profile_list_init(out);
        return rc;
    }
    if (!exists) {
        return TS_SETTINGS_OK;   /* 空列表 + loaded=0：调用方可以尝试迁移 */
    }
    if (out_loaded_from_disk != NULL) *out_loaded_from_disk = 1;

    /* 去掉 UTF-8 BOM（不是我们写的，但可能被别的编辑器加上）。 */
    {
        size_t off = 0;
        if (raw_len >= 3 && (unsigned char)raw[0] == 0xEF &&
            (unsigned char)raw[1] == 0xBB && (unsigned char)raw[2] == 0xBF) {
            off = 3;
        }
        if (!ts_utf8_valid((const unsigned char *)raw + off, raw_len - off)) {
            ts_free(raw);
            if (warning != NULL && warning_sz > 0) {
                snprintf(warning, warning_sz,
                         "设置文件不是合法的 UTF-8，已改用内置默认（空）配置；"
                         "原文件保持不动，未被覆盖");
            }
            return TS_SETTINGS_OK;
        }
        rc = ts_profile_list_parse(raw + off, raw_len - off, out, err, err_sz);
    }
    ts_free(raw);

    if (rc != TS_SETTINGS_OK) {
        ts_profile_list_free(out);
        ts_profile_list_init(out);
        if (warning != NULL && warning_sz > 0) {
            snprintf(warning, warning_sz,
                     "设置文件无法解析或版本不兼容，已改用内置默认（空）配置；"
                     "原文件保持不动，未被覆盖。原因：%s",
                     (err != NULL && err[0] != '\0') ? err : "未知");
        }
        return TS_SETTINGS_OK;
    }
    return TS_SETTINGS_OK;
}

/* ------------------------------------------------------------------ */
/* 迁移（旧 config.json → legacy profile）                              */
/* ------------------------------------------------------------------ */

int ts_settings_migrate_legacy(TsProfileList *list, const TsConfig *legacy_cfg,
                               char *err, size_t err_sz)
{
    TsProfile p;
    char host[TS_PROFILE_HOST_MAX];
    char note[1024];
    int imported = 0;
    int cred_err = 0;

    if (list == NULL || legacy_cfg == NULL) {
        return ps_fail(err, err_sz, "迁移参数为空");
    }
    ts_profile_init(&p);
    if (ts_profile_from_legacy_config(legacy_cfg, TS_LEGACY_PROFILE_ID, &p,
                                      err, err_sz) != 0) {
        ts_profile_free(&p);
        return TS_SETTINGS_ERR;
    }

    ts_url_host(p.chat_url, host, sizeof(host));

    /*
     * 内联密钥一次性导入凭据管理器：仅当本次迁移真的从旧配置读到内联密钥。
     * 环境变量方式保持原样（运行期解析），不落盘。
     * 旧 config.json **不删除、不修改**。
     */
    if (legacy_cfg->api_key != NULL && legacy_cfg->api_key[0] != '\0') {
        char cerr[512];
        cerr[0] = '\0';
        if (ts_credential_set(p.id, host, legacy_cfg->api_key,
                              strlen(legacy_cfg->api_key),
                              cerr, sizeof(cerr)) == 0) {
            p.credential_configured = 1;
            ts_free(p.credential_host);
            p.credential_host = ts_strdup(host);
            imported = 1;
        } else {
            cred_err = 1;
            /* 不用 cerr 原文（可能含系统信息），只保留分类描述。 */
        }
    }

    if (ts_profile_list_append(list, &p) != 0) {
        ts_profile_free(&p);
        return ps_fail(err, err_sz, "内存分配失败");
    }

    ts_free(list->default_profile_id);
    list->default_profile_id = ts_strdup(p.id);
    ts_free(list->default_model_id);
    list->default_model_id = ts_strdup(p.model_id);
    list->default_thinking = p.thinking;
    ts_free(list->default_reasoning_effort);
    list->default_reasoning_effort =
        (p.thinking == TS_THINKING_ENABLED && p.reasoning_effort != NULL)
            ? ts_strdup(p.reasoning_effort) : NULL;

    list->migration_legacy = 1;

    if (cred_err) {
        snprintf(note, sizeof(note),
                 "已从旧 config.json 迁移出 1 个模型连接（id=%s）。旧文件未修改、未删除；"
                 "内联 API Key 导入 Windows 凭据管理器失败，请在“模型”页重新输入一次。",
                 p.id);
    } else if (imported) {
        snprintf(note, sizeof(note),
                 "已从旧 config.json 迁移出 1 个模型连接（id=%s）。旧文件未修改、未删除；"
                 "内联 API Key 已一次性导入 Windows 凭据管理器，settings.json 与备份均不含密钥。",
                 p.id);
    } else if (p.api_key_env != NULL && p.api_key_env[0] != '\0') {
        snprintf(note, sizeof(note),
                 "已从旧 config.json 迁移出 1 个模型连接（id=%s）。旧文件未修改、未删除；"
                 "API Key 仍由环境变量 %s 在运行期提供，未写入磁盘。",
                 p.id, p.api_key_env);
    } else {
        snprintf(note, sizeof(note),
                 "已从旧 config.json 迁移出 1 个模型连接（id=%s，无鉴权）。"
                 "旧文件未修改、未删除。", p.id);
    }
    ts_free(list->migration_note);
    list->migration_note = ts_strdup(note);

    ts_profile_free(&p);
    if (list->migration_note == NULL) {
        return ps_fail(err, err_sz, "内存分配失败");
    }
    return TS_SETTINGS_OK;
}

/* ------------------------------------------------------------------ */
/* 保存请求解析                                                        */
/* ------------------------------------------------------------------ */

void ts_settings_request_init(TsSettingsRequest *r)
{
    if (r == NULL) return;
    memset(r, 0, sizeof(*r));
    ts_profile_list_init(&r->list);
}

void ts_settings_request_free(TsSettingsRequest *r)
{
    size_t i;
    if (r == NULL) return;
    ts_profile_list_free(&r->list);
    ts_free(r->revision_present);
    for (i = 0; i < r->deleted_count; i++) ts_free(r->deleted_ids[i]);
    ts_free(r->deleted_ids);
    memset(r, 0, sizeof(*r));
}

static int jhas(const struct cJSON *o, const char *key)
{
    return cJSON_GetObjectItemCaseSensitive((cJSON *)o, key) != NULL ? 1 : 0;
}

static const char *jstr(const cJSON *o, const char *key)
{
    const cJSON *it = cJSON_GetObjectItemCaseSensitive(o, key);
    if (it == NULL || !cJSON_IsString(it)) return NULL;
    return cJSON_GetStringValue(it);
}





int ts_settings_request_parse(const char *json, size_t len,
                              TsSettingsRequest *out, char *err, size_t err_sz)
{
    cJSON *root;
    const cJSON *profiles;
    const cJSON *deleted;
    const char *s;
    int n;
    int i;
    int rc = TS_SETTINGS_ERR;

    if (out == NULL) return ps_fail(err, err_sz, "输出参数为空");
    ts_settings_request_init(out);
    if (json == NULL || len == 0) {
        return ps_fail(err, err_sz, "设置请求为空");
    }
    root = cJSON_ParseWithLength(json, len);
    if (root == NULL) {
        return ps_fail(err, err_sz, "设置请求不是合法 JSON");
    }
    if (!cJSON_IsObject(root)) {
        cJSON_Delete(root);
        return ps_fail(err, err_sz, "设置请求必须是 JSON 对象");
    }

    /* schemaVersion：允许缺省（视为 2），显式给出且不为 2 则拒绝。 */
    {
        const cJSON *sv = cJSON_GetObjectItemCaseSensitive(root, "schemaVersion");
        if (sv != NULL && cJSON_IsNumber(sv)) {
            out->list.schema_version = (int)sv->valuedouble;
            if (out->list.schema_version != TS_SETTINGS_SCHEMA_VERSION) {
                char msg[192];
                snprintf(msg, sizeof(msg),
                         "设置请求的 schemaVersion=%d 与本程序（%d）不兼容",
                         out->list.schema_version, TS_SETTINGS_SCHEMA_VERSION);
                cJSON_Delete(root);
                ts_settings_request_free(out);
                return ps_fail(err, err_sz, msg);
            }
        } else {
            out->list.schema_version = TS_SETTINGS_SCHEMA_VERSION;
        }
    }

    profiles = cJSON_GetObjectItemCaseSensitive(root, "profiles");
    if (profiles != NULL && !cJSON_IsNull(profiles)) {
        if (!cJSON_IsArray(profiles)) {
            cJSON_Delete(root);
            ts_settings_request_free(out);
            return ps_fail(err, err_sz, "profiles 必须是数组");
        }
        n = cJSON_GetArraySize(profiles);
        if (n > 0) {
            size_t bytes;
            if (ts_mul_overflow((size_t)n, sizeof(unsigned char), &bytes)) {
                cJSON_Delete(root);
                ts_settings_request_free(out);
                return ps_fail(err, err_sz, "内存分配失败");
            }
            out->revision_present = (unsigned char *)ts_calloc((size_t)n, 1);
            if (out->revision_present == NULL) {
                cJSON_Delete(root);
                ts_settings_request_free(out);
                return ps_fail(err, err_sz, "内存分配失败");
            }
        }
        for (i = 0; i < n; i++) {
            const cJSON *item = cJSON_GetArrayItem(profiles, i);
            TsProfile p;
            ts_profile_init(&p);
            if (ts_profile_from_json(item, &p, err, err_sz) != 0) {
                ts_profile_free(&p);
                cJSON_Delete(root);
                ts_settings_request_free(out);
                return TS_SETTINGS_ERR;
            }
            out->revision_present[i] = (unsigned char)(jhas(item, "revision") ? 1 : 0);
            if (ts_profile_list_append(&out->list, &p) != 0) {
                ts_profile_free(&p);
                cJSON_Delete(root);
                ts_settings_request_free(out);
                return ps_fail(err, err_sz, "内存分配失败");
            }
            ts_profile_free(&p);
        }
    }

    deleted = cJSON_GetObjectItemCaseSensitive(root, "deletedProfileIds");
    if (deleted != NULL && !cJSON_IsNull(deleted)) {
        if (!cJSON_IsArray(deleted)) {
            cJSON_Delete(root);
            ts_settings_request_free(out);
            return ps_fail(err, err_sz, "deletedProfileIds 必须是数组");
        }
        n = cJSON_GetArraySize(deleted);
        if (n > 0) {
            size_t bytes;
            if (ts_mul_overflow((size_t)n, sizeof(char *), &bytes)) {
                cJSON_Delete(root);
                ts_settings_request_free(out);
                return ps_fail(err, err_sz, "内存分配失败");
            }
            out->deleted_ids = (char **)ts_calloc((size_t)n, sizeof(char *));
            if (out->deleted_ids == NULL) {
                cJSON_Delete(root);
                ts_settings_request_free(out);
                return ps_fail(err, err_sz, "内存分配失败");
            }
            for (i = 0; i < n; i++) {
                const cJSON *item = cJSON_GetArrayItem(deleted, i);
                const char *id;
                if (item == NULL || !cJSON_IsString(item)) {
                    cJSON_Delete(root);
                    ts_settings_request_free(out);
                    return ps_fail(err, err_sz, "deletedProfileIds 里必须是字符串");
                }
                id = cJSON_GetStringValue(item);
                out->deleted_ids[out->deleted_count] = ts_strdup(id);
                if (out->deleted_ids[out->deleted_count] == NULL) {
                    cJSON_Delete(root);
                    ts_settings_request_free(out);
                    return ps_fail(err, err_sz, "内存分配失败");
                }
                out->deleted_count++;
            }
        }
    }

    s = jstr(root, "defaultProfileId");
    if (s != NULL && s[0] != '\0') {
        out->list.default_profile_id = ts_strdup(s);
        if (out->list.default_profile_id == NULL) goto oom;
    }
    s = jstr(root, "defaultModelId");
    if (s != NULL && s[0] != '\0') {
        out->list.default_model_id = ts_strdup(s);
        if (out->list.default_model_id == NULL) goto oom;
    }
    s = jstr(root, "defaultThinking");
    if (s != NULL) {
        TsThinking t = TS_THINKING_UNSUPPORTED;
        if (ts_thinking_parse(s, &t) == 0) out->list.default_thinking = t;
    }
    s = jstr(root, "defaultReasoningEffort");
    if (s != NULL && s[0] != '\0') {
        out->list.default_reasoning_effort = ts_strdup(s);
        if (out->list.default_reasoning_effort == NULL) goto oom;
    }

    /* 迁移标记不由前端写入，这里固定为 0。 */
    out->list.migration_legacy = 0;

    cJSON_Delete(root);
    rc = TS_SETTINGS_OK;
    return rc;

oom:
    cJSON_Delete(root);
    ts_settings_request_free(out);
    return ps_fail(err, err_sz, "内存分配失败");
}

/* ------------------------------------------------------------------ */
/* 合并（乐观 revision）                                                */
/* ------------------------------------------------------------------ */

static int str_eq_optional(const char *a, const char *b)
{
    const char *x = (a != NULL) ? a : "";
    const char *y = (b != NULL) ? b : "";
    return strcmp(x, y) == 0;
}

/*
 * 用户可编辑字段是否完全相同。
 * 刻意**不比较** revision / credentialConfigured / credentialHost：
 * 前者的递增规则由这里决定，后两者由凭据子系统维护，前端不应改动它们。
 */
static int same_editable(const TsProfile *a, const TsProfile *b)
{
    if (a->protocol != b->protocol) return 0;
    if (a->thinking != b->thinking) return 0;
    if ((a->json_mode ? 1 : 0) != (b->json_mode ? 1 : 0)) return 0;
    if (!str_eq_optional(a->id, b->id)) return 0;
    if (!str_eq_optional(a->name, b->name)) return 0;
    if (!str_eq_optional(a->base_url, b->base_url)) return 0;
    if (!str_eq_optional(a->chat_url, b->chat_url)) return 0;
    if (!str_eq_optional(a->models_url, b->models_url)) return 0;
    if (!str_eq_optional(a->auth_mode, b->auth_mode)) return 0;
    if (!str_eq_optional(a->api_key_env, b->api_key_env)) return 0;
    if (!str_eq_optional(a->model_id, b->model_id)) return 0;
    if (!str_eq_optional(a->reasoning_effort, b->reasoning_effort)) return 0;
    return 1;
}

static int is_deleted(const TsSettingsRequest *req, const char *id)
{
    size_t i;
    for (i = 0; i < req->deleted_count; i++) {
        if (strcmp(req->deleted_ids[i], id) == 0) return 1;
    }
    return 0;
}

/* 用 incoming 替换 working 中同 id 的项（深拷贝 + 保留凭据元信息 + revision 规则）。 */
static int replace_item(TsProfileList *working, size_t index,
                        const TsProfile *incoming, long new_revision,
                        const TsProfile *cred_from, char *err, size_t err_sz)
{
    TsProfile merged;
    ts_profile_init(&merged);
    if (ts_profile_copy(&merged, incoming) != 0) {
        return ps_fail(err, err_sz, "内存分配失败");
    }
    merged.revision = new_revision;
    /* 凭据元信息以磁盘状态为准：前端不得通过保存来伪造“已配置”。 */
    merged.credential_configured = cred_from->credential_configured;
    ts_free(merged.credential_host);
    merged.credential_host = (cred_from->credential_host != NULL &&
                              cred_from->credential_host[0] != '\0')
                                 ? ts_strdup(cred_from->credential_host) : NULL;
    if (cred_from->credential_host != NULL && cred_from->credential_host[0] != '\0' &&
        merged.credential_host == NULL) {
        ts_profile_free(&merged);
        return ps_fail(err, err_sz, "内存分配失败");
    }

    ts_profile_free(&working->items[index]);
    working->items[index] = merged;
    return TS_SETTINGS_OK;
}

int ts_settings_merge(const TsProfileList *current, const TsSettingsRequest *req,
                      TsProfileList *out,
                      char *conflict_profile_id, size_t conflict_sz,
                      char *err, size_t err_sz,
                      const char **err_kind)
{
    TsProfileList working;
    size_t i;
    int rc = TS_SETTINGS_ERR;

    if (err_kind != NULL) *err_kind = "invalidRequest";
    if (conflict_profile_id != NULL && conflict_sz > 0) conflict_profile_id[0] = '\0';
    if (err != NULL && err_sz > 0) err[0] = '\0';
    if (out == NULL || current == NULL || req == NULL) {
        return ps_fail(err, err_sz, "合并参数为空");
    }
    ts_profile_list_init(out);

    /* 1) 以磁盘状态为基线。 */
    ts_profile_list_init(&working);
    if (ts_profile_list_copy(&working, current) != 0) {
        return ps_fail(err, err_sz, "内存分配失败");
    }

    /* 2) 先处理删除（幂等：删一个本来就不存在的 id 不算错）。 */
    for (i = 0; i < req->deleted_count; i++) {
        (void)ts_profile_list_remove(&working, req->deleted_ids[i]);
    }

    /* 3) 再处理新增/修改。 */
    for (i = 0; i < req->list.count; i++) {
        const TsProfile *in = &req->list.items[i];
        TsProfile *cur;
        int revision_present = (req->revision_present != NULL &&
                                req->revision_present[i]) ? 1 : 0;

        if (in->id == NULL || in->id[0] == '\0') {
            if (err_kind != NULL) *err_kind = "validation";
            rc = ps_fail(err, err_sz, "profile 缺少 id");
            goto done;
        }
        if (is_deleted(req, in->id)) {
            if (err_kind != NULL) *err_kind = "invalidRequest";
            rc = ps_fail(err, err_sz,
                         "同一个请求里既删除又修改了某个连接；请刷新后重试");
            goto done;
        }

        cur = ts_profile_list_find_mut(&working, in->id);
        if (cur == NULL) {
            /* 新建：revision 必须是 0（或缺失），保存后为 1。 */
            TsProfile fresh;
            if (revision_present && in->revision != 0) {
                if (err_kind != NULL) *err_kind = "invalidRevision";
                ps_failf(err, err_sz,
                         "连接 %s 在磁盘上不存在，但请求里带了 revision=%ld；"
                         "新建连接必须用 revision=0，请刷新后重试",
                         in->id, in->revision);
                rc = TS_SETTINGS_ERR;
                goto done;
            }
            ts_profile_init(&fresh);
            if (ts_profile_copy(&fresh, in) != 0) {
                rc = ps_fail(err, err_sz, "内存分配失败");
                goto done;
            }
            fresh.revision = 1;
            fresh.credential_configured = 0;
            ts_free(fresh.credential_host);
            fresh.credential_host = NULL;
            if (ts_profile_list_append(&working, &fresh) != 0) {
                ts_profile_free(&fresh);
                rc = ps_fail(err, err_sz, "内存分配失败");
                goto done;
            }
            ts_profile_free(&fresh);
        } else {
            /*
             * 修改：revision 必须显式给出且与磁盘一致。
             * 缺失 revision 与 revision 不匹配都不是“用最新配置顶上”的理由。
             */
            if (!revision_present) {
                if (err_kind != NULL) *err_kind = "invalidRevision";
                ps_failf(err, err_sz,
                         "连接 %s 的请求缺少 revision，无法确认配置版本；"
                         "请刷新设置后重试（不会用最新配置静默替代）", in->id);
                rc = TS_SETTINGS_ERR;
                goto done;
            }
            if (in->revision != cur->revision) {
                if (conflict_profile_id != NULL && conflict_sz > 0) {
                    snprintf(conflict_profile_id, conflict_sz, "%s", in->id);
                }
                if (err_kind != NULL) *err_kind = "conflict";
                ps_failf(err, err_sz,
                         "模型配置已被修改，请刷新后重试"
                         "（连接 %s：磁盘 revision=%ld，请求 revision=%ld）",
                         in->id, cur->revision, in->revision);
                rc = TS_SETTINGS_CONFLICT;
                goto done;
            }
            {
                long new_rev = same_editable(cur, in) ? cur->revision : (cur->revision + 1);
                size_t index = (size_t)(cur - working.items);
                rc = replace_item(&working, index, in, new_rev, cur, err, err_sz);
                if (rc != TS_SETTINGS_OK) goto done;
            }
        }
    }

    /* 4) 默认值来自请求。 */
    ts_free(working.default_profile_id);
    working.default_profile_id = NULL;
    if (req->list.default_profile_id != NULL) {
        working.default_profile_id = ts_strdup(req->list.default_profile_id);
        if (working.default_profile_id == NULL) {
            rc = ps_fail(err, err_sz, "内存分配失败");
            goto done;
        }
    }
    ts_free(working.default_model_id);
    working.default_model_id = NULL;
    if (req->list.default_model_id != NULL) {
        working.default_model_id = ts_strdup(req->list.default_model_id);
        if (working.default_model_id == NULL) {
            rc = ps_fail(err, err_sz, "内存分配失败");
            goto done;
        }
    }
    working.default_thinking = req->list.default_thinking;
    ts_free(working.default_reasoning_effort);
    working.default_reasoning_effort = NULL;
    if (req->list.default_reasoning_effort != NULL &&
        req->list.default_reasoning_effort[0] != '\0') {
        working.default_reasoning_effort =
            ts_strdup(req->list.default_reasoning_effort);
        if (working.default_reasoning_effort == NULL) {
            rc = ps_fail(err, err_sz, "内存分配失败");
            goto done;
        }
    }

    /* 5) 整体校验（默认值必须指向存在的连接）。 */
    if (ts_profile_list_validate(&working, err, err_sz) != 0) {
        if (err_kind != NULL) *err_kind = "validation";
        rc = TS_SETTINGS_ERR;
        goto done;
    }

    /* 6) 所有权移交。 */
    *out = working;
    ts_profile_list_init(&working);
    if (err_kind != NULL) *err_kind = "ok";
    rc = TS_SETTINGS_OK;

done:
    ts_profile_list_free(&working);
    return rc;
}

