// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'audio_engine.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

T _$identity<T>(T value) => value;

final _privateConstructorUsedError = UnsupportedError(
    'It seems like you constructed your class using `MyClass._()`. This constructor is only meant to be used by freezed and you are not supposed to need it nor use it.\nPlease check the documentation here for more information: https://github.com/rrousselGit/freezed#adding-getters-and-methods-to-our-models');

/// @nodoc
mixin _$EngineEvent {
  @optionalTypeArgs
  TResult when<TResult extends Object?>({
    required TResult Function(String fileId, String message) playbackFailed,
    required TResult Function(BigInt requestId) tokenRefreshRequested,
    required TResult Function(bool isPlaying, bool isBuffering) playbackState,
    required TResult Function(String fileId) trackStarted,
    required TResult Function(String fileId) trackEnded,
    required TResult Function(int positionMs, int durationMs) positionUpdate,
    required TResult Function(
            int bufferedMs, int fetchesInFlight, BigInt bytesFetched)
        bufferTelemetry,
    required TResult Function(int grMillidb, BigInt clippedSamples)
        limiterTelemetry,
  }) =>
      throw _privateConstructorUsedError;
  @optionalTypeArgs
  TResult? whenOrNull<TResult extends Object?>({
    TResult? Function(String fileId, String message)? playbackFailed,
    TResult? Function(BigInt requestId)? tokenRefreshRequested,
    TResult? Function(bool isPlaying, bool isBuffering)? playbackState,
    TResult? Function(String fileId)? trackStarted,
    TResult? Function(String fileId)? trackEnded,
    TResult? Function(int positionMs, int durationMs)? positionUpdate,
    TResult? Function(int bufferedMs, int fetchesInFlight, BigInt bytesFetched)?
        bufferTelemetry,
    TResult? Function(int grMillidb, BigInt clippedSamples)? limiterTelemetry,
  }) =>
      throw _privateConstructorUsedError;
  @optionalTypeArgs
  TResult maybeWhen<TResult extends Object?>({
    TResult Function(String fileId, String message)? playbackFailed,
    TResult Function(BigInt requestId)? tokenRefreshRequested,
    TResult Function(bool isPlaying, bool isBuffering)? playbackState,
    TResult Function(String fileId)? trackStarted,
    TResult Function(String fileId)? trackEnded,
    TResult Function(int positionMs, int durationMs)? positionUpdate,
    TResult Function(int bufferedMs, int fetchesInFlight, BigInt bytesFetched)?
        bufferTelemetry,
    TResult Function(int grMillidb, BigInt clippedSamples)? limiterTelemetry,
    required TResult orElse(),
  }) =>
      throw _privateConstructorUsedError;
  @optionalTypeArgs
  TResult map<TResult extends Object?>({
    required TResult Function(EngineEvent_PlaybackFailed value) playbackFailed,
    required TResult Function(EngineEvent_TokenRefreshRequested value)
        tokenRefreshRequested,
    required TResult Function(EngineEvent_PlaybackState value) playbackState,
    required TResult Function(EngineEvent_TrackStarted value) trackStarted,
    required TResult Function(EngineEvent_TrackEnded value) trackEnded,
    required TResult Function(EngineEvent_PositionUpdate value) positionUpdate,
    required TResult Function(EngineEvent_BufferTelemetry value)
        bufferTelemetry,
    required TResult Function(EngineEvent_LimiterTelemetry value)
        limiterTelemetry,
  }) =>
      throw _privateConstructorUsedError;
  @optionalTypeArgs
  TResult? mapOrNull<TResult extends Object?>({
    TResult? Function(EngineEvent_PlaybackFailed value)? playbackFailed,
    TResult? Function(EngineEvent_TokenRefreshRequested value)?
        tokenRefreshRequested,
    TResult? Function(EngineEvent_PlaybackState value)? playbackState,
    TResult? Function(EngineEvent_TrackStarted value)? trackStarted,
    TResult? Function(EngineEvent_TrackEnded value)? trackEnded,
    TResult? Function(EngineEvent_PositionUpdate value)? positionUpdate,
    TResult? Function(EngineEvent_BufferTelemetry value)? bufferTelemetry,
    TResult? Function(EngineEvent_LimiterTelemetry value)? limiterTelemetry,
  }) =>
      throw _privateConstructorUsedError;
  @optionalTypeArgs
  TResult maybeMap<TResult extends Object?>({
    TResult Function(EngineEvent_PlaybackFailed value)? playbackFailed,
    TResult Function(EngineEvent_TokenRefreshRequested value)?
        tokenRefreshRequested,
    TResult Function(EngineEvent_PlaybackState value)? playbackState,
    TResult Function(EngineEvent_TrackStarted value)? trackStarted,
    TResult Function(EngineEvent_TrackEnded value)? trackEnded,
    TResult Function(EngineEvent_PositionUpdate value)? positionUpdate,
    TResult Function(EngineEvent_BufferTelemetry value)? bufferTelemetry,
    TResult Function(EngineEvent_LimiterTelemetry value)? limiterTelemetry,
    required TResult orElse(),
  }) =>
      throw _privateConstructorUsedError;
}

/// @nodoc
abstract class $EngineEventCopyWith<$Res> {
  factory $EngineEventCopyWith(
          EngineEvent value, $Res Function(EngineEvent) then) =
      _$EngineEventCopyWithImpl<$Res, EngineEvent>;
}

/// @nodoc
class _$EngineEventCopyWithImpl<$Res, $Val extends EngineEvent>
    implements $EngineEventCopyWith<$Res> {
  _$EngineEventCopyWithImpl(this._value, this._then);

  // ignore: unused_field
  final $Val _value;
  // ignore: unused_field
  final $Res Function($Val) _then;

  /// Create a copy of EngineEvent
  /// with the given fields replaced by the non-null parameter values.
}

/// @nodoc
abstract class _$$EngineEvent_PlaybackFailedImplCopyWith<$Res> {
  factory _$$EngineEvent_PlaybackFailedImplCopyWith(
          _$EngineEvent_PlaybackFailedImpl value,
          $Res Function(_$EngineEvent_PlaybackFailedImpl) then) =
      __$$EngineEvent_PlaybackFailedImplCopyWithImpl<$Res>;
  @useResult
  $Res call({String fileId, String message});
}

/// @nodoc
class __$$EngineEvent_PlaybackFailedImplCopyWithImpl<$Res>
    extends _$EngineEventCopyWithImpl<$Res, _$EngineEvent_PlaybackFailedImpl>
    implements _$$EngineEvent_PlaybackFailedImplCopyWith<$Res> {
  __$$EngineEvent_PlaybackFailedImplCopyWithImpl(
      _$EngineEvent_PlaybackFailedImpl _value,
      $Res Function(_$EngineEvent_PlaybackFailedImpl) _then)
      : super(_value, _then);

  /// Create a copy of EngineEvent
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? fileId = null,
    Object? message = null,
  }) {
    return _then(_$EngineEvent_PlaybackFailedImpl(
      fileId: null == fileId
          ? _value.fileId
          : fileId // ignore: cast_nullable_to_non_nullable
              as String,
      message: null == message
          ? _value.message
          : message // ignore: cast_nullable_to_non_nullable
              as String,
    ));
  }
}

/// @nodoc

class _$EngineEvent_PlaybackFailedImpl extends EngineEvent_PlaybackFailed {
  const _$EngineEvent_PlaybackFailedImpl(
      {required this.fileId, required this.message})
      : super._();

  @override
  final String fileId;
  @override
  final String message;

