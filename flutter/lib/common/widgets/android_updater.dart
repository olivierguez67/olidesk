import 'dart:io';

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
  try {
    // Mirrors the desktop `handleUpdate()` convention in
    // `desktop/widgets/update_progress.dart`: a GitHub release page URL
    // (".../releases/tag/{tag}") becomes a download URL
    // (".../releases/download/{tag}") once the asset filename is appended.
    final downloadBase = releasePageUrl.replaceAll('tag', 'download');
    final tag = downloadBase.substring(downloadBase.lastIndexOf('/') + 1);
    final filename = await bind.mainGetCommonSync(key: 'download-file-$tag');
    if (filename.isEmpty || filename.startsWith('error:')) {
      showToast('Update: could not resolve the download for $tag');
      return;
    }
    final downloadUrl = '$downloadBase/$filename';
    showToast('Downloading update $tag…');
    final dir = await getTemporaryDirectory();
    final savePath = '${dir.path}/$filename';
    final response = await http.Client().send(http.Request('GET', Uri.parse(downloadUrl)));
    if (response.statusCode != 200) {
      showToast('Update download failed (${response.statusCode})');
      return;
    }
    final file = File(savePath);
    final sink = file.openWrite();
    await response.stream.pipe(sink);
    await sink.close();
    await OpenFilex.open(savePath);
  } catch (e) {
    showToast('Update download failed: $e');
  } finally {
    _androidUpdateDownloading = false;
  }
}
