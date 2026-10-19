// Unit tests for the application-preferences store.
//
// Covered: atomic write (tmp -> bak -> rename), recovery from the backup copy,
// corrupted/newer files falling back to defaults **without touching the original file**,
// value clamping and "no leftover .tmp".

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:taskscheduler_flutter/src/model/settings.dart';
import 'package:taskscheduler_flutter/src/state/settings_store.dart';

import 'support/test_support.dart';

void main() {
  late Directory dir;
  late SettingsStore store;
  late File prefsFile;

  setUp(() {
    dir = createTempDataDir('prefs');
    store = SettingsStore(dir);
    prefsFile = store.prefsFile;
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  test('missing file returns defaults and creates nothing', () async {
    final result = await store.load();

    expect(result.prefs, const AppPreferences());
    expect(result.warning, isNull);
    expect(result.existed, isFalse);
    expect(prefsFile.existsSync(), isFalse, reason: '读取不得写出任何文件');
  });

  test('save then load round-trips every preference', () async {
    const prefs = AppPreferences(
      themeMode: AppThemeMode.dark,
      fontScale: 1.15,
      defaultChartMode: AppPreferences.kChartModeGantt,
      showCompletedTasks: false,
      sendMode: SendMode.enter,
      notifyOnSuccess: false,
      notifyOnFailure: false,
    );
    await store.save(prefs);

    expect(prefsFile.existsSync(), isTrue);
    final raw = jsonDecode(await prefsFile.readAsString()) as Map<String, dynamic>;
    expect(raw['schemaVersion'], 1);

    final loaded = await store.load();
    expect(loaded.prefs, prefs);
    expect(loaded.warning, isNull);
    expect(loaded.existed, isTrue);
  });

  test('the second save keeps the previous payload in .bak', () async {
    const first = AppPreferences(themeMode: AppThemeMode.light);
    const second = AppPreferences(themeMode: AppThemeMode.dark);
    await store.save(first);
    await store.save(second);

    expect((await store.load()).prefs.themeMode, AppThemeMode.dark);
    final bak = File('${prefsFile.path}.bak');
    expect(bak.existsSync(), isTrue);
    final bakJson = jsonDecode(await bak.readAsString()) as Map<String, dynamic>;
    expect((bakJson['prefs'] as Map<String, dynamic>)['themeMode'], 'light');
    // Atomic write must not leave the staging file behind on success.
    expect(File('${prefsFile.path}.tmp').existsSync(), isFalse);
  });

  test('a corrupted main file is recovered from .bak', () async {
    await store.save(const AppPreferences(themeMode: AppThemeMode.light));
    await store.save(const AppPreferences(themeMode: AppThemeMode.dark));
    await prefsFile.writeAsString('{ this is not json');

    final loaded = await store.load();
    expect(loaded.recoveredFromBackup, isTrue);
    expect(loaded.prefs.themeMode, AppThemeMode.light,
        reason: '.bak 保存的是上一次成功写入的值');
    expect(loaded.warning, isNotNull);
    // The damaged file is preserved for inspection, not silently deleted.
    expect(prefsFile.existsSync(), isTrue);
    expect(await prefsFile.readAsString(), contains('this is not json'));
  });

  test('a corrupted file without backup falls back to defaults and is preserved',
      () async {
    await store.settingsDir.create(recursive: true);
    const damaged = '{"schemaVersion": 1, "prefs": {"themeMode": ';
    await prefsFile.writeAsString(damaged);

    final loaded = await store.load();
    expect(loaded.prefs, const AppPreferences());
    expect(loaded.warning, isNotNull);
    expect(await prefsFile.readAsString(), damaged,
        reason: '损坏的文件必须原样保留，绝不覆盖用户数据');
  });

  test('a newer schema version is reported and left untouched', () async {
    await store.settingsDir.create(recursive: true);
    final payload = jsonEncode(<String, dynamic>{
      'schemaVersion': 99,
      'prefs': const AppPreferences(themeMode: AppThemeMode.dark).toJson(),
    });
    await prefsFile.writeAsString(payload);

    final loaded = await store.load();
    expect(loaded.prefs, const AppPreferences(),
        reason: '未来版本的文件不应被当前版本猜测解析');
    expect(loaded.warning, contains('schemaVersion=99'));
    expect(await prefsFile.readAsString(), payload);
  });

  test('out-of-range values are clamped on read instead of breaking the UI',
      () async {
    await store.settingsDir.create(recursive: true);
    await prefsFile.writeAsString(jsonEncode(<String, dynamic>{
      'schemaVersion': 1,
      'prefs': <String, dynamic>{
        'themeMode': 'neon',
        'fontScale': 99.0,
        'defaultChartMode': 'pie',
        'showCompletedTasks': 'yes',
        'sendMode': 'telepathy',
        'notifyOnSuccess': null,
        'notifyOnFailure': false,
      },
    }));

    final loaded = await store.load();
    expect(loaded.prefs.themeMode, AppThemeMode.system);
    expect(loaded.prefs.fontScale, AppPreferences.maxFontScale);
    expect(loaded.prefs.defaultChartMode, AppPreferences.kChartModeTree);
    expect(loaded.prefs.showCompletedTasks, isTrue);
    expect(loaded.prefs.sendMode, SendMode.ctrlEnter);
    expect(loaded.prefs.notifyOnSuccess, isTrue);
    expect(loaded.prefs.notifyOnFailure, isFalse);
  });

  test('save normalises the value it writes', () async {
    await store.save(const AppPreferences(fontScale: 5.0));
    final raw = jsonDecode(await prefsFile.readAsString()) as Map<String, dynamic>;
    final prefs = raw['prefs'] as Map<String, dynamic>;
    expect(prefs['fontScale'], AppPreferences.maxFontScale);
  });

  test('empty file is treated as "no preferences yet"', () async {
    await store.settingsDir.create(recursive: true);
    await prefsFile.writeAsString('');
    final loaded = await store.load();
    expect(loaded.prefs, const AppPreferences());
    expect(loaded.warning, isNotNull);
  });

  test('the preferences path lives under <root>/settings', () {
    expect(
      store.prefsPath,
      '${dir.path}${Platform.pathSeparator}settings'
      '${Platform.pathSeparator}app_prefs.json',
    );
  });
}