  @override
  String toString() {
    return 'EngineEvent.playbackFailed(fileId: $fileId, message: $message)';
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _$EngineEvent_PlaybackFailedImpl &&
            (identical(other.fileId, fileId) || other.fileId == fileId) &&
            (identical(other.message, message) || other.message == message));
  }

  @override
  int get hashCode => Object.hash(runtimeType, fileId, message);

  /// Create a copy of EngineEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  @pragma('vm:prefer-inline')
  _$$EngineEvent_PlaybackFailedImplCopyWith<_$EngineEvent_PlaybackFailedImpl>
      get copyWith => __$$EngineEvent_PlaybackFailedImplCopyWithImpl<
          _$EngineEvent_PlaybackFailedImpl>(this, _$identity);

  @override
  @optionalTypeArgs
  TResult when<TResult extends Object?>({
    required TResult Function(String fileId, String message) playbackFailed,
    required TResult Function(BigInt requestId) tokenRefreshRequested,
    required TResult Function(bool isPlaying, bool isBuffering) playbackState,
    required TResult Function(String fileId) trackStarted,
    required TResult Function(String fileId) trackEnded,
    required TResult Function(int positionMs, int durationMs) positionUpdate,
    required TResult Function(
            int bufferedMs, int fetchesInFlight, BigInt bytesFetched)
        bufferTelemetry,
    required TResult Function(int grMillidb, BigInt clippedSamples)
        limiterTelemetry,
  }) {
    return playbackFailed(fileId, message);
  }

  @override
  @optionalTypeArgs
  TResult? whenOrNull<TResult extends Object?>({
    TResult? Function(String fileId, String message)? playbackFailed,
    TResult? Function(BigInt requestId)? tokenRefreshRequested,
    TResult? Function(bool isPlaying, bool isBuffering)? playbackState,
    TResult? Function(String fileId)? trackStarted,
    TResult? Function(String fileId)? trackEnded,
    TResult? Function(int positionMs, int durationMs)? positionUpdate,
    TResult? Function(int bufferedMs, int fetchesInFlight, BigInt bytesFetched)?
        bufferTelemetry,
    TResult? Function(int grMillidb, BigInt clippedSamples)? limiterTelemetry,
  }) {
    return playbackFailed?.call(fileId, message);
  }

  @override
  @optionalTypeArgs
  TResult maybeWhen<TResult extends Object?>({
    TResult Function(String fileId, String message)? playbackFailed,
    TResult Function(BigInt requestId)? tokenRefreshRequested,
    TResult Function(bool isPlaying, bool isBuffering)? playbackState,
    TResult Function(String fileId)? trackStarted,
    TResult Function(String fileId)? trackEnded,
    TResult Function(int positionMs, int durationMs)? positionUpdate,
    TResult Function(int bufferedMs, int fetchesInFlight, BigInt bytesFetched)?
        bufferTelemetry,
    TResult Function(int grMillidb, BigInt clippedSamples)? limiterTelemetry,
    required TResult orElse(),
  }) {
    if (playbackFailed != null) {
      return playbackFailed(fileId, message);
    }
    return orElse();
  }

  @override
  @optionalTypeArgs
  TResult map<TResult extends Object?>({
    required TResult Function(EngineEvent_PlaybackFailed value) playbackFailed,
    required TResult Function(EngineEvent_TokenRefreshRequested value)
        tokenRefreshRequested,
    required TResult Function(EngineEvent_PlaybackState value) playbackState,
    required TResult Function(EngineEvent_TrackStarted value) trackStarted,
    required TResult Function(EngineEvent_TrackEnded value) trackEnded,
    required TResult Function(EngineEvent_PositionUpdate value) positionUpdate,
    required TResult Function(EngineEvent_BufferTelemetry value)
        bufferTelemetry,
    required TResult Function(EngineEvent_LimiterTelemetry value)
        limiterTelemetry,
  }) {
    return playbackFailed(this);
  }

  @override
  @optionalTypeArgs
  TResult? mapOrNull<TResult extends Object?>({
    TResult? Function(EngineEvent_PlaybackFailed value)? playbackFailed,
    TResult? Function(EngineEvent_TokenRefreshRequested value)?
        tokenRefreshRequested,
    TResult? Function(EngineEvent_PlaybackState value)? playbackState,
    TResult? Function(EngineEvent_TrackStarted value)? trackStarted,
    TResult? Function(EngineEvent_TrackEnded value)? trackEnded,
    TResult? Function(EngineEvent_PositionUpdate value)? positionUpdate,
    TResult? Function(EngineEvent_BufferTelemetry value)? bufferTelemetry,
    TResult? Function(EngineEvent_LimiterTelemetry value)? limiterTelemetry,
  }) {
    return playbackFailed?.call(this);
  }

  @override
  @optionalTypeArgs
  TResult maybeMap<TResult extends Object?>({
    TResult Function(EngineEvent_PlaybackFailed value)? playbackFailed,
    TResult Function(EngineEvent_TokenRefreshRequested value)?
        tokenRefreshRequested,
    TResult Function(EngineEvent_PlaybackState value)? playbackState,
    TResult Function(EngineEvent_TrackStarted value)? trackStarted,
    TResult Function(EngineEvent_TrackEnded value)? trackEnded,
    TResult Function(EngineEvent_PositionUpdate value)? positionUpdate,
    TResult Function(EngineEvent_BufferTelemetry value)? bufferTelemetry,
    TResult Function(EngineEvent_LimiterTelemetry value)? limiterTelemetry,
    required TResult orElse(),
  }) {
    if (playbackFailed != null) {
      return playbackFailed(this);
    }
    return orElse();
  }
}

abstract class EngineEvent_PlaybackFailed extends EngineEvent {
  const factory EngineEvent_PlaybackFailed(
      {required final String fileId,
      required final String message}) = _$EngineEvent_PlaybackFailedImpl;
  const EngineEvent_PlaybackFailed._() : super._();

  String get fileId;
  String get message;

  /// Create a copy of EngineEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  _$$EngineEvent_PlaybackFailedImplCopyWith<_$EngineEvent_PlaybackFailedImpl>
      get copyWith => throw _privateConstructorUsedError;
}

/// @nodoc
abstract class _$$EngineEvent_TokenRefreshRequestedImplCopyWith<$Res> {
  factory _$$EngineEvent_TokenRefreshRequestedImplCopyWith(
          _$EngineEvent_TokenRefreshRequestedImpl value,
          $Res Function(_$EngineEvent_TokenRefreshRequestedImpl) then) =
      __$$EngineEvent_TokenRefreshRequestedImplCopyWithImpl<$Res>;
  @useResult
  $Res call({BigInt requestId});
}

/// @nodoc
class __$$EngineEvent_TokenRefreshRequestedImplCopyWithImpl<$Res>
    extends _$EngineEventCopyWithImpl<$Res,
        _$EngineEvent_TokenRefreshRequestedImpl>
    implements _$$EngineEvent_TokenRefreshRequestedImplCopyWith<$Res> {
  __$$EngineEvent_TokenRefreshRequestedImplCopyWithImpl(
      _$EngineEvent_TokenRefreshRequestedImpl _value,
      $Res Function(_$EngineEvent_TokenRefreshRequestedImpl) _then)
      : super(_value, _then);

  /// Create a copy of EngineEvent
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? requestId = null,
  }) {
    return _then(_$EngineEvent_TokenRefreshRequestedImpl(
      requestId: null == requestId
          ? _value.requestId
          : requestId // ignore: cast_nullable_to_non_nullable
              as BigInt,
    ));
  }
}

/// @nodoc

