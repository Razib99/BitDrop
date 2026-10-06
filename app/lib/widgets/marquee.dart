import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// Scrolls text horizontally when it does not fit, then pauses at each end.
///
/// Falls back to a static ellipsis when the system asks for reduced motion,
/// so a long title never becomes a moving distraction.
class Marquee extends StatefulWidget {
  const Marquee({
    super.key,
    required this.text,
    required this.style,
    this.velocity = 28,
    this.pause = const Duration(seconds: 2),
    this.textAlign = TextAlign.start,
  });

  final String text;
  final TextStyle style;

  /// Logical pixels per second.
  final double velocity;
  final Duration pause;
  final TextAlign textAlign;

  @override
  State<Marquee> createState() => _MarqueeState();
}

class _MarqueeState extends State<Marquee> with SingleTickerProviderStateMixin {
  final _controller = ScrollController();
  late final Ticker _ticker;
  double _offset = 0;
  int _direction = 1;
  Duration _waitUntil = Duration.zero;
  Duration _elapsed = Duration.zero;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick)..start();
  }

  @override
  void didUpdateWidget(Marquee old) {
    super.didUpdateWidget(old);
    if (old.text != widget.text) {
      _offset = 0;
      _direction = 1;
      _waitUntil = _elapsed + widget.pause;
      if (_controller.hasClients) _controller.jumpTo(0);
    }
  }

  void _onTick(Duration elapsed) {
    _elapsed = elapsed;
    if (!_controller.hasClients) return;
    final max = _controller.position.maxScrollExtent;
    if (max <= 0) return;
    if (elapsed < _waitUntil) return;

    _offset += _direction * widget.velocity / 60;
    if (_offset >= max) {
      _offset = max;
      _direction = -1;
      _waitUntil = elapsed + widget.pause;
    } else if (_offset <= 0) {
      _offset = 0;
      _direction = 1;
      _waitUntil = elapsed + widget.pause;
    }
    _controller.jumpTo(_offset);
  }

  @override
  void dispose() {
    _ticker.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduce = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (reduce) {
      return Text(
        widget.text,
        style: widget.style,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        textAlign: widget.textAlign,
      );
    }

    return SizedBox(
      height: (widget.style.fontSize ?? 16) * (widget.style.height ?? 1.3),
      child: SingleChildScrollView(
        controller: _controller,
        scrollDirection: Axis.horizontal,
        physics: const NeverScrollableScrollPhysics(),
        child: Text(widget.text, style: widget.style, maxLines: 1),
      ),
    );
  }
}
