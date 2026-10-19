/*
 * credential.c — Windows 凭据管理器的 API Key 读写删；目标名按数据空间与主机隔离，内存中的密钥释放前擦除。
 *
 * 主要函数：ts_credential_set_scoped / load_scoped / exists_scoped / delete_scoped、ts_credential_space_id。
 */

#include "credential.h"

#include "mem.h"
#include "text.h"

#include <stdio.h>
#include <string.h>

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <wincred.h>

/* advapi32 由 CMake 显式链接（target_link_libraries(ts_core ... advapi32)），不做 #pragma comment。 */

#define TS_CRED_MAX_BLOB (TS_CREDENTIAL_MAX_KEY_BYTES + 1)

static int cred_fail(char *err, size_t err_sz, const char *msg)
{
    if (err != NULL && err_sz > 0) {
        snprintf(err, err_sz, "%s", msg);
    }
    return 1;
}

/* 构造目标名：TaskScheduler/model/<id>。目标名必须是 UTF-16。 */
static wchar_t *target_name(const char *profile_id)
{
    char narrow[TS_CREDENTIAL_TARGET_MAX];
    wchar_t *wide;
    int n;

    if (profile_id == NULL || profile_id[0] == '\0') return NULL;
    if (strlen(profile_id) > 128) return NULL;
    if (snprintf(narrow, sizeof(narrow), "%s%s",
                 TS_CREDENTIAL_TARGET_PREFIX, profile_id) < 0) {
        return NULL;
    }
    n = MultiByteToWideChar(CP_UTF8, 0, narrow, -1, NULL, 0);
    if (n <= 0) return NULL;
    wide = (wchar_t *)ts_calloc((size_t)n, sizeof(wchar_t));
    if (wide == NULL) return NULL;
    if (MultiByteToWideChar(CP_UTF8, 0, narrow, -1, wide, n) <= 0) {
        ts_free(wide);
        return NULL;
    }
    return wide;
}

/* 构造任意窄目标名的 UTF-16 版本（调用方负责长度与字符集）。 */
static wchar_t *target_name_raw(const char *narrow)
{
    wchar_t *wide;
    int n;

    if (narrow == NULL || narrow[0] == '\0') return NULL;
    n = MultiByteToWideChar(CP_UTF8, 0, narrow, -1, NULL, 0);
    if (n <= 0) return NULL;
    wide = (wchar_t *)ts_calloc((size_t)n, sizeof(wchar_t));
    if (wide == NULL) return NULL;
    if (MultiByteToWideChar(CP_UTF8, 0, narrow, -1, wide, n) <= 0) {
        ts_free(wide);
        return NULL;
    }
    return wide;
}

/*
 * 构造带数据空间的目标名：TaskScheduler/model/<space>/<profileId>。
 * space 为空时退化为旧目标名（兼容路径）。
 */
static wchar_t *target_name_scoped(const char *space, const char *profile_id)
{
    char narrow[TS_CREDENTIAL_TARGET_MAX];
    int n;

    if (profile_id == NULL || profile_id[0] == '\0') return NULL;
    if (strlen(profile_id) > 128) return NULL;
    if (space == NULL || space[0] == '\0') return target_name(profile_id);
    if (strlen(space) >= TS_CREDENTIAL_SPACE_MAX) return NULL;
    n = snprintf(narrow, sizeof(narrow), "%s%s/%s",
                 TS_CREDENTIAL_TARGET_PREFIX, space, profile_id);
    if (n < 0 || (size_t)n >= sizeof(narrow)) return NULL;
    return target_name_raw(narrow);
}

/* ------------------------------------------------------------------ */
/* 数据空间标识（data_dir → 16 位小写十六进制）                         */
/* ------------------------------------------------------------------ */

#define TS_FNV64_OFFSET 14695981039346656037ULL
#define TS_FNV64_PRIME  1099511628211ULL

static unsigned long long fnv1a64(const void *data, size_t len)
{
    const unsigned char *p = (const unsigned char *)data;
    unsigned long long h = TS_FNV64_OFFSET;
    size_t i;
    for (i = 0; i < len; i++) {
        h ^= (unsigned long long)p[i];
        h *= TS_FNV64_PRIME;
    }
    return h;
}

