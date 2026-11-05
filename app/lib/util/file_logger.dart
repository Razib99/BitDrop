import 'dart:io';

void logToFile(String msg) {
  try {
    final file = File('/sdcard/Android/data/com.bitdrop.bitdrop/trace.log');
    file.writeAsStringSync('[${DateTime.now().toIso8601String()}] $msg\n',
        mode: FileMode.append, flush: true);
  } catch (_) {}
}
