cmake_minimum_required(VERSION 3.16)
project(TaskScheduler LANGUAGES C)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_C_EXTENSIONS OFF)

if(MSVC)
    add_compile_definitions(_CRT_SECURE_NO_WARNINGS UNICODE _UNICODE)
endif()

# ---------------------------------------------------------------------------
# cJSON（第三方，单文件库）。请先运行 scripts/fetch_deps.ps1 或按
# third_party/README.md 下载 cJSON v1.7.18 到 third_party/。
# ---------------------------------------------------------------------------
set(CJSON_DIR ${CMAKE_CURRENT_SOURCE_DIR}/third_party)
if(NOT EXISTS ${CJSON_DIR}/cJSON.c OR NOT EXISTS ${CJSON_DIR}/cJSON.h)
    message(FATAL_ERROR
        "缺少 cJSON：请运行 scripts/fetch_deps.ps1 或按 third_party/README.md "
        "下载 cJSON v1.7.18（cJSON.c / cJSON.h）到 third_party/")
endif()

add_library(cjson STATIC ${CJSON_DIR}/cJSON.c)
target_include_directories(cjson PUBLIC ${CJSON_DIR})
if(MSVC)
    target_compile_options(cjson PRIVATE /W2)
endif()

# ---------------------------------------------------------------------------
# libcurl。查找顺序：
#   1) third_party/curl（本仓库自带的官方 Windows x64 预编译包，版本与 SHA-256
#      记录在 third_party/DEPENDENCIES.txt；scripts/fetch_deps.ps1 -Curl 可重放获取）
#   2) 系统 / vcpkg（find_package(CURL)）
# 找到则启用真实 HTTP（TS_HAVE_CURL）；都找不到时仍可完整构建，但仅支持 mock 模式。
# ---------------------------------------------------------------------------
set(TS_CURL_VENDOR_DIR ${CMAKE_CURRENT_SOURCE_DIR}/third_party/curl)
set(TS_CURL_VENDORED FALSE)

if(EXISTS ${TS_CURL_VENDOR_DIR}/include/curl/curl.h AND
   EXISTS ${TS_CURL_VENDOR_DIR}/lib/libcurl.lib)
    set(TS_CURL_VENDORED TRUE)
    add_library(ts_curl_vendor SHARED IMPORTED GLOBAL)
    set_target_properties(ts_curl_vendor PROPERTIES
        IMPORTED_IMPLIB ${TS_CURL_VENDOR_DIR}/lib/libcurl.lib
        IMPORTED_LOCATION ${TS_CURL_VENDOR_DIR}/bin/libcurl-x64.dll
        INTERFACE_INCLUDE_DIRECTORIES ${TS_CURL_VENDOR_DIR}/include)
    # 该 DLL 只依赖 Windows 系统 DLL（已用 dumpbin /dependents 核实）。
    set(TS_CURL_TARGET ts_curl_vendor)
    message(STATUS "使用 third_party/curl 自带的 libcurl")
else()
    find_package(CURL QUIET)
    if(CURL_FOUND)
        set(TS_CURL_TARGET CURL::libcurl)
    endif()
endif()

# ---------------------------------------------------------------------------
# 核心库：与 GUI 无关的业务模块。
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# 目录分层（源码依赖方向，见 src/README.md）：
#   app → bridge → domain → state → util，platform 只被 state/domain 调用。
# 头文件名在全仓唯一，因此用同一组 include 根目录向上编译；
# 新增目录时只需在此登记一次。
# ---------------------------------------------------------------------------
set(TS_INCLUDE_RELS
    src
    src/app
    src/util
    src/platform
    src/state
    src/domain
    src/domain/analysis
    src/domain/plan
    src/domain/schedule
    src/domain/present
    src/domain/export
    src/domain/input
    src/bridge
)
set(TS_INCLUDE_DIRS "")
foreach(ts_rel IN LISTS TS_INCLUDE_RELS)
    list(APPEND TS_INCLUDE_DIRS "${CMAKE_CURRENT_SOURCE_DIR}/${ts_rel}")
endforeach()