class _$EngineEvent_TokenRefreshRequestedImpl
    extends EngineEvent_TokenRefreshRequested {
  const _$EngineEvent_TokenRefreshRequestedImpl({required this.requestId})
      : super._();

  @override
  final BigInt requestId;

  @override
  String toString() {
    return 'EngineEvent.tokenRefreshRequested(requestId: $requestId)';
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _$EngineEvent_TokenRefreshRequestedImpl &&
            (identical(other.requestId, requestId) ||
                other.requestId == requestId));
  }

  @override
  int get hashCode => Object.hash(runtimeType, requestId);

  /// Create a copy of EngineEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  @pragma('vm:prefer-inline')
  _$$EngineEvent_TokenRefreshRequestedImplCopyWith<
          _$EngineEvent_TokenRefreshRequestedImpl>
      get copyWith => __$$EngineEvent_TokenRefreshRequestedImplCopyWithImpl<
          _$EngineEvent_TokenRefreshRequestedImpl>(this, _$identity);

  @override
  @optionalTypeArgs
  TResult when<TResult extends Object?>({
    required TResult Function(String fileId, String message) playbackFailed,
    required TResult Function(BigInt requestId) tokenRefreshRequested,
    required TResult Function(bool isPlaying, bool isBuffering) playbackState,
    required TResult Function(String fileId) trackStarted,
    required TResult Function(String fileId) trackEnded,
    required TResult Function(int positionMs, int durationMs) positionUpdate,
    required TResult Function(
            int bufferedMs, int fetchesInFlight, BigInt bytesFetched)
        bufferTelemetry,
    required TResult Function(int grMillidb, BigInt clippedSamples)
        limiterTelemetry,
  }) {
    return tokenRefreshRequested(requestId);
  }

  @override
  @optionalTypeArgs
  TResult? whenOrNull<TResult extends Object?>({
    TResult? Function(String fileId, String message)? playbackFailed,
    TResult? Function(BigInt requestId)? tokenRefreshRequested,
    TResult? Function(bool isPlaying, bool isBuffering)? playbackState,
    TResult? Function(String fileId)? trackStarted,
    TResult? Function(String fileId)? trackEnded,
    TResult? Function(int positionMs, int durationMs)? positionUpdate,
    TResult? Function(int bufferedMs, int fetchesInFlight, BigInt bytesFetched)?
        bufferTelemetry,
    TResult? Function(int grMillidb, BigInt clippedSamples)? limiterTelemetry,
  }) {
    return tokenRefreshRequested?.call(requestId);
  }

  @override
  @optionalTypeArgs
  TResult maybeWhen<TResult extends Object?>({
    TResult Function(String fileId, String message)? playbackFailed,
    TResult Function(BigInt requestId)? tokenRefreshRequested,
    TResult Function(bool isPlaying, bool isBuffering)? playbackState,
    TResult Function(String fileId)? trackStarted,
    TResult Function(String fileId)? trackEnded,
    TResult Function(int positionMs, int durationMs)? positionUpdate,
    TResult Function(int bufferedMs, int fetchesInFlight, BigInt bytesFetched)?
        bufferTelemetry,
    TResult Function(int grMillidb, BigInt clippedSamples)? limiterTelemetry,
    required TResult orElse(),
  }) {
    if (tokenRefreshRequested != null) {
      return tokenRefreshRequested(requestId);
    }
    return orElse();
  }

  @override
  @optionalTypeArgs
  TResult map<TResult extends Object?>({
    required TResult Function(EngineEvent_PlaybackFailed value) playbackFailed,
    required TResult Function(EngineEvent_TokenRefreshRequested value)
        tokenRefreshRequested,
    required TResult Function(EngineEvent_PlaybackState value) playbackState,
    required TResult Function(EngineEvent_TrackStarted value) trackStarted,
    required TResult Function(EngineEvent_TrackEnded value) trackEnded,
    required TResult Function(EngineEvent_PositionUpdate value) positionUpdate,
    required TResult Function(EngineEvent_BufferTelemetry value)
        bufferTelemetry,
    required TResult Function(EngineEvent_LimiterTelemetry value)
        limiterTelemetry,
  }) {
    return tokenRefreshRequested(this);
  }

  @override
  @optionalTypeArgs
  TResult? mapOrNull<TResult extends Object?>({
    TResult? Function(EngineEvent_PlaybackFailed value)? playbackFailed,
    TResult? Function(EngineEvent_TokenRefreshRequested value)?
        tokenRefreshRequested,
    TResult? Function(EngineEvent_PlaybackState value)? playbackState,
    TResult? Function(EngineEvent_TrackStarted value)? trackStarted,
    TResult? Function(EngineEvent_TrackEnded value)? trackEnded,
    TResult? Function(EngineEvent_PositionUpdate value)? positionUpdate,
    TResult? Function(EngineEvent_BufferTelemetry value)? bufferTelemetry,
    TResult? Function(EngineEvent_LimiterTelemetry value)? limiterTelemetry,
  }) {
    return tokenRefreshRequested?.call(this);
  }

  @override
  @optionalTypeArgs
  TResult maybeMap<TResult extends Object?>({
    TResult Function(EngineEvent_PlaybackFailed value)? playbackFailed,
    TResult Function(EngineEvent_TokenRefreshRequested value)?
        tokenRefreshRequested,
    TResult Function(EngineEvent_PlaybackState value)? playbackState,
    TResult Function(EngineEvent_TrackStarted value)? trackStarted,
    TResult Function(EngineEvent_TrackEnded value)? trackEnded,
    TResult Function(EngineEvent_PositionUpdate value)? positionUpdate,
    TResult Function(EngineEvent_BufferTelemetry value)? bufferTelemetry,
    TResult Function(EngineEvent_LimiterTelemetry value)? limiterTelemetry,
    required TResult orElse(),
  }) {
    if (tokenRefreshRequested != null) {
      return tokenRefreshRequested(this);
    }
    return orElse();
  }
}

abstract class EngineEvent_TokenRefreshRequested extends EngineEvent {
  const factory EngineEvent_TokenRefreshRequested(
          {required final BigInt requestId}) =
      _$EngineEvent_TokenRefreshRequestedImpl;
  const EngineEvent_TokenRefreshRequested._() : super._();

  BigInt get requestId;

  /// Create a copy of EngineEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  _$$EngineEvent_TokenRefreshRequestedImplCopyWith<
          _$EngineEvent_TokenRefreshRequestedImpl>
      get copyWith => throw _privateConstructorUsedError;
}

/// @nodoc
abstract class _$$EngineEvent_PlaybackStateImplCopyWith<$Res> {
  factory _$$EngineEvent_PlaybackStateImplCopyWith(
          _$EngineEvent_PlaybackStateImpl value,
          $Res Function(_$EngineEvent_PlaybackStateImpl) then) =
      __$$EngineEvent_PlaybackStateImplCopyWithImpl<$Res>;
  @useResult
  $Res call({bool isPlaying, bool isBuffering});
}

/// @nodoc
class __$$EngineEvent_PlaybackStateImplCopyWithImpl<$Res>
    extends _$EngineEventCopyWithImpl<$Res, _$EngineEvent_PlaybackStateImpl>
    implements _$$EngineEvent_PlaybackStateImplCopyWith<$Res> {
  __$$EngineEvent_PlaybackStateImplCopyWithImpl(
      _$EngineEvent_PlaybackStateImpl _value,
      $Res Function(_$EngineEvent_PlaybackStateImpl) _then)
      : super(_value, _then);

  /// Create a copy of EngineEvent
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? isPlaying = null,
    Object? isBuffering = null,
  }) {
    return _then(_$EngineEvent_PlaybackStateImpl(
      isPlaying: null == isPlaying
          ? _value.isPlaying
          : isPlaying // ignore: cast_nullable_to_non_nullable
              as bool,
      isBuffering: null == isBuffering
          ? _value.isBuffering
          : isBuffering // ignore: cast_nullable_to_non_nullable
              as bool,
    ));
  }
}

/// @nodoc

class _$EngineEvent_PlaybackStateImpl extends EngineEvent_PlaybackState {
  const _$EngineEvent_PlaybackStateImpl(
      {required this.isPlaying, required this.isBuffering})
      : super._();

  @override
  final bool isPlaying;
  @override
  final bool isBuffering;

