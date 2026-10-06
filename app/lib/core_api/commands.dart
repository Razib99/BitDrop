import 'package:flutter/foundation.dart';

import 'enums.dart';
import 'models.dart';

/// Commands the UI sends to the core. Fire-and-forget: every result comes back
/// through the streams, so no command returns state.
@immutable
sealed class PlayerCommand {
  const PlayerCommand();
}

/// Start a context (album, playlist, folder, search result) at [startIndex].
class PlayContext extends PlayerCommand {
  const PlayContext({
    required this.contextId,
    required this.trackIds,
    this.startIndex = 0,
    this.shuffle = false,
    this.contextLabel = '',
  });

  final String contextId;
  final List<String> trackIds;
  final int startIndex;
  final bool shuffle;
  final String contextLabel;
}

class Pause extends PlayerCommand {
  const Pause();
}

class Resume extends PlayerCommand {
  const Resume();
}

class Seek extends PlayerCommand {
  const Seek(this.positionMs);
  final int positionMs;
}

class Next extends PlayerCommand {
  const Next();
}

class Previous extends PlayerCommand {
  const Previous();
}

class SetShuffle extends PlayerCommand {
  const SetShuffle(this.enabled);
  final bool enabled;
}

class SetRepeat extends PlayerCommand {
  const SetRepeat(this.mode);
  final RepeatMode mode;
}

class Enqueue extends PlayerCommand {
  const Enqueue(this.trackIds);
  final List<String> trackIds;
}

class PlayNext extends PlayerCommand {
  const PlayNext(this.trackIds);
  final List<String> trackIds;
}

class Reorder extends PlayerCommand {
  const Reorder({required this.oldIndex, required this.newIndex});
  final int oldIndex;
  final int newIndex;
}

class RemoveFromQueue extends PlayerCommand {
  const RemoveFromQueue(this.itemId);
  final String itemId;
}

class ClearQueue extends PlayerCommand {
  const ClearQueue();
}

class ShuffleRemaining extends PlayerCommand {
  const ShuffleRemaining();
}

class SetEqBands extends PlayerCommand {
  const SetEqBands(this.bands);
  final List<EqBand> bands;
}

class SetEqMode extends PlayerCommand {
  const SetEqMode(this.mode);
  final EqMode mode;
}

class SetGraphicGains extends PlayerCommand {
  const SetGraphicGains(this.gains);
  final List<double> gains;
}

class SetBypass extends PlayerCommand {
  const SetBypass(this.bypass);
  final bool bypass;
}

class SetPreamp extends PlayerCommand {
  const SetPreamp(this.db);
  final double db;
}

class SetTone extends PlayerCommand {
  const SetTone({this.bassDb, this.trebleDb, this.balance, this.mono});
  final double? bassDb;
  final double? trebleDb;
  final double? balance;
  final bool? mono;
}

class SetReplayGain extends PlayerCommand {
  const SetReplayGain({required this.mode, this.preampDb});
  final ReplayGainMode mode;
  final double? preampDb;
}

class ApplyAutoEqProfile extends PlayerCommand {
  const ApplyAutoEqProfile(this.profileId);
  final String profileId;
}

class ImportParametricEq extends PlayerCommand {
  const ImportParametricEq(this.text);
  final String text;
}

class AssignEqToDevice extends PlayerCommand {
  const AssignEqToDevice({required this.deviceId, required this.assign});
  final String deviceId;
  final bool assign;
}

class Pin extends PlayerCommand {
  const Pin({required this.id, required this.kind});
  final String id;

  /// "album", "playlist", "folder", "track"
  final String kind;
}

class Unpin extends PlayerCommand {
  const Unpin({required this.id, required this.kind});
  final String id;
  final String kind;
}

class SetFavorite extends PlayerCommand {
  const SetFavorite({required this.trackId, required this.favorite});
  final String trackId;
  final bool favorite;
}

class Rescan extends PlayerCommand {
  const Rescan({this.sourceId});
  final String? sourceId;
}

class ReconnectSource extends PlayerCommand {
  const ReconnectSource(this.sourceId);
  final String sourceId;
}

class RemoveSource extends PlayerCommand {
  const RemoveSource(this.sourceId);
  final String sourceId;
}

class RunSafetyCheck extends PlayerCommand {
  const RunSafetyCheck({this.deviceId});
  final String? deviceId;
}

class SetSafetyAttenuation extends PlayerCommand {
  const SetSafetyAttenuation({required this.enabled, this.db});
  final bool enabled;
  final double? db;
}

class SetVolumeDb extends PlayerCommand {
  const SetVolumeDb(this.db);
  final double db;
}

class SetCacheLimit extends PlayerCommand {
  const SetCacheLimit(this.bytes);
  final int bytes;
}

class ClearCache extends PlayerCommand {
  const ClearCache();
}

class PauseDownload extends PlayerCommand {
  const PauseDownload({required this.jobId, required this.paused});
  final String jobId;
  final bool paused;
}

class DismissBanner extends PlayerCommand {
  const DismissBanner(this.bannerId);
  final String bannerId;
}

class CreatePlaylist extends PlayerCommand {
  const CreatePlaylist({required this.name, this.trackIds = const []});
  final String name;
  final List<String> trackIds;
}

class SaveQueueAsPlaylist extends PlayerCommand {
  const SaveQueueAsPlaylist(this.name);
  final String name;
}

class SetSleepTimer extends PlayerCommand {
  const SetSleepTimer(this.minutes);

  /// Null cancels the timer.
  final int? minutes;
}

/// Generic settings write. [key] matches a field on the settings model.
class SetSetting extends PlayerCommand {
  const SetSetting({required this.key, required this.value});
  final String key;
  final Object? value;
}
