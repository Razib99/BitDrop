import 'package:flutter/material.dart';

import '../core_api/enums.dart';
import '../core_api/models.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import '../l10n/l10n.dart';

/// Group heading with an optional trailing action.
class SectionHeader extends StatelessWidget {
  const SectionHeader({
    super.key,
    required this.title,
    this.actionLabel,
    this.onAction,
    this.subtitle,
    this.padding,
  });

  final String title;
  final String? actionLabel;
  final VoidCallback? onAction;
  final String? subtitle;
  final EdgeInsets? padding;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding ??
          const EdgeInsets.only(
            left: Spacing.md,
            right: Spacing.xs,
            top: Spacing.lg,
            bottom: Spacing.xs,
          ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: context.t.titleSmall),
                if (subtitle != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      subtitle!,
                      style: context.t.bodySmall
                          .copyWith(color: context.c.textSecondary),
                    ),
                  ),
              ],
            ),
          ),
          if (actionLabel != null && onAction != null)
            TextButton(onPressed: onAction, child: Text(actionLabel!)),
        ],
      ),
    );
  }
}

/// Inline message with a tier-neutral palette. Info is calm by design: a
/// resampled output or a rate limit is **not** an error.
class StatusBanner extends StatelessWidget {
  const StatusBanner({
    super.key,
    required this.kind,
    required this.message,
    this.actionLabel,
    this.onAction,
    this.onDismiss,
    this.icon,
    this.margin,
  });

  final BannerKind kind;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;
  final VoidCallback? onDismiss;
  final IconData? icon;
  final EdgeInsets? margin;

  factory StatusBanner.fromBanner(
    AppBanner banner, {
    VoidCallback? onAction,
    VoidCallback? onDismiss,
  }) =>
      StatusBanner(
        kind: banner.kind,
        message: banner.message,
        actionLabel: banner.actionLabel,
        onAction: onAction,
        onDismiss: banner.dismissible ? onDismiss : null,
      );

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final (Color accent, IconData defaultIcon) = switch (kind) {
      BannerKind.info => (c.tierNativeRate, Icons.info_outline),
      BannerKind.warning => (c.tierResampled, Icons.warning_amber_rounded),
      BannerKind.error => (c.error, Icons.error_outline),
      BannerKind.success => (c.success, Icons.check_circle_outline),
    };

    return Semantics(
      liveRegion: true,
      container: true,
      child: Container(
        margin: margin ??
            const EdgeInsets.symmetric(
                horizontal: Spacing.md, vertical: Spacing.xxs),
        padding: const EdgeInsets.fromLTRB(
            Spacing.sm, Spacing.sm, Spacing.xs, Spacing.sm),
        decoration: BoxDecoration(
          color: accent.withOpacity(0.10),
          borderRadius: Radii.chipR,
          border: Border.all(color: accent.withOpacity(0.4)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 1),
              child: Icon(icon ?? defaultIcon, size: 18, color: accent),
            ),
            const SizedBox(width: Spacing.xs),
            Expanded(
              child: Text(message, style: context.t.bodySmall),
            ),
            if (actionLabel != null && onAction != null)
              Padding(
                padding: const EdgeInsets.only(left: Spacing.xs),
                child: TextButton(
                  onPressed: onAction,
                  style: TextButton.styleFrom(
                    minimumSize: const Size(0, 32),
                    padding: const EdgeInsets.symmetric(horizontal: Spacing.xs),
                    foregroundColor: accent,
                  ),
                  child: Text(actionLabel!, style: context.t.label),
                ),
              ),
            if (onDismiss != null)
              IconButton(
                onPressed: onDismiss,
                icon: const Icon(Icons.close, size: 18),
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                tooltip: context.l10n.actionDismiss,
                color: context.c.textSecondary,
              ),
          ],
        ),
      ),
    );
  }
}