/*
 * 把路径规范化为“可哈希的稳定形式”：绝对路径 + 统一分隔符 + 小写 + 去尾分隔符。
 * 返回 owned 的 wchar_t*；失败返回 NULL（调用方退回哈希原始字节）。
 */
static wchar_t *space_normalize_path(const char *data_dir)
{
    const wchar_t *src;
    wchar_t *raw = NULL;
    wchar_t *full = NULL;
    DWORD need;
    size_t len;

    if (data_dir != NULL && data_dir[0] != '\0') {
        raw = ts_utf8_to_wide(data_dir, strlen(data_dir), NULL);
    }
    src = (raw != NULL) ? raw : L".";

    need = GetFullPathNameW(src, 0, NULL, NULL);
    if (need > 0) {
        full = (wchar_t *)ts_calloc((size_t)need + 1, sizeof(wchar_t));
        if (full != NULL) {
            DWORD got = GetFullPathNameW(src, need + 1, full, NULL);
            if (got == 0 || got > need) {
                ts_free(full);
                full = NULL;
            }
        }
    }
    if (full == NULL && raw != NULL) {
        /* 绝对化失败：至少用原始路径（仍然稳定）。 */
        full = (wchar_t *)ts_calloc(wcslen(raw) + 1, sizeof(wchar_t));
        if (full != NULL) wcscpy(full, raw);
    }
    ts_free(raw);
    if (full == NULL) return NULL;

    /* 统一分隔符 + 小写。 */
    for (len = 0; full[len] != L'\0'; len++) {
        wchar_t c = full[len];
        if (c == L'/') {
            full[len] = L'\\';
        } else if (c >= L'A' && c <= L'Z') {
            full[len] = (wchar_t)(c - L'A' + L'a');
        }
    }
    /* 去掉结尾分隔符，但保留盘符根（"c:\"）。 */
    while (len > 3 && full[len - 1] == L'\\') {
        full[len - 1] = L'\0';
        len--;
    }
    return full;
}

void ts_credential_space_id(const char *data_dir, char *out, size_t out_sz)
{
    wchar_t *norm;
    char *utf8 = NULL;
    unsigned long long h;

    if (out == NULL || out_sz == 0) return;
    out[0] = '\0';

    norm = space_normalize_path(data_dir);
    if (norm != NULL) {
        utf8 = ts_wide_to_utf8(norm, wcslen(norm));
        ts_free(norm);
    }
    if (utf8 != NULL) {
        h = fnv1a64(utf8, strlen(utf8));
        ts_free(utf8);
    } else if (data_dir != NULL && data_dir[0] != '\0') {
        h = fnv1a64(data_dir, strlen(data_dir));
    } else {
        h = fnv1a64(".", 1);
    }
    snprintf(out, out_sz, "%016llx", h);
}

static void cred_last_error_msg(char *err, size_t err_sz, const char *what)
{
    DWORD code = GetLastError();
    if (err == NULL || err_sz == 0) return;
    if (code == ERROR_NO_SUCH_LOGON_SESSION || code == ERROR_NOT_FOUND) {
        snprintf(err, err_sz, "%s：系统中没有找到该凭据（可能已被删除）", what);
        return;
    }
    if (code == ERROR_ACCESS_DENIED) {
        snprintf(err, err_sz, "%s：访问被拒绝（凭据属于其它登录用户？）", what);
        return;
    }
    if (code == ERROR_BAD_USERNAME) {
        snprintf(err, err_sz, "%s：凭据字段格式不正确", what);
        return;
    }
    snprintf(err, err_sz, "%s：Windows 错误码 %lu", what, (unsigned long)code);
}

/* ------------------------------------------------------------------ */
/* 底层：按目标名写入 / 读取 / 删除                                    */
/* ------------------------------------------------------------------ */

