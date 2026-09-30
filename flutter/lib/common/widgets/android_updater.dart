import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';

bool _androidUpdateDownloading = false;

/// Downloads the flavor-matching (admin/client) universal APK referenced by
/// [releasePageUrl] (a `https://github.com/.../releases/tag/vX.Y.Z` URL, as
/// set on `stateGlobal.updateUrl` once the backend finds a newer release) and
/// hands it to Android's package installer.
///
/// Android has no silent-install API for regular apps, so launching the
/// system installer intent *is* the "prompt to install" step the spec asks
/// for; there is no further, more automatic path available on this OS.
Future<void> downloadAndInstallAndroidUpdate(String releasePageUrl) async {
  if (!isAndroid || releasePageUrl.isEmpty || _androidUpdateDownloading) {
    return;
  }
  _androidUpdateDownloading = true;
  await _logUpdater('=== update check: releasePageUrl=$releasePageUrl ===');
  try {
    // Mirrors the desktop `handleUpdate()` convention in
    // `desktop/widgets/update_progress.dart`: a GitHub release page URL
    // (".../releases/tag/{tag}") becomes a download URL
    // (".../releases/download/{tag}") once the asset filename is appended.
    final downloadBase = releasePageUrl.replaceAll('tag', 'download');
    final tag = downloadBase.substring(downloadBase.lastIndexOf('/') + 1);
    final filename = await bind.mainGetCommonSync(key: 'download-file-$tag');
    await _logUpdater('resolved filename for tag=$tag: $filename');
    if (filename.isEmpty || filename.startsWith('error:')) {
      await _logUpdater('aborting: filename resolution failed');
      showToast('Update: could not resolve the download for $tag');
      return;
    }
    final downloadUrl = '$downloadBase/$filename';
    await _logUpdater('requesting GET $downloadUrl');
    showToast('Downloading update $tag…');
    final dir = await getTemporaryDirectory();
    final savePath = '${dir.path}/$filename';
    final response =
        await http.Client().send(http.Request('GET', Uri.parse(downloadUrl)));
    final contentLength = response.contentLength;
    await _logUpdater(
        'response: HTTP ${response.statusCode}, Content-Length=${contentLength ?? '(none)'}, '
        'final URL=${response.request?.url}');
    if (response.statusCode != 200) {
      await _logUpdater('aborting: non-200 status');
      showToast('Update download failed (${response.statusCode})');
      return;
    }
    final file = File(savePath);
    final sink = file.openWrite();
    var bytesWritten = 0;
    await response.stream.map((chunk) {
      bytesWritten += chunk.length;
      return chunk;
    }).pipe(sink);
    await sink.close();
    final fileSize = await file.length();
    await _logUpdater('wrote $bytesWritten bytes to $savePath (file size on '
        'disk: $fileSize)');
    if (contentLength != null && bytesWritten != contentLength) {
      await _logUpdater(
          'WARNING: bytes written ($bytesWritten) != Content-Length ($contentLength) '
          '-- download likely truncated');
    }

    // An APK is a ZIP archive; a truncated download, an interrupted
    // connection, or some unexpected non-APK response landing here with a
    // 200 gets caught before it ever reaches the installer.
    final looksLikeApk = await _looksLikeApk(file);
    await _logUpdater('magic-byte check (PK\\x03\\x04): $looksLikeApk');
    if (!looksLikeApk) {
      await file.delete().catchError((_) => file);
      await _logUpdater('aborting: failed magic-byte check, file deleted');
      showToast('Update download failed: not a valid APK');
      return;
    }
    await _logUpdater('handing off to OpenFilex.open($savePath)');
    final openResult = await OpenFilex.open(savePath);
    await _logUpdater(
        'OpenFilex result: type=${openResult.type}, message=${openResult.message}');
  } catch (e, st) {
    await _logUpdater('EXCEPTION: $e\n$st');
    showToast('Update download failed: $e');
  } finally {
    _androidUpdateDownloading = false;
  }
}

/// Checks for the ZIP local-file-header signature ('PK\x03\x04') an APK
/// starts with, since it's just a ZIP archive under a different extension.
Future<bool> _looksLikeApk(File file) async {
  try {
    final raf = await file.open();
    final header = await raf.read(4);
    await raf.close();
    return header.length == 4 &&
        header[0] == 0x50 &&
        header[1] == 0x4B &&
        header[2] == 0x03 &&
        header[3] == 0x04;
  } catch (_) {
    return false;
  }
}

// ---------------------------------------------------------------------------
// Logging
//
// Writes to olidesk-updater.log in this app's internal documents directory
// (getApplicationDocumentsDirectory(), e.g. /data/data/<package>/app_flutter)
// -- unlike app-specific *external* storage (getExternalStorageDirectory()),
// which can legitimately return null with no error on some devices/Android
// versions and silently drop every log line, internal storage has no
// permission model at all and is always available to the app that owns it.
// The tradeoff is it isn't reachable from a file manager or over USB, so
// readAndroidUpdaterLog() below exists for the in-app "Copy diagnostics"
// button in Settings instead. Plain text, one timestamped line per event;
// logging failures are swallowed so they never affect the update itself.
// ---------------------------------------------------------------------------

const _kUpdaterLogFileName = 'olidesk-updater.log';
File? _updaterLogFile;
bool _updaterLogFileTried = false;

Future<void> _logUpdater(String line) async {
  debugPrint('[olidesk-updater] $line');
  final file = await _resolveUpdaterLogFile();
  if (file == null) return;
  final ts = DateTime.now().toIso8601String();
  try {
    await file.writeAsString('$ts  $line\n',
        mode: FileMode.append, flush: true);
  } catch (_) {
    // Logging must never be the reason the update fails.
  }
}

Future<File?> _resolveUpdaterLogFile() async {
  if (_updaterLogFileTried) return _updaterLogFile;
  _updaterLogFileTried = true;
  try {
    final dir = await getApplicationDocumentsDirectory();
    _updaterLogFile = File('${dir.path}/$_kUpdaterLogFileName');
  } catch (_) {
    _updaterLogFile = null;
  }
  return _updaterLogFile;
}

/// Reads back the updater's own log for display/copy in Settings -- the log
/// lives in internal storage precisely because nothing else can reach it.
Future<String> readAndroidUpdaterLog() async {
  final file = await _resolveUpdaterLogFile();
  if (file == null || !await file.exists()) {
    return '(no update log yet -- nothing has triggered an update check)';
  }
  try {
    return await file.readAsString();
  } catch (e) {
    return '(failed to read log: $e)';
  }
}
