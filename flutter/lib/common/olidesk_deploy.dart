import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../models/platform_model.dart';
import '../utils/http_service.dart' as http_svc;

// ---------------------------------------------------------------------------
// Auto-registration from a deployment config dropped next to the installed
// executable (`olidesk-deploy.json`). Lets a per-site deployment package
// (client exe + json naming the site's group) register itself into the
// address book on first launch, instead of a manual address-book entry per
// machine. See olidesk-api/app.py's /api/clients/register for the server
// side.
//
// The Windows MSI writes this file itself, from its device-registration
// prompt (see res/msi/CustomActions/DeployConfig.cpp and
// res/msi/Package/UI/DeployConfigDlg.wxs) -- `device_name` is the name
// typed into that prompt (or the msiexec DEVICENAME property for a silent
// install), used here as the hostname sent to the server if present,
// falling back to Platform.localHostname when it's absent (e.g. a
// hand-written olidesk-deploy.json that predates that field).
//
// Everything here writes to a plain-text log (see _log below) because this
// runs in a release build with no attached console -- debugPrint alone would
// be invisible. Check that log first when a machine doesn't show up.
// ---------------------------------------------------------------------------

const _kRegisteredOptionKey = 'olidesk-deploy-registered';
const _kDeployFileName = 'olidesk-deploy.json';
const _kLogFileName = 'olidesk-deploy.log';

// Bounded: a machine with no network (or no id yet) on its very first boot
// should not hang app startup forever. Registration is retried on the next
// launch if it doesn't succeed within this window.
const _kIdWaitAttempts = 30;
const _kIdWaitInterval = Duration(seconds: 1);

File? _logFile;
bool _logFileTried = false;

Future<void> tryOlideskAutoRegister() async {
  await _log('--- olidesk auto-registration starting ---');
  try {
    // Fast path: already registered, skip the file check entirely.
    if (bind.mainGetLocalOption(key: _kRegisteredOptionKey) == 'Y') {
      await _log('already registered on this machine, nothing to do');
      return;
    }

    final exeDir = _exeDir();
    if (exeDir == null) {
      await _log('could not resolve the executable directory, aborting');
      return;
    }
    final file = File('${exeDir.path}${Platform.pathSeparator}$_kDeployFileName');
    await _log('looking for deploy config at: ${file.path}');
    if (!await file.exists()) {
      await _log('no $_kDeployFileName found next to the executable, nothing to do');
      return;
    }
    await _log('found $_kDeployFileName');

    Map<String, dynamic> config;
    try {
      var raw = await file.readAsString();
      // Strip a leading UTF-8 BOM: common when the file is hand-edited in
      // Notepad, and jsonDecode rejects it outright with no useful message.
      if (raw.isNotEmpty && raw.codeUnitAt(0) == 0xFEFF) {
        raw = raw.substring(1);
      }
      final parsed = jsonDecode(raw);
      if (parsed is! Map<String, dynamic>) {
        await _log('$_kDeployFileName does not contain a JSON object, aborting');
        return;
      }
      config = parsed;
    } catch (e) {
      await _log('failed to parse $_kDeployFileName: $e');
      return;
    }

    final apiUrl = ((config['api_url'] as String?) ?? '')
        .trim()
        .replaceAll(RegExp(r'/+$'), '');
    final deployToken = ((config['deploy_token'] as String?) ?? '').trim();
    final group = ((config['group'] as String?) ?? '').trim();
    final deviceName = ((config['device_name'] as String?) ?? '').trim();

    if (apiUrl.isEmpty || deployToken.isEmpty) {
      await _log(
          '$_kDeployFileName is missing api_url or deploy_token, aborting');
      return;
    }
    await _log('config ok: api_url=$apiUrl group=${group.isEmpty ? '(none)' : group}');

    await _log('waiting for a RustDesk id (up to ${_kIdWaitAttempts}s)...');
    final olideskId = await _waitForId();
    if (olideskId == null || olideskId.isEmpty) {
      await _log('no RustDesk id available yet, will retry next launch');
      return;
    }
    await _log('got id: $olideskId');

    final body = jsonEncode({
      'olidesk_id': olideskId,
      'hostname': deviceName.isNotEmpty ? deviceName : _hostname(),
      'os': _osName(),
      if (group.isNotEmpty) 'group': group,
    });
    await _log('POST $apiUrl/api/clients/register body=$body');

    final http.Response resp;
    try {
      resp = await http_svc
          .post(
            Uri.parse('$apiUrl/api/clients/register'),
            headers: {
              'Authorization': 'Bearer $deployToken',
              'Content-Type': 'application/json',
            },
            body: body,
          )
          .timeout(const Duration(seconds: 15));
    } catch (e) {
      await _log('registration request failed: $e');
      return;
    }
    await _log('response: HTTP ${resp.statusCode} ${resp.body}');

    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      await _log('registration rejected by the server, will retry next launch');
      return;
    }

    await bind.mainSetLocalOption(key: _kRegisteredOptionKey, value: 'Y');
    await _log('registered successfully, marked done');

    // Best-effort: the machine stays registered even if this fails, e.g.
    // because the file was copied from read-only removable media, or the
    // install directory isn't writable by this user.
    try {
      await file.delete();
      await _log('deleted $_kDeployFileName');
    } catch (e) {
      await _log('could not delete $_kDeployFileName (harmless): $e');
    }
  } catch (e, st) {
    await _log('unexpected error: $e\n$st');
  } finally {
    await _log('--- olidesk auto-registration finished ---');
  }
}