/// Illustration + message + optional action, for every "nothing here" case.
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.actionLabel,
    this.onAction,
    this.secondaryActionLabel,
    this.onSecondaryAction,
    this.hints = const [],
  });

  final IconData icon;
  final String title;
  final String? message;
  final String? actionLabel;
  final VoidCallback? onAction;
  final String? secondaryActionLabel;
  final VoidCallback? onSecondaryAction;

  /// Short tips, e.g. `Try "24/192" or "ALAC"`.
  final List<String> hints;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(Spacing.xl),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 96,
              height: 96,
              decoration: BoxDecoration(
                color: c.surface2,
                shape: BoxShape.circle,
                border: Border.all(color: c.outline),
              ),
              child: Icon(icon, size: 40, color: c.textSecondary),
            ),
            const SizedBox(height: Spacing.lg),
            Text(title, style: context.t.title, textAlign: TextAlign.center),
            if (message != null) ...[
              const SizedBox(height: Spacing.xs),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 360),
                child: Text(
                  message!,
                  style: context.t.body.copyWith(color: c.textSecondary),
                  textAlign: TextAlign.center,
                ),
              ),
            ],
            if (hints.isNotEmpty) ...[
              const SizedBox(height: Spacing.md),
              Wrap(
                alignment: WrapAlignment.center,
                spacing: Spacing.xs,
                runSpacing: Spacing.xs,
                children: [
                  for (final h in hints)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: Spacing.sm, vertical: 6),
                      decoration: BoxDecoration(
                        color: c.surface2,
                        borderRadius: Radii.chipR,
                        border: Border.all(color: c.outline),
                      ),
                      child: Text(h,
                          style: context.t.monoReadout
                              .copyWith(color: c.textSecondary)),
                    ),
                ],
              ),
            ],
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: Spacing.lg),
              FilledButton(onPressed: onAction, child: Text(actionLabel!)),
            ],
            if (secondaryActionLabel != null && onSecondaryAction != null) ...[
              const SizedBox(height: Spacing.xs),
              TextButton(
                onPressed: onSecondaryAction,
                child: Text(secondaryActionLabel!),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Shimmering placeholder. Used for fields the scanner has not filled yet, so
/// the library is browsable within seconds of the first pass.
class SkeletonLoader extends StatefulWidget {
  const SkeletonLoader({
    super.key,
    this.width,
    this.height = 12,
    this.borderRadius,
    this.shape = BoxShape.rectangle,
  });

  final double? width;
  final double height;
  final BorderRadius? borderRadius;
  final BoxShape shape;

  @override
  State<SkeletonLoader> createState() => _SkeletonLoaderState();
}

class _SkeletonLoaderState extends State<SkeletonLoader>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  )..repeat();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final reduce = MediaQuery.maybeDisableAnimationsOf(context) ?? false;

    if (reduce) {
      return _box(c.shimmerBase, null);
    }

    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, _) {
        final t = _ctrl.value;
        return _box(
          c.shimmerBase,
          LinearGradient(
            begin: Alignment(-1 + t * 3, 0),
            end: Alignment(-0.4 + t * 3, 0),
            colors: [c.shimmerBase, c.shimmerHighlight, c.shimmerBase],
          ),
        );
      },
    );
  }

  Widget _box(Color base, Gradient? gradient) => Container(
        width: widget.width,
        height: widget.height,
        decoration: BoxDecoration(
          color: base,
          gradient: gradient,
          shape: widget.shape,
          borderRadius: widget.shape == BoxShape.circle
              ? null
              : (widget.borderRadius ?? Radii.badgeR),
        ),
      );
}

/// Flat segmented control. Scrolls horizontally when the labels do not fit,
/// which they will not at 200% text.
class SegmentedTabs<T> extends StatelessWidget {
  const SegmentedTabs({
    super.key,
    required this.values,
    required this.labels,
    required this.selected,
    required this.onChanged,
    this.padding,
  });