static int cred_write(wchar_t *target, const char *host,
                      const char *key, size_t key_len,
                      char *err, size_t err_sz)
{
    wchar_t *user = NULL;
    CREDENTIALW cred;
    char user_narrow[TS_CREDENTIAL_TARGET_MAX];

    if (snprintf(user_narrow, sizeof(user_narrow), "host:%s",
                 (host != NULL) ? host : "") < 0) {
        return cred_fail(err, err_sz, "写入凭据失败：主机字段过长");
    }
    {
        int n = MultiByteToWideChar(CP_UTF8, 0, user_narrow, -1, NULL, 0);
        if (n <= 0) {
            return cred_fail(err, err_sz, "写入凭据失败：无法转换主机字段");
        }
        user = (wchar_t *)ts_calloc((size_t)n, sizeof(wchar_t));
        if (user == NULL) {
            return cred_fail(err, err_sz, "写入凭据失败：内存分配失败");
        }
        if (MultiByteToWideChar(CP_UTF8, 0, user_narrow, -1, user, n) <= 0) {
            ts_free(user);
            return cred_fail(err, err_sz, "写入凭据失败：无法转换主机字段");
        }
    }

    memset(&cred, 0, sizeof(cred));
    cred.Type = CRED_TYPE_GENERIC;
    cred.TargetName = target;
    cred.Comment = (LPWSTR)L"TaskScheduler 模型 API Key";
    cred.CredentialBlobSize = (DWORD)key_len;
    cred.CredentialBlob = (LPBYTE)(void *)key;
    cred.Persist = CRED_PERSIST_LOCAL_MACHINE;
    cred.UserName = user;

    if (!CredWriteW(&cred, 0)) {
        cred_last_error_msg(err, err_sz, "写入凭据失败");
        ts_free(user);
        return 1;
    }
    /* 宽字符串里没有密钥内容，可以直接释放。 */
    ts_free(user);
    return 0;
}

/*
 * 从已构造好的目标名读取。
 * 返回 0 = 找到；1 = 未找到（可安全回退到旧目标）；2 = 其它错误。
 */
static int cred_read(wchar_t *target, char **out_key, char **out_host,
                     char *err, size_t err_sz)
{
    PCREDENTIALW cred = NULL;
    char *key = NULL;
    char *host = NULL;

    if (!CredReadW(target, CRED_TYPE_GENERIC, 0, &cred)) {
        DWORD code = GetLastError();
        if (code == ERROR_NOT_FOUND || code == ERROR_NO_SUCH_LOGON_SESSION) {
            cred_fail(err, err_sz, "尚未为这个连接保存 API Key");
            return 1;
        }
        cred_last_error_msg(err, err_sz, "读取凭据失败");
        return 2;
    }

    if (cred->CredentialBlob == NULL || cred->CredentialBlobSize == 0) {
        CredFree(cred);
        cred_fail(err, err_sz, "凭据存在但内容为空，请重新输入 API Key");
        return 2;
    }
    if (cred->CredentialBlobSize > TS_CREDENTIAL_MAX_KEY_BYTES) {
        CredFree(cred);
        cred_fail(err, err_sz, "凭据内容异常（过长），请重新输入 API Key");
        return 2;
    }

    key = ts_strndup((const char *)cred->CredentialBlob, cred->CredentialBlobSize);
    if (key == NULL) {
        CredFree(cred);
        cred_fail(err, err_sz, "读取凭据失败：内存分配失败");
        return 2;
    }
    /* 用户名字段形如 host:<host>；不符合时视为“未绑定主机”。 */
    if (cred->UserName != NULL) {
        char *user_utf8 = ts_wide_to_utf8(cred->UserName, wcslen(cred->UserName));
        if (user_utf8 != NULL) {
            if (strncmp(user_utf8, "host:", 5) == 0 && user_utf8[5] != '\0') {
                host = ts_strdup(user_utf8 + 5);
                if (host == NULL) {
                    ts_secure_free(&key);
                    ts_free(user_utf8);
                    CredFree(cred);
                    cred_fail(err, err_sz, "读取凭据失败：内存分配失败");
                    return 2;
                }
            }
            ts_free(user_utf8);
        }
    }
    CredFree(cred);

    if (out_key != NULL) {
        *out_key = key;
    } else {
        ts_secure_free(&key);
    }
    if (out_host != NULL) {
        *out_host = host;
    } else {
        ts_free(host);
    }
    return 0;
}

