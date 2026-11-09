/*
 * ts_activation.h — 可操作 Windows 通知的**纯逻辑**部分（URI / Toast XML / 队列 /
 * 待处理激活文件），不依赖 WinRT、COM，方便离线 C 测试。
 *
 * 设计：
 *   - 通知正文点击与两个按钮全部用 `activationType="protocol"` +
 *     `taskscheduler://<action>?taskId=…&executionId=…&deadline=…` 激活；
 *     action ∈ {open, extend, finish}，身份参数由 Dart 原样提供、原样回传，
 *     绝不使用“最后一次通知时间”推断目标。
 *   - 第二实例（系统通过协议启动）把 URI 通过命名管道交给运行实例；运行实例
 *     把 URI 解析成动作 JSON 放入队列，Dart 用 ts_bridge_take_execution_action
 *     取走。应用未运行时第二实例把 URI 追加到待处理文件，运行实例启动后
 *     prepare 阶段读取。
 *
 * 主要函数：ts_activation_queue_*、ts_activation_parse_uri、
 * ts_activation_build_uri、ts_activation_build_toast_xml、
 * ts_activation_pending_path / append / drain。
 */
#ifndef TS_ACTIVATION_H
#define TS_ACTIVATION_H

#include <stddef.h>
#include <wchar.h>

#ifdef __cplusplus
extern "C" {
#endif

/* 协议名（不带 "://"）。小写。 */
#define TS_ACTIVATION_SCHEME "taskscheduler"

/* 命名管道 / 待处理文件互斥体的名字（runner/main.cpp 里也使用同一字面量）。 */
#define TS_ACTIVATION_PIPE_NAME L"\\\\.\\pipe\\TaskScheduler.Activation"
#define TS_ACTIVATION_PENDING_MUTEX_NAME L"Local\\TaskScheduler.Activation.Pending"
/* 待处理文件名（在 %LOCALAPPDATA%\\TaskScheduler 下）。 */
#define TS_ACTIVATION_PENDING_FILE L"pending_activation.txt"

/* 动作队列上限：点击频率远低于此；满时丢弃最旧的一条。 */
#define TS_ACTIVATION_MAX_QUEUE 16
/* 单条激活 URI 上限（有界拷贝）。 */
#define TS_ACTIVATION_MAX_URI_BYTES 8192

typedef struct TsActivationQueue TsActivationQueue;

/* 创建/销毁动作队列（内部有 CRITICAL_SECTION，可跨线程使用）。 */
TsActivationQueue *ts_activation_queue_create(void);
void ts_activation_queue_destroy(TsActivationQueue *queue);

/*
 * 解析一条 taskscheduler:// URI 并入队。
 * 成功返回 0；URI 非本协议 / action 未知 / 缺 taskId/executionId/deadline
 * 返回非 0（不入队）。
 */
int ts_activation_queue_push_uri(TsActivationQueue *queue, const char *uri_utf8);

/*
 * 直接入队一条已构造好的动作 JSON（接管所有权；失败时不接管）。
 * 用于测试与未来的其它激活来源。
 */
int ts_activation_queue_push_json(TsActivationQueue *queue, char *json_owned);

/*
 * 取走最早的一条动作 JSON（调用方 ts_free）；空队列返回 NULL。
 */
char *ts_activation_queue_take(TsActivationQueue *queue);

/*
 * taskscheduler://open?taskId=…&executionId=…&deadline=…
 * 解析成功返回动作 JSON（malloc，调用方 ts_free）：
 *   {"action":"open|extend|finish","taskId":"…","executionId":"…","deadline":"…"}
 * 非本协议或身份不全返回 NULL。percent-encoding 会被解码；deadline 始终以
 * 字符串原样返回（原生不做时区换算）。
 */
char *ts_activation_parse_uri(const char *uri_utf8);

/*
 * 由动作名 + payload JSON（{"taskId","executionId","deadline"}，deadline 可为
 * 字符串或数字）构造 URI。成功返回 malloc 字符串；参数非法返回 NULL。
 */
char *ts_activation_build_uri(const char *action, const char *payload_json);

/*
 * 构造真实的 Toast XML（UTF-8，malloc）。
 *   launch       = taskscheduler://open?…
 *   按钮 1       = 延长时间 -> taskscheduler://extend?…
 *   按钮 2       = 结束任务 -> taskscheduler://finish?…
 * title/body/按钮文案按 UTF-8 传入并做 XML 转义；payload 缺身份返回 NULL。
 */
char *ts_activation_build_toast_xml(const char *title_utf8, const char *body_utf8,
                                    const char *payload_json,
                                    const char *extend_label_utf8,
                                    const char *finish_label_utf8);

/*
 * XML 属性/文本转义（& < > " '）。返回 malloc 字符串；NULL 输入返回 NULL。
 */
char *ts_activation_escape_xml(const char *s);

/*
 * URI 查询参数 percent-encode（只保留 RFC 3986 unreserved 字符）。
 * 返回 malloc 字符串；NULL 输入返回 NULL。
 */
char *ts_activation_uri_encode(const char *s);

/*
 * 待处理激活文件路径（UTF-8，malloc）：
 *   override_dir 非空 → <override_dir>\pending_activation.txt
 *   否则              → %LOCALAPPDATA%\TaskScheduler\pending_activation.txt
 * 失败返回 NULL。
 */
char *ts_activation_pending_path(const char *override_dir_utf8);

/*
 * 把一条 URI 追加到待处理文件（自动加 '\n'；跨进程用命名互斥体串行化）。
 * 成功返回 0。
 */
int ts_activation_append_pending(const char *path_utf8, const char *uri_utf8);

/*
 * 读取并清空待处理文件，把每一行解析入队。
 * 返回本次成功入队的条数；文件不存在返回 0；读写失败返回 -1。
 */
int ts_activation_drain_pending(TsActivationQueue *queue, const char *path_utf8);

#ifdef __cplusplus
}
#endif

#endif /* TS_ACTIVATION_H */