set(TS_CORE_SOURCES
    # domain：纯数据结构
    src/domain/types.c
    # platform：Windows 底层服务（时钟、编码转换、凭据）
    src/platform/text.c
    src/platform/runtime.c
    src/platform/credential.c
    src/platform/file_io.c
    # state：配置与持久化
    src/state/config.c
    src/state/profile.c        # 供应商 profile 数据结构 / JSON / 校验 / 与 TsConfig 互转
    src/state/profile_store.c  # settings.json 原子保存 / .bak / 乐观 revision / 旧配置迁移
    # domain：输入、计划、调度、分析、展示、导出
    src/domain/input/input.c
    src/domain/analysis/model.c
    src/domain/plan/plan.c          # JSON 解析（用 cJSON）
    src/domain/plan/plan_validate.c # 业务校验（不依赖 cJSON，可离线测试）
    src/domain/plan/plan_local.c    # 本地计划 JSON（稳定 ID / 完成状态）编解码（用 cJSON）
    src/domain/schedule/scheduler.c
    src/domain/analysis/prompt.c
    src/domain/analysis/analyze.c
    src/domain/analysis/constraints.c   # 日历约束识别（专用提示词 + 专用结果校验器）
    src/domain/present/display.c        # 展示快照（用户可见事实 + 自然语言理由；不含分数）
    src/domain/export/export.c          # TXT 导出（不依赖 cJSON，可离线测试）
    src/domain/export/export_json.c     # JSON 导出 + 格式分派（用 cJSON）
    src/domain/export/export_user.c     # 面向用户的 TXT 导出（不含分数/权重，Flutter 界面使用）
    # app：旧 Win32 界面的后台任务与生命周期装配
    # （只被 gui_win32.c 使用；ts_bridge 有自己的作业实现，不共享这条路径）
    src/app/controller.c
)

add_library(ts_core STATIC ${TS_CORE_SOURCES})
target_include_directories(ts_core PUBLIC ${TS_INCLUDE_DIRS})
target_link_libraries(ts_core PUBLIC cjson)
if(WIN32)
    # 凭据管理器（CredWriteW / CredReadW / CredDeleteW）。
    target_link_libraries(ts_core PUBLIC advapi32)
endif()

if(MSVC)
    target_compile_options(ts_core PRIVATE /W4 /utf-8)
endif()

if(TS_CURL_TARGET)
    target_compile_definitions(ts_core PUBLIC TS_HAVE_CURL)
    target_link_libraries(ts_core PUBLIC ${TS_CURL_TARGET})
    if(TS_CURL_VENDORED)
        message(STATUS "已找到 libcurl（third_party/curl，8.23.0）：启用真实 HTTP")
    else()
        message(STATUS "已找到 libcurl ${CURL_VERSION_STRING}：启用真实 HTTP")
    endif()
else()
    message(WARNING "未找到 libcurl：真实 HTTP 不可用，仅支持 mock 模式（见 README.md）")
endif()

# ---------------------------------------------------------------------------
# Win32 GUI 可执行文件（Windows 子系统，Unicode）。
# ---------------------------------------------------------------------------
add_executable(TaskScheduler WIN32
    src/app/main.c
    src/gui_win32.c
)
target_link_libraries(TaskScheduler PRIVATE
    ts_core
    comctl32
    comdlg32
    shell32
    user32
    gdi32
)
if(MSVC)
    target_compile_options(TaskScheduler PRIVATE /W4 /utf-8)
endif()

# ---------------------------------------------------------------------------
# Flutter(Dart FFI) 桥接 DLL。
#
# 为什么单独做成 DLL 而不是把 Flutter 界面直接链进 exe：
#   - Flutter 用动态库加载（DynamicLibrary.open）在**短调用**里取数据，
#     模型调用与文件读取都在 DLL 自己的工作线程里完成，UI 线程不会被阻塞；
#   - 旧 Win32 界面（TaskScheduler.exe）不依赖这个 DLL，可以继续作为回归对照。
#
# 所有导出符号见 src/bridge/ts_bridge.h；返回的缓冲区只能由 ts_bridge_free 释放。
# ---------------------------------------------------------------------------
add_library(ts_bridge SHARED src/bridge/ts_bridge.c src/bridge/ts_file_list.c)
target_compile_definitions(ts_bridge PRIVATE TS_BRIDGE_BUILD)
target_link_libraries(ts_bridge PRIVATE ts_core comdlg32)
if(MSVC)
    target_compile_options(ts_bridge PRIVATE /W4 /utf-8)
endif()
set_target_properties(ts_bridge PROPERTIES OUTPUT_NAME "ts_bridge")