  @override
  String toString() {
    return 'EngineEvent.playbackState(isPlaying: $isPlaying, isBuffering: $isBuffering)';
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _$EngineEvent_PlaybackStateImpl &&
            (identical(other.isPlaying, isPlaying) ||
                other.isPlaying == isPlaying) &&
            (identical(other.isBuffering, isBuffering) ||
                other.isBuffering == isBuffering));
  }

  @override
  int get hashCode => Object.hash(runtimeType, isPlaying, isBuffering);

  /// Create a copy of EngineEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  @pragma('vm:prefer-inline')
  _$$EngineEvent_PlaybackStateImplCopyWith<_$EngineEvent_PlaybackStateImpl>
      get copyWith => __$$EngineEvent_PlaybackStateImplCopyWithImpl<
          _$EngineEvent_PlaybackStateImpl>(this, _$identity);

  @override
  @optionalTypeArgs
  TResult when<TResult extends Object?>({
    required TResult Function(String fileId, String message) playbackFailed,
    required TResult Function(BigInt requestId) tokenRefreshRequested,
    required TResult Function(bool isPlaying, bool isBuffering) playbackState,
    required TResult Function(String fileId) trackStarted,
    required TResult Function(String fileId) trackEnded,
    required TResult Function(int positionMs, int durationMs) positionUpdate,
    required TResult Function(
            int bufferedMs, int fetchesInFlight, BigInt bytesFetched)
        bufferTelemetry,
    required TResult Function(int grMillidb, BigInt clippedSamples)
        limiterTelemetry,
  }) {
    return playbackState(isPlaying, isBuffering);
  }

  @override
  @optionalTypeArgs
  TResult? whenOrNull<TResult extends Object?>({
    TResult? Function(String fileId, String message)? playbackFailed,
    TResult? Function(BigInt requestId)? tokenRefreshRequested,
    TResult? Function(bool isPlaying, bool isBuffering)? playbackState,
    TResult? Function(String fileId)? trackStarted,
    TResult? Function(String fileId)? trackEnded,
    TResult? Function(int positionMs, int durationMs)? positionUpdate,
    TResult? Function(int bufferedMs, int fetchesInFlight, BigInt bytesFetched)?
        bufferTelemetry,
    TResult? Function(int grMillidb, BigInt clippedSamples)? limiterTelemetry,
  }) {
    return playbackState?.call(isPlaying, isBuffering);
  }

  @override
  @optionalTypeArgs
  TResult maybeWhen<TResult extends Object?>({
    TResult Function(String fileId, String message)? playbackFailed,
    TResult Function(BigInt requestId)? tokenRefreshRequested,
    TResult Function(bool isPlaying, bool isBuffering)? playbackState,
    TResult Function(String fileId)? trackStarted,
    TResult Function(String fileId)? trackEnded,
    TResult Function(int positionMs, int durationMs)? positionUpdate,
    TResult Function(int bufferedMs, int fetchesInFlight, BigInt bytesFetched)?
        bufferTelemetry,
    TResult Function(int grMillidb, BigInt clippedSamples)? limiterTelemetry,
    required TResult orElse(),
  }) {
    if (playbackState != null) {
      return playbackState(isPlaying, isBuffering);
    }
    return orElse();
  }

  @override
  @optionalTypeArgs
  TResult map<TResult extends Object?>({
    required TResult Function(EngineEvent_PlaybackFailed value) playbackFailed,
    required TResult Function(EngineEvent_TokenRefreshRequested value)
        tokenRefreshRequested,
    required TResult Function(EngineEvent_PlaybackState value) playbackState,
    required TResult Function(EngineEvent_TrackStarted value) trackStarted,
    required TResult Function(EngineEvent_TrackEnded value) trackEnded,
    required TResult Function(EngineEvent_PositionUpdate value) positionUpdate,
    required TResult Function(EngineEvent_BufferTelemetry value)
        bufferTelemetry,
    required TResult Function(EngineEvent_LimiterTelemetry value)
        limiterTelemetry,
  }) {
    return playbackState(this);
  }

  @override
  @optionalTypeArgs
  TResult? mapOrNull<TResult extends Object?>({
    TResult? Function(EngineEvent_PlaybackFailed value)? playbackFailed,
    TResult? Function(EngineEvent_TokenRefreshRequested value)?
        tokenRefreshRequested,
    TResult? Function(EngineEvent_PlaybackState value)? playbackState,
    TResult? Function(EngineEvent_TrackStarted value)? trackStarted,
    TResult? Function(EngineEvent_TrackEnded value)? trackEnded,
    TResult? Function(EngineEvent_PositionUpdate value)? positionUpdate,
    TResult? Function(EngineEvent_BufferTelemetry value)? bufferTelemetry,
    TResult? Function(EngineEvent_LimiterTelemetry value)? limiterTelemetry,
  }) {
    return playbackState?.call(this);
  }

  @override
  @optionalTypeArgs
  TResult maybeMap<TResult extends Object?>({
    TResult Function(EngineEvent_PlaybackFailed value)? playbackFailed,
    TResult Function(EngineEvent_TokenRefreshRequested value)?
        tokenRefreshRequested,
    TResult Function(EngineEvent_PlaybackState value)? playbackState,
    TResult Function(EngineEvent_TrackStarted value)? trackStarted,
    TResult Function(EngineEvent_TrackEnded value)? trackEnded,
    TResult Function(EngineEvent_PositionUpdate value)? positionUpdate,
    TResult Function(EngineEvent_BufferTelemetry value)? bufferTelemetry,
    TResult Function(EngineEvent_LimiterTelemetry value)? limiterTelemetry,
    required TResult orElse(),
  }) {
    if (playbackState != null) {
      return playbackState(this);
    }
    return orElse();
  }
}

abstract class EngineEvent_PlaybackState extends EngineEvent {
  const factory EngineEvent_PlaybackState(
      {required final bool isPlaying,
      required final bool isBuffering}) = _$EngineEvent_PlaybackStateImpl;
  const EngineEvent_PlaybackState._() : super._();

  bool get isPlaying;
  bool get isBuffering;

  /// Create a copy of EngineEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  _$$EngineEvent_PlaybackStateImplCopyWith<_$EngineEvent_PlaybackStateImpl>
      get copyWith => throw _privateConstructorUsedError;
}

/// @nodoc
abstract class _$$EngineEvent_TrackStartedImplCopyWith<$Res> {
  factory _$$EngineEvent_TrackStartedImplCopyWith(
          _$EngineEvent_TrackStartedImpl value,
          $Res Function(_$EngineEvent_TrackStartedImpl) then) =
      __$$EngineEvent_TrackStartedImplCopyWithImpl<$Res>;
  @useResult
  $Res call({String fileId});
}

/// @nodoc
class __$$EngineEvent_TrackStartedImplCopyWithImpl<$Res>
    extends _$EngineEventCopyWithImpl<$Res, _$EngineEvent_TrackStartedImpl>
    implements _$$EngineEvent_TrackStartedImplCopyWith<$Res> {
  __$$EngineEvent_TrackStartedImplCopyWithImpl(
      _$EngineEvent_TrackStartedImpl _value,
      $Res Function(_$EngineEvent_TrackStartedImpl) _then)
      : super(_value, _then);

  /// Create a copy of EngineEvent
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? fileId = null,
  }) {
    return _then(_$EngineEvent_TrackStartedImpl(
      fileId: null == fileId
          ? _value.fileId
          : fileId // ignore: cast_nullable_to_non_nullable
              as String,
    ));
  }
}

/// @nodoc

class _$EngineEvent_TrackStartedImpl extends EngineEvent_TrackStarted {
  const _$EngineEvent_TrackStartedImpl({required this.fileId}) : super._();

  @override
  final String fileId;

  @override
  String toString() {
    return 'EngineEvent.trackStarted(fileId: $fileId)';
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _$EngineEvent_TrackStartedImpl &&
            (identical(other.fileId, fileId) || other.fileId == fileId));
  }

  @override
  int get hashCode => Object.hash(runtimeType, fileId);

  /// Create a copy of EngineEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  @pragma('vm:prefer-inline')
  _$$EngineEvent_TrackStartedImplCopyWith<_$EngineEvent_TrackStartedImpl>
      get copyWith => __$$EngineEvent_TrackStartedImplCopyWithImpl<
          _$EngineEvent_TrackStartedImpl>(this, _$identity);

  @override
  @optionalTypeArgs
  TResult when<TResult extends Object?>({
    required TResult Function(String fileId, String message) playbackFailed,
    required TResult Function(BigInt requestId) tokenRefreshRequested,
    required TResult Function(bool isPlaying, bool isBuffering) playbackState,
    required TResult Function(String fileId) trackStarted,
    required TResult Function(String fileId) trackEnded,
    required TResult Function(int positionMs, int durationMs) positionUpdate,
    required TResult Function(
            int bufferedMs, int fetchesInFlight, BigInt bytesFetched)
        bufferTelemetry,
    required TResult Function(int grMillidb, BigInt clippedSamples)
        limiterTelemetry,
  }) {
    return trackStarted(fileId);
  }

  @override
  @optionalTypeArgs
  TResult? whenOrNull<TResult extends Object?>({
    TResult? Function(String fileId, String message)? playbackFailed,
    TResult? Function(BigInt requestId)? tokenRefreshRequested,
    TResult? Function(bool isPlaying, bool isBuffering)? playbackState,
    TResult? Function(String fileId)? trackStarted,
    TResult? Function(String fileId)? trackEnded,
    TResult? Function(int positionMs, int durationMs)? positionUpdate,
    TResult? Function(int bufferedMs, int fetchesInFlight, BigInt bytesFetched)?
        bufferTelemetry,
    TResult? Function(int grMillidb, BigInt clippedSamples)? limiterTelemetry,
  }) {
    return trackStarted?.call(fileId);
  }

  @override
  @optionalTypeArgs
  TResult maybeWhen<TResult extends Object?>({
    TResult Function(String fileId, String message)? playbackFailed,
    TResult Function(BigInt requestId)? tokenRefreshRequested,
    TResult Function(bool isPlaying, bool isBuffering)? playbackState,
    TResult Function(String fileId)? trackStarted,
    TResult Function(String fileId)? trackEnded,
    TResult Function(int positionMs, int durationMs)? positionUpdate,
    TResult Function(int bufferedMs, int fetchesInFlight, BigInt bytesFetched)?
        bufferTelemetry,
    TResult Function(int grMillidb, BigInt clippedSamples)? limiterTelemetry,
    required TResult orElse(),
  }) {
    if (trackStarted != null) {
      return trackStarted(fileId);
    }
    return orElse();
  }

  @override
  @optionalTypeArgs
  TResult map<TResult extends Object?>({
    required TResult Function(EngineEvent_PlaybackFailed value) playbackFailed,
    required TResult Function(EngineEvent_TokenRefreshRequested value)
        tokenRefreshRequested,
    required TResult Function(EngineEvent_PlaybackState value) playbackState,
    required TResult Function(EngineEvent_TrackStarted value) trackStarted,
    required TResult Function(EngineEvent_TrackEnded value) trackEnded,
    required TResult Function(EngineEvent_PositionUpdate value) positionUpdate,
    required TResult Function(EngineEvent_BufferTelemetry value)
        bufferTelemetry,
    required TResult Function(EngineEvent_LimiterTelemetry value)
        limiterTelemetry,
  }) {
    return trackStarted(this);
  }

  @override
  @optionalTypeArgs
  TResult? mapOrNull<TResult extends Object?>({
    TResult? Function(EngineEvent_PlaybackFailed value)? playbackFailed,
    TResult? Function(EngineEvent_TokenRefreshRequested value)?
        tokenRefreshRequested,
    TResult? Function(EngineEvent_PlaybackState value)? playbackState,
    TResult? Function(EngineEvent_TrackStarted value)? trackStarted,
    TResult? Function(EngineEvent_TrackEnded value)? trackEnded,
    TResult? Function(EngineEvent_PositionUpdate value)? positionUpdate,
    TResult? Function(EngineEvent_BufferTelemetry value)? bufferTelemetry,
    TResult? Function(EngineEvent_LimiterTelemetry value)? limiterTelemetry,
  }) {
    return trackStarted?.call(this);
  }

  @override
  @optionalTypeArgs
  TResult maybeMap<TResult extends Object?>({
    TResult Function(EngineEvent_PlaybackFailed value)? playbackFailed,
    TResult Function(EngineEvent_TokenRefreshRequested value)?
        tokenRefreshRequested,
    TResult Function(EngineEvent_PlaybackState value)? playbackState,
    TResult Function(EngineEvent_TrackStarted value)? trackStarted,
    TResult Function(EngineEvent_TrackEnded value)? trackEnded,
    TResult Function(EngineEvent_PositionUpdate value)? positionUpdate,
    TResult Function(EngineEvent_BufferTelemetry value)? bufferTelemetry,
    TResult Function(EngineEvent_LimiterTelemetry value)? limiterTelemetry,
    required TResult orElse(),
  }) {
    if (trackStarted != null) {
      return trackStarted(this);
    }
    return orElse();
  }
}

