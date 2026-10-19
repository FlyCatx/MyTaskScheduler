# third_party 依赖说明（真实依赖，不使用手写仿制源码）

本项目的业务代码只使用两个第三方库：

| 库 | 版本 | 必需性 | 用途 |
| --- | --- | --- | --- |
| **cJSON** | v1.7.18 | 必需 | 配置文件解析、模型 JSON 解析、JSON 导出 |
| **libcurl** | 8.23.0 | 真实 HTTP 需要 | Chat Completions 请求（multi 接口，可取消） |

取得方式：运行 `scripts/fetch_deps.ps1`（见下）。脚本会把真实上游文件放到本目录，
并生成 `DEPENDENCIES.txt` 记录每个文件的字节数与 SHA-256。

**不包含任何手写的“声明桩”**：这里放的是上游发布的真实头文件与实现
（`cJSON.c` 是完整实现；libcurl 提供官方头文件、官方 DLL 与由官方 `.def` 生成的
MSVC 导入库）。构建与链接都直接使用它们。

---

## 1. cJSON v1.7.18

- 官方仓库：<https://github.com/DaveGamble/cJSON>
- 本目录需要的文件：
  - `cJSON.c`（完整实现）
  - `cJSON.h`
  - `LICENSE`（MIT）
- 获取：

```powershell
Invoke-WebRequest "https://raw.githubusercontent.com/DaveGamble/cJSON/v1.7.18/cJSON.c" -OutFile cJSON.c
Invoke-WebRequest "https://raw.githubusercontent.com/DaveGamble/cJSON/v1.7.18/cJSON.h" -OutFile cJSON.h
Invoke-WebRequest "https://raw.githubusercontent.com/DaveGamble/cJSON/v1.7.18/LICENSE" -OutFile LICENSE
```

或直接运行 `scripts/fetch_deps.ps1 -Cjson`。

---

## 2. libcurl 8.23.0（Windows x64）

使用 **curl.se 官方 Windows 预编译包**：
`curl-8.23.0_1-win64-mingw.zip`
（<https://curl.se/windows/>，构建哈希见包内 `BUILD-HASHES.txt`）。

本目录结构（由 `scripts/fetch_deps.ps1 -Curl` 生成）：

```
third_party/curl/
├─ include/curl/*.h          官方头文件（curl.h、multi.h、curlver.h …）
├─ bin/libcurl-x64.dll       官方 x64 DLL（SHA-256 见 DEPENDENCIES.txt）
├─ lib/libcurl-x64.def       官方导出清单
├─ lib/libcurl.lib           由 .def 用 MSVC lib.exe 生成的导入库
└─ licenses/*                curl 及其静态依赖的许可证原文
```

**为什么需要自己生成 `libcurl.lib`**：官方包只提供 MinGW 格式的 `.a`，
MSVC 无法直接链接；`.def` 是官方给出的导出清单，用 `lib.exe /def` 生成导入库
是标准做法，不改变任何函数签名或行为。

**DLL 依赖**：`libcurl-x64.dll` 只依赖 Windows 系统 DLL
（`WLDAP32.dll`、`Normaliz.dll`、`bcrypt.dll`、`CRYPT32.dll`、`Secur32.dll`、
`WS2_32.dll`、`IPHLPAPI.DLL`、`KERNEL32.dll`、`USER32.dll` 与 Universal CRT），
已用 `dumpbin /dependents` 核实，因此发布包只需附带这一个非系统 DLL。

**TLS**：该构建使用 LibreSSL，证书校验走 libcurl 默认的系统 CA 存储。
本项目始终开启 `CURLOPT_SSL_VERIFYPEER` / `CURLOPT_SSL_VERIFYHOST`，
**绝不通过关闭校验来绕过连接问题**。

---

## 3. 若确实无法联网

在能联网的机器上运行 `scripts/fetch_deps.ps1`，把整个 `third_party/` 目录
（含 `curl/`）复制到本机即可；`DEPENDENCIES.txt` 里的 SHA-256 可用于核对。

缺少 cJSON 时 CMake 会**直接报错终止**（不静默降级）；缺少 libcurl 时会给出警告，
仍然可以构建，但真实 HTTP 不可用，程序会明确提示并只支持 `mock_mode`。