# 多选文件对话框的路径还原（纯逻辑，不需要真的弹窗）。见 src/bridge/ts_file_list.h。
if(EXISTS ${CMAKE_CURRENT_SOURCE_DIR}/tests/test_file_list.c)
    add_executable(ts_test_file_list tests/test_file_list.c src/bridge/ts_file_list.c)
    target_include_directories(ts_test_file_list PRIVATE ${TS_INCLUDE_DIRS})
    if(MSVC)
        target_compile_options(ts_test_file_list PRIVATE /W4 /utf-8)
    endif()
endif()

# ---------------------------------------------------------------------------
# 桥接集成测试（真实 DLL + 真实 ABI，不经过 Flutter）。
#   覆盖：异步调用不阻塞、事件轮询、结果复制、资源释放、取消、迟到结果、
#         退出顺序（shutdown_begin → shutdown_ready → destroy）。
# ---------------------------------------------------------------------------
if(EXISTS ${CMAKE_CURRENT_SOURCE_DIR}/tests/test_bridge.c)
    add_executable(ts_test_bridge tests/test_bridge.c)
    target_include_directories(ts_test_bridge PRIVATE ${TS_INCLUDE_DIRS})
    target_link_libraries(ts_test_bridge PRIVATE ts_bridge ts_core)
    if(MSVC)
        target_compile_options(ts_test_bridge PRIVATE /W4 /utf-8)
    endif()
    add_dependencies(ts_test_bridge ts_bridge)
    add_custom_command(TARGET ts_test_bridge POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E copy_if_different
                $<TARGET_FILE:ts_bridge>
                $<TARGET_FILE_DIR:ts_test_bridge>
        COMMENT "复制 ts_bridge.dll 到测试目录")
endif()

# ---------------------------------------------------------------------------
# 0.0.4 设置功能测试
#   ts_test_settings：profile / 凭据 / settings 原子保存 / revision / 迁移 / 请求体形状
#                     （离线，不联网；只使用 sk-test-… 形式的虚构密钥）
#   ts_test_probe   ：内置 winsock mock HTTP 服务 + 真实桥接 ABI，
#                     验证请求捕获、快照隔离、凭据主机隔离、探针错误分类
# ---------------------------------------------------------------------------
if(EXISTS ${CMAKE_CURRENT_SOURCE_DIR}/tests/test_settings.c)
    add_executable(ts_test_settings tests/test_settings.c)
    target_include_directories(ts_test_settings PRIVATE ${TS_INCLUDE_DIRS})
    target_link_libraries(ts_test_settings PRIVATE ts_core)
    if(MSVC)
        target_compile_options(ts_test_settings PRIVATE /W4 /utf-8)
    endif()
endif()

if(EXISTS ${CMAKE_CURRENT_SOURCE_DIR}/tests/test_probe.c)
    add_executable(ts_test_probe tests/test_probe.c)
    target_include_directories(ts_test_probe PRIVATE ${TS_INCLUDE_DIRS})
    target_link_libraries(ts_test_probe PRIVATE ts_bridge ts_core)
    if(WIN32)
        target_link_libraries(ts_test_probe PRIVATE ws2_32)
    endif()
    if(MSVC)
        target_compile_options(ts_test_probe PRIVATE /W4 /utf-8)
    endif()
    add_dependencies(ts_test_probe ts_bridge)
    add_custom_command(TARGET ts_test_probe POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E copy_if_different
                $<TARGET_FILE:ts_bridge>
                $<TARGET_FILE_DIR:ts_test_probe>
        COMMENT "复制 ts_bridge.dll 到测试目录")
endif()

# ---------------------------------------------------------------------------
# 控制台测试（不依赖真实 API）。
#   ts_test  : 配置/输入/模拟响应
#   ts_test3 : 调度算法
#   ts_test4 : 分析材料组装
# ---------------------------------------------------------------------------
add_executable(ts_test tests/test_phase2.c)
target_link_libraries(ts_test PRIVATE ts_core)
if(MSVC)
    target_compile_options(ts_test PRIVATE /W4 /utf-8)
endif()

add_executable(ts_test3 tests/test_phase3.c)
target_link_libraries(ts_test3 PRIVATE ts_core)
if(MSVC)
    target_compile_options(ts_test3 PRIVATE /W4 /utf-8)
endif()

add_executable(ts_test4 tests/test_phase4.c)
target_link_libraries(ts_test4 PRIVATE ts_core)
if(MSVC)
    target_compile_options(ts_test4 PRIVATE /W4 /utf-8)
endif()

add_executable(ts_test6 tests/test_phase6.c)
target_link_libraries(ts_test6 PRIVATE ts_core)
if(MSVC)
    target_compile_options(ts_test6 PRIVATE /W4 /utf-8)
