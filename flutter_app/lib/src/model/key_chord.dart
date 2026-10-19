// Pure-Dart keyboard chord value object.
//
// Kept free of Flutter imports so `settings.dart` (and the plain-Dart demo data tool)
// stay runnable on the Dart VM. Flutter-specific activation lives in shortcuts.dart.

class KeyChord {
  const KeyChord(
    this.keyId, {
    this.control = false,
    this.shift = false,
    this.alt = false,
    this.meta = false,
  });

  final int keyId;
  final bool control;
  final bool shift;
  final bool alt;
  final bool meta;

  String get signature => '$keyId:$control:$shift:$alt:$meta';

  String get label {
    final parts = <String>[
      if (control) 'Ctrl',
      if (shift) 'Shift',
      if (alt) 'Alt',
      if (meta) 'Win',
      _keyName(keyId),
    ];
    return parts.join('+');
  }

  Map<String, Object> toJson() => <String, Object>{
        'keyId': keyId,
        'control': control,
        'shift': shift,
        'alt': alt,
        'meta': meta,
      };

  static KeyChord? fromJson(Object? raw) {
    if (raw is! Map<String, dynamic>) return null;
    final keyId = (raw['keyId'] as num?)?.toInt();
    if (keyId == null || keyId <= 0) return null;
    return KeyChord(
      keyId,
      control: raw['control'] == true,
      shift: raw['shift'] == true,
      alt: raw['alt'] == true,
      meta: raw['meta'] == true,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is KeyChord && other.signature == signature;

  @override
  int get hashCode => signature.hashCode;
}

/// Flutter `LogicalKeyboardKey.keyId` values: printable ASCII uses its Unicode code
/// point, so the persisted number is stable and readable. This map only covers the
/// names we show in the default settings; unknown keys fall back to `键<id>`.
String _keyName(int id) {
  if (id >= 97 && id <= 122) {
    return String.fromCharCode(id - 32); // a-z -> A-Z
  }
  if (id >= 65 && id <= 90) return String.fromCharCode(id);
  if (id >= 48 && id <= 57) return String.fromCharCode(id);
  if (id == 13 || id == 0x10000000d) return 'Enter';
  if (id == 27 || id == 0x10000001b) return 'Esc';
  if (id == 8 || id == 0x100000008) return 'Backspace';
  if (id == 32 || id == 0x100000020) return 'Space';
  if (id == 44) return ',';
  if (id == 46) return '.';
  if (id == 0x10000008a) return 'F10';
  return '键$id';
}

