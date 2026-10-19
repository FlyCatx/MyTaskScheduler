/*
 * main.c — 程序入口（Win32 GUI 子系统）：解析命令行（--config / --mock / --input / --export），
 * 载入配置后启动界面。
 *
 * 主要函数：wWinMain。
 */


#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0601
#endif

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <shellapi.h>

#include <stdio.h>
#include <string.h>
#include <wchar.h>

#include "config.h"
#include "gui_win32.h"
#include "model.h"
#include "text.h"
#include "mem.h"

#pragma comment(lib, "shell32.lib")

typedef struct TsCliOptions {
    wchar_t config[1024];
    wchar_t input[1024];
    wchar_t export_path[1024];
    int force_mock;
} TsCliOptions;

static int ParseCommandLine(TsCliOptions *o)
{
    int argc = 0;
    LPWSTR *argv = CommandLineToArgvW(GetCommandLineW(), &argc);
    int i;

    memset(o, 0, sizeof(*o));
    if (argv == NULL) {
        return 1;
    }
    for (i = 1; i < argc; i++) {
        if (wcscmp(argv[i], L"--mock") == 0) {
            o->force_mock = 1;
        } else if (wcscmp(argv[i], L"--config") == 0 && i + 1 < argc) {
            wcsncpy_s(o->config, _countof(o->config), argv[++i], _TRUNCATE);
        } else if (wcscmp(argv[i], L"--input") == 0 && i + 1 < argc) {
            wcsncpy_s(o->input, _countof(o->input), argv[++i], _TRUNCATE);
        } else if (wcscmp(argv[i], L"--export") == 0 && i + 1 < argc) {
            wcsncpy_s(o->export_path, _countof(o->export_path), argv[++i], _TRUNCATE);
        }
    }
    LocalFree(argv);
    return 0;
}

static void ShowFatal(const wchar_t *title, const wchar_t *text)
{
    MessageBoxW(NULL, text, title, MB_ICONERROR | MB_OK);
}

static int BuildDefaultConfigPath(wchar_t *out, size_t cch)
{
    wchar_t exe[MAX_PATH * 2];
    wchar_t *p;

    if (GetModuleFileNameW(NULL, exe, (DWORD)(sizeof(exe) / sizeof(exe[0]))) == 0) {
        return 0;
    }
    p = wcsrchr(exe, L'\\');
    if (p != NULL) {
        *(p + 1) = L'\0';
    } else {
        exe[0] = L'\0';
    }
    if (_snwprintf_s(out, cch, _TRUNCATE, L"%sconfig.json", exe) < 0) {
        return 0;
    }
    return 1;
}

int WINAPI wWinMain(_In_ HINSTANCE hInstance, _In_opt_ HINSTANCE hPrevInstance,
                    _In_ LPWSTR lpCmdLine, _In_ int nCmdShow)
{
    TsConfig cfg;
    TsCliOptions opt;
    wchar_t cfg_path_w[1024];
    char *cfg_path_u8 = NULL;
    char err[1024];
    int rc;

    (void)hPrevInstance;
    (void)lpCmdLine;

    cfg_path_w[0] = L'\0';

    ParseCommandLine(&opt);

    if (opt.config[0] != L'\0') {
        wcsncpy_s(cfg_path_w, _countof(cfg_path_w), opt.config, _TRUNCATE);
    } else if (!BuildDefaultConfigPath(cfg_path_w, _countof(cfg_path_w))) {
        ShowFatal(L"TaskScheduler", L"无法确定配置文件路径。");
        return 1;
    }

    cfg_path_u8 = ts_wide_to_utf8(cfg_path_w, wcslen(cfg_path_w));
    if (cfg_path_u8 == NULL) {
        ShowFatal(L"TaskScheduler", L"配置文件路径转换失败。");
        return 1;
    }

    if (ts_config_load(cfg_path_u8, &cfg, err, sizeof(err)) != 0) {
        wchar_t *m;
        char msg[2048];
        snprintf(msg, sizeof(msg),
                 "配置加载失败：\n%s\n\n配置文件：%s\n\n"
                 "请把 config.example.json 复制为 config.json 并按需修改；\n"
                 "API Key 通过配置里的 api_key_env 指定的环境变量提供，不要写进配置文件。\n"
                 "如需离线演示，可在配置中设置 \"mock_mode\": true，或启动时加 --mock 参数。",
                 err, cfg_path_u8);
        m = ts_utf8_to_wide(msg, strlen(msg), NULL);
        ShowFatal(L"TaskScheduler 配置错误", (m != NULL) ? m : L"配置加载失败。");
        ts_free(m);
        ts_config_free(&cfg);
        ts_free(cfg_path_u8);
        return 1;
    }
    ts_free(cfg_path_u8);

    if (opt.force_mock) {
        cfg.mock_mode = 1;
    }

    if (!ts_model_available() && !cfg.mock_mode) {
        MessageBoxW(NULL,
                    L"本次构建未包含 libcurl，无法发起真实请求。\n"
                    L"请安装 libcurl 后重新构建，或在配置中设置 \"mock_mode\": true。\n"
                    L"程序将以模拟模式继续运行。",
                    L"TaskScheduler", MB_ICONWARNING | MB_OK);
        cfg.mock_mode = 1;
    }

    rc = ts_gui_run_ex(hInstance, &cfg, nCmdShow,
                       (opt.input[0] != L'\0') ? opt.input : NULL,
                       (opt.export_path[0] != L'\0') ? opt.export_path : NULL);

    ts_config_free(&cfg);
    return rc;
}

