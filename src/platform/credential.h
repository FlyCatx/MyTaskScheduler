#ifndef TS_CREDENTIAL_H
#define TS_CREDENTIAL_H

/*
 * credential.h — Windows 凭据管理器中的模型 API Key（按数据空间与主机隔离）。
 *
 * 主要函数：ts_credential_set / set_scoped、ts_credential_load / load_scoped、
 * ts_credential_exists / exists_scoped、ts_credential_delete / delete_scoped、ts_credential_space_id。
 */
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* 凭据目标名前缀；新目标为 TaskScheduler/model/<space>/<profileId>，
 * 旧目标为 TaskScheduler/model/<profileId>（仅兼容读取）。 */
#define TS_CREDENTIAL_TARGET_PREFIX "TaskScheduler/model/"

/*
 * 数据空间隔离（0.0.4 验收修复）：
 *
 * 只按 profileId 命名凭据时，两个便携副本 / 不同数据目录里同名的 profile
 * 会共用或互相覆盖同一份密钥（症状：在 A 目录换了 Key，B 目录悄悄用了它）。
 * 因此凭据目标名改为：
 *
 *     TaskScheduler/model/<space>/<profileId>
 *
 * <space> 由**数据目录的绝对路径**规范化后做 FNV-1a 64 位哈希，取 16 位小写十六进制：
 *   - 相对路径先解析成绝对路径（GetFullPathName）；
 *   - 路径分隔符统一为 '\\'；
 *   - 大小写不敏感（统一转小写）；
 *   - 去掉结尾分隔符（盘符根 "C:\\" 保留）。
 * 同一个数据目录永远得到同一个 space（跨进程稳定）；不同目录得到不同 space。
 *
 * 旧目标 `TaskScheduler/model/<profileId>` 仍然兼容：只有 scoped 接口在
 * “新目标缺失”时回退读取旧目标，命中后复制到新目标（**不删除**旧目标）。
 * 旧接口（不带 space 的 ts_credential_*）只走旧目标，仅用于兼容路径
 * （旧配置迁移等）；bridge 一律使用 scoped 接口。
 */
#define TS_CREDENTIAL_SPACE_HEX 16
#define TS_CREDENTIAL_SPACE_MAX (TS_CREDENTIAL_SPACE_HEX + 1)

/*
 * 计算数据空间的稳定标识（16 位小写十六进制 + NUL）。
 * data_dir 为 NULL/空 → 用当前工作目录（cfg/当前目录）。
 * 无法解析路径时退化为对原始字节做哈希（仍然是稳定的 16 位十六进制），
 * 因此 out 永远是以 NUL 结尾的非空字符串。
 */
void ts_credential_space_id(const char *data_dir, char *out, size_t out_sz);

/* 单个密钥的字节上限（Credential Manager 的 blob 上限远大于此）。 */
#define TS_CREDENTIAL_MAX_KEY_BYTES 4096

/* 目标名缓冲区建议大小。 */
#define TS_CREDENTIAL_TARGET_MAX 256

/*
 * 写入/替换某 profile 的密钥。
 * profile_id 必须非空；host 可为空串（表示未绑定主机）。
 * 成功返回 0；失败返回非 0，err 为可读原因（不含密钥）。
 */
int ts_credential_set(const char *profile_id, const char *host,
                      const char *key, size_t key_len,
                      char *err, size_t err_sz);

/*
 * 读取某 profile 的密钥与绑定主机。
 * 找到时返回 0，*out_key / *out_host 为 owned（调用方用 ts_secure_free /
 * ts_free 释放）；*out_host 可能为 NULL（用户名为空或格式不符）。
 * 未配置返回 1（err 说明“未配置”）；其它错误返回非 0。
 */
int ts_credential_load(const char *profile_id, char **out_key, char **out_host,
                       char *err, size_t err_sz);

/* 该 profile 是否已存有密钥。1 = 有，0 = 无（含任何错误）。 */
int ts_credential_exists(const char *profile_id);

/*
 * 删除某 profile 的密钥。
 * 成功（含“本来就不存在”）返回 0；失败返回非 0。
 */
int ts_credential_delete(const char *profile_id, char *err, size_t err_sz);

/* ------------------------------------------------------------------ */
/* 数据空间隔离版本（bridge 使用；对外 ABI 不变）                       */
/* ------------------------------------------------------------------ */

/*
 * 以下 scoped 接口把目标名限定在某个数据空间内：
 *     TaskScheduler/model/<space>/<profileId>
 * space 必须是 ts_credential_space_id 的结果（16 位小写十六进制）。
 * 传 NULL/空 space 等价于旧接口（只用旧目标名），便于测试与兼容路径。
 */

/* 写入/替换某数据空间内某 profile 的密钥。成功返回 0。 */
int ts_credential_set_scoped(const char *space, const char *profile_id,
                             const char *host, const char *key, size_t key_len,
                             char *err, size_t err_sz);

/*
 * 读取某数据空间内某 profile 的密钥与绑定主机。
 * 新目标缺失时回退读取旧目标（TaskScheduler/model/<profileId>），
 * 命中后复制到新目标（**不删除**旧目标，便于回退旧版本）。
 * *out_migrated 可为 NULL；非 NULL 时写 1 表示本次是从旧目标迁移读取的。
 * 找到返回 0；未配置返回 1；其它错误返回非 0。
 */
int ts_credential_load_scoped(const char *space, const char *profile_id,
                              char **out_key, char **out_host, int *out_migrated,
                              char *err, size_t err_sz);

/* 该数据空间内（或旧目标）是否已存有密钥。1 = 有，0 = 无。 */
int ts_credential_exists_scoped(const char *space, const char *profile_id);

/* 删除该数据空间内**以及**旧目标里的密钥（两处都删）。成功返回 0。 */
int ts_credential_delete_scoped(const char *space, const char *profile_id,
                                char *err, size_t err_sz);

#ifdef __cplusplus
}
#endif

#endif /* TS_CREDENTIAL_H */