endif()

add_executable(ts_test_validate tests/test_validate.c)
target_link_libraries(ts_test_validate PRIVATE ts_core)
if(MSVC)
    target_compile_options(ts_test_validate PRIVATE /W4 /utf-8)
endif()

add_executable(ts_test_initonce tests/test_initonce.c)
target_link_libraries(ts_test_initonce PRIVATE ts_core)
if(MSVC)
    target_compile_options(ts_test_initonce PRIVATE /W4 /utf-8)
endif()

# ---------------------------------------------------------------------------
# HTTP 外壳解析 / 错误分类 / 重试策略的离线测试（使用真实 cJSON，不需要网络）。
# 覆盖修复 2（必需字段）、3（取消终态）、8（Retry-After / 可重试状态码）。
# ---------------------------------------------------------------------------
if(EXISTS ${CMAKE_CURRENT_SOURCE_DIR}/tests/test_model.c)
    add_executable(ts_test_model tests/test_model.c)
    target_link_libraries(ts_test_model PRIVATE ts_core)
    if(MSVC)
        target_compile_options(ts_test_model PRIVATE /W4 /utf-8)
    endif()
endif()

# JSON 解析（plan.c）的运行期行为：真实 cJSON 下的字段完整性与协议拒绝路径。
if(EXISTS ${CMAKE_CURRENT_SOURCE_DIR}/tests/test_plan.c)
    add_executable(ts_test_plan tests/test_plan.c)
    target_link_libraries(ts_test_plan PRIVATE ts_core)
    if(MSVC)
        target_compile_options(ts_test_plan PRIVATE /W4 /utf-8)
    endif()
endif()

# 日历约束识别（constraints.c）的结果校验器：离线，不发请求。
if(EXISTS ${CMAKE_CURRENT_SOURCE_DIR}/tests/test_constraints.c)
    add_executable(ts_test_constraints tests/test_constraints.c)
    target_link_libraries(ts_test_constraints PRIVATE ts_core)
    if(MSVC)
        target_compile_options(ts_test_constraints PRIVATE /W4 /utf-8)
    endif()
endif()

# JSON 导出（export_json.c）的运行期输出：真实 cJSON 构造 + 读回校验。
if(EXISTS ${CMAKE_CURRENT_SOURCE_DIR}/tests/test_export_json.c)
    add_executable(ts_test_export_json tests/test_export_json.c)
    target_link_libraries(ts_test_export_json PRIVATE ts_core)
    if(MSVC)
        target_compile_options(ts_test_export_json PRIVATE /W4 /utf-8)
    endif()
endif()

# HTTP 集成测试（阶段 2）：驱动程序，配合 tests/mock_server.py 使用。
if(EXISTS ${CMAKE_CURRENT_SOURCE_DIR}/tests/test_http_integration.c)
    add_executable(ts_test_http tests/test_http_integration.c)
    target_link_libraries(ts_test_http PRIVATE ts_core)
    if(MSVC)
        target_compile_options(ts_test_http PRIVATE /W4 /utf-8)
    endif()
endif()

# 鉴权相关测试。
#   ts_test_auth_offline：配置加载 / 是否要求鉴权 / 密钥格式检查 / 诊断脱敏（无需网络）
#   ts_test_http_auth   ：鉴权行为（真实 libcurl + 本地模拟服务，使用虚构密钥）
# 对应本轮“HTTP 401 Authentication Fails(governor)”排查的验收项 1~5。
if(EXISTS ${CMAKE_CURRENT_SOURCE_DIR}/tests/test_auth_offline.c)
    add_executable(ts_test_auth_offline tests/test_auth_offline.c)
    target_link_libraries(ts_test_auth_offline PRIVATE ts_core)
    if(MSVC)
        target_compile_options(ts_test_auth_offline PRIVATE /W4 /utf-8)
    endif()
endif()

if(EXISTS ${CMAKE_CURRENT_SOURCE_DIR}/tests/test_http_auth.c)
    add_executable(ts_test_http_auth tests/test_http_auth.c)
    target_link_libraries(ts_test_http_auth PRIVATE ts_core)
    if(MSVC)
        target_compile_options(ts_test_http_auth PRIVATE /W4 /utf-8)
    endif()
endif()

# 临时诊断目标（仅用于云端模型/参数验证，验证完即删除）。
if(EXISTS ${CMAKE_CURRENT_SOURCE_DIR}/tests/probe_cloud.c)
    add_executable(probe_cloud tests/probe_cloud.c)
    target_link_libraries(probe_cloud PRIVATE ts_core)
    if(MSVC)
        target_compile_options(probe_cloud PRIVATE /W4 /utf-8)
    endif()