/* 删除已构造好的目标名；“本来就不存在”算成功。 */
static int cred_delete(wchar_t *target, char *err, size_t err_sz)
{
    if (CredDeleteW(target, CRED_TYPE_GENERIC, 0)) return 0;
    {
        DWORD code = GetLastError();
        if (code == ERROR_NOT_FOUND || code == ERROR_NO_SUCH_LOGON_SESSION) {
            /* 本来就不存在：对调用方来说“已经删掉”是同样的结果。 */
            return 0;
        }
    }
    cred_last_error_msg(err, err_sz, "删除凭据失败");
    return 1;
}

int ts_credential_set(const char *profile_id, const char *host,
                      const char *key, size_t key_len,
                      char *err, size_t err_sz)
{
    wchar_t *target = NULL;
    int rc;

    if (err != NULL && err_sz > 0) err[0] = '\0';

    if (profile_id == NULL || profile_id[0] == '\0') {
        return cred_fail(err, err_sz, "写入凭据失败：profile id 为空");
    }
    if (key == NULL || key_len == 0) {
        return cred_fail(err, err_sz, "写入凭据失败：API Key 为空");
    }
    if (key_len > TS_CREDENTIAL_MAX_KEY_BYTES) {
        return cred_fail(err, err_sz, "写入凭据失败：API Key 过长");
    }

    target = target_name(profile_id);
    if (target == NULL) {
        return cred_fail(err, err_sz, "写入凭据失败：无法构造凭据目标名");
    }
    rc = cred_write(target, host, key, key_len, err, err_sz);
    ts_free(target);
    return rc;
}

int ts_credential_set_scoped(const char *space, const char *profile_id,
                             const char *host, const char *key, size_t key_len,
                             char *err, size_t err_sz)
{
    wchar_t *target = NULL;
    int rc;

    if (err != NULL && err_sz > 0) err[0] = '\0';

    if (profile_id == NULL || profile_id[0] == '\0') {
        return cred_fail(err, err_sz, "写入凭据失败：profile id 为空");
    }
    if (key == NULL || key_len == 0) {
        return cred_fail(err, err_sz, "写入凭据失败：API Key 为空");
    }
    if (key_len > TS_CREDENTIAL_MAX_KEY_BYTES) {
        return cred_fail(err, err_sz, "写入凭据失败：API Key 过长");
    }

    target = target_name_scoped(space, profile_id);
    if (target == NULL) {
        return cred_fail(err, err_sz, "写入凭据失败：无法构造凭据目标名");
    }
    rc = cred_write(target, host, key, key_len, err, err_sz);
    ts_free(target);
    return rc;
}

int ts_credential_load(const char *profile_id, char **out_key, char **out_host,
                       char *err, size_t err_sz)
{
    wchar_t *target = NULL;
    int rc;

    if (out_key != NULL) *out_key = NULL;
    if (out_host != NULL) *out_host = NULL;
    if (err != NULL && err_sz > 0) err[0] = '\0';

    if (profile_id == NULL || profile_id[0] == '\0') {
        return cred_fail(err, err_sz, "读取凭据失败：profile id 为空");
    }

    target = target_name(profile_id);
    if (target == NULL) {
        return cred_fail(err, err_sz, "读取凭据失败：无法构造凭据目标名");
    }
    rc = cred_read(target, out_key, out_host, err, err_sz);
    ts_free(target);
    /* 对外契约不变：只有“找到”返回 0。 */
    return (rc == 0) ? 0 : 1;
}

