// 启动装配（组合根）：解析数据目录 → 打开 ts_bridge.dll → 载入设置 → 载入会话，
// 再把控制权交给 AppShell。每一步失败都有独立提示，界面不影响其它步骤。
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../ffi/native_gateway.dart';
import '../model/settings.dart';
import '../state/app_controller.dart';
import '../state/execution/execution_deadline_controller.dart';
import '../state/execution/execution_deadline_store.dart';
import '../state/execution/execution_notification.dart';
import '../state/execution/execution_store.dart';
import '../state/execution/timer_controller.dart';
import '../state/external_calendar_service.dart';
import '../state/ocr/ocr_service.dart';
import '../state/schedule/schedule_controller.dart';
import '../state/schedule/schedule_reminders.dart';
import '../state/schedule/schedule_store.dart';
import '../state/external_calendar_store.dart';
import '../state/ics/ics_expander.dart';
import '../state/memory_session_repository.dart';
import '../state/schedule_engine.dart';
import '../state/session_repository.dart';
import '../state/session_store.dart';
import '../state/settings_controller.dart';
import '../state/settings_store.dart';
import '../state/storage_root.dart';
import '../ui/app_shell.dart';
import '../ui/desktop_window.dart';
import '../ui/external_calendar_dialog.dart';
import '../ui/theme.dart';
import '../ui/widgets/app_notice.dart';
import '../ui/window_surface.dart';
import 'startup_screens.dart';

/// 进程入口：初始化绑定、设定初始调色板，然后运行 [TsBootstrap]。
///
/// 窗口端口在 `runApp` 之前 attach，这样首帧就能拿到真实窗口状态（例如"以最大化
/// 启动"），不会先画一帧圆角再跳到直角。
Future<void> runTaskScheduler() async {
  WidgetsFlutterBinding.ensureInitialized();
  TsColors.apply(Brightness.light);
  await _ensureWindowAttached();
  runApp(const TsBootstrap());
}

/// 进程内唯一的窗口端口（`DesktopWindow()` 默认返回共享实例）。
DesktopWindow? _windowPort;

/// 已 attach 的窗口端口；缺少原生实现（测试环境）时也返回一个可用但降级的端口。
DesktopWindow get windowPort => _windowPort ??= DesktopWindow();