abstract class EngineEvent_TrackStarted extends EngineEvent {
  const factory EngineEvent_TrackStarted({required final String fileId}) =
      _$EngineEvent_TrackStartedImpl;
  const EngineEvent_TrackStarted._() : super._();

  String get fileId;

  /// Create a copy of EngineEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  _$$EngineEvent_TrackStartedImplCopyWith<_$EngineEvent_TrackStartedImpl>
      get copyWith => throw _privateConstructorUsedError;
}

/// @nodoc
abstract class _$$EngineEvent_TrackEndedImplCopyWith<$Res> {
  factory _$$EngineEvent_TrackEndedImplCopyWith(
          _$EngineEvent_TrackEndedImpl value,
          $Res Function(_$EngineEvent_TrackEndedImpl) then) =
      __$$EngineEvent_TrackEndedImplCopyWithImpl<$Res>;
  @useResult
  $Res call({String fileId});
}

/// @nodoc
class __$$EngineEvent_TrackEndedImplCopyWithImpl<$Res>
    extends _$EngineEventCopyWithImpl<$Res, _$EngineEvent_TrackEndedImpl>
    implements _$$EngineEvent_TrackEndedImplCopyWith<$Res> {
  __$$EngineEvent_TrackEndedImplCopyWithImpl(
      _$EngineEvent_TrackEndedImpl _value,
      $Res Function(_$EngineEvent_TrackEndedImpl) _then)
      : super(_value, _then);

  /// Create a copy of EngineEvent
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? fileId = null,
  }) {
    return _then(_$EngineEvent_TrackEndedImpl(
      fileId: null == fileId
          ? _value.fileId
          : fileId // ignore: cast_nullable_to_non_nullable
              as String,
    ));
  }
}

/// @nodoc

class _$EngineEvent_TrackEndedImpl extends EngineEvent_TrackEnded {
  const _$EngineEvent_TrackEndedImpl({required this.fileId}) : super._();

  @override
  final String fileId;

  @override
  String toString() {
    return 'EngineEvent.trackEnded(fileId: $fileId)';
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _$EngineEvent_TrackEndedImpl &&
            (identical(other.fileId, fileId) || other.fileId == fileId));
  }

  @override
  int get hashCode => Object.hash(runtimeType, fileId);

  /// Create a copy of EngineEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  @pragma('vm:prefer-inline')
  _$$EngineEvent_TrackEndedImplCopyWith<_$EngineEvent_TrackEndedImpl>
      get copyWith => __$$EngineEvent_TrackEndedImplCopyWithImpl<
          _$EngineEvent_TrackEndedImpl>(this, _$identity);

  @override
  @optionalTypeArgs
  TResult when<TResult extends Object?>({
    required TResult Function(String fileId, String message) playbackFailed,
    required TResult Function(BigInt requestId) tokenRefreshRequested,
    required TResult Function(bool isPlaying, bool isBuffering) playbackState,
    required TResult Function(String fileId) trackStarted,
    required TResult Function(String fileId) trackEnded,
    required TResult Function(int positionMs, int durationMs) positionUpdate,
    required TResult Function(
            int bufferedMs, int fetchesInFlight, BigInt bytesFetched)
        bufferTelemetry,
    required TResult Function(int grMillidb, BigInt clippedSamples)
        limiterTelemetry,
  }) {
    return trackEnded(fileId);
  }

  @override
  @optionalTypeArgs
  TResult? whenOrNull<TResult extends Object?>({
    TResult? Function(String fileId, String message)? playbackFailed,
    TResult? Function(BigInt requestId)? tokenRefreshRequested,
    TResult? Function(bool isPlaying, bool isBuffering)? playbackState,
    TResult? Function(String fileId)? trackStarted,
    TResult? Function(String fileId)? trackEnded,
    TResult? Function(int positionMs, int durationMs)? positionUpdate,
    TResult? Function(int bufferedMs, int fetchesInFlight, BigInt bytesFetched)?
        bufferTelemetry,
    TResult? Function(int grMillidb, BigInt clippedSamples)? limiterTelemetry,
  }) {
    return trackEnded?.call(fileId);
  }

  @override
  @optionalTypeArgs
  TResult maybeWhen<TResult extends Object?>({
    TResult Function(String fileId, String message)? playbackFailed,
    TResult Function(BigInt requestId)? tokenRefreshRequested,
    TResult Function(bool isPlaying, bool isBuffering)? playbackState,
    TResult Function(String fileId)? trackStarted,
    TResult Function(String fileId)? trackEnded,
    TResult Function(int positionMs, int durationMs)? positionUpdate,
    TResult Function(int bufferedMs, int fetchesInFlight, BigInt bytesFetched)?
        bufferTelemetry,
    TResult Function(int grMillidb, BigInt clippedSamples)? limiterTelemetry,
    required TResult orElse(),
  }) {
    if (trackEnded != null) {
      return trackEnded(fileId);
    }
    return orElse();
  }

  @override
  @optionalTypeArgs
  TResult map<TResult extends Object?>({
    required TResult Function(EngineEvent_PlaybackFailed value) playbackFailed,
    required TResult Function(EngineEvent_TokenRefreshRequested value)
        tokenRefreshRequested,
    required TResult Function(EngineEvent_PlaybackState value) playbackState,
    required TResult Function(EngineEvent_TrackStarted value) trackStarted,
    required TResult Function(EngineEvent_TrackEnded value) trackEnded,
    required TResult Function(EngineEvent_PositionUpdate value) positionUpdate,
    required TResult Function(EngineEvent_BufferTelemetry value)
        bufferTelemetry,
    required TResult Function(EngineEvent_LimiterTelemetry value)
        limiterTelemetry,
  }) {
    return trackEnded(this);
  }

  @override
  @optionalTypeArgs
  TResult? mapOrNull<TResult extends Object?>({
    TResult? Function(EngineEvent_PlaybackFailed value)? playbackFailed,
    TResult? Function(EngineEvent_TokenRefreshRequested value)?
        tokenRefreshRequested,
    TResult? Function(EngineEvent_PlaybackState value)? playbackState,
    TResult? Function(EngineEvent_TrackStarted value)? trackStarted,
    TResult? Function(EngineEvent_TrackEnded value)? trackEnded,
    TResult? Function(EngineEvent_PositionUpdate value)? positionUpdate,
    TResult? Function(EngineEvent_BufferTelemetry value)? bufferTelemetry,
    TResult? Function(EngineEvent_LimiterTelemetry value)? limiterTelemetry,
  }) {
    return trackEnded?.call(this);
  }

  @override
  @optionalTypeArgs
  TResult maybeMap<TResult extends Object?>({
    TResult Function(EngineEvent_PlaybackFailed value)? playbackFailed,
    TResult Function(EngineEvent_TokenRefreshRequested value)?
        tokenRefreshRequested,
    TResult Function(EngineEvent_PlaybackState value)? playbackState,
    TResult Function(EngineEvent_TrackStarted value)? trackStarted,
    TResult Function(EngineEvent_TrackEnded value)? trackEnded,
    TResult Function(EngineEvent_PositionUpdate value)? positionUpdate,
    TResult Function(EngineEvent_BufferTelemetry value)? bufferTelemetry,
    TResult Function(EngineEvent_LimiterTelemetry value)? limiterTelemetry,
    required TResult orElse(),
  }) {
    if (trackEnded != null) {
      return trackEnded(this);
    }
    return orElse();
  }
}

