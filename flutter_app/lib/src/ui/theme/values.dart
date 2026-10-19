// 主题样式值：颜色、状态色、字体、尺寸、间距的唯一定义处。
// 只放常量、纯函数（[TsSizes.textScaleAwareHeight]）和一个显式的全局调色板开关
// （[TsColors.apply] 会改写静态 `_palette`，因此不是纯函数）；不放绘制、控件或主题装配。
import 'package:flutter/material.dart';

/// One complete colour set. Status colours are static per brightness (see
/// [StatusPalette]) because they must not lose their meaning in dark mode.
class TsPalette {
  final Color background;
  final Color surface;
  final Color surfaceAlt;
  final Color sidebar;
  final Color border;
  final Color borderStrong;
  final Color accent;
  final Color accentSoft;
  final Color textPrimary;
  final Color textSecondary;
  final Color textFaint;

  /// 普通动作按钮令牌：深蓝实心填充 + 白色文字/图标。
  ///
  /// 状态色各有独立令牌：危险用 [blocked]、成功用 [ready]、禁用用 [buttonDisabledFill]；
  /// 其他位置不得硬编码按钮蓝色。
  final Color buttonFill;
  final Color buttonFillHover;
  final Color buttonFillPressed;
  final Color onButton;
  final Color buttonDisabledFill;
  final Color onButtonDisabled;
  final Color buttonFocus;

  /// Status foregrounds/backgrounds.
  final Color ready;
  final Color readySoft;
  final Color waiting;
  final Color waitingSoft;
  final Color pending;
  final Color pendingSoft;
  final Color blocked;
  final Color blockedSoft;
  final Color done;
  final Color doneSoft;

  /// 唯一的“选中/激活”蓝：普通按钮、[BezierSegments]、Switch、Slider 与 Checkbox 共用。
  ///
  /// 这些控件都通过这些令牌取色，并各自提供 hover / pressed / focus / disabled 状态，
  /// 不再各自解析 ColorScheme 主色。
  final Color selected;
  final Color selectedHover;
  final Color selectedPressed;
  final Color selectedDisabled;

  /// The neutral track behind an unselected control (segment track, switch track off,
  /// slider inactive rail).
  final Color track;

  /// Track when the control is disabled.
  final Color trackDisabled;

  const TsPalette({
    required this.background,
    required this.surface,
    required this.surfaceAlt,
    required this.sidebar,
    required this.border,
    required this.borderStrong,
    required this.accent,
    required this.accentSoft,
    required this.textPrimary,
    required this.textSecondary,
    required this.textFaint,
    required this.buttonFill,
    required this.buttonFillHover,
    required this.buttonFillPressed,
    required this.onButton,
    required this.buttonDisabledFill,
    required this.onButtonDisabled,
    required this.buttonFocus,
    required this.ready,
    required this.readySoft,
    required this.waiting,
    required this.waitingSoft,
    required this.pending,
    required this.pendingSoft,
    required this.blocked,
    required this.blockedSoft,
    required this.done,
    required this.doneSoft,
    required this.selected,
    required this.selectedHover,
    required this.selectedPressed,
    required this.selectedDisabled,
    required this.track,
    required this.trackDisabled,
  });

  static const TsPalette light = TsPalette(
    background: Color(0xFFF6F7F9),
    surface: Color(0xFFFFFFFF),
    surfaceAlt: Color(0xFFF3F5F9),
    sidebar: Color(0xFFFAFBFC),
    border: Color(0xFFE2E6EC),
    borderStrong: Color(0xFFC9D4E8),
    accent: Color(0xFF3B6CF6),
    accentSoft: Color(0xFFE8EEFE),
    textPrimary: Color(0xFF1B1F26),
    textSecondary: Color(0xFF5B6472),
    textFaint: Color(0xFF8A93A3),
    buttonFill: Color(0xFF3B6CF6),
    buttonFillHover: Color(0xFF315FDD),
    buttonFillPressed: Color(0xFF2950C4),
    onButton: Color(0xFFFFFFFF),
    buttonDisabledFill: Color(0xFFDDE2EA),
    onButtonDisabled: Color(0xFF8A93A3),
    buttonFocus: Color(0x593B6CF6),
    ready: Color(0xFF2E7D32),
    readySoft: Color(0xFFE7F4E8),
    waiting: Color(0xFF1565C0),
    waitingSoft: Color(0xFFE6EFFB),
    pending: Color(0xFFEF6C00),
    pendingSoft: Color(0xFFFFF3E3),
    blocked: Color(0xFFC62828),
    blockedSoft: Color(0xFFFDEBEB),
    done: Color(0xFF6B7280),
    doneSoft: Color(0xFFEFF1F4),
    selected: Color(0xFF3B6CF6),
    selectedHover: Color(0xFF315FDD),
    selectedPressed: Color(0xFF2950C4),
    selectedDisabled: Color(0xFFDDE2EA),
    track: Color(0xFFE7EAF0),
    trackDisabled: Color(0xFFF1F3F7),
  );

