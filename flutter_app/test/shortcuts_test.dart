import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taskscheduler_flutter/src/model/settings.dart';
import 'package:taskscheduler_flutter/src/model/shortcuts.dart';

void main() {
  test('registry exposes the preserved defaults and stable ids', () {
    final send = AppCommands.byId(AppCommands.send)!;
    final newConversation = AppCommands.byId(AppCommands.newConversation)!;
    expect(send.defaultChord?.label, 'Ctrl+Enter');
    expect(newConversation.defaultChord?.label, 'Ctrl+N');
    expect(AppCommands.byId('missing'), isNull);
    expect(AppCommands.all.map((c) => c.id).toSet().length,
        AppCommands.all.length);
  });

  test('absent override uses the default; explicit null unbinds', () {
    final def = AppCommands.byId(AppCommands.newConversation)!;
    final empty = <String, KeyChord?>{};
    expect(resolveBinding(def.id, empty, def.defaultChord), def.defaultChord);
    final unbound = <String, KeyChord?>{def.id: null};
    expect(resolveBinding(def.id, unbound, def.defaultChord), isNull);
    final custom = <String, KeyChord?>{
      def.id: KeyChord(LogicalKeyboardKey.keyJ.keyId, control: true)
    };
    expect(resolveBinding(def.id, custom, def.defaultChord)?.label, 'Ctrl+J');
  });

  test('conflicts are detected in overlapping scopes only', () {
    final bindings = <String, KeyChord?>{};
    final ctrlN =
        KeyChord(LogicalKeyboardKey.keyN.keyId, control: true);
    expect(findShortcutConflict(AppCommands.openSettings, ctrlN, bindings),
        contains('新建会话'));
    final ctrlEnter = KeyChord(LogicalKeyboardKey.enter.keyId, control: true);
    expect(findShortcutConflict(AppCommands.newConversation, ctrlEnter, bindings),
        contains('发送当前输入'),
        reason: '应用级动作与输入框动作保守视为冲突');
    final unboundTarget = <String, KeyChord?>{
      AppCommands.newConversation: null,
    };
    expect(
        findShortcutConflict(AppCommands.openSettings, ctrlN, unboundTarget),
        isNull,
        reason: '显式取消绑定后该组合可被占用');
  });

  test('protected text editing and modifier-only chords are rejected', () {
    expect(
        validateChord(
            KeyChord(LogicalKeyboardKey.keyC.keyId, control: true),
            fixed: false),
        contains('Ctrl+C'));
    expect(
        validateChord(
            KeyChord(LogicalKeyboardKey.controlLeft.keyId), fixed: false),
        contains('非修饰键'));
    expect(validateChord(const KeyChord(0), fixed: false), contains('无法识别'));
    expect(validateChord(const KeyChord(27), fixed: true), contains('固定'));
  });

  test('preferences persist stable key ids and explicit unbinds', () {
    final chord = KeyChord(LogicalKeyboardKey.keyJ.keyId, control: true,
        shift: true);
    final prefs = const AppPreferences().copyWith(shortcutOverrides: {
      AppCommands.newConversation: chord,
      AppCommands.openSettings: null,
    });
    final json = prefs.toJson();
    expect(json['shortcuts'], isA<Map<String, dynamic>>());
    final back = AppPreferences.fromJson(json);
    expect(back.shortcutOverrides[AppCommands.newConversation], chord);
    expect(back.shortcutOverrides.containsKey(AppCommands.openSettings), isTrue);
    expect(back.shortcutOverrides[AppCommands.openSettings], isNull);
    expect(back, prefs);
    expect(jsonEncodeStable(json), contains('keyId'));
  });

  test('corrupt shortcut JSON is dropped without killing preferences', () {
    final prefs = AppPreferences.fromJson(<String, dynamic>{
      'themeMode': 'dark',
      'shortcuts': <String, dynamic>{
        AppCommands.newConversation: <String, dynamic>{'keyId': 0},
        AppCommands.openSettings: 'not-a-chord',
      },
    });
    expect(prefs.themeMode, AppThemeMode.dark);
    expect(prefs.shortcutOverrides, isEmpty);
  });
}

/// Only used to assert the persisted shape contains the stable id field.
String jsonEncodeStable(Object? value) => value.toString();

