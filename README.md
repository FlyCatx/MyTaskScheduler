# TaskScheduler

TaskScheduler is a Windows desktop application for turning notes and documents into an ordered task plan. It uses an OpenAI-compatible model to analyze supplied text, then validates dependencies and presents the plan locally. It does not execute tasks or run model-generated commands.

## Features

- C core for task validation, dependency analysis, scheduling, and export
- Win32 and Flutter desktop interfaces
- Configurable OpenAI-compatible model endpoint
- Local settings and credential handling
- TXT, JSON, PDF, DOCX, and PPTX text input support

## Repository layout

- `src/` — C application and shared business logic
- `flutter_app/` — Flutter Windows interface
- `tests/` — automated unit and local mock-service tests
- `scripts/` — dependency, build, and packaging scripts
- `third_party/` — vendored cJSON and libcurl files with licenses
- `docs/` — design and requirements documents

Local build outputs, user settings, logs, one-off AI acceptance inputs, UI captures, and temporary probe files are excluded from this repository.

## Build on Windows

Install Visual Studio with C/C++ tools, CMake, and the Flutter SDK.

Build the C application and its offline tests:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/build.ps1 -Test
```

Build the Flutter Windows application:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/build_flutter_app.ps1
```

## Configuration

Copy `config.example.json` to `config.json`, set the endpoint and model, and provide credentials through the environment variable configured by `api_key_env`. Do not commit local `config.json` or credential values.