  static const TsPalette dark = TsPalette(
    background: Color(0xFF15171C),
    surface: Color(0xFF1D2026),
    surfaceAlt: Color(0xFF242830),
    sidebar: Color(0xFF181B21),
    border: Color(0xFF2C313A),
    borderStrong: Color(0xFF3A4150),
    accent: Color(0xFF7A9BFF),
    accentSoft: Color(0xFF25304A),
    textPrimary: Color(0xFFE7EAF0),
    textSecondary: Color(0xFFAEB6C4),
    textFaint: Color(0xFF818A9A),
    // Dark keeps the *same* deep blue rather than the light-accent 0xFF7A9BFF:
    // white text on 0xFF7A9BFF is only ~2.3:1, while 0xFF3B6CF6 with white is ~4.5:1.
    // `accent` above stays the lighter blue for text/links/focus outlines.
    buttonFill: Color(0xFF3B6CF6),
    buttonFillHover: Color(0xFF4C7BFF),
    buttonFillPressed: Color(0xFF2E57D6),
    onButton: Color(0xFFFFFFFF),
    buttonDisabledFill: Color(0xFF2E343E),
    onButtonDisabled: Color(0xFF737C8B),
    buttonFocus: Color(0x997A9BFF),
    ready: Color(0xFF6FC274),
    readySoft: Color(0xFF1D2E20),
    waiting: Color(0xFF74B5F5),
    waitingSoft: Color(0xFF19273A),
    pending: Color(0xFFFFB264),
    pendingSoft: Color(0xFF33261A),
    blocked: Color(0xFFF08080),
    blockedSoft: Color(0xFF351F22),
    done: Color(0xFF9AA3B2),
    doneSoft: Color(0xFF24272E),
    // Dark keeps the same "selected" blue as the buttons so a switch and a filled
    // button read as the same accent.
    selected: Color(0xFF3B6CF6),
    selectedHover: Color(0xFF4C7BFF),
    selectedPressed: Color(0xFF2E57D6),
    selectedDisabled: Color(0xFF2E343E),
    track: Color(0xFF303033),
    trackDisabled: Color(0xFF262A31),
  );
}

/// 全应用读取颜色的门面：读的是当前生效的静态调色板（不是常量，也不随 BuildContext 变化）。
class TsColors {
  TsColors._();

  static TsPalette _palette = TsPalette.light;

  static TsPalette get palette => _palette;

  /// 切换全局调色板：改写静态 [_palette]（有副作用，不是纯函数）。
  /// 调用时机：MaterialApp.builder 在子控件构建前，以及直接 pump 单个页面的测试。
  static void apply(Brightness brightness) {
    _palette =
        brightness == Brightness.dark ? TsPalette.dark : TsPalette.light;
  }

  static bool get isDark => identical(_palette, TsPalette.dark);

  static Color get background => _palette.background;
  static Color get surface => _palette.surface;
  static Color get surfaceAlt => _palette.surfaceAlt;
  static Color get sidebar => _palette.sidebar;
  static Color get border => _palette.border;
  static Color get borderStrong => _palette.borderStrong;
  static Color get accent => _palette.accent;
  static Color get accentSoft => _palette.accentSoft;
  static Color get textPrimary => _palette.textPrimary;
  static Color get textSecondary => _palette.textSecondary;
  static Color get textFaint => _palette.textFaint;