  final List<T> values;
  final String Function(T) labels;
  final T selected;
  final ValueChanged<T> onChanged;
  final EdgeInsets? padding;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: padding ?? const EdgeInsets.symmetric(horizontal: Spacing.md),
      child: Row(
        children: [
          for (final v in values)
            Padding(
              padding: const EdgeInsets.only(right: Spacing.xs),
              child: _Segment(
                label: labels(v),
                selected: v == selected,
                onTap: () => onChanged(v),
                colors: c,
              ),
            ),
        ],
      ),
    );
  }
}

class _Segment extends StatelessWidget {
  const _Segment({
    required this.label,
    required this.selected,
    required this.onTap,
    required this.colors,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final BitDropColors colors;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      selected: selected,
      button: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: Radii.chipR,
        child: AnimatedContainer(
          duration: Motion.micro,
          constraints: const BoxConstraints(minHeight: 36),
          padding: const EdgeInsets.symmetric(
              horizontal: Spacing.sm, vertical: Spacing.xs),
          decoration: BoxDecoration(
            color: selected ? colors.accent : colors.surface2,
            borderRadius: Radii.chipR,
            border:
                Border.all(color: selected ? colors.accent : colors.outline),
          ),
          alignment: Alignment.center,
          child: Text(
            label,
            style: context.t.label.copyWith(
              color: selected ? colors.onAccent : colors.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}

/// Row of filter chips with an optional count badge on the leading button.
class FilterChipRow extends StatelessWidget {
  const FilterChipRow({super.key, required this.children, this.padding});

  final List<Widget> children;
  final EdgeInsets? padding;

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: padding ?? const EdgeInsets.symmetric(horizontal: Spacing.md),
        child: Row(
          children: [
            for (final child in children)
              Padding(
                padding: const EdgeInsets.only(right: Spacing.xs),
                child: child,
              ),
          ],
        ),
      );
}

/// A single selectable chip used throughout filters and sorts.
class BitChip extends StatelessWidget {
  const BitChip({
    super.key,
    required this.label,
    this.selected = false,
    this.onTap,
    this.icon,
    this.trailingCount,
    this.mono = false,
  });

  final String label;
  final bool selected;
  final VoidCallback? onTap;
  final IconData? icon;
  final int? trailingCount;
  final bool mono;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final fg = selected ? c.onAccent : c.textSecondary;
    return Semantics(
      selected: selected,
      button: onTap != null,
      child: InkWell(
        onTap: onTap,
        borderRadius: Radii.chipR,
        child: Container(
          constraints: const BoxConstraints(minHeight: 36),
          padding:
              const EdgeInsets.symmetric(horizontal: Spacing.sm, vertical: 6),
          decoration: BoxDecoration(
            color: selected ? c.accent : c.surface2,
            borderRadius: Radii.chipR,
            border: Border.all(color: selected ? c.accent : c.outline),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 15, color: fg),
                const SizedBox(width: 5),
              ],
              Text(
                label,
                style: (mono ? context.t.monoReadout : context.t.label)
                    .copyWith(color: fg),
              ),
              if (trailingCount != null && trailingCount! > 0) ...[
                const SizedBox(width: 5),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                  decoration: BoxDecoration(
                    color: selected
                        ? c.onAccent.withOpacity(0.25)
                        : c.accent.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    '$trailingCount',
                    style: context.t.monoLabel
                        .copyWith(color: selected ? c.onAccent : c.accent),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Bottom sheet frame with a title row and consistent padding.
class BottomSheetScaffold extends StatelessWidget {
  const BottomSheetScaffold({
    super.key,
    required this.title,
    required this.child,
    this.subtitle,
    this.actions = const [],
    this.scrollable = true,
    this.maxHeightFactor = 0.9,
  });

  final String title;
  final Widget child;
  final String? subtitle;
  final List<Widget> actions;
  final bool scrollable;
  final double maxHeightFactor;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final media = MediaQuery.of(context);
    return Container(
      constraints: BoxConstraints(
        maxHeight: media.size.height * maxHeightFactor,
      ),
      decoration: BoxDecoration(
        color: c.surface1,
        borderRadius: Radii.sheetR,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
                Spacing.md, Spacing.xs, Spacing.xs, Spacing.xs),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: context.t.titleSmall),
                      if (subtitle != null)
                        Text(
                          subtitle!,
                          style: context.t.bodySmall
                              .copyWith(color: c.textSecondary),
                        ),
                    ],
                  ),
                ),
                ...actions,
                IconButton(
                  onPressed: () => Navigator.of(context).maybePop(),
                  icon: const Icon(Icons.close),
                  tooltip: context.l10n.actionClose,
                ),
              ],
            ),
          ),
          Divider(height: 1, color: c.outline),
          Flexible(
            child: scrollable
                ? SingleChildScrollView(
                    padding: EdgeInsets.only(
                      bottom: media.padding.bottom + Spacing.md,
                    ),
                    child: child,
                  )
                : child,
          ),
        ],
      ),
    );
  }
}