endif()

# TLS / 真实 HTTPS 传输层验证（只在显式运行时联网；不发送用户材料）。
if(EXISTS ${CMAKE_CURRENT_SOURCE_DIR}/tests/test_model_tls.c)
    add_executable(ts_test_model_tls tests/test_model_tls.c)
    target_link_libraries(ts_test_model_tls PRIVATE ts_core)
    if(MSVC)
        target_compile_options(ts_test_model_tls PRIVATE /W4 /utf-8)
    endif()
endif()

# GUI 端到端验收测试：真实窗口 + 消息循环 + mock 响应，跑通
# 解析 → 校验 → 排序 → 展示 → 本地编辑 → 重新排序 → 导出入口 → 关窗。
if(EXISTS ${CMAKE_CURRENT_SOURCE_DIR}/tests/test_gui_accept.c)
    add_executable(ts_test_gui tests/test_gui_accept.c src/gui_win32.c)
    target_link_libraries(ts_test_gui PRIVATE
        ts_core
        comctl32
        comdlg32
        shell32
        user32
        gdi32
    )
    if(MSVC)
        target_compile_options(ts_test_gui PRIVATE /W4 /utf-8)
    endif()
endif()

# ---------------------------------------------------------------------------
# CTest 注册（0.0.4 验收补充）。
#
# 以前这些可执行文件只能由 PowerShell 脚本逐个运行；`ctest` 里找不到任何测试。
# 这里只注册**离线**测试：不依赖网络、Python 模拟服务或真实 API Key。
# 需要外部服务的 ts_test_http / ts_test_http_auth / ts_test_model_tls 仍由
# tests/run_http_tests.ps1 等脚本按需运行，避免 `ctest` 出现“假通过/假失败”。
# ---------------------------------------------------------------------------
enable_testing()

set(TS_OFFLINE_TEST_TARGETS
    ts_test
    ts_test3
    ts_test4
    ts_test6
    ts_test_validate
    ts_test_initonce
    ts_test_model
    ts_test_plan
    ts_test_constraints
    ts_test_export_json
    ts_test_auth_offline
    ts_test_file_list
    ts_test_bridge
    ts_test_settings
    ts_test_probe
    ts_test_gui
)

foreach(ts_test_name IN LISTS TS_OFFLINE_TEST_TARGETS)
    if(TARGET ${ts_test_name})
        add_test(NAME ${ts_test_name} COMMAND ${ts_test_name})
        set_tests_properties(${ts_test_name} PROPERTIES
            WORKING_DIRECTORY "$<TARGET_FILE_DIR:${ts_test_name}>"
            TIMEOUT 180
            LABELS "offline")
    endif()
endforeach()

# ---------------------------------------------------------------------------
# cJSON 单文件库自带所有符号；测试程序与本程序共享同一份实现。
# 所有可执行文件都需要 libcurl 的 DLL 才能启动（真实 HTTP 构建时）。
# ---------------------------------------------------------------------------
if(TS_CURL_VENDORED)
    get_property(TS_PREREQ_TARGETS DIRECTORY PROPERTY BUILDSYSTEM_TARGETS)
    foreach(t IN LISTS TS_PREREQ_TARGETS)
        get_target_property(ttype ${t} TYPE)
        if(ttype STREQUAL "EXECUTABLE")
            add_custom_command(TARGET ${t} POST_BUILD
                COMMAND ${CMAKE_COMMAND} -E copy_if_different
                        ${TS_CURL_VENDOR_DIR}/bin/libcurl-x64.dll
                        $<TARGET_FILE_DIR:${t}>
                COMMENT "复制 libcurl-x64.dll 到 $<TARGET_FILE_DIR:${t}>")
            # TLS 根证书包：放在 exe 同目录，程序启动时自动发现（绝不关闭证书校验）。
            if(EXISTS ${TS_CURL_VENDOR_DIR}/bin/cacert.pem)
                add_custom_command(TARGET ${t} POST_BUILD
                    COMMAND ${CMAKE_COMMAND} -E copy_if_different
                            ${TS_CURL_VENDOR_DIR}/bin/cacert.pem
                            $<TARGET_FILE_DIR:${t}>
                    COMMENT "复制 cacert.pem 到 $<TARGET_FILE_DIR:${t}>")
            endif()
        endif()
    endforeach()
endif()

