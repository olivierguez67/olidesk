import 'dart:async';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

// ---------------------------------------------------------------------------
// General-purpose in-app diagnostic log, for debugging things a developer
// can't just `adb logcat` for (see readAndroidUpdaterLog() in
// android_updater.dart, which this mirrors) -- specifically built to chase
// the "2FA dialog disappears and the connection restarts when the app comes
// back from the background" report, where the open question is which of
// three things actually happens: the Activity/process gets killed, the
// connection session gets torn down, or just the dialog's widget state is
// lost while everything else survives. Each layer involved (Activity
// lifecycle, Dart isolate lifecycle, AppLock, the 2FA dialog, RemotePage)
// logs into this one place so the sequence can be read back afterward.
//
// Persisted to this app's internal documents directory (no permission
// needed, unlike app-specific external storage) so the trail survives even
// if the process is killed outright -- which is one of the three hypotheses
// being tested. Read via readDiagLog() in Settings.
// ---------------------------------------------------------------------------

const _kDiagLogFileName = 'olidesk-diag.log';
const _kDiagLogMaxLines = 3000;
final List<String> _diagLogLines = [];
File? _diagLogFile;
bool _diagLogFileTried = false;

void logDiag(String line) {
  // ignore: avoid_print
  print('[olidesk-diag] $line');
  final ts = DateTime.now().toIso8601String();
  final entry = '$ts  $line';

  _diagLogLines.add(entry);
  if (_diagLogLines.length > _kDiagLogMaxLines) {
    _diagLogLines.removeRange(0, _diagLogLines.length - _kDiagLogMaxLines);
  }

  // Fire-and-forget: logging must never throw or block the caller, many of
  // which are lifecycle callbacks where an unhandled error would be worse
  // than a dropped log line.
  unawaited(_persistDiagLine(entry));
}

Future<void> _persistDiagLine(String entry) async {
  try {
    final file = await _resolveDiagLogFile();
    if (file == null) return;
    await file.writeAsString('$entry\n', mode: FileMode.append, flush: true);
  } catch (_) {}
}

Future<File?> _resolveDiagLogFile() async {
  if (_diagLogFileTried) return _diagLogFile;
  _diagLogFileTried = true;
  try {
    final dir = await getApplicationDocumentsDirectory();
    _diagLogFile = File('${dir.path}/$_kDiagLogFileName');
  } catch (_) {
    _diagLogFile = null;
  }
  return _diagLogFile;
}

/// The persisted file is the primary copy here (unlike the updater log) --
/// the whole point is surviving a process kill, which clears the in-memory
/// buffer along with everything else.
Future<String> readDiagLog() async {
  final file = await _resolveDiagLogFile();
  if (file != null && await file.exists()) {
    try {
      final content = await file.readAsString();
      if (content.isNotEmpty) return content;
    } catch (_) {}
  }
  if (_diagLogLines.isNotEmpty) {
    return _diagLogLines.join('\n');
  }
  return '(no diagnostics logged yet)';
}

Future<void> clearDiagLog() async {
  _diagLogLines.clear();
  final file = await _resolveDiagLogFile();
  if (file != null) {
    try {
      await file.writeAsString('');
    } catch (_) {}
  }
}
