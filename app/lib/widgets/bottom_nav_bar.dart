import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_theme.dart';

/// Destination item for [BitDropBottomNavBar].
class BitDropNavDestination {
  const BitDropNavDestination({
    required this.path,
    required this.icon,
    required this.label,
  });

  final String path;
  final IconData icon;
  final String label;
}

/// Bespoke bottom navigation dock for BitDrop.
///
/// Features:
/// - Edge-to-edge full width dock matching phone borders.
/// - Dark obsidian surface2 background harmonizing with the docked mini-player.
/// - Ultra-fine 1px hairline top separation line.
/// - Stable icon geometry: uses identical icon glyphs across active/inactive states
///   so icons never morph, shift, or distort shape/size when tapped.
/// - Frosted white (`#F1F5F9`) active indicator matching play/pause transport controls.
/// - Persistent, legible micro-labels.
/// - Tactile haptic feedback on tab change.
class BitDropBottomNavBar extends StatelessWidget {
  const BitDropBottomNavBar({
    super.key,
    required this.selectedIndex,
    required this.onDestinationSelected,
    required this.destinations,
  });

  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;
  final List<BitDropNavDestination> destinations;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    const activeColor = Color(0xFFF1F5F9);
    final inactiveColor = Colors.white.withOpacity(0.40);

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: c.surface2,
        border: Border(
          top: BorderSide(
            color: c.outline.withOpacity(0.35),
            width: 1.0,
          ),
        ),
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 64.0,
          child: Row(
            children: [
              for (int i = 0; i < destinations.length; i++)
                Expanded(
                  child: _NavBarItem(
                    dest: destinations[i],
                    isSelected: i == selectedIndex,
                    activeColor: activeColor,
                    inactiveColor: inactiveColor,
                    onTap: () {
                      if (i != selectedIndex) {
                        HapticFeedback.selectionClick();
                      }
                      onDestinationSelected(i);
                    },
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NavBarItem extends StatelessWidget {
  const _NavBarItem({
    required this.dest,
    required this.isSelected,
    required this.activeColor,
    required this.inactiveColor,
    required this.onTap,
  });

  final BitDropNavDestination dest;
  final bool isSelected;
  final Color activeColor;
  final Color inactiveColor;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = isSelected ? activeColor : inactiveColor;

    return Semantics(
      button: true,
      selected: isSelected,
      label: dest.label,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          splashColor: Colors.white.withOpacity(0.06),
          highlightColor: Colors.transparent,
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  dest.icon,
                  size: 24,
                  color: color,
                ),
                const SizedBox(height: 3),
                Text(
                  dest.label,
                  style: TextStyle(
                    fontSize: 11,
                    letterSpacing: -0.1,
                    fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
                    color: color,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
