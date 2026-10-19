#ifndef TS_PROFILE_STORE_H
#define TS_PROFILE_STORE_H

/*
 * profile_store.h — `<data_dir>/settings.json` 的原子保存、备份、旧配置迁移与乐观 revision 合并。
 *
 * 主要函数：ts_settings_load、ts_settings_write_atomic、ts_settings_merge、
 * ts_settings_migrate_legacy、ts_settings_path、ts_settings_request_*。
 */
#include <stddef.h>

#include "profile.h"

#ifdef __cplusplus
extern "C" {
#endif

/* 保存/合并的返回码。 */
#define TS_SETTINGS_OK        0
#define TS_SETTINGS_ERR       1
#define TS_SETTINGS_CONFLICT  2

/* settings 文件名（相对 data_dir）。 */
#define TS_SETTINGS_FILE_NAME "settings.json"
#define TS_SETTINGS_BAK_SUFFIX ".bak"
#define TS_SETTINGS_TMP_SUFFIX ".tmp"

/* 迁移出来的旧配置 profile 使用的固定 id。 */
#define TS_LEGACY_PROFILE_ID "legacy-config"

/*
 * 拼接 settings.json / .bak / .tmp 的完整路径。
 * kind: 0 = 主文件，1 = .bak，2 = .tmp。
 * 成功返回 0；data_dir 为空或路径过长返回非 0。
 */
int ts_settings_path(const char *data_dir, int kind, char *out, size_t out_sz);

/*
 * 读取 settings.json。
 * 成功返回 0：
 *   - 文件不存在：*out 为空列表，*out_loaded_from_disk = 0（由调用方决定是否迁移）；
 *   - 文件损坏/版本不兼容：*out 为空列表，*out_loaded_from_disk = 1，
 *     warning 写入可读说明（原文件保持不动，不会被覆盖）；
 *   - 正常：*out 为解析结果，*out_loaded_from_disk = 1。
 * 只有“路径本身无法构造”这类硬错误才返回非 0。
 */
int ts_settings_load(const char *data_dir, TsProfileList *out,
                     int *out_loaded_from_disk,
                     char *warning, size_t warning_sz,
                     char *err, size_t err_sz);

/*
 * 原子写入整份 settings.json。
 * 顺序：写 .tmp（并 FlushFileBuffers）→ 现有文件改名为 .bak → .tmp 提升为主文件。
 * 提升失败时尝试用 .bak 恢复原文件。成功返回 0。
 */
int ts_settings_write_atomic(const char *data_dir, const TsProfileList *list,
                             char *err, size_t err_sz);

/* 从旧 config.json 迁移出一个 legacy profile（含内联密钥一次性导入凭据）。 */
int ts_settings_migrate_legacy(TsProfileList *list, const TsConfig *legacy_cfg,
                               char *err, size_t err_sz);

/* ------------------------------------------------------------------ */
/* 保存请求（settings_save 的解析结果）                                 */
/* ------------------------------------------------------------------ */

typedef struct TsSettingsRequest {
    TsProfileList list;
    /*
     * 与 list.items 平行：该 profile 的 JSON 里**是否显式写了 revision**。
     * 区分“revision = 0（新建）”与“漏写 revision（未知版本）”，
     * 后者必须明确失败，绝不静默用最新配置替代。
     */
    unsigned char *revision_present;
    char **deleted_ids;
    size_t deleted_count;
} TsSettingsRequest;

void ts_settings_request_init(TsSettingsRequest *r);
void ts_settings_request_free(TsSettingsRequest *r);

/* 解析 settings_save 的入参 JSON。成功 0；失败非 0 并写 err。 */
int ts_settings_request_parse(const char *json, size_t len,
                              TsSettingsRequest *out, char *err, size_t err_sz);

/*
 * 把请求合并到 current 上（纯内存，不写盘）。
 * 返回：
 *   TS_SETTINGS_OK       → *out 为合并结果（已通过校验）；
 *   TS_SETTINGS_CONFLICT → *out 未定义；conflict_profile_id 填冲突的 id；
 *   TS_SETTINGS_ERR      → err 写原因（含 invalidRevision / validation）。
 * err_kind（可选出参）返回稳定的错误分类字符串：
 *   "conflict" / "invalidRevision" / "validation" / "invalidRequest" / "memory"。
 */
int ts_settings_merge(const TsProfileList *current, const TsSettingsRequest *req,
                      TsProfileList *out,
                      char *conflict_profile_id, size_t conflict_sz,
                      char *err, size_t err_sz,
                      const char **err_kind);

#ifdef __cplusplus
}
#endif

#endif /* TS_PROFILE_STORE_H */