Directory? _exeDir() {
  try {
    return File(Platform.resolvedExecutable).parent;
  } catch (_) {
    return null;
  }
}

Future<String?> _waitForId() async {
  for (var i = 0; i < _kIdWaitAttempts; i++) {
    final id = await bind.mainGetMyId();
    if (id.isNotEmpty) return id;
    await Future.delayed(_kIdWaitInterval);
  }
  return null;
}

String _hostname() {
  try {
    return Platform.localHostname;
  } catch (_) {
    return '';
  }
}

String _osName() {
  if (Platform.isWindows) return 'Windows';
  if (Platform.isMacOS) return 'macOS';
  if (Platform.isLinux) return 'Linux';
  if (Platform.isAndroid) return 'Android';
  if (Platform.isIOS) return 'iOS';
  return '';
}

// ---------------------------------------------------------------------------
// Logging
//
// Tries, once per run, to open a log file next to the executable (same
// folder as olidesk-deploy.json -- the most discoverable place, since it's
// where whoever is deploying is already looking). If that folder isn't
// writable (e.g. a non-elevated user under Program Files), falls back to
// this user's %APPDATA%\Olidesk (Windows) or $HOME (elsewhere), which is
// always writable. Every line also goes through debugPrint for anyone
// attached with a debugger or running from a terminal.
// ---------------------------------------------------------------------------

Future<void> _log(String line) async {
  debugPrint('[olidesk-deploy] $line');
  final file = await _resolveLogFile();
  if (file == null) return;
  final ts = DateTime.now().toIso8601String();
  try {
    await file.writeAsString('$ts  $line\n',
        mode: FileMode.append, flush: true);
  } catch (_) {
    // Logging must never be the reason registration fails.
  }
}

Future<File?> _resolveLogFile() async {
  if (_logFileTried) return _logFile;
  _logFileTried = true;

  final exeDir = _exeDir();
  if (exeDir != null) {
    final candidate =
        File('${exeDir.path}${Platform.pathSeparator}$_kLogFileName');
    if (await _canAppend(candidate)) {
      _logFile = candidate;
      return _logFile;
    }
  }

  final fallbackDir = _fallbackLogDir();
  if (fallbackDir != null) {
    try {
      await fallbackDir.create(recursive: true);
    } catch (_) {}
    final candidate =
        File('${fallbackDir.path}${Platform.pathSeparator}$_kLogFileName');
    if (await _canAppend(candidate)) {
      _logFile = candidate;
      return _logFile;
    }
  }

  _logFile = null;
  return null;
}

Future<bool> _canAppend(File f) async {
  try {
    await f.writeAsString('', mode: FileMode.append, flush: true);
    return true;
  } catch (_) {
    return false;
  }
}

Directory? _fallbackLogDir() {
  try {
    if (Platform.isWindows) {
      final appData = Platform.environment['APPDATA'];
      if (appData == null || appData.isEmpty) return null;
      return Directory('$appData${Platform.pathSeparator}Olidesk');
    }
    final home = Platform.environment['HOME'];
    if (home == null || home.isEmpty) return null;
    return Directory('$home${Platform.pathSeparator}.olidesk');
  } catch (_) {
    return null;
  }
}
