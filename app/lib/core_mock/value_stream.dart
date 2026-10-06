import 'dart:async';

/// A broadcast stream that also remembers its latest value and replays it to
/// each new listener.
///
/// The real core will push state from Rust; this gives the prototype the same
/// "always has a current value" behaviour that `StreamProvider` expects, so no
/// screen has to cope with an empty first frame.
class ValueStream<T> {
  ValueStream(this._value);

  final StreamController<T> _controller = StreamController<T>.broadcast();
  T _value;

  T get value => _value;

  Stream<T> get stream async* {
    yield _value;
    yield* _controller.stream;
  }

  /// Emits only when the value actually changed identity, so high-frequency
  /// callers do not wake listeners for nothing.
  void emit(T next) {
    _value = next;
    if (!_controller.isClosed) _controller.add(next);
  }

  /// Recomputes from the current value.
  void update(T Function(T current) transform) => emit(transform(_value));

  Future<void> close() => _controller.close();
}
