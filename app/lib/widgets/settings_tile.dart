import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/tokens.dart';

/// Settings rows.
///
/// Every option carries a one-line explanation, and a disabled option always
/// says *why* it is disabled — the fix for Poweramp's unexplained toggles.
sealed class SettingsTile extends StatelessWidget {
  const SettingsTile({
    super.key,
    required this.title,
    this.subtitle,
    this.icon,
    this.enabled = true,
    this.disabledReason,
    this.highlighted = false,
    this.advanced = false,
  });

  final String title;
  final String? subtitle;
  final IconData? icon;
  final bool enabled;

  /// Shown in place of [subtitle] when [enabled] is false.
  final String? disabledReason;

  /// Set when a settings search match should flash this row.
  final bool highlighted;
  final bool advanced;

  /// Text searched by the settings search field.
  String get searchText =>
      '$title ${subtitle ?? ''} ${disabledReason ?? ''}'.toLowerCase();

  Widget buildTrailing(BuildContext context);
  VoidCallback? onRowTap(BuildContext context) => null;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final effectiveSubtitle = enabled ? subtitle : (disabledReason ?? subtitle);

    return Semantics(
      enabled: enabled,
      child: Material(
        color: highlighted ? c.accent.withOpacity(0.12) : Colors.transparent,
        child: InkWell(
          onTap: enabled ? onRowTap(context) : null,
          child: Opacity(
            opacity: enabled ? 1 : 0.6,
            child: Container(
              constraints:
                  const BoxConstraints(minHeight: Sizes.touchTarget + 8),
              padding: const EdgeInsets.symmetric(
                  horizontal: Spacing.md, vertical: Spacing.xs),
              child: Row(
                children: [
                  if (icon != null) ...[
                    Icon(icon, size: 20, color: c.textSecondary),
                    const SizedBox(width: Spacing.sm),
                  ],
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(title, style: context.t.body),
                        if (effectiveSubtitle != null) ...[
                          const SizedBox(height: 2),
                          Text(
                            effectiveSubtitle,
                            style: context.t.bodySmall.copyWith(
                              color:
                                  enabled ? c.textSecondary : c.tierResampled,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: Spacing.sm),
                  buildTrailing(context),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class SwitchSettingsTile extends SettingsTile {
  const SwitchSettingsTile({
    super.key,
    required super.title,
    required this.value,
    required this.onChanged,
    super.subtitle,
    super.icon,
    super.enabled,
    super.disabledReason,
    super.highlighted,
    super.advanced,
  });

  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget buildTrailing(BuildContext context) => Semantics(
        label: title,
        toggled: value,
        child: Switch(value: value, onChanged: enabled ? onChanged : null),
      );

  @override
  VoidCallback? onRowTap(BuildContext context) => () => onChanged(!value);
}

class ChoiceSettingsTile<T> extends SettingsTile {
  const ChoiceSettingsTile({
    super.key,
    required super.title,
    required this.value,
    required this.options,
    required this.labelOf,
    required this.onChanged,
    super.subtitle,
    super.icon,
    super.enabled,
    super.disabledReason,
    super.highlighted,
    super.advanced,
  });

  final T value;
  final List<T> options;
  final String Function(T) labelOf;
  final ValueChanged<T> onChanged;

  @override
  Widget buildTrailing(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(labelOf(value),
              style: context.t.monoReadout
                  .copyWith(color: context.c.textSecondary)),
          Icon(Icons.arrow_drop_down, color: context.c.textSecondary),
        ],
      );

  @override
  VoidCallback? onRowTap(BuildContext context) => () async {
        final picked = await showModalBottomSheet<T>(
          context: context,
          builder: (_) => SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.all(Spacing.md),
                  child: Text(title, style: context.t.titleSmall),
                ),
                for (final o in options)
                  RadioListTile<T>(
                    value: o,
                    groupValue: value,
                    title: Text(labelOf(o)),
                    onChanged: (v) => Navigator.of(context).pop(v),
                  ),
                const SizedBox(height: Spacing.xs),
              ],
            ),
          ),
        );
        if (picked != null) onChanged(picked);
      };
}

class SliderSettingsTile extends SettingsTile {
  const SliderSettingsTile({
    super.key,
    required super.title,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    required this.valueLabel,
    this.divisions,
    super.subtitle,
    super.icon,
    super.enabled,
    super.disabledReason,
    super.highlighted,
    super.advanced,
  });

  final double value;
  final double min;
  final double max;
  final int? divisions;
  final ValueChanged<double> onChanged;
  final String Function(double) valueLabel;

  @override
  Widget buildTrailing(BuildContext context) => const SizedBox.shrink();

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Opacity(
      opacity: enabled ? 1 : 0.6,
      child: Container(
        color: highlighted ? c.accent.withOpacity(0.12) : null,
        padding: const EdgeInsets.fromLTRB(
            Spacing.md, Spacing.xs, Spacing.md, Spacing.xs),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (icon != null) ...[
                  Icon(icon, size: 20, color: c.textSecondary),
                  const SizedBox(width: Spacing.sm),
                ],
                Expanded(child: Text(title, style: context.t.body)),
                Text(valueLabel(value), style: context.t.monoReadout),
              ],
            ),
            if (subtitle != null)
              Padding(
                padding: EdgeInsets.only(left: icon != null ? 32 : 0, top: 2),
                child: Text(
                  enabled ? subtitle! : (disabledReason ?? subtitle!),
                  style: context.t.bodySmall.copyWith(color: c.textSecondary),
                ),
              ),
            Semantics(
              slider: true,
              label: title,
              value: valueLabel(value),
              excludeSemantics: true,
              child: Slider(
                value: value.clamp(min, max),
                min: min,
                max: max,
                divisions: divisions,
                label: valueLabel(value),
                onChanged: enabled ? onChanged : null,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class NavigationSettingsTile extends SettingsTile {
  const NavigationSettingsTile({
    super.key,
    required super.title,
    required this.onTap,
    this.trailingText,
    super.subtitle,
    super.icon,
    super.enabled,
    super.disabledReason,
    super.highlighted,
    super.advanced,
  });

  final VoidCallback onTap;
  final String? trailingText;

  @override
  Widget buildTrailing(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (trailingText != null)
            Text(trailingText!,
                style: context.t.monoReadout
                    .copyWith(color: context.c.textSecondary)),
          Icon(Icons.chevron_right, color: context.c.textTertiary),
        ],
      );

  @override
  VoidCallback? onRowTap(BuildContext context) => onTap;
}

/// A settings group with an optional "Advanced" disclosure.
class SettingsGroup extends StatefulWidget {
  const SettingsGroup({
    super.key,
    required this.title,
    required this.tiles,
    this.icon,
    this.initiallyExpandedAdvanced = false,
  });

  final String title;
  final List<SettingsTile> tiles;
  final IconData? icon;
  final bool initiallyExpandedAdvanced;

  @override
  State<SettingsGroup> createState() => _SettingsGroupState();
}

class _SettingsGroupState extends State<SettingsGroup> {
  late bool _advancedOpen = widget.initiallyExpandedAdvanced;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final basic = widget.tiles.where((t) => !t.advanced).toList();
    final advanced = widget.tiles.where((t) => t.advanced).toList();
    if (basic.isEmpty && advanced.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
              Spacing.md, Spacing.lg, Spacing.md, Spacing.xs),
          child: Row(
            children: [
              if (widget.icon != null) ...[
                Icon(widget.icon, size: 16, color: c.accent),
                const SizedBox(width: Spacing.xs),
              ],
              Text(
                widget.title.toUpperCase(),
                style: context.t.monoLabel.copyWith(color: c.accent),
              ),
            ],
          ),
        ),
        Container(
          margin: const EdgeInsets.symmetric(horizontal: Spacing.sm),
          decoration: BoxDecoration(
            color: c.surface1,
            borderRadius: Radii.cardR,
            border: Border.all(color: c.outline),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              for (var i = 0; i < basic.length; i++) ...[
                if (i > 0) Divider(height: 1, color: c.outline),
                basic[i],
              ],
              if (advanced.isNotEmpty) ...[
                Divider(height: 1, color: c.outline),
                InkWell(
                  onTap: () => setState(() => _advancedOpen = !_advancedOpen),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: Spacing.md, vertical: Spacing.sm),
                    child: Row(
                      children: [
                        Icon(
                          _advancedOpen ? Icons.expand_less : Icons.expand_more,
                          size: 18,
                          color: c.textSecondary,
                        ),
                        const SizedBox(width: Spacing.xs),
                        Text('Advanced',
                            style: context.t.label
                                .copyWith(color: c.textSecondary)),
                      ],
                    ),
                  ),
                ),
                if (_advancedOpen)
                  for (final t in advanced) ...[
                    Divider(height: 1, color: c.outline),
                    t,
                  ],
              ],
            ],
          ),
        ),
      ],
    );
  }
}
