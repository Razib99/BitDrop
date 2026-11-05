import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Manages the state, progress (0.0 to 1.0), and gesture coordination
/// for the persistent expanding player sheet across the app shell.
class PlayerSheetController extends ChangeNotifier {
  AnimationController? _animController;

  void attach(AnimationController controller) {
    if (_animController == controller) return;
    _animController?.removeListener(_onTick);
    _animController = controller;
    _animController?.addListener(_onTick);
  }

  void detach(AnimationController controller) {
    if (_animController == controller) {
      _animController?.removeListener(_onTick);
      _animController = null;
    }
  }

  void _onTick() {
    notifyListeners();
  }

  double get progress => _animController?.value ?? 0.0;
  bool get isExpanded => progress > 0.5;
  bool get isCollapsed => progress <= 0.001;
  AnimationController? get animController => _animController;

  void expand({Duration? duration}) {
    _animController?.animateTo(
      1.0,
      duration: duration ?? const Duration(milliseconds: 340),
      curve: Curves.easeOutCubic,
    );
  }

  void collapse({Duration? duration}) {
    _animController?.animateTo(
      0.0,
      duration: duration ?? const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
    );
  }

  void setProgress(double p) {
    _animController?.value = p.clamp(0.0, 1.0);
  }

  /// Snaps to expanded or collapsed state based on touch velocity and progress.
  void settle(double velocity) {
    if (_animController == null) return;
    final p = _animController!.value;
    // velocity is in dp/s. Negative velocity means dragging up, positive means dragging down
    if (velocity < -280) {
      expand();
    } else if (velocity > 280) {
      collapse();
    } else if (p > 0.35) {
      expand();
    } else {
      collapse();
    }
  }
}

final playerSheetControllerProvider =
    ChangeNotifierProvider<PlayerSheetController>((ref) {
  return PlayerSheetController();
});