/// Confirmation dialog with an explicit, named action verb.
class ConfirmDialog extends StatelessWidget {
  const ConfirmDialog({
    super.key,
    required this.title,
    required this.message,
    required this.confirmLabel,
    this.cancelLabel = 'Cancel',
    this.destructive = false,
    this.checkboxLabel,
  });

  final String title;
  final String message;
  final String confirmLabel;
  final String cancelLabel;
  final bool destructive;

  /// When set, the confirm button stays disabled until it is ticked.
  final String? checkboxLabel;

  static Future<bool> show(
    BuildContext context, {
    required String title,
    required String message,
    required String confirmLabel,
    String cancelLabel = 'Cancel',
    bool destructive = false,
    String? checkboxLabel,
  }) async =>
      await showDialog<bool>(
        context: context,
        builder: (_) => ConfirmDialog(
          title: title,
          message: message,
          confirmLabel: confirmLabel,
          cancelLabel: cancelLabel,
          destructive: destructive,
          checkboxLabel: checkboxLabel,
        ),
      ) ??
      false;

  @override
  Widget build(BuildContext context) => _ConfirmBody(
        title: title,
        message: message,
        confirmLabel: confirmLabel,
        cancelLabel: cancelLabel,
        destructive: destructive,
        checkboxLabel: checkboxLabel,
      );
}

class _ConfirmBody extends StatefulWidget {
  const _ConfirmBody({
    required this.title,
    required this.message,
    required this.confirmLabel,
    required this.cancelLabel,
    required this.destructive,
    this.checkboxLabel,
  });

  final String title;
  final String message;
  final String confirmLabel;
  final String cancelLabel;
  final bool destructive;
  final String? checkboxLabel;

  @override
  State<_ConfirmBody> createState() => _ConfirmBodyState();
}

class _ConfirmBodyState extends State<_ConfirmBody> {
  bool _checked = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.checkboxLabel == null || _checked;
    return AlertDialog(
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.message,
              style: context.t.body.copyWith(color: context.c.textSecondary)),
          if (widget.checkboxLabel != null) ...[
            const SizedBox(height: Spacing.sm),
            InkWell(
              onTap: () => setState(() => _checked = !_checked),
              borderRadius: Radii.badgeR,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: Spacing.xxs),
                child: Row(
                  children: [
                    Checkbox(
                      value: _checked,
                      onChanged: (v) => setState(() => _checked = v ?? false),
                    ),
                    Expanded(
                      child: Text(widget.checkboxLabel!,
                          style: context.t.bodySmall),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(widget.cancelLabel),
        ),
        FilledButton(
          onPressed: enabled ? () => Navigator.of(context).pop(true) : null,
          style: widget.destructive
              ? FilledButton.styleFrom(
                  backgroundColor: context.c.error,
                  foregroundColor: Colors.white,
                )
              : null,
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}
