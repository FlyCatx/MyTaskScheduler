#ifndef TS_GUI_WIN32_H
#define TS_GUI_WIN32_H

/*
 * gui_win32.h — Win32 Unicode 主界面（窗口、控件、列表、详情、提示框）。
 *
 * 主要函数：ts_gui_run、ts_gui_run_ex（可带非交互的输入/导出路径）。
 */
#include <windows.h>
#include "config.h"

#ifdef __cplusplus
extern "C" {
#endif

/* 创建主窗口并进入消息循环。cfg 必须比窗口存活更久。返回进程退出码。 */
int ts_gui_run(HINSTANCE instance, const TsConfig *cfg, int n_cmd_show);

/*
 * 同上，但可传入“非交互验收”参数（命令行 --input / --export）：
 * auto_input_path 非 NULL 时启动即加载该 UTF-8 文本文件并开始分析；
 * auto_export_path 非 NULL 时分析成功后导出到该路径并自动关闭窗口。
 * 两者都为 NULL 时行为与 ts_gui_run 完全一致。
 */
int ts_gui_run_ex(HINSTANCE instance, const TsConfig *cfg, int n_cmd_show,
                  const wchar_t *auto_input_path, const wchar_t *auto_export_path);

#ifdef __cplusplus
}
#endif

#endif /* TS_GUI_WIN32_H */