int ts_credential_load_scoped(const char *space, const char *profile_id,
                              char **out_key, char **out_host, int *out_migrated,
                              char *err, size_t err_sz)
{
    wchar_t *target = NULL;
    wchar_t *legacy = NULL;
    char legerr[512];
    int rc;

    if (out_key != NULL) *out_key = NULL;
    if (out_host != NULL) *out_host = NULL;
    if (out_migrated != NULL) *out_migrated = 0;
    if (err != NULL && err_sz > 0) err[0] = '\0';

    if (profile_id == NULL || profile_id[0] == '\0') {
        return cred_fail(err, err_sz, "读取凭据失败：profile id 为空");
    }

    target = target_name_scoped(space, profile_id);
    if (target == NULL) {
        return cred_fail(err, err_sz, "读取凭据失败：无法构造凭据目标名");
    }
    rc = cred_read(target, out_key, out_host, err, err_sz);
    ts_free(target);

    if (rc == 0) return 0;
    if (rc != 1) return 1;   /* 其它错误：不回退旧目标，直接报错 */
    if (space == NULL || space[0] == '\0') return 1;   /* 没有新目标可言 */

    /*
     * 兼容旧版本：旧目标是 TaskScheduler/model/<profileId>（无数据空间）。
     * 命中后**复制**到新目标（不删除旧目标，便于回退旧版本）。
     * 复制失败不影响本次读取结果，但要记下原因以外的情况只在调试时才看：
     * 这里保持“能读到就算成功”，避免用户因为一次写失败而无法使用已保存的密钥。
     */
    legacy = target_name(profile_id);
    if (legacy == NULL) return 1;
    legerr[0] = '\0';
    rc = cred_read(legacy, out_key, out_host, legerr, sizeof(legerr));
    ts_free(legacy);
    if (rc != 0) {
        /* 旧目标也没有：用新目标的“未配置”说明（更符合当前语义）。 */
        cred_fail(err, err_sz, "尚未为这个连接保存 API Key");
        return 1;
    }

    if (out_key != NULL && *out_key != NULL) {
        char werr[512];
        werr[0] = '\0';
        ts_credential_set_scoped(space, profile_id,
                                 (out_host != NULL && *out_host != NULL) ? *out_host : "",
                                 *out_key, strlen(*out_key), werr, sizeof(werr));
    }
    if (out_migrated != NULL) *out_migrated = 1;
    return 0;
}

int ts_credential_exists(const char *profile_id)
{
    char err[256];
    char *key = NULL;
    int rc;
    err[0] = '\0';
    rc = ts_credential_load(profile_id, &key, NULL, err, sizeof(err));
    ts_secure_free(&key);
    return (rc == 0) ? 1 : 0;
}

int ts_credential_exists_scoped(const char *space, const char *profile_id)
{
    char err[256];
    char *key = NULL;
    int rc;
    err[0] = '\0';
    rc = ts_credential_load_scoped(space, profile_id, &key, NULL, NULL,
                                   err, sizeof(err));
    ts_secure_free(&key);
    return (rc == 0) ? 1 : 0;
}

int ts_credential_delete(const char *profile_id, char *err, size_t err_sz)
{
    wchar_t *target = NULL;
    int rc;

    if (err != NULL && err_sz > 0) err[0] = '\0';

    if (profile_id == NULL || profile_id[0] == '\0') {
        return cred_fail(err, err_sz, "删除凭据失败：profile id 为空");
    }
    target = target_name(profile_id);
    if (target == NULL) {
        return cred_fail(err, err_sz, "删除凭据失败：无法构造凭据目标名");
    }
    rc = cred_delete(target, err, err_sz);
    ts_free(target);
    return rc;
}

int ts_credential_delete_scoped(const char *space, const char *profile_id,
                                char *err, size_t err_sz)
{
    wchar_t *target = NULL;
    wchar_t *legacy = NULL;
    int rc = 0;

    if (err != NULL && err_sz > 0) err[0] = '\0';

    if (profile_id == NULL || profile_id[0] == '\0') {
        return cred_fail(err, err_sz, "删除凭据失败：profile id 为空");
    }

    /* 新目标（带数据空间）。 */
    target = target_name_scoped(space, profile_id);
    if (target == NULL) {
        return cred_fail(err, err_sz, "删除凭据失败：无法构造凭据目标名");
    }
    rc = cred_delete(target, err, err_sz);
    ts_free(target);

    /* 旧目标也删掉：否则新版本删了，旧版本仍会读到它。 */
    if (space != NULL && space[0] != '\0') {
        char legerr[512];
        legerr[0] = '\0';
        legacy = target_name(profile_id);
        if (legacy != NULL) {
            if (cred_delete(legacy, legerr, sizeof(legerr)) != 0 && rc == 0) {
                rc = 1;
                if (err != NULL && err_sz > 0) {
                    snprintf(err, err_sz, "删除旧凭据目标失败：%s", legerr);
                }
            }
            ts_free(legacy);
        }
    }
    return rc;
}

