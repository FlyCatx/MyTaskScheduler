// 主题装配：用样式值与按钮映射组装亮/暗两套 ThemeData。
// 这里同时是主题模块的统一出口：样式值、按钮映射、按钮行、状态芯片。
import 'package:flutter/material.dart';

import 'theme/buttons.dart';
import 'theme/values.dart';
import 'widgets/bezier_ui.dart';

export 'theme/buttons.dart';
export 'theme/values.dart';
export 'widgets/button_row.dart';
export 'widgets/status_chip.dart';
/// Builds the Material theme for an explicit brightness.
///
/// The palette is taken from a local variable on purpose: building both the light and
/// the dark ThemeData must not race on the global [TsColors] palette.
ThemeData buildAppTheme([Brightness brightness = Brightness.light]) {
  final p = brightness == Brightness.dark ? TsPalette.dark : TsPalette.light;

  final base = ThemeData(
    useMaterial3: true,
    fontFamily: kUiFontFamily,
    fontFamilyFallback: kUiFontFallback,
    brightness: brightness,
    colorScheme: ColorScheme.fromSeed(
      seedColor: p.accent,
      brightness: brightness,
      surface: p.surface,
    ),
    scaffoldBackgroundColor: p.background,
    visualDensity: VisualDensity.standard,
  );

  ButtonStyle buttonStyle(double radius) => ButtonStyle(
        shape: WidgetStatePropertyAll(
          BezierRoundedRectangleBorder(radius: radius),
        ),
      );

  return base.copyWith(
    // `copyWith` does not carry fontFamily, so the text theme is rebuilt from `base`
    // (which already has it) and every style is made explicit.
    textTheme: base.textTheme.apply(
      fontFamily: kUiFontFamily,
      fontFamilyFallback: kUiFontFallback,
      bodyColor: p.textPrimary,
      displayColor: p.textPrimary,
    ),
    primaryTextTheme: base.primaryTextTheme.apply(
      fontFamily: kUiFontFamily,
      fontFamilyFallback: kUiFontFallback,
    ),
    dividerColor: p.border,
    dividerTheme: DividerThemeData(color: p.border, thickness: 1),
    cardTheme: CardThemeData(
      elevation: 0,
      color: p.surface,
      margin: EdgeInsets.zero,
      shape: BezierRoundedRectangleBorder(
        side: BorderSide(color: p.border),
        radius: 12,
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: p.surface,
      shape: const BezierRoundedRectangleBorder(radius: 14),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: p.surface,
      // Flat, like the hand-drawn menus: hairline separation instead of a drop shadow.
      elevation: 0,
      shadowColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      shape: BezierRoundedRectangleBorder(
        side: BorderSide(color: p.border),
        radius: 12,
      ),
      textStyle: TextStyle(
        fontFamily: kUiFontFamily,
        fontFamilyFallback: kUiFontFallback,
        color: p.textPrimary,
        fontSize: 13,
      ),
    ),
    menuTheme: MenuThemeData(
      style: MenuStyle(
        shape: const WidgetStatePropertyAll(
          BezierRoundedRectangleBorder(radius: 12),
        ),
        backgroundColor: WidgetStatePropertyAll(p.surface),
        elevation: const WidgetStatePropertyAll<double>(0),
        shadowColor: const WidgetStatePropertyAll<Color>(Colors.transparent),
        surfaceTintColor:
            const WidgetStatePropertyAll<Color>(Colors.transparent),
      ),
    ),
    chipTheme: base.chipTheme.copyWith(
      shape: const BezierRoundedRectangleBorder(radius: 8),
      side: BorderSide.none,
    ),
    snackBarTheme: const SnackBarThemeData(
      shape: BezierRoundedRectangleBorder(radius: 10),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      shape: BezierRoundedRectangleBorder(radius: 14),
    ),
    tooltipTheme: TooltipThemeData(
      waitDuration: const Duration(milliseconds: 500),
      textStyle: TextStyle(
        fontFamily: kUiFontFamily,
        fontFamilyFallback: kUiFontFallback,
        color: p.textPrimary,
        fontSize: 11.5,
      ),
      decoration: ShapeDecoration(
        color: p.surface,
        shape: BezierRoundedRectangleBorder(
          side: BorderSide(color: p.border),
          radius: 7,
        ),
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: TsButtons.solid(),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: TsButtons.solid(),
    ),
    // 描边按钮与普通动作按钮同为实心外观；需要“非填充次要按钮”的调用处
    // 显式使用 `TsButtons.outline()`。
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: TsButtons.solid(),
    ),
    // 裸 TextButton 是行内动作（透明），不是蓝色实心块。
    textButtonTheme: TextButtonThemeData(
      style: TsButtons.inline(),
    ),
    // 裸 IconButton 是透明承载体，命中区 32 px。
    iconButtonTheme: IconButtonThemeData(
      style: TsButtons.icon(),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(style: buttonStyle(9)),
    // ---- Switch / Slider / Checkbox / Radio 共用同一个“选中”蓝 ------------------
    // 这些控件显式取 selected* 令牌，不继承 seedColor，因此“开启”状态只有一种颜色。
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.disabled)) return p.onButtonDisabled;
        if (states.contains(WidgetState.selected)) return p.onButton;
        return p.surface;
      }),
      trackColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.disabled)) {
          return states.contains(WidgetState.selected)
              ? p.selectedDisabled
              : p.trackDisabled;
        }
        if (states.contains(WidgetState.selected)) {
          if (states.contains(WidgetState.pressed)) return p.selectedPressed;
          if (states.contains(WidgetState.hovered)) return p.selectedHover;
          return p.selected;
        }
        if (states.contains(WidgetState.hovered)) return p.borderStrong;
        return p.track;
      }),
      trackOutlineColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) return Colors.transparent;
        return p.border;
      }),
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    ),
    sliderTheme: SliderThemeData(
      activeTrackColor: p.selected,
      inactiveTrackColor: p.track,
      disabledActiveTrackColor: p.selectedDisabled,
      disabledInactiveTrackColor: p.trackDisabled,
      thumbColor: p.selected,
      disabledThumbColor: p.onButtonDisabled,
      overlayColor: p.selected.withValues(alpha: 0.12),
      valueIndicatorColor: p.selected,
      activeTickMarkColor: p.onButton,
      inactiveTickMarkColor: p.track,
    ),
    checkboxTheme: CheckboxThemeData(
      shape: const BezierRoundedRectangleBorder(radius: 3),
      fillColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.disabled)) {
          return states.contains(WidgetState.selected)
              ? p.selectedDisabled
              : Colors.transparent;
        }
        if (states.contains(WidgetState.selected)) {
          if (states.contains(WidgetState.pressed)) return p.selectedPressed;
          if (states.contains(WidgetState.hovered)) return p.selectedHover;
          return p.selected;
        }
        return Colors.transparent;
      }),
      checkColor: WidgetStatePropertyAll(p.onButton),
      side: BorderSide(color: p.borderStrong, width: 1.4),
    ),
    radioTheme: RadioThemeData(
      fillColor: WidgetStateProperty.resolveWith((states) =>
          states.contains(WidgetState.selected) ? p.selected : p.borderStrong),
    ),
    inputDecorationTheme: InputDecorationTheme(
      isDense: true,
      filled: true,
      fillColor: p.surface,
      hintStyle: TextStyle(
        fontFamily: kUiFontFamily,
        fontFamilyFallback: kUiFontFallback,
        color: p.textFaint,
      ),
      labelStyle: TextStyle(
        fontFamily: kUiFontFamily,
        fontFamilyFallback: kUiFontFallback,
        color: p.textSecondary,
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      border: BezierInputBorder(
        radius: 12,
        borderSide: BorderSide(color: p.border),
      ),
      enabledBorder: BezierInputBorder(
        radius: 12,
        borderSide: BorderSide(color: p.border),
      ),
      focusedBorder: BezierInputBorder(
        radius: 12,
        borderSide: BorderSide(color: p.accent, width: 1.4),
      ),
      errorBorder: BezierInputBorder(
        radius: 12,
        borderSide: BorderSide(color: p.blocked),
      ),
      focusedErrorBorder: BezierInputBorder(
        radius: 12,
        borderSide: BorderSide(color: p.blocked, width: 1.4),
      ),
      disabledBorder: BezierInputBorder(
        radius: 12,
        borderSide: BorderSide(color: p.border),
      ),
    ),
  );
}

