/*
 * ts_toast.h — 真实 Windows Toast（WinRT）通道：AUMID 快捷方式、URL 协议注册、
 * 命名管道激活转发、Toast 投递。实现见 ts_toast.cpp（C++/WinRT）。
 *
 * 与 ts_bridge.h 的导出关系：ts_bridge_prepare_notifications /
 * ts_bridge_show_execution_notification 转发到这里的 ts_toast_prepare / ts_toast_show。
 * 纯逻辑（XML/URI/队列）在 ts_activation.c，可离线测试；本文件负责系统集成。
 */
#ifndef TS_TOAST_H
#define TS_TOAST_H

#include "ts_bridge.h"
#include "ts_activation.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct TsToastState TsToastState;

/*
 * 创建/销毁通知状态。queue 由 TsBridge 拥有并保证生命周期长于本状态：
 * 管道线程与待处理文件解析出的动作都放进同一个队列，Dart 通过
 * ts_bridge_take_execution_action 取走。
 */
TsToastState *ts_toast_create(TsActivationQueue *queue);
void ts_toast_destroy(TsToastState *state);

/*
 * 准备通知通道（0=就绪；非 0=未就绪但仍写 out_status_json）。
 *   - aumid_utf8 必填（与 runner SetCurrentProcessExplicitAppUserModelID 一致）；
 *   - exe_path_utf8 为空时用当前进程模块路径；
 *   - 创建开始菜单快捷方式（System.AppUserModel.ID）、注册 HKCU URL 协议
 *     taskscheduler://、启动命名管道线程并取走待处理激活。
 * 不做任何网络访问。
 */
int ts_toast_prepare(TsToastState *state, const char *aumid_utf8,
                     const char *exe_path_utf8, TsBridgeBuffer *out_status_json);

/*
 * 投递一条可操作 Toast。1=系统接受；0=失败（out_result_json 始终带可读原因）。
 * payload_json 必须含 taskId / executionId / deadline（身份原样回传）。
 */
int ts_toast_show(TsToastState *state, const char *title_utf8,
                  const char *body_utf8, const char *payload_json,
                  TsBridgeBuffer *out_result_json);

#ifdef __cplusplus
}
#endif

#endif /* TS_TOAST_H */
