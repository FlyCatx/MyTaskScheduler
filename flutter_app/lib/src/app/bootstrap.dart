// 启动装配（组合根）：解析数据目录 → 打开 ts_bridge.dll → 载入设置 → 载入会话，
// 再把控制权交给 AppShell。每一步失败都有独立提示，界面不影响其它步骤。
import 'dart:io';

import 'package:flutter/material.dart';

import '../ffi/native_gateway.dart';
import '../model/settings.dart';
import '../state/app_controller.dart';
import '../state/memory_session_repository.dart';
import '../state/schedule_engine.dart';
import '../state/session_repository.dart';
import '../state/session_store.dart';
import '../state/settings_controller.dart';
import '../state/settings_store.dart';
import '../state/storage_root.dart';
import '../ui/app_shell.dart';
import '../ui/theme.dart';
import 'startup_screens.dart';

/// 进程入口：初始化绑定、设定初始调色板，然后运行 [TsBootstrap]。
Future<void> runTaskScheduler() async {
  WidgetsFlutterBinding.ensureInitialized();
  TsColors.apply(Brightness.light);
  runApp(const TsBootstrap());
}
class TsBootstrap extends StatefulWidget {
  const TsBootstrap({super.key});

  @override
  State<TsBootstrap> createState() => _TsBootstrapState();
}

class _TsBootstrapState extends State<TsBootstrap> {
  AppController? _controller;
  SettingsController? _settings;
  NativeGateway? _gateway;
  StartupFailure? _failure;
  String? _bootNotice;
  VoidCallback? _paletteListener;

  /// Applies the global palette for the committed preferences. Registered before any
  /// other settings listener so widgets rebuilding from this notification already see
  /// the new colours (an open settings dialog must switch theme immediately too).
  void _syncPalette(SettingsController settings) {
    final brightness = switch (settings.prefs.themeMode) {
      AppThemeMode.light => Brightness.light,
      AppThemeMode.dark => Brightness.dark,
      AppThemeMode.system =>
        WidgetsBinding.instance.platformDispatcher.platformBrightness,
    };
    TsColors.apply(brightness);
  }

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    // ---- 1. storage (non-fatal) ------------------------------------------
    StorageRoot root;
    try {
      root = await resolveStorageRoot();
    } catch (e) {
      root = StorageRoot(
        directory: null,
        source: 'memory',
        path: '',
        rejected: <RejectedRoot>[RejectedRoot('resolve', '', e.toString())],
        memoryOnly: true,
      );
    }

    SessionRepository store;
    if (root.directory != null) {
      store = SessionStore(root.directory!);
    } else {
      store = InMemorySessionRepository();
    }

