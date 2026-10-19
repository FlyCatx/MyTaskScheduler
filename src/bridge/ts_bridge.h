#ifndef TS_BRIDGE_H
#define TS_BRIDGE_H

/*
 * ts_bridge.h — Flutter(Dart FFI) 与 C 内核之间的唯一 ABI（ABI 2：不透明句柄、轮询事件、DLL 分配缓冲）。
 *
 * 主要函数：ts_bridge_create_ex / ts_bridge_destroy、ts_bridge_analyze_async / constraints_async / probe_async、
 * ts_bridge_poll / result / cancel / release_job、ts_bridge_settings_*、ts_bridge_credential_*、
 * ts_bridge_edit / export、ts_bridge_shutdown_begin / shutdown_ready、ts_bridge_free。
 */
#include <stddef.h>
#include <stdint.h>

#if defined(_WIN32)
#  if defined(TS_BRIDGE_BUILD)
#    define TS_BRIDGE_API __declspec(dllexport)
#  else
#    define TS_BRIDGE_API __declspec(dllimport)
#  endif
#else
#  define TS_BRIDGE_API
#endif

#ifdef __cplusplus
extern "C" {
#endif

typedef struct TsBridge TsBridge;
typedef uint64_t TsJobId;

/* ABI 版本：Dart 侧启动时校验，不匹配直接报错而不是静默错位。 */
#define TS_BRIDGE_ABI_VERSION 2

/* 探针并发上限（分析始终只允许 1 个；合计最多 5 个 job）。 */
#define TS_BRIDGE_MAX_PROBE_JOBS 4

typedef struct TsBridgeBuffer {
    char *data;      /* DLL 拥有；UTF-8，并以 NUL 结尾 */
    size_t length;   /* 不含结尾 NUL */
} TsBridgeBuffer;

/* ------------------------------------------------------------------ */
/* 生命周期                                                            */
/* ------------------------------------------------------------------ */

/*
 * 创建桥接实例（ABI 2）。
 * config_path_utf8：旧配置文件路径（沿用 config.json 的格式与 api_key_env 约定）。
 * data_dir_utf8   ：settings.json 所在目录；NULL/空 = 配置文件所在目录，
 *                   再退化为当前目录。
 * 成功返回 0；失败返回非 0 并把可读原因写入 out_error（仍需 ts_bridge_free）。
 */
TS_BRIDGE_API int ts_bridge_create_ex(const char *config_path_utf8,
                                      const char *data_dir_utf8,
                                      TsBridge **out_bridge,
                                      TsBridgeBuffer *out_error);

/*
 * 兼容入口（ABI 1 的签名）：等价于 data_dir = 配置文件所在目录
 * （没有配置路径时为当前目录）。
 */
TS_BRIDGE_API int ts_bridge_create(const char *config_path_utf8,
                                   TsBridge **out_bridge,
                                   TsBridgeBuffer *out_error);

/*
 * 释放由 ts_bridge_* 返回的缓冲区。对 NULL / 已释放的缓冲区安全（置零）。
 * 只能释放 DLL 返回的指针，不能释放 Dart 自己分配的内存。
 */
TS_BRIDGE_API void ts_bridge_free(TsBridgeBuffer *buffer);

/*
 * 运行期信息（JSON）：模型名、脱敏端点、是否有可用密钥（布尔）、配置路径、
 * mock 模式、等待提醒阈值等。**绝不包含密钥内容**。
 * 成功返回 0 并写 out_info。
 */
TS_BRIDGE_API int ts_bridge_info(TsBridge *bridge, TsBridgeBuffer *out_info);

/* ------------------------------------------------------------------ */
/* 分析（异步）                                                        */
/* ------------------------------------------------------------------ */

/*
 * 启动一次分析。非阻塞：只做有界校验与拷贝，随后在工作线程中执行。
 *
 * request_json 结构（UTF-8 JSON）：
 * {
 *   "conversationId": "本地会话 ID",
 *   "requestId":      "本地请求 ID",
 *   "baseVersionId":  "基准版本 ID 或 null",
 *   "baseRevision":   0,
 *   "userRequest":    "用户本次要求（可为空）",
 *   "planContext":    "上一版计划的紧凑文本（可为空）",
 *   "sources": [
 *     { "kind": "text", "label": "文段1", "text": "……" },
 *     { "kind": "file", "path": "C:\\…\\a.txt" }
 *   ],
 *   "modelSelection": { "profileId":"…", "profileRevision":3, "modelId":"…",
 *                       "thinking":"enabled", "reasoningEffort":"high" }
 * }
 *
 * modelSelection 缺省 = 使用全局默认连接（settings 的 defaultProfileId）；
 * 显式给出但 revision 不匹配 / profile 已删除 / 不存在时**立即返回错误**
 * （不创建 job，绝不静默改用最新配置）。
 *
 * 快照语义：本调用在锁内校验，并把 profile + 基础配置 + 凭据**深拷贝**到
 * job 自有的 TsConfig；工作线程只读这份快照。因此之后保存、删除或切换模型
 * 都不会影响已经启动的任务，也**不会修改或释放 bridge 的基础配置**。
 *
 * 成功返回 0 并写 out_job；失败返回非 0 并写 out_error。
 * 同一实例同时只允许一个活动分析：已有活动分析时返回非 0（不会排队，
 * 避免用户以为“点了就一定会跑”）。
 */
TS_BRIDGE_API int ts_bridge_analyze_async(TsBridge *bridge,
                                          const char *request_json, size_t length,
                                          TsJobId *out_job,
                                          TsBridgeBuffer *out_error);

/*
 * 拉取并清空该 job 的事件队列。
 *
 * 返回 JSON：
 * { "job": 1, "terminal": true,
 *   "events": [ { "seq":1, "type":"started", "stage":"构建提示词", "detail":"",
 *                 "conversationId":"…","requestId":"…",
 *                 "baseVersionId":null,"baseRevision":0,"atMs":0 } ] }
 *
 * 事件类型：started / progress / succeeded / failed / cancelled。
 * 成功/失败/取消是终态事件，一旦入队就不会被丢弃（只能被 poll 取走）。
 * 未取走前多次 poll 会返回空 events（队列已空），terminal 仍为 true。
 */
TS_BRIDGE_API int ts_bridge_poll(TsBridge *bridge, TsJobId job,
                                 TsBridgeBuffer *out_events_json);

/*
 * 请求取消。协作式：工作线程在 200ms 内响应；**不使用 TerminateThread**。
 * 取消后即使完整结果到达也不会作为成功结果返回。
 */
TS_BRIDGE_API int ts_bridge_cancel(TsBridge *bridge, TsJobId job);

/*
 * 取终态结果。
 *
 * 成功（分析成功且校验通过）：
 * { "ok": true, "job":1, "jobType":"analyze", "plan": { …本地计划 JSON（模型 id）… },
 *   "elapsedMs": 12345, "usage": {…token 用量…}, "diagnostics": {…},
 *   "source": {"profileId":"…","profileRevision":3,"modelId":"…",
 *              "protocol":"deepseek-chat","thinking":"enabled",
 *              "reasoningEffort":"high","endpointHost":"api.deepseek.com"},
 *   "identity": {"conversationId":"…","requestId":"…","baseVersionId":null,
 *                "baseRevision":0} }
 *
 * 失败/取消：
 * { "ok": false, "job":1, "jobType":"analyze",
 *   "errorKind":"cancelled|auth|network|…", "error":"可读原因",
 *   "retryable":false, "httpStatus":0, "elapsedMs": 100 }
 *
 * 说明：
 *   - result["source"] **绝不含密钥**；失败结果可能不带 source，
 *     此时 Dart 记“来源未知”。
 *   - 这里返回的是**模型建议的计划**，还不是“已采纳的版本”。
 *     是否采纳、如何继承完成状态，由 Dart 侧提交门判定（见 README 的四个边界）。
 *   - 在 job 未进入终态前调用返回非 0。
 */
TS_BRIDGE_API int ts_bridge_result(TsBridge *bridge, TsJobId job,
                                   TsBridgeBuffer *out_result_json);

/* 释放终态 job。工作线程仍在运行时返回非 0（不会强行释放）。 */
TS_BRIDGE_API int ts_bridge_release_job(TsBridge *bridge, TsJobId job);

/* ------------------------------------------------------------------ */
/* 设置（settings.json）                                                */
/* ------------------------------------------------------------------ */

/*
 * 读取当前设置。返回：
 * { "ok":true, "abiVersion":2, "schemaVersion":2, "settingsPath":"C:\\…\\settings.json",
 *   "defaultProfileId":"…", "defaultModelId":"…",
 *   "defaultThinking":"enabled", "defaultReasoningEffort":"high",
 *   "profiles":[ {…见规格 §3…} ],
 *   "migrationNote":"…（本次运行从旧 config.json 迁移时的说明，否则为空）" }
 *
 * **绝不含任何密钥**：密钥只在 Windows 凭据管理器里，Dart 侧没有读取接口。
 */
TS_BRIDGE_API int ts_bridge_settings_get(TsBridge *bridge, TsBridgeBuffer *out_json);

/*
 * 保存设置（乐观 revision）。
 *
 * settings_json 结构同 settings_get 的返回，另可带：
 *   "deletedProfileIds": ["id", …]
 *
 * revision 规则：
 *   - 已存在 id：必须显式给出与磁盘一致的 revision，否则整体拒绝；
 *   - 新 id：revision 传 0（或省略），保存后为 1；
 *   - 字段实际变化时保存后 +1；无变化保持不变。
 *
 * 成功：与 settings_get 同形的 JSON，另带 "ok":true。
 * 失败：{ "ok":false, "errorKind":"conflict|invalidRevision|validation|…",
 *         "error":"可读原因", "current":{…当前磁盘状态…} }（conflict 时带 current）。
 * 失败时**不写盘**，内存态保持旧值。
 */
TS_BRIDGE_API int ts_bridge_settings_save(TsBridge *bridge,
                                          const char *settings_json, size_t length,
                                          TsBridgeBuffer *out_json_or_error);

/* ------------------------------------------------------------------ */
/* 凭据（Windows 凭据管理器，profile 粒度）                            */
/* ------------------------------------------------------------------ */

/*
 * 写入/替换某个 profile 的 API Key。
 * 主机取自该 profile 的 chatUrl（凭据与主机绑定，换地址后必须重新输入）。
 * 返回 { "ok":true } 或 { "ok":false, "errorKind":"…", "error":"…" }。
 * **绝不返回密钥**。
 *
 * 部分成功（0.0.4 验收修复）：密钥已写入凭据管理器、但 settings.json
 * 写入失败时返回
 *   { "ok":false, "errorKind":"writeFailed",
 *     "error":"凭据已生效，但 settings.json 写入失败，请重新保存设置…",
 *     "partial":true, "credentialConfigured":true, "credentialHost":"…" }
 * Dart 据此提示“凭据已生效，只需重新保存设置”，不要要求用户重新输入密钥。
 */
TS_BRIDGE_API int ts_bridge_credential_set(TsBridge *bridge, const char *profile_id,
                                           const char *key_utf8, size_t key_len,
                                           TsBridgeBuffer *out_error);

/*
 * 删除某个 profile 的 API Key。返回 { "ok":true } 或错误。
 * 部分成功时与 credential_set 同形，但 credentialConfigured=false、
 * credentialHost 为删除前绑定的主机（不含密钥）。
 */
TS_BRIDGE_API int ts_bridge_credential_delete(TsBridge *bridge, const char *profile_id,
                                              TsBridgeBuffer *out_error);

/* ------------------------------------------------------------------ */
/* 探针（模型发现 / 连通性测试，异步、可取消）                          */
/* ------------------------------------------------------------------ */

/*
 * 启动一个探针 job。非阻塞，立即返回 job id。
 *
 * probe_json：
 * { "kind":"models"|"chat", "profileId":"…", "profileRevision":3,
 *   "modelId":"…", "thinking":"enabled|disabled|unsupported",
 *   "reasoningEffort":"high", "timeoutMs":30000 }
 *
 *   - kind=models：GET 完整 modelsUrl；
 *   - kind=chat  ：POST 完整 chatUrl，固定的小型、无用户隐私的请求
 *                  （不使用任何用户文件）。
 *   - 凭据授权范围按**本次实际请求 URL** 校验：目标 origin 与 chatUrl 的
 *     origin 不同（scheme / host / 有效端口任一不同）时，请求前即失败
 *     （errorKind="config"，不发送请求、不使用环境变量凭据、不回退旧密钥）。
 *     authMode=none 允许跨源，但绝不携带 Authorization。
 *   - 超时：连接 min(connect_timeout_ms, 10000)，总超时默认 30000ms，
 *     可用 timeoutMs 覆盖（限制 [3000, 120000]）。可取消。
 *
 * 探针与分析复用同一套 poll / result / cancel / release_job；
 * 但 result 里带 "jobType":"probe"，Dart **不得**把它提交为计划。
 * 探针可并发，最多 4 个；分析此时仍只允许 1 个。
 */
TS_BRIDGE_API int ts_bridge_probe_async(TsBridge *bridge,
                                        const char *probe_json, size_t length,
                                        TsJobId *out_job,
                                        TsBridgeBuffer *out_error);

/*
 * 启动一次“日历约束识别”（0.07）。
 *
 * 请求体与 ts_bridge_analyze_async 相同（sources 里放已提交的用户补充与已上传
 * 附件的提取文本），但**不产出任务计划**：它只识别时间约束提案。
 *
 * 结果（ts_bridge_result，jobType = "constraints"）：
 * { "ok": true, "job":1, "jobType":"constraints",
 *   "constraints": { "schemaVersion":1,
 *                    "proposals":[ { "kind":"occupancy", "title":"上课",
 *                                    "occupancyKind":"course", "weekdays":[2,4],
 *                                    "date":null, "closed":false,
 *                                    "ranges":[{"start":480,"end":600}],
 *                                    "durationMinutes":null,
 *                                    "evidence":"周二周四 8-10 上课",
 *                                    "source":"文件1:第2段",
 *                                    "needsTime":false, "question":null } ],
 *                    "notes":["…"] },
 *   "thinking": {"enabled":true,"effort":"high","protocol":"deepseek-chat"},
 *   "source": {…同分析…}, "elapsedMs": 1234 }
 *
 * 失败/取消：{ "ok": false, "jobType":"constraints",
 *              "errorKind":"cancelled|auth|protocol|…", "error":"可读原因" }
 *
 * 语义约束：proposals 里的每一条都只是**候选**，界面必须默认不勾选，只有用户
 * 明确确认后才写入正式的 weekly / exceptions / occupancies。
 * 与探针共用 poll / cancel / result / release_job，最多 4 个并发后台请求。
 */
TS_BRIDGE_API int ts_bridge_constraints_async(TsBridge *bridge,
                                              const char *request_json, size_t length,
                                              TsJobId *out_job,
                                              TsBridgeBuffer *out_error);

/* ------------------------------------------------------------------ */
/* 本地校验 / 重排 / 导出（短调用）                                     */
/* ------------------------------------------------------------------ */

/*
 * 校验并重排一份本地计划，返回展示快照。
 *
 * 这是本地编辑（勾选完成、改字段、确认外部条件）之后唯一的“重算”入口：
 * 不调用模型，只做 ts_plan_validate → ts_schedule_build → ts_schedule_status
 * → display。
 *
 * command_json：
 * { "plan": { …本地计划 JSON… } }
 *
 * 返回：
 * { "ok": true, "display": { …展示快照… } }
 * { "ok": false, "error": "可读原因", "errorKind": "validation" }
 *
 * 校验失败时**不返回半成品快照**：调用方应保留原计划不变。
 */
TS_BRIDGE_API int ts_bridge_edit(TsBridge *bridge,
                                 const char *command_json, size_t length,
                                 TsBridgeBuffer *out_snapshot_or_error_json);

/*
 * 导出。format：
 *   "txt"  —— 面向用户的 TXT（含自然语言理由，不含分数/权重/公式）
 *   "diag" —— 结构化诊断 JSON（保留计算数据，明确与日常导出分开）
 *
 * command_json：
 * { "plan": { …本地计划 JSON… }, "format": "txt", "path": "C:\\…\\out.txt" }
 */
TS_BRIDGE_API int ts_bridge_export(TsBridge *bridge,
                                   const char *command_json, size_t length,
                                   TsBridgeBuffer *out_result_json);

/* ------------------------------------------------------------------ */
/* 系统文件选择对话框                                                  */
/* ------------------------------------------------------------------ */

/*
 * 用 Windows 自带的“打开文件”对话框选择文本文件（**支持多选**）。
 *
 * 为什么放在 DLL 而不是 Dart：Dart 没有标准的文件对话框，用 Flutter 自绘的对话框
 * 不符合桌面习惯；直接调用 comdlg32 的 GetOpenFileNameW 才是系统组件，外观、
 * 键盘操作、快速访问/网络位置都由系统提供。
 *
 * 阻塞说明：对话框是**模态**的，调用期间本线程停在系统对话框的消息循环里，
 * 因此不要在等待网络/分析时调用；返回后立刻继续。owner 自动绑定到 Flutter 主窗口
 * （类名 FLUTTER_RUNNER_WIN32_WINDOW），所以对话框不会跑到窗口后面。
 *
 * 成功返回 0，并把选中的 UTF-8 绝对路径写入 out_path（仍需 ts_bridge_free）：
 *   - 单选时是一整条路径；
 *   - 多选时是**以 '\n' 分隔**的多条路径，顺序与对话框一致。
 * 用户取消：返回 0 且 out_path->data == NULL、length == 0。
 * 失败返回非 0，out_error 为可读原因（JSON）。
 *
 * title_utf8 可为 NULL（默认“选择文本文件”）。
 */
TS_BRIDGE_API int ts_bridge_pick_file(TsBridge *bridge,
                                      const char *title_utf8,
                                      TsBridgeBuffer *out_path,
                                      TsBridgeBuffer *out_error);

/*
 * 显示一个 Windows 通知（托盘气泡）。返回 1 表示系统接受；0 表示不可用/被策略阻止。
 * 点击气泡后 ts_bridge_notification_clicked 返回 1 一次，供 UI 定位会话。
 */
TS_BRIDGE_API int ts_bridge_show_notification(TsBridge *bridge,
                                              const char *title_utf8,
                                              const char *body_utf8);
TS_BRIDGE_API int ts_bridge_notification_clicked(TsBridge *bridge);

/* ------------------------------------------------------------------ */
/* 关闭                                                                */
/* ------------------------------------------------------------------ */

/*
 * 开始关闭：标记不可再启动分析并请求取消当前活动分析。非阻塞。
 */
TS_BRIDGE_API int ts_bridge_shutdown_begin(TsBridge *bridge);

/*
 * 关闭是否已完成（所有工作线程已退出）。
 * 返回 1 = 可以 destroy；0 = 仍有线程在工作。**由 Dart 轮询，不阻塞 UI。**
 */
TS_BRIDGE_API int ts_bridge_shutdown_ready(TsBridge *bridge);

/*
 * 销毁。仅当 ts_bridge_shutdown_ready 返回 1 时才真正释放；
 * 否则先在内部等待有限时间（默认 10 秒），仍不退出则**放弃释放**并返回，
 * 以免工作线程访问已释放内存（宁可泄漏，不可崩溃/野指针）。
 */
TS_BRIDGE_API void ts_bridge_destroy(TsBridge *bridge);

#ifdef __cplusplus
}
#endif

#endif /* TS_BRIDGE_H */