abstract class EngineEvent_TrackEnded extends EngineEvent {
  const factory EngineEvent_TrackEnded({required final String fileId}) =
      _$EngineEvent_TrackEndedImpl;
  const EngineEvent_TrackEnded._() : super._();

  String get fileId;

  /// Create a copy of EngineEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  _$$EngineEvent_TrackEndedImplCopyWith<_$EngineEvent_TrackEndedImpl>
      get copyWith => throw _privateConstructorUsedError;
}

/// @nodoc
abstract class _$$EngineEvent_PositionUpdateImplCopyWith<$Res> {
  factory _$$EngineEvent_PositionUpdateImplCopyWith(
          _$EngineEvent_PositionUpdateImpl value,
          $Res Function(_$EngineEvent_PositionUpdateImpl) then) =
      __$$EngineEvent_PositionUpdateImplCopyWithImpl<$Res>;
  @useResult
  $Res call({int positionMs, int durationMs});
}

/// @nodoc
class __$$EngineEvent_PositionUpdateImplCopyWithImpl<$Res>
    extends _$EngineEventCopyWithImpl<$Res, _$EngineEvent_PositionUpdateImpl>
    implements _$$EngineEvent_PositionUpdateImplCopyWith<$Res> {
  __$$EngineEvent_PositionUpdateImplCopyWithImpl(
      _$EngineEvent_PositionUpdateImpl _value,
      $Res Function(_$EngineEvent_PositionUpdateImpl) _then)
      : super(_value, _then);

  /// Create a copy of EngineEvent
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? positionMs = null,
    Object? durationMs = null,
  }) {
    return _then(_$EngineEvent_PositionUpdateImpl(
      positionMs: null == positionMs
          ? _value.positionMs
          : positionMs // ignore: cast_nullable_to_non_nullable
              as int,
      durationMs: null == durationMs
          ? _value.durationMs
          : durationMs // ignore: cast_nullable_to_non_nullable
              as int,
    ));
  }
}

/// @nodoc

class _$EngineEvent_PositionUpdateImpl extends EngineEvent_PositionUpdate {
  const _$EngineEvent_PositionUpdateImpl(
      {required this.positionMs, required this.durationMs})
      : super._();

  @override
  final int positionMs;
  @override
  final int durationMs;

  @override
  String toString() {
    return 'EngineEvent.positionUpdate(positionMs: $positionMs, durationMs: $durationMs)';
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _$EngineEvent_PositionUpdateImpl &&
            (identical(other.positionMs, positionMs) ||
                other.positionMs == positionMs) &&
            (identical(other.durationMs, durationMs) ||
                other.durationMs == durationMs));
  }

  @override
  int get hashCode => Object.hash(runtimeType, positionMs, durationMs);

  /// Create a copy of EngineEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  @pragma('vm:prefer-inline')
  _$$EngineEvent_PositionUpdateImplCopyWith<_$EngineEvent_PositionUpdateImpl>
      get copyWith => __$$EngineEvent_PositionUpdateImplCopyWithImpl<
          _$EngineEvent_PositionUpdateImpl>(this, _$identity);

  @override
  @optionalTypeArgs
  TResult when<TResult extends Object?>({
    required TResult Function(String fileId, String message) playbackFailed,
    required TResult Function(BigInt requestId) tokenRefreshRequested,
    required TResult Function(bool isPlaying, bool isBuffering) playbackState,
    required TResult Function(String fileId) trackStarted,
    required TResult Function(String fileId) trackEnded,
    required TResult Function(int positionMs, int durationMs) positionUpdate,
    required TResult Function(
            int bufferedMs, int fetchesInFlight, BigInt bytesFetched)
        bufferTelemetry,
    required TResult Function(int grMillidb, BigInt clippedSamples)
        limiterTelemetry,
  }) {
    return positionUpdate(positionMs, durationMs);
  }

  @override
  @optionalTypeArgs
  TResult? whenOrNull<TResult extends Object?>({
    TResult? Function(String fileId, String message)? playbackFailed,
    TResult? Function(BigInt requestId)? tokenRefreshRequested,
    TResult? Function(bool isPlaying, bool isBuffering)? playbackState,
    TResult? Function(String fileId)? trackStarted,
    TResult? Function(String fileId)? trackEnded,
    TResult? Function(int positionMs, int durationMs)? positionUpdate,
    TResult? Function(int bufferedMs, int fetchesInFlight, BigInt bytesFetched)?
        bufferTelemetry,
    TResult? Function(int grMillidb, BigInt clippedSamples)? limiterTelemetry,
  }) {
    return positionUpdate?.call(positionMs, durationMs);
  }

  @override
  @optionalTypeArgs
  TResult maybeWhen<TResult extends Object?>({
    TResult Function(String fileId, String message)? playbackFailed,
    TResult Function(BigInt requestId)? tokenRefreshRequested,
    TResult Function(bool isPlaying, bool isBuffering)? playbackState,
    TResult Function(String fileId)? trackStarted,
    TResult Function(String fileId)? trackEnded,
    TResult Function(int positionMs, int durationMs)? positionUpdate,
    TResult Function(int bufferedMs, int fetchesInFlight, BigInt bytesFetched)?
        bufferTelemetry,
    TResult Function(int grMillidb, BigInt clippedSamples)? limiterTelemetry,
    required TResult orElse(),
  }) {
    if (positionUpdate != null) {
      return positionUpdate(positionMs, durationMs);
    }
    return orElse();
  }

  @override
  @optionalTypeArgs
  TResult map<TResult extends Object?>({
    required TResult Function(EngineEvent_PlaybackFailed value) playbackFailed,
    required TResult Function(EngineEvent_TokenRefreshRequested value)
        tokenRefreshRequested,
    required TResult Function(EngineEvent_PlaybackState value) playbackState,
    required TResult Function(EngineEvent_TrackStarted value) trackStarted,
    required TResult Function(EngineEvent_TrackEnded value) trackEnded,
    required TResult Function(EngineEvent_PositionUpdate value) positionUpdate,
    required TResult Function(EngineEvent_BufferTelemetry value)
        bufferTelemetry,
    required TResult Function(EngineEvent_LimiterTelemetry value)
        limiterTelemetry,
  }) {
    return positionUpdate(this);
  }

  @override
  @optionalTypeArgs
  TResult? mapOrNull<TResult extends Object?>({
    TResult? Function(EngineEvent_PlaybackFailed value)? playbackFailed,
    TResult? Function(EngineEvent_TokenRefreshRequested value)?
        tokenRefreshRequested,
    TResult? Function(EngineEvent_PlaybackState value)? playbackState,
    TResult? Function(EngineEvent_TrackStarted value)? trackStarted,
    TResult? Function(EngineEvent_TrackEnded value)? trackEnded,
    TResult? Function(EngineEvent_PositionUpdate value)? positionUpdate,
    TResult? Function(EngineEvent_BufferTelemetry value)? bufferTelemetry,
    TResult? Function(EngineEvent_LimiterTelemetry value)? limiterTelemetry,
  }) {
    return positionUpdate?.call(this);
  }

  @override
  @optionalTypeArgs
  TResult maybeMap<TResult extends Object?>({
    TResult Function(EngineEvent_PlaybackFailed value)? playbackFailed,
    TResult Function(EngineEvent_TokenRefreshRequested value)?
        tokenRefreshRequested,
    TResult Function(EngineEvent_PlaybackState value)? playbackState,
    TResult Function(EngineEvent_TrackStarted value)? trackStarted,
    TResult Function(EngineEvent_TrackEnded value)? trackEnded,
    TResult Function(EngineEvent_PositionUpdate value)? positionUpdate,
    TResult Function(EngineEvent_BufferTelemetry value)? bufferTelemetry,
    TResult Function(EngineEvent_LimiterTelemetry value)? limiterTelemetry,
    required TResult orElse(),
  }) {
    if (positionUpdate != null) {
      return positionUpdate(this);
    }
    return orElse();
  }
}

abstract class EngineEvent_PositionUpdate extends EngineEvent {
  const factory EngineEvent_PositionUpdate(
      {required final int positionMs,
      required final int durationMs}) = _$EngineEvent_PositionUpdateImpl;
  const EngineEvent_PositionUpdate._() : super._();

  int get positionMs;
  int get durationMs;

  /// Create a copy of EngineEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  _$$EngineEvent_PositionUpdateImplCopyWith<_$EngineEvent_PositionUpdateImpl>
      get copyWith => throw _privateConstructorUsedError;
}

