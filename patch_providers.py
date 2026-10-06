import re

with open("app/lib/providers/core_providers.dart", "r") as f:
    content = f.read()

imports = """import '../core_live/live_core.dart';
import '../core_live/audio_handler.dart';
import 'package:audio_service/audio_service.dart';

late final BitDropAudioHandler globalAudioHandler;
"""

content = content.replace("import '../core_mock/scenarios.dart';", "import '../core_mock/scenarios.dart';\n" + imports)

provider_replacement = """final coreProvider = Provider<BitDropCore>((ref) {
  final core = LiveBitDropCore(globalAudioHandler);
  ref.onDispose(core.dispose);
  return core;
});
"""

content = re.sub(
    r"final coreProvider = Provider<MockBitDropCore>\(\(ref\) \{.*?return core;\n\}\);", 
    provider_replacement, 
    content, 
    flags=re.DOTALL
)

with open("app/lib/providers/core_providers.dart", "w") as f:
    f.write(content)
