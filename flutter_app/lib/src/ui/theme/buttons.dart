// 按钮样式映射：把 values.dart 中的颜色/尺寸映射成 Material 的 ButtonStyle。
// solid（实心主按钮）、outline、inline、ghost 四类外观只在这里定义。
import 'package:flutter/material.dart';

import '../widgets/bezier_ui.dart';
import 'values.dart';

/// 共享按钮样式：在调用处显式选择一类外观。
///
/// Two families, chosen explicitly at every call site:
///
///   * [solid] — the deep blue filled action button (primary and secondary alike),
///   * [outline] / [inline] / [ghost] — transparent affordances: inline text actions,
///     low-emphasis icon buttons and the translucent close button.
///
/// The global `TextButtonTheme` / `IconButtonTheme` now map to [inline] / [ghost]: a
/// bare `IconButton` (an ellipsis, a delete, a header export icon) must never be a blue
/// rectangle. Icon-looking controls that ARE actions opt into [solid] explicitly.
class TsButtons {
  TsButtons._();

  static WidgetStateProperty<Color?> _fill(
    Color base, {
    required Color hover,
    required Color pressed,
    required Color disabled,
  }) =>
      WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.disabled)) return disabled;
        if (states.contains(WidgetState.pressed)) return pressed;
        if (states.contains(WidgetState.hovered) ||
            states.contains(WidgetState.focused)) {
          return hover;
        }
        return base;
      });

  /// The ordinary solid button: deep blue fill, white label/icon, 36 px tall.
  static ButtonStyle solid({
    double radius = TsSizes.buttonRadius,
    Color? fill,
    Color? foreground,
    EdgeInsetsGeometry? padding,
    Size? minimumSize,
    double? fontSize,
    bool circular = false,
  }) {
    final base = fill ?? TsColors.buttonFill;
    final hover = fill == null
        ? TsColors.buttonFillHover
        : (Color.lerp(base, const Color(0xFF000000), 0.10) ?? base);
    final pressed = fill == null
        ? TsColors.buttonFillPressed
        : (Color.lerp(base, const Color(0xFF000000), 0.20) ?? base);
    final onColor = foreground ?? TsColors.onButton;
    return ButtonStyle(
      backgroundColor: _fill(
        base,
        hover: hover,
        pressed: pressed,
        disabled: TsColors.buttonDisabledFill,
      ),
      foregroundColor: WidgetStateProperty.resolveWith((states) =>
          states.contains(WidgetState.disabled)
              ? TsColors.onButtonDisabled
              : onColor),
      iconColor: WidgetStateProperty.resolveWith((states) =>
          states.contains(WidgetState.disabled)
              ? TsColors.onButtonDisabled
              : onColor),
      // The fill already changes on hover/press, so no double overlay tint. Focus is
      // still visible through the ring drawn by [overlayColor] below.
      overlayColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.focused)) return TsColors.buttonFocus;
        return const Color(0x00000000);
      }),
      elevation: const WidgetStatePropertyAll<double>(0),
      shadowColor: const WidgetStatePropertyAll<Color>(Color(0x00000000)),
      side: const WidgetStatePropertyAll<BorderSide>(BorderSide.none),
      shape: WidgetStatePropertyAll<OutlinedBorder>(
        circular
            ? const CircleBorder()
            : BezierRoundedRectangleBorder(radius: radius),
      ),
      padding: padding == null ? null : WidgetStatePropertyAll(padding),
      minimumSize: WidgetStatePropertyAll(
          minimumSize ?? const Size(0, TsSizes.buttonHeight)),
      textStyle: WidgetStatePropertyAll(
          TextStyle(fontSize: fontSize ?? TsSizes.buttonFontSize)),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
  }

  /// Secondary emphasis with the same geometry as [solid]: transparent fill, hairline
  /// border, primary text. Used for 取消 next to 保存.
  static ButtonStyle outline({
    double radius = TsSizes.buttonRadius,
    double height = TsSizes.buttonHeight,
    double? fontSize,
    Color? foreground,
  }) =>
      ButtonStyle(
        backgroundColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.disabled)) {
            return const Color(0x00000000);
          }
          if (states.contains(WidgetState.pressed)) {
            return TsColors.textPrimary.withValues(alpha: 0.10);
          }
          if (states.contains(WidgetState.hovered) ||
              states.contains(WidgetState.focused)) {
            return TsColors.textPrimary.withValues(alpha: 0.06);
          }
          return const Color(0x00000000);
        }),
        foregroundColor: WidgetStateProperty.resolveWith((states) =>
            states.contains(WidgetState.disabled)
                ? TsColors.onButtonDisabled
                : (foreground ?? TsColors.textPrimary)),
        iconColor: WidgetStateProperty.resolveWith((states) =>
            states.contains(WidgetState.disabled)
                ? TsColors.onButtonDisabled
                : (foreground ?? TsColors.textPrimary)),
        elevation: const WidgetStatePropertyAll<double>(0),
        side: WidgetStatePropertyAll(
            BorderSide(color: TsColors.border, width: 1)),
        shape: WidgetStatePropertyAll<OutlinedBorder>(
            BezierRoundedRectangleBorder(radius: radius)),
        padding: const WidgetStatePropertyAll(
            EdgeInsets.symmetric(horizontal: TsSizes.buttonPaddingH)),
        minimumSize: WidgetStatePropertyAll(Size(0, height)),
        textStyle: WidgetStatePropertyAll(
            TextStyle(fontSize: fontSize ?? TsSizes.buttonFontSize)),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      );

  /// Dangerous action: red fill, white text, never blue.
  static ButtonStyle danger({double radius = TsSizes.buttonRadius}) => solid(
        radius: radius,
        fill: TsColors.blocked,
        minimumSize: const Size(0, TsSizes.compactButtonHeight),
      );

  /// Confirmed / successful action: green fill, white text.
  static ButtonStyle success({double radius = TsSizes.buttonRadius}) =>
      solid(radius: radius, fill: TsColors.ready);

  /// Inline text action ("展开完整端点", "恢复全局默认"): no fill, accent text. Used where
  /// a solid block would break the sentence it sits in.
  static ButtonStyle link({double fontSize = 11.5}) => ButtonStyle(
        backgroundColor: const WidgetStatePropertyAll<Color>(Color(0x00000000)),
        foregroundColor: WidgetStatePropertyAll(TsColors.accent),
        overlayColor: WidgetStatePropertyAll(
          TsColors.accent.withValues(alpha: 0.10),
        ),
        elevation: const WidgetStatePropertyAll<double>(0),
        side: const WidgetStatePropertyAll<BorderSide>(BorderSide.none),
        padding:
            const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 4)),
        minimumSize: const WidgetStatePropertyAll(Size(0, TsSizes.inlineHeight)),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        textStyle: WidgetStatePropertyAll(TextStyle(fontSize: fontSize)),
        shape: const WidgetStatePropertyAll<OutlinedBorder>(
          BezierRoundedRectangleBorder(radius: 6),
        ),
      );

  /// The default for a bare `TextButton`: transparent, secondary text, subtle hover.
  ///
  /// 只给行内文字动作使用：透明底色、次要文字色与轻微 hover；不是蓝色实心块。
  static ButtonStyle inline({double fontSize = 12, double? height}) =>
      ButtonStyle(
        backgroundColor: const WidgetStatePropertyAll<Color>(Color(0x00000000)),
        foregroundColor: WidgetStateProperty.resolveWith((states) =>
            states.contains(WidgetState.disabled)
                ? TsColors.onButtonDisabled
                : TsColors.textSecondary),
        iconColor: WidgetStateProperty.resolveWith((states) =>
            states.contains(WidgetState.disabled)
                ? TsColors.onButtonDisabled
                : TsColors.textSecondary),
        overlayColor: WidgetStatePropertyAll(
          TsColors.textPrimary.withValues(alpha: 0.06),
        ),
        elevation: const WidgetStatePropertyAll<double>(0),
        side: const WidgetStatePropertyAll<BorderSide>(BorderSide.none),
        padding: const WidgetStatePropertyAll(
            EdgeInsets.symmetric(horizontal: 6, vertical: 4)),
        minimumSize: WidgetStatePropertyAll(
            Size(0, height ?? TsSizes.inlineHeight)),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        textStyle: WidgetStatePropertyAll(TextStyle(fontSize: fontSize)),
        shape: const WidgetStatePropertyAll<OutlinedBorder>(
          BezierRoundedRectangleBorder(radius: 6),
        ),
      );

  /// Low-emphasis icon/text affordance inside coloured banners: no fill, keeps the
  /// inherited foreground so an orange warning stays orange.
  static ButtonStyle ghost() => ButtonStyle(
        backgroundColor: const WidgetStatePropertyAll<Color>(Color(0x00000000)),
        foregroundColor: WidgetStatePropertyAll(TsColors.textSecondary),
        iconColor: WidgetStatePropertyAll(TsColors.textSecondary),
        overlayColor: WidgetStatePropertyAll(
          TsColors.textSecondary.withValues(alpha: 0.12),
        ),
        elevation: const WidgetStatePropertyAll<double>(0),
        side: const WidgetStatePropertyAll<BorderSide>(BorderSide.none),
        minimumSize:
            const WidgetStatePropertyAll(Size(0, TsSizes.inlineHeight)),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        shape: const WidgetStatePropertyAll<OutlinedBorder>(
          BezierRoundedRectangleBorder(radius: 6),
        ),
      );

  /// The default for a bare `IconButton`: transparent background, secondary glyph,
  /// 32x32 hit box. An ellipsis / delete / header icon is an affordance, not a button.
  ///
  /// Pass [foreground] for semantic icons (e.g. a delete icon keeps its danger colour)
  /// and [size] to match a dense row.
  static ButtonStyle icon({
    double size = TsSizes.iconButtonSize,
    Color? foreground,
  }) {
    final color = foreground ?? TsColors.textSecondary;
    return ButtonStyle(
      backgroundColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.disabled)) {
          return const Color(0x00000000);
        }
        if (states.contains(WidgetState.pressed)) {
          return color.withValues(alpha: 0.18);
        }
        if (states.contains(WidgetState.hovered) ||
            states.contains(WidgetState.focused)) {
          return color.withValues(alpha: 0.10);
        }
        return const Color(0x00000000);
      }),
      foregroundColor: WidgetStateProperty.resolveWith((states) =>
          states.contains(WidgetState.disabled)
              ? TsColors.onButtonDisabled
              : color),
      iconColor: WidgetStateProperty.resolveWith((states) =>
          states.contains(WidgetState.disabled)
              ? TsColors.onButtonDisabled
              : color),
      overlayColor: const WidgetStatePropertyAll<Color>(Color(0x00000000)),
      elevation: const WidgetStatePropertyAll<double>(0),
      side: const WidgetStatePropertyAll<BorderSide>(BorderSide.none),
      minimumSize: WidgetStatePropertyAll(Size.square(size)),
      fixedSize: WidgetStatePropertyAll(Size.square(size)),
      padding: const WidgetStatePropertyAll(EdgeInsets.zero),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      shape: const WidgetStatePropertyAll<OutlinedBorder>(
        BezierRoundedRectangleBorder(radius: 7),
      ),
    );
  }

  /// The round translucent close button. It must not become a blue rectangle.
  static ButtonStyle closeIcon({double size = 30}) => ButtonStyle(
        backgroundColor: WidgetStateProperty.resolveWith((states) {
          final strong = states.contains(WidgetState.hovered) ||
              states.contains(WidgetState.focused);
          return TsColors.textPrimary.withValues(alpha: strong ? 0.16 : 0.08);
        }),
        foregroundColor: WidgetStatePropertyAll(TsColors.textPrimary),
        iconColor: WidgetStatePropertyAll(TsColors.textPrimary),
        overlayColor: const WidgetStatePropertyAll<Color>(Color(0x00000000)),
        elevation: const WidgetStatePropertyAll<double>(0),
        side: const WidgetStatePropertyAll<BorderSide>(BorderSide.none),
        minimumSize: WidgetStatePropertyAll(Size.square(size)),
        fixedSize: WidgetStatePropertyAll(Size.square(size)),
        padding: const WidgetStatePropertyAll(EdgeInsets.zero),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        shape: const WidgetStatePropertyAll<OutlinedBorder>(CircleBorder()),
      );

  /// [solid] 的兼容别名，保留原有调用名。
  static ButtonStyle filled({
    double radius = TsSizes.buttonRadius,
    Color? fill,
    Color? foreground,
    EdgeInsetsGeometry? padding,
    Size? minimumSize,
    double? fontSize,
    bool circular = false,
  }) =>
      solid(
        radius: radius,
        fill: fill,
        foreground: foreground,
        padding: padding,
        minimumSize: minimumSize,
        fontSize: fontSize,
        circular: circular,
      );
}