Future<void> _ensureWindowAttached() async {
  try {
    await windowPort.attach();
  } catch (_) {
    // 没有原生 runner（测试/异常环境）时保持降级，不影响界面启动。
  }
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
  TimerController? _timer;
  ScheduleController? _schedule;
  ScheduleReminderService? _reminders;
  ExecutionDeadlineController? _executionDeadline;
  VoidCallback? _windowShapeListener;

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

  /// 打开外部日历服务：`<dataRoot>/external_calendar/`。失败时返回 null（UI 显示不可用）。
  Future<ExternalCalendarService?> _openExternalCalendar(Directory root) async {
    try {
      final store = ExternalCalendarStore(root);
      final service = ExternalCalendarService(
        store: store,
        limits: const IcsLimits(),
      );
      await service.load();
      return service;
    } catch (e) {
      // 外部日历是附加数据：读不出来时保持 0.2.1 行为（没有外部来源），并记住原因。
      // 外部日历是附加数据：读不出来时保持 0.2.1 行为（没有外部来源）并在启动提示里说明。
      _appendBootNotice('外部日历不可用（本次运行不加载外部来源）：$e');
      return null;
    }
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

    // 外部日历文件选择器由 bootstrap 注入（UI 只依赖抽象 hook，测试可覆盖）。
    // 必须在 gateway 打开之后注册：对话框不可用时自身会明确报错，不会假装成功。
    // 0.5.0 任务 06：ICS 导入使用日历专用筛选（.ics/.ical + 所有文件），
    // 与通用“添加材料”和 OCR 专用筛选互不影响。
    ExternalCalendarFilePicker.defaultPick = () => gateway.pickTextFiles(
          filter: PickFilter.calendar,
          title: '选择 ICS 日历文件',
        );

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

    // ---- 3b. external calendar (non-fatal) -------------------------------
    /*
     * 外部日历的本地副本与手工时间表分开存储（<dataRoot>/external_calendar/）。
     * 载入失败不阻止启动：服务内部保留错误信息，UI 显示“外部日历不可用”，
     * 0.2.1 的既有行为（没有外部来源）保持完全一致。
     */
    final externalCalendar = await _openExternalCalendar(settingsRoot);

    // ---- 3c. execution timer (0.2.3 R3-E, non-fatal) ---------------------
    /*
     * 执行记录与计划版本分开存储（<dataRoot>/execution/）。载入失败/只读（另一个
     * 实例持有写锁）都不阻止启动：计时功能明确不可用或只读，计划功能完全不变。
     * 崩溃留下的检查点由 TimerController 转成"待校正"区间，不会把退出期间算成工作。
     */
    TimerController? timer;
    try {
      final ExecutionStore executionStore = root.directory != null
          ? ExecutionStore(root.directory!)
          : ExecutionStore.memory();
      final candidate = TimerController(store: executionStore);
      final loadResult = await candidate.load();
      timer = candidate;
      final notices = <String>[
        if (loadResult.notice != null && loadResult.notice!.trim().isNotEmpty)
          loadResult.notice!,
        if (loadResult.recoveryNotice != null &&
            loadResult.recoveryNotice!.trim().isNotEmpty)
          loadResult.recoveryNotice!,
      ];
      if (notices.isNotEmpty) _appendBootNotice(notices.join('\n'));
    } catch (e) {
      _appendBootNotice('执行计时不可用（本次不记录实际耗时）：$e');
    }
    _timer = timer;

    // ---- 3c2. global schedule service (0.4.0, non-fatal) ------------------
    /*
     * 日程是全局真实来源（<dataRoot>/schedules/events.json），与执行记录同样
     * 使用实例锁：第二实例只读并提示。载入失败不阻止启动，日程功能明确只读/
     * 不可用；绝不写空库覆盖损坏文件。
     */
    try {
      final scheduleStore = root.directory != null
          ? ScheduleStore(root.directory!)
          : ScheduleStore.memory();
      final candidate = ScheduleController(store: scheduleStore);
      final opened = await candidate.initialize();
      _schedule = candidate;
      final scheduleNotices = <String>[
        if (opened.notice != null && opened.notice!.trim().isNotEmpty)
          opened.notice!,
      ];
      if (scheduleNotices.isNotEmpty) {
        _appendBootNotice('日程：${scheduleNotices.join('\n')}');
      }
    } catch (e) {
      _appendBootNotice('全局日程不可用（本次不显示/不保存日程）：$e');
    }

    // ---- 3d. local OCR service (0.2.3 R3-O, non-fatal) --------------------
    /*
     * 本地离线 OCR：helper 在 <exe>\data\ocr\ocr_host.exe，语言/可用性在真正使用
     * 时才探测。缺失时服务自身给出明确诊断，不阻止启动、不影响文本 PDF/DOCX。
     */
    final ocr = OcrService(dataRoot: root.directory);

    // ---- 4. controller ----------------------------------------------------
    AppController createController(
      SessionRepository sessionStore, {
      required String storagePath,
      required bool storageIsPersistent,
      String? storageNotice,
    }) =>
        AppController(
          engine: NativeScheduleEngine(gateway),
          store: sessionStore,
          gateway: gateway,
          settings: settings,
          externalCalendar: externalCalendar,
          timer: _timer,
          dataDirectory: root.directory,
          ocr: ocr,
          schedule: _schedule,
          storageNotice: storageNotice,
          storagePath: storagePath,
          storageIsPersistent: storageIsPersistent,
          storageRejected: root.rejected,
          storageSource: root.source,
        );
    final controller = createController(
      store,
      storagePath: root.describe,
      storageIsPersistent: !root.memoryOnly,
      storageNotice: root.notice,
    );
    try {
      await controller.initialize();
    } catch (e) {
      // Initialization failures must not dead-end the app: fall back to an in-memory
      // store so the user can still analyze, and say what happened.
      final fallback = InMemorySessionRepository();
      final retry = createController(
        fallback,
        storagePath: '（内存中）',
        storageIsPersistent: false,
        storageNotice: '读取本地会话失败，本次运行不会保存历史：$e',
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
    // 运行期日程提醒：组合根注入原生通知发送，UI 不直接调 FFI。
    final scheduleController = _schedule;
    if (scheduleController != null) {
      final reminders = ScheduleReminderService(
        controller: scheduleController,
        store: scheduleController.store,
        send: (title, body) async {
          try {
            return gateway.showSystemNotification(title, body);
          } catch (_) {
            return false;
          }
        },
        onNotice: (message) {
          AppNotices.instance.show(
            kind: AppNoticeKind.info,
            message: message,
            dedupeKey: 'schedule-reminder',
          );
        },
      );
      _reminders = reminders;
      unawaited(reminders.start());
    }

    // ---- 4b. execution deadline/reminder controller (0.5.0 任务 13) -------
    /*
     * 截止提醒的生命周期独立于 UI：计时器恢复出来之后创建控制器，由它负责
     * “到点结算 → 待处理 → 两次提醒 → 自动完成”的状态机与持久化。
     * 原生可操作通知不可用时降级为前台等价操作并记录投递结果，不阻止启动。
     */
    final timerForDeadline = _timer;
    if (timerForDeadline != null) {
      try {
        final deadlineStore = ExecutionDeadlineStore(timerForDeadline.store);
        final notifications = NativeExecutionNotificationPort(gateway);
        final deadline = ExecutionDeadlineController(
          timer: timerForDeadline,
          store: deadlineStore,
          clock: timerForDeadline.clock,
          localTime: timerForDeadline.localTime,
          notifications: notifications,
          resolveTarget: controller.executionDeadlineTargetFor,
          taskRefFor: controller.executionTaskRefIn,
          completeTask: controller.completeTaskFromExecution,
          previewExtensionFor: controller.previewExecutionExtension,
          applyExtensionFor: controller.applyExecutionExtension,
          openTask: controller.openExecutionTask,
          // 最小化/失焦时不能假装“前台已显示”；恢复后由 tick 补发。
          isAppVisible: () => !windowPort.shape.value.minimized,
          onNotice: (message, {bool error = false}) {
            AppNotices.instance.show(
              kind: error ? AppNoticeKind.error : AppNoticeKind.info,
              message: message,
              dedupeKey: 'execution-deadline',
              autoDismiss: error ? null : const Duration(seconds: 6),
            );
          },
        );
        controller.attachExecutionDeadline(deadline);
        _executionDeadline = deadline;
        // 最小化/恢复到前台时立即补一次校核（原本错过/未送达的提醒重新投递）。
        void onShape() {
          unawaited(deadline.handleAppVisibilityChanged());
        }

        _windowShapeListener = onShape;
        windowPort.shape.addListener(onShape);
        await deadline.load();
        final status = deadline.notificationStatus;
        if (status != null && status.trim().isNotEmpty) {
          _appendBootNotice(status);
        }
      } catch (e) {
        _appendBootNotice('执行截止提醒不可用（计时与任务完成不受影响）：$e');
      }
    }
    setState(() {
      _gateway = gateway;
      _settings = settings;
      _controller = controller;
      // root.notice（没有可写目录）与计时/外部日历提示都要保留，不能互相覆盖。
      final rootNotice = root.notice;
      if (rootNotice != null && rootNotice.trim().isNotEmpty) {
        _appendBootNotice(rootNotice);
      }
    });
  }

  /// 追加启动提示（多步失败各自可读，不互相覆盖）。
  void _appendBootNotice(String text) {
    final value = text.trim();
    if (value.isEmpty) return;
    final existing = _bootNotice?.trim() ?? '';
    _bootNotice = existing.isEmpty ? value : '$existing\n$value';
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
    final shapeListener = _windowShapeListener;
    if (shapeListener != null) {
      windowPort.shape.removeListener(shapeListener);
      _windowShapeListener = null;
    }
    final deadline = _executionDeadline;
    _executionDeadline = null;
    if (deadline != null) {
      unawaited(deadline.shutdown());
      deadline.dispose();
    }
    _gateway?.close();
    _settings?.dispose();
    _controller?.dispose();
    _timer?.dispose();
    // 提醒服务先停（停止新派发），再释放日程实例锁；失败不阻塞退出。
    final reminders = _reminders;
    _reminders = null;
    reminders?.stop();
    final schedule = _schedule;
    _schedule = null;
    schedule?.close();
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
        builder: _withWindowSurface,
        home: FatalScreen(failure: failure),
      );
    }
    if (settings == null) {
      return MaterialApp(
        title: 'TaskScheduler',
        debugShowCheckedModeBanner: false,
        theme: buildAppTheme(Brightness.light),
        builder: _withWindowSurface,
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
            return _withWindowSurface(
              context,
              MediaQuery(
                data: media.copyWith(
                  textScaler: TextScaler.linear(prefs.fontScale),
                ),
                child: child ?? const SizedBox.shrink(),
              ),
            );
          },
          home: _buildHome(settings),
        );
      },
    );
  }

  /// 整个顶层窗口共用一个外轮廓：MaterialApp.builder 位于 Navigator/Overlay 之外，
  /// 因此标题栏、主区、弹窗遮罩与菜单都被裁到同一条三次贝塞尔路径内，灰色描边也
  /// 画在它们之上（全屏遮罩盖不住）。原生侧用同一路径生成窗口 Region。
  ///
  /// 应用级通知宿主挂在这里——位于 Navigator 之上，弹窗打开
  /// 时通知仍可见可点；宿主只挂一次，AppShell 通过 [AppNoticeMountScope] 识别到
  /// 已挂载后不再自行渲染，避免“同一通知两份”。
  Widget _withWindowSurface(BuildContext context, Widget? child) {
    return WindowSurface(
      shape: windowPort.shape,
      child: AppNoticeHost(
        controller: AppNotices.instance,
        child: AppNoticeMountScope(
          mounted: true,
          child: child ?? const SizedBox.shrink(),
        ),
      ),
    );
  }

  Widget _buildHome(SettingsController settings) {
    final controller = _controller;
    if (controller == null) return const LoadingScreen();
    return AppShell(
      controller: controller,
      settings: settings,
      bootNotice: _bootNotice,
      scheduleController: _schedule,
      reminders: _reminders,
    );
  }
}