/// @nodoc
abstract class _$$EngineEvent_BufferTelemetryImplCopyWith<$Res> {
  factory _$$EngineEvent_BufferTelemetryImplCopyWith(
          _$EngineEvent_BufferTelemetryImpl value,
          $Res Function(_$EngineEvent_BufferTelemetryImpl) then) =
      __$$EngineEvent_BufferTelemetryImplCopyWithImpl<$Res>;
  @useResult
  $Res call({int bufferedMs, int fetchesInFlight, BigInt bytesFetched});
}

/// @nodoc
class __$$EngineEvent_BufferTelemetryImplCopyWithImpl<$Res>
    extends _$EngineEventCopyWithImpl<$Res, _$EngineEvent_BufferTelemetryImpl>
    implements _$$EngineEvent_BufferTelemetryImplCopyWith<$Res> {
  __$$EngineEvent_BufferTelemetryImplCopyWithImpl(
      _$EngineEvent_BufferTelemetryImpl _value,
      $Res Function(_$EngineEvent_BufferTelemetryImpl) _then)
      : super(_value, _then);

  /// Create a copy of EngineEvent
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? bufferedMs = null,
    Object? fetchesInFlight = null,
    Object? bytesFetched = null,
  }) {
    return _then(_$EngineEvent_BufferTelemetryImpl(
      bufferedMs: null == bufferedMs
          ? _value.bufferedMs
          : bufferedMs // ignore: cast_nullable_to_non_nullable
              as int,
      fetchesInFlight: null == fetchesInFlight
          ? _value.fetchesInFlight
          : fetchesInFlight // ignore: cast_nullable_to_non_nullable
              as int,
      bytesFetched: null == bytesFetched
          ? _value.bytesFetched
          : bytesFetched // ignore: cast_nullable_to_non_nullable
              as BigInt,
    ));
  }
}

/// @nodoc

class _$EngineEvent_BufferTelemetryImpl extends EngineEvent_BufferTelemetry {
  const _$EngineEvent_BufferTelemetryImpl(
      {required this.bufferedMs,
      required this.fetchesInFlight,
      required this.bytesFetched})
      : super._();

  @override
  final int bufferedMs;
  @override
  final int fetchesInFlight;
  @override
  final BigInt bytesFetched;

  @override
  String toString() {
    return 'EngineEvent.bufferTelemetry(bufferedMs: $bufferedMs, fetchesInFlight: $fetchesInFlight, bytesFetched: $bytesFetched)';
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _$EngineEvent_BufferTelemetryImpl &&
            (identical(other.bufferedMs, bufferedMs) ||
                other.bufferedMs == bufferedMs) &&
            (identical(other.fetchesInFlight, fetchesInFlight) ||
                other.fetchesInFlight == fetchesInFlight) &&
            (identical(other.bytesFetched, bytesFetched) ||
                other.bytesFetched == bytesFetched));
  }

  @override
  int get hashCode =>
      Object.hash(runtimeType, bufferedMs, fetchesInFlight, bytesFetched);

  /// Create a copy of EngineEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  @pragma('vm:prefer-inline')
  _$$EngineEvent_BufferTelemetryImplCopyWith<_$EngineEvent_BufferTelemetryImpl>
      get copyWith => __$$EngineEvent_BufferTelemetryImplCopyWithImpl<
          _$EngineEvent_BufferTelemetryImpl>(this, _$identity);

  @override
  @optionalTypeArgs
  TResult when<TResult extends Object?>({
    required TResult Function(String fileId, String message) playbackFailed,
    required TResult Function(BigInt requestId) tokenRefreshRequested,
    required TResult Function(bool isPlaying, bool isBuffering) playbackState,
    required TResult Function(String fileId) trackStarted,
    required TResult Function(String fileId) trackEnded,
    required TResult Function(int positionMs, int durationMs) positionUpdate,
    required TResult Function(
            int bufferedMs, int fetchesInFlight, BigInt bytesFetched)
        bufferTelemetry,
    required TResult Function(int grMillidb, BigInt clippedSamples)
        limiterTelemetry,
  }) {
    return bufferTelemetry(bufferedMs, fetchesInFlight, bytesFetched);
  }

  @override
  @optionalTypeArgs
  TResult? whenOrNull<TResult extends Object?>({
    TResult? Function(String fileId, String message)? playbackFailed,
    TResult? Function(BigInt requestId)? tokenRefreshRequested,
    TResult? Function(bool isPlaying, bool isBuffering)? playbackState,
    TResult? Function(String fileId)? trackStarted,
    TResult? Function(String fileId)? trackEnded,
    TResult? Function(int positionMs, int durationMs)? positionUpdate,
    TResult? Function(int bufferedMs, int fetchesInFlight, BigInt bytesFetched)?
        bufferTelemetry,
    TResult? Function(int grMillidb, BigInt clippedSamples)? limiterTelemetry,
  }) {
    return bufferTelemetry?.call(bufferedMs, fetchesInFlight, bytesFetched);
  }

  @override
  @optionalTypeArgs
  TResult maybeWhen<TResult extends Object?>({
    TResult Function(String fileId, String message)? playbackFailed,
    TResult Function(BigInt requestId)? tokenRefreshRequested,
    TResult Function(bool isPlaying, bool isBuffering)? playbackState,
    TResult Function(String fileId)? trackStarted,
    TResult Function(String fileId)? trackEnded,
    TResult Function(int positionMs, int durationMs)? positionUpdate,
    TResult Function(int bufferedMs, int fetchesInFlight, BigInt bytesFetched)?
        bufferTelemetry,
    TResult Function(int grMillidb, BigInt clippedSamples)? limiterTelemetry,
    required TResult orElse(),
  }) {
    if (bufferTelemetry != null) {
      return bufferTelemetry(bufferedMs, fetchesInFlight, bytesFetched);
    }
    return orElse();
  }

  @override
  @optionalTypeArgs
  TResult map<TResult extends Object?>({
    required TResult Function(EngineEvent_PlaybackFailed value) playbackFailed,
    required TResult Function(EngineEvent_TokenRefreshRequested value)
        tokenRefreshRequested,
    required TResult Function(EngineEvent_PlaybackState value) playbackState,
    required TResult Function(EngineEvent_TrackStarted value) trackStarted,
    required TResult Function(EngineEvent_TrackEnded value) trackEnded,
    required TResult Function(EngineEvent_PositionUpdate value) positionUpdate,
    required TResult Function(EngineEvent_BufferTelemetry value)
        bufferTelemetry,
    required TResult Function(EngineEvent_LimiterTelemetry value)
        limiterTelemetry,
  }) {
    return bufferTelemetry(this);
  }

  @override
  @optionalTypeArgs
  TResult? mapOrNull<TResult extends Object?>({
    TResult? Function(EngineEvent_PlaybackFailed value)? playbackFailed,
    TResult? Function(EngineEvent_TokenRefreshRequested value)?
        tokenRefreshRequested,
    TResult? Function(EngineEvent_PlaybackState value)? playbackState,
    TResult? Function(EngineEvent_TrackStarted value)? trackStarted,
    TResult? Function(EngineEvent_TrackEnded value)? trackEnded,
    TResult? Function(EngineEvent_PositionUpdate value)? positionUpdate,
    TResult? Function(EngineEvent_BufferTelemetry value)? bufferTelemetry,
    TResult? Function(EngineEvent_LimiterTelemetry value)? limiterTelemetry,
  }) {
    return bufferTelemetry?.call(this);
  }

  @override
  @optionalTypeArgs
  TResult maybeMap<TResult extends Object?>({
    TResult Function(EngineEvent_PlaybackFailed value)? playbackFailed,
    TResult Function(EngineEvent_TokenRefreshRequested value)?
        tokenRefreshRequested,
    TResult Function(EngineEvent_PlaybackState value)? playbackState,
    TResult Function(EngineEvent_TrackStarted value)? trackStarted,
    TResult Function(EngineEvent_TrackEnded value)? trackEnded,
    TResult Function(EngineEvent_PositionUpdate value)? positionUpdate,
    TResult Function(EngineEvent_BufferTelemetry value)? bufferTelemetry,
    TResult Function(EngineEvent_LimiterTelemetry value)? limiterTelemetry,
    required TResult orElse(),
  }) {
    if (bufferTelemetry != null) {
      return bufferTelemetry(this);
    }
    return orElse();
  }
}

abstract class EngineEvent_BufferTelemetry extends EngineEvent {
  const factory EngineEvent_BufferTelemetry(
      {required final int bufferedMs,
      required final int fetchesInFlight,
      required final BigInt bytesFetched}) = _$EngineEvent_BufferTelemetryImpl;
  const EngineEvent_BufferTelemetry._() : super._();