    // ---- 2. native bridge (fatal when missing) ----------------------------
    final configPath = _resolveConfigPath();
    NativeGateway gateway;
    try {
      gateway = NativeGateway.open(
        configPath: configPath ?? '',
        dataDir: root.directory?.path ?? '',
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _failure = StartupFailure(
          title: '无法加载分析内核',
          summary: '界面需要与 C 内核的桥接库 ts_bridge.dll 一起运行。'
              '请确认它与本程序在同一目录（另需 libcurl-x64.dll 与 cacert.pem）。',
          detail: '$e',
          hints: const [
            '请把压缩包**整体解压**后再运行，不要只拷贝 taskscheduler.exe（data\\ 目录与 DLL 缺一不可）。',
            '若已放在同一目录，请检查是否被杀毒软件拦截了 DLL 加载。',
          ],
        );
      });
      return;
    }

    // ---- 3. settings (non-fatal) -----------------------------------------
    /*
     * Preferences live under the resolved data root. In memory-only mode there is no
     * writable root, so a throw-away folder is used: the app still works, but the
     * storage page says "关闭后丢失" and no persistence is claimed.
     */
    final settingsRoot = root.directory ??
        Directory(
            '${Directory.systemTemp.path}${Platform.pathSeparator}TaskSchedulerSession');
    final settings = SettingsController(
      store: SettingsStore(settingsRoot),
      bridge: gateway,
    );
    try {
      await settings.load();
    } catch (e) {
      // SettingsController.load() is defensive; this is only a last-resort guard.
      settings.reportLoadFailure('读取设置失败：$e');
    }
    /*
     * Apply the palette *before* the other listeners (AppShell, the open settings
     * dialog) rebuild. Otherwise those widgets would rebuild once with the previous
     * palette and only the next frame/restart would show the new theme. This listener
     * is registered first on purpose.
     */
    _paletteListener = () => _syncPalette(settings);
    settings.addListener(_paletteListener!);
    _syncPalette(settings);

    // ---- 4. controller ----------------------------------------------------
    final controller = AppController(
      engine: NativeScheduleEngine(gateway),
      store: store,
      gateway: gateway,
      settings: settings,
      storageNotice: root.notice,
      storagePath: root.describe,
      storageIsPersistent: !root.memoryOnly,
      storageRejected: root.rejected,
      storageSource: root.source,
    );
    try {
      await controller.initialize();
    } catch (e) {
      // Initialization failures must not dead-end the app: fall back to an in-memory
      // store so the user can still analyze, and say what happened.
      final fallback = InMemorySessionRepository();
      final retry = AppController(
        engine: NativeScheduleEngine(gateway),
        store: fallback,
        gateway: gateway,
        settings: settings,
        storageNotice: '读取本地会话失败，本次运行不会保存历史：$e',
        storagePath: '（内存中）',
        storageIsPersistent: false,
        storageRejected: root.rejected,
        storageSource: root.source,
      );
      await retry.initialize();
      if (!mounted) {
        await gateway.close();
        return;
      }
      setState(() {
        _gateway = gateway;
        _settings = settings;
        _controller = retry;
        _bootNotice = '读取本地会话失败，已改用内存存储：$e';
      });
      return;
    }

    if (!mounted) {
      await gateway.close();
      settings.dispose();
      controller.dispose();
      return;
    }
    setState(() {
      _gateway = gateway;
      _settings = settings;
      _controller = controller;
      _bootNotice = root.notice;
    });
  }

  /// Config resolution order (first hit wins). The API key itself is never read by
  /// Dart: the C bridge resolves it from config/env exactly as before.
  String? _resolveConfigPath() {
    final candidates = <String>[];
    final env = Platform.environment['TASKSCHEDULER_CONFIG'];
    if (env != null && env.trim().isNotEmpty) candidates.add(env.trim());
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    candidates.add('$exeDir${Platform.pathSeparator}config.json');
    candidates.add('${Directory.current.path}${Platform.pathSeparator}config.json');
    for (final c in candidates) {
      if (File(c).existsSync()) return c;
    }
    return null;
  }

  @override
  void dispose() {
    final listener = _paletteListener;
    if (listener != null) _settings?.removeListener(listener);
    _gateway?.close();
    _settings?.dispose();
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settings = _settings;
    final failure = _failure;
    if (failure != null) {
      return MaterialApp(
        title: 'TaskScheduler',
        debugShowCheckedModeBanner: false,
        theme: buildAppTheme(Brightness.light),
        darkTheme: buildAppTheme(Brightness.dark),
        home: FatalScreen(failure: failure),
      );
    }
    if (settings == null) {
      return MaterialApp(
        title: 'TaskScheduler',
        debugShowCheckedModeBanner: false,
        theme: buildAppTheme(Brightness.light),
        home: const LoadingScreen(),
      );
    }
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) {
        final prefs = settings.prefs;
        return MaterialApp(
          title: 'TaskScheduler',
          debugShowCheckedModeBanner: false,
          theme: buildAppTheme(Brightness.light),
          darkTheme: buildAppTheme(Brightness.dark),
          themeMode: switch (prefs.themeMode) {
            AppThemeMode.light => ThemeMode.light,
            AppThemeMode.dark => ThemeMode.dark,
            AppThemeMode.system => ThemeMode.system,
          },
          builder: (context, child) {
            // Apply the palette for the brightness the preference resolved to. Using
            // Theme.of(context) alone is not enough while MaterialApp animates the
            // theme: it can still report the old brightness for a frame, which would
            // overwrite the palette the settings listener just applied.
            TsColors.apply(switch (prefs.themeMode) {
              AppThemeMode.light => Brightness.light,
              AppThemeMode.dark => Brightness.dark,
              AppThemeMode.system => Theme.of(context).brightness,
            });
            final media = MediaQuery.of(context);
            return MediaQuery(
              data: media.copyWith(
                textScaler: TextScaler.linear(prefs.fontScale),
              ),
              child: child ?? const SizedBox.shrink(),
            );
          },
          home: _buildHome(settings),
        );
      },
    );
  }

  Widget _buildHome(SettingsController settings) {
    final controller = _controller;
    if (controller == null) return const LoadingScreen();
    return AppShell(
      controller: controller,
      settings: settings,
      bootNotice: _bootNotice,
    );
  }
}