  static Color get buttonFill => _palette.buttonFill;
  static Color get buttonFillHover => _palette.buttonFillHover;
  static Color get buttonFillPressed => _palette.buttonFillPressed;
  static Color get onButton => _palette.onButton;
  static Color get buttonDisabledFill => _palette.buttonDisabledFill;
  static Color get onButtonDisabled => _palette.onButtonDisabled;
  static Color get buttonFocus => _palette.buttonFocus;

  static Color get ready => _palette.ready;
  static Color get readySoft => _palette.readySoft;
  static Color get waiting => _palette.waiting;
  static Color get waitingSoft => _palette.waitingSoft;
  static Color get pending => _palette.pending;
  static Color get pendingSoft => _palette.pendingSoft;
  static Color get blocked => _palette.blocked;
  static Color get blockedSoft => _palette.blockedSoft;
  static Color get done => _palette.done;
  static Color get doneSoft => _palette.doneSoft;

  static Color get selected => _palette.selected;
  static Color get selectedHover => _palette.selectedHover;
  static Color get selectedPressed => _palette.selectedPressed;
  static Color get selectedDisabled => _palette.selectedDisabled;
  static Color get track => _palette.track;
  static Color get trackDisabled => _palette.trackDisabled;
}

/// Height of the task-list / chart pane header rows, shared so both panes' bottom rules
/// sit on exactly one line.
const double kPaneHeaderHeight = 44;

/// 顶部标题栏高度：左侧栏、摘要栏与输入区共用，保证两条标题行基线对齐。
const double kTopBarHeight = 56;

/// Colour + soft background for a status key coming from the C display snapshot.
class StatusPalette {
  final Color foreground;
  final Color background;
  const StatusPalette(this.foreground, this.background);

  static StatusPalette of(String status) => switch (status) {
        'ready' => StatusPalette(TsColors.ready, TsColors.readySoft),
        'waiting' => StatusPalette(TsColors.waiting, TsColors.waitingSoft),
        'pending' => StatusPalette(TsColors.pending, TsColors.pendingSoft),
        'blocked' => StatusPalette(TsColors.blocked, TsColors.blockedSoft),
        'done' => StatusPalette(TsColors.done, TsColors.doneSoft),
        _ => StatusPalette(TsColors.textSecondary, TsColors.doneSoft),
      };
}

/// Global UI font: Microsoft YaHei (微软雅黑) with sensible fallbacks.
///
/// Chosen explicitly so the whole app — not just the parts that happen to inherit a
/// system default — renders with the same Chinese face. Icons keep their own font.
const String kUiFontFamily = 'Microsoft YaHei';
const List<String> kUiFontFallback = <String>[
  'Microsoft YaHei UI',
  'Segoe UI',
  'SimSun',
];

/// 交互控件唯一的尺寸规格。
///
/// 所有按钮高度、内边距、字号与间距都取自这里，同一行的兄弟控件因此高度一致；
/// 只有文本缩放确实需要时才用 `textScaleAwareHeight` 放大，且同组仍保持一致。
class TsSizes {
  TsSizes._();

  /// Ordinary solid action button (保存 / 新增 / 自动安排 …).
  static const double buttonHeight = 36;
  static const double buttonRadius = 9;
  static const double buttonPaddingH = 14;
  static const double buttonFontSize = 12.5;

  /// Compact solid button inside a dialog row (日期例外 关闭/开放 …).
  static const double compactButtonHeight = 32;

  /// Inline text action ("展开完整端点", "重新识别") — never a blue block.
  static const double inlineHeight = 28;

  /// Icon-only affordance hit box. Bigger than the glyph on purpose.
  static const double iconButtonSize = 32;
  static const double compactIconSize = 28;

  /// Gap between siblings in one button group, and between groups.
  static const double gapInGroup = 8;
  static const double gapBetweenGroups = 14;

  /// Never let a fixed height clip an enlarged label.
  static double textScaleAwareHeight(BuildContext context, double base) {
    final scale = MediaQuery.textScalerOf(context).scale(base);
    return base * scale > base * 1.35 ? base * 1.35 : base;
  }
}

