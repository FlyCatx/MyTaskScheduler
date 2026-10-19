// Thin message strip shown at the top of the content area (below the title bar).
//
// Why not in the title bar: the title bar has a fixed height so it can line up with the
// sidebar header. Anything that may wrap (storage fallback notice, error text, result
// status) therefore lives here, where it can grow without breaking the alignment.

import 'package:flutter/material.dart';

import 'bezier_ui.dart';
import '../theme.dart';

class StatusStrip extends StatelessWidget {
  final String? storageNotice;
  final String? errorMessage;
  final String? statusMessage;
  final VoidCallback onDismissError;

  const StatusStrip({
    super.key,
    this.storageNotice,
    this.errorMessage,
    this.statusMessage,
    required this.onDismissError,
  });

  bool get _isEmpty =>
      storageNotice == null && errorMessage == null && statusMessage == null;

  @override
  Widget build(BuildContext context) {
    if (_isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (storageNotice != null)
            _Banner(
              icon: Icons.folder_off_outlined,
              color: TsColors.pending,
              background: TsColors.pendingSoft,
              border: TsColors.pending.withValues(alpha: 0.35),
              message: storageNotice!,
            ),
          if (errorMessage != null) ...[
            if (storageNotice != null) const SizedBox(height: 6),
            _Banner(
              icon: Icons.error_outline,
              color: TsColors.blocked,
              background: TsColors.blockedSoft,
              border: TsColors.blocked.withValues(alpha: 0.35),
              message: errorMessage!,
              onDismiss: onDismissError,
            ),
          ],
          if (statusMessage != null) ...[
            if (storageNotice != null || errorMessage != null)
              const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.only(left: 2, top: 2),
              child: Text(
                statusMessage!,
                style: TextStyle(fontSize: 11.5, color: TsColors.textSecondary),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  final IconData icon;
  final Color color;
  final Color background;
  final Color border;
  final String message;
  final VoidCallback? onDismiss;

  const _Banner({
    required this.icon,
    required this.color,
    required this.background,
    required this.border,
    required this.message,
    this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.fromLTRB(10, 7, onDismiss == null ? 10 : 4, 7),
      decoration: bezierDecoration(
        color: background,
        radius: 8,
        border: Border.all(color: border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 15, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11.5, color: color, height: 1.4),
            ),
          ),
          if (onDismiss != null)
            IconButton(
              tooltip: '关闭提示',
              visualDensity: VisualDensity.compact,
              // A dismiss affordance inside a coloured banner: transparent, so the
              // warning/error colour stays readable instead of a blue block.
              style: TsButtons.ghost(),
              onPressed: onDismiss,
              icon: Icon(Icons.close, size: 14, color: color),
            ),
        ],
      ),
    );
  }
}