  int get bufferedMs;
  int get fetchesInFlight;
  BigInt get bytesFetched;

  /// Create a copy of EngineEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  _$$EngineEvent_BufferTelemetryImplCopyWith<_$EngineEvent_BufferTelemetryImpl>
      get copyWith => throw _privateConstructorUsedError;
}

/// @nodoc
abstract class _$$EngineEvent_LimiterTelemetryImplCopyWith<$Res> {
  factory _$$EngineEvent_LimiterTelemetryImplCopyWith(
          _$EngineEvent_LimiterTelemetryImpl value,
          $Res Function(_$EngineEvent_LimiterTelemetryImpl) then) =
      __$$EngineEvent_LimiterTelemetryImplCopyWithImpl<$Res>;
  @useResult
  $Res call({int grMillidb, BigInt clippedSamples});
}

/// @nodoc
class __$$EngineEvent_LimiterTelemetryImplCopyWithImpl<$Res>
    extends _$EngineEventCopyWithImpl<$Res, _$EngineEvent_LimiterTelemetryImpl>
    implements _$$EngineEvent_LimiterTelemetryImplCopyWith<$Res> {
  __$$EngineEvent_LimiterTelemetryImplCopyWithImpl(
      _$EngineEvent_LimiterTelemetryImpl _value,
      $Res Function(_$EngineEvent_LimiterTelemetryImpl) _then)
      : super(_value, _then);

  /// Create a copy of EngineEvent
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? grMillidb = null,
    Object? clippedSamples = null,
  }) {
    return _then(_$EngineEvent_LimiterTelemetryImpl(
      grMillidb: null == grMillidb
          ? _value.grMillidb
          : grMillidb // ignore: cast_nullable_to_non_nullable
              as int,
      clippedSamples: null == clippedSamples
          ? _value.clippedSamples
          : clippedSamples // ignore: cast_nullable_to_non_nullable
              as BigInt,
    ));
  }
}

/// @nodoc

class _$EngineEvent_LimiterTelemetryImpl extends EngineEvent_LimiterTelemetry {
  const _$EngineEvent_LimiterTelemetryImpl(
      {required this.grMillidb, required this.clippedSamples})
      : super._();

  @override
  final int grMillidb;
  @override
  final BigInt clippedSamples;

  @override
  String toString() {
    return 'EngineEvent.limiterTelemetry(grMillidb: $grMillidb, clippedSamples: $clippedSamples)';
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _$EngineEvent_LimiterTelemetryImpl &&
            (identical(other.grMillidb, grMillidb) ||
                other.grMillidb == grMillidb) &&
            (identical(other.clippedSamples, clippedSamples) ||
                other.clippedSamples == clippedSamples));
  }

  @override
  int get hashCode => Object.hash(runtimeType, grMillidb, clippedSamples);

  /// Create a copy of EngineEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  @pragma('vm:prefer-inline')
  _$$EngineEvent_LimiterTelemetryImplCopyWith<
          _$EngineEvent_LimiterTelemetryImpl>
      get copyWith => __$$EngineEvent_LimiterTelemetryImplCopyWithImpl<
          _$EngineEvent_LimiterTelemetryImpl>(this, _$identity);

  @override
  @optionalTypeArgs
  TResult when<TResult extends Object?>({
    required TResult Function(String fileId, String message) playbackFailed,
    required TResult Function(BigInt requestId) tokenRefreshRequested,
    required TResult Function(bool isPlaying, bool isBuffering) playbackState,
    required TResult Function(String fileId) trackStarted,
    required TResult Function(String fileId) trackEnded,
    required TResult Function(int positionMs, int durationMs) positionUpdate,
    required TResult Function(
            int bufferedMs, int fetchesInFlight, BigInt bytesFetched)
        bufferTelemetry,
    required TResult Function(int grMillidb, BigInt clippedSamples)
        limiterTelemetry,
  }) {
    return limiterTelemetry(grMillidb, clippedSamples);
  }

  @override
  @optionalTypeArgs
  TResult? whenOrNull<TResult extends Object?>({
    TResult? Function(String fileId, String message)? playbackFailed,
    TResult? Function(BigInt requestId)? tokenRefreshRequested,
    TResult? Function(bool isPlaying, bool isBuffering)? playbackState,
    TResult? Function(String fileId)? trackStarted,
    TResult? Function(String fileId)? trackEnded,
    TResult? Function(int positionMs, int durationMs)? positionUpdate,
    TResult? Function(int bufferedMs, int fetchesInFlight, BigInt bytesFetched)?
        bufferTelemetry,
    TResult? Function(int grMillidb, BigInt clippedSamples)? limiterTelemetry,
  }) {
    return limiterTelemetry?.call(grMillidb, clippedSamples);
  }

  @override
  @optionalTypeArgs
  TResult maybeWhen<TResult extends Object?>({
    TResult Function(String fileId, String message)? playbackFailed,
    TResult Function(BigInt requestId)? tokenRefreshRequested,
    TResult Function(bool isPlaying, bool isBuffering)? playbackState,
    TResult Function(String fileId)? trackStarted,
    TResult Function(String fileId)? trackEnded,
    TResult Function(int positionMs, int durationMs)? positionUpdate,
    TResult Function(int bufferedMs, int fetchesInFlight, BigInt bytesFetched)?
        bufferTelemetry,
    TResult Function(int grMillidb, BigInt clippedSamples)? limiterTelemetry,
    required TResult orElse(),
  }) {
    if (limiterTelemetry != null) {
      return limiterTelemetry(grMillidb, clippedSamples);
    }
    return orElse();
  }

  @override
  @optionalTypeArgs
  TResult map<TResult extends Object?>({
    required TResult Function(EngineEvent_PlaybackFailed value) playbackFailed,
    required TResult Function(EngineEvent_TokenRefreshRequested value)
        tokenRefreshRequested,
    required TResult Function(EngineEvent_PlaybackState value) playbackState,
    required TResult Function(EngineEvent_TrackStarted value) trackStarted,
    required TResult Function(EngineEvent_TrackEnded value) trackEnded,
    required TResult Function(EngineEvent_PositionUpdate value) positionUpdate,
    required TResult Function(EngineEvent_BufferTelemetry value)
        bufferTelemetry,
    required TResult Function(EngineEvent_LimiterTelemetry value)
        limiterTelemetry,
  }) {
    return limiterTelemetry(this);
  }

  @override
  @optionalTypeArgs
  TResult? mapOrNull<TResult extends Object?>({
    TResult? Function(EngineEvent_PlaybackFailed value)? playbackFailed,
    TResult? Function(EngineEvent_TokenRefreshRequested value)?
        tokenRefreshRequested,
    TResult? Function(EngineEvent_PlaybackState value)? playbackState,
    TResult? Function(EngineEvent_TrackStarted value)? trackStarted,
    TResult? Function(EngineEvent_TrackEnded value)? trackEnded,
    TResult? Function(EngineEvent_PositionUpdate value)? positionUpdate,
    TResult? Function(EngineEvent_BufferTelemetry value)? bufferTelemetry,
    TResult? Function(EngineEvent_LimiterTelemetry value)? limiterTelemetry,
  }) {
    return limiterTelemetry?.call(this);
  }

  @override
  @optionalTypeArgs
  TResult maybeMap<TResult extends Object?>({
    TResult Function(EngineEvent_PlaybackFailed value)? playbackFailed,
    TResult Function(EngineEvent_TokenRefreshRequested value)?
        tokenRefreshRequested,
    TResult Function(EngineEvent_PlaybackState value)? playbackState,
    TResult Function(EngineEvent_TrackStarted value)? trackStarted,
    TResult Function(EngineEvent_TrackEnded value)? trackEnded,
    TResult Function(EngineEvent_PositionUpdate value)? positionUpdate,
    TResult Function(EngineEvent_BufferTelemetry value)? bufferTelemetry,
    TResult Function(EngineEvent_LimiterTelemetry value)? limiterTelemetry,
    required TResult orElse(),
  }) {
    if (limiterTelemetry != null) {
      return limiterTelemetry(this);
    }
    return orElse();
  }
}

abstract class EngineEvent_LimiterTelemetry extends EngineEvent {
  const factory EngineEvent_LimiterTelemetry(
          {required final int grMillidb,
          required final BigInt clippedSamples}) =
      _$EngineEvent_LimiterTelemetryImpl;
  const EngineEvent_LimiterTelemetry._() : super._();

  int get grMillidb;
  BigInt get clippedSamples;

  /// Create a copy of EngineEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  _$$EngineEvent_LimiterTelemetryImplCopyWith<
          _$EngineEvent_LimiterTelemetryImpl>
      get copyWith => throw _privateConstructorUsedError;
}
