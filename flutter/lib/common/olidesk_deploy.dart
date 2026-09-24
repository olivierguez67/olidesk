import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../models/platform_model.dart';
import '../utils/http_service.dart' as http_svc;

// ---------------------------------------------------------------------------
// Device registration — silent path (this file) and interactive path
// (widgets/olidesk_register_device.dart), both talking to
// olidesk-api/app.py's /api/clients/register.
//
// The silent path reads a deployment config dropped next to the installed
// executable (`olidesk-deploy.json`). The Windows MSI writes this file
// itself when a silent install passes ENROLLCODE (and optionally GROUP/
// DEVICENAME) as msiexec properties (see
// res/msi/CustomActions/DeployConfig.cpp); a plain interactive install
// with no such properties gets no file, and no attempt is made here --
// the interactive onboarding wizard's Register step handles that case
// entirely (see main.dart, which calls tryOlideskAutoRegister() followed
// by maybeOpenOlideskOnboardingWindow() -- see
// widgets/olidesk_register_device.dart for the full wizard, which also
// covers the permanent password and 2FA steps this file has nothing to do
// with).
//
// Older versions of this installer baked a long-lived DEPLOY_TOKEN into
// every client MSI and drove the whole flow (device name, group, network
// call) from an installer-side dialog. That's gone: no secret of any kind
// ships in a public installer now. enroll_code here is a short-lived
// (24h), revocable, per-deployment-batch code minted from the admin app
// (see ENROLL_CODE_TTL and /api/admin/enrollment-codes in
// olidesk-api/app.py) -- treat it like a credential (never logged) but
// not like a long-term secret.
//
// Everything here writes to a plain-text log (see logOlideskDeploy below)
// because this runs in a release build with no attached console --
// debugPrint alone would be invisible. Check that log first when a
// machine doesn't show up.
// ---------------------------------------------------------------------------

const kOlideskRegisteredOptionKey = 'olidesk-deploy-registered';
const kOlideskDefaultApiUrl = 'https://olidesk.olisys.co.il';
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
  await logOlideskDeploy('--- olidesk auto-registration starting ---');
  try {
    // Fast path: already registered, skip the file check entirely.
    if (bind.mainGetLocalOption(key: kOlideskRegisteredOptionKey) == 'Y') {
      await logOlideskDeploy('already registered on this machine, nothing to do');
      return;
    }

    final file = await _deployFile();
    if (file == null) {
      await logOlideskDeploy('could not resolve the executable directory, aborting');
      return;
    }
    await logOlideskDeploy('looking for deploy config at: ${file.path}');
    if (!await file.exists()) {
      await logOlideskDeploy('no $_kDeployFileName found next to the executable, nothing to do');
      return;
    }
    await logOlideskDeploy('found $_kDeployFileName');

    final config = await _readDeployFile(file);
    if (config == null) {
      return;
    }

    final apiUrl = ((config['api_url'] as String?) ?? '')
        .trim()
        .replaceAll(RegExp(r'/+$'), '');
    final code = ((config['enroll_code'] as String?) ?? '').trim();
    final group = ((config['group'] as String?) ?? '').trim();
    final deviceName = ((config['device_name'] as String?) ?? '').trim();

    if (apiUrl.isEmpty || code.isEmpty) {
      await logOlideskDeploy(
          '$_kDeployFileName is missing api_url or enroll_code, aborting');
      return;
    }

    await logOlideskDeploy('config ok: api_url=$apiUrl group=${group.isEmpty ? '(none)' : group}');

    await logOlideskDeploy('waiting for a RustDesk id (up to ${_kIdWaitAttempts}s)...');
    final olideskId = await waitForOlideskId();
    if (olideskId == null || olideskId.isEmpty) {
      await logOlideskDeploy('no RustDesk id available yet, will retry next launch');
      return;
    }
    await logOlideskDeploy('got id: $olideskId');

    final hostname = deviceName.isNotEmpty ? deviceName : olideskHostname();
    await logOlideskDeploy('registering with the server...');
    final result = await registerOlideskDevice(
      apiUrl: apiUrl,
      code: code,
      olideskId: olideskId,
      hostname: hostname,
      os: olideskOsName(),
      group: group.isNotEmpty ? group : null,
    );
    await logOlideskDeploy('response: HTTP ${result.statusCode} ok=${result.ok}'
        '${result.ok ? '' : ' (${result.message})'}');

    if (!result.ok) {
      await logOlideskDeploy('registration rejected by the server, will retry next launch');
      return;
    }

    await bind.mainSetLocalOption(key: kOlideskRegisteredOptionKey, value: 'Y');
    await logOlideskDeploy('registered successfully, marked done');

    // Best-effort: the machine stays registered even if this fails, e.g.
    // because the file was copied from read-only removable media, or the
    // install directory isn't writable by this user.
    try {
      await file.delete();
      await logOlideskDeploy('deleted $_kDeployFileName');
    } catch (e) {
      await logOlideskDeploy('could not delete $_kDeployFileName (harmless): $e');
    }
  } catch (e, st) {
    await logOlideskDeploy('unexpected error: $e\n$st');
  } finally {
    await logOlideskDeploy('--- olidesk auto-registration finished ---');
  }
}

// ---------------------------------------------------------------------------
// Shared helpers — used by both the silent path above and the interactive
// "Register this device" dialog (widgets/olidesk_register_device.dart).
// ---------------------------------------------------------------------------

class OlideskRegisterResult {
  final bool ok;
  final int statusCode;
  final String message;
  const OlideskRegisterResult(this.ok, this.statusCode, this.message);
}

/// POSTs to /api/clients/register. Never logs [code] (or anything derived
/// from it) — only the caller's own step-by-step log lines around this call
/// should ever mention non-secret details like the group or status code.
Future<OlideskRegisterResult> registerOlideskDevice({
  required String apiUrl,
  required String code,
  required String olideskId,
  required String hostname,
  required String os,
  String? group,
}) async {
  final body = jsonEncode({
    'olidesk_id': olideskId,
    'hostname': hostname,
    'os': os,
    if (group != null && group.isNotEmpty) 'group': group,
  });
  final http.Response resp;
  try {
    resp = await http_svc
        .post(
          Uri.parse('$apiUrl/api/clients/register'),
          headers: {
            'Authorization': 'Bearer $code',
            'Content-Type': 'application/json',
          },
          body: body,
        )
        .timeout(const Duration(seconds: 15));
  } catch (e) {
    return OlideskRegisterResult(false, 0, e.toString());
  }

  final ok = resp.statusCode >= 200 && resp.statusCode < 300;
  var message = 'HTTP ${resp.statusCode}';
  if (!ok) {
    try {
      final parsed = jsonDecode(resp.body);
      if (parsed is Map && parsed['error'] != null) {
        message = parsed['error'].toString();
      }
    } catch (_) {}
  }
  return OlideskRegisterResult(ok, resp.statusCode, message);
}

/// GETs /api/deploy/groups with [code] as the bearer credential. Returns
/// null on any failure (unreachable, invalid/expired code, bad response) --
/// the caller can't distinguish those cases from this alone, but the
/// dialog only needs a yes/no "is this code usable right now".
Future<List<String>?> fetchOlideskGroups({
  required String apiUrl,
  required String code,
}) async {
  try {
    final resp = await http_svc
        .get(
          Uri.parse('$apiUrl/api/deploy/groups'),
          headers: {'Authorization': 'Bearer $code'},
        )
        .timeout(const Duration(seconds: 10));
    if (resp.statusCode != 200) return null;
    final parsed = jsonDecode(resp.body);
    if (parsed is! List) return null;
    return parsed.whereType<String>().toList();
  } catch (_) {
    return null;
  }
}

/// Best-effort read of olidesk-deploy.json, e.g. so the interactive dialog
/// can prefill device_name/api_url/group if a (possibly code-less) file
/// exists. Returns null if there's no file, or it can't be read/parsed.
Future<Map<String, dynamic>?> readOlideskDeployFile() async {
  final file = await _deployFile();
  if (file == null || !await file.exists()) return null;
  return _readDeployFile(file);
}

Future<Map<String, dynamic>?> _readDeployFile(File file) async {
  try {
    var raw = await file.readAsString();
    // Strip a leading UTF-8 BOM: common when the file is hand-edited in
    // Notepad, and jsonDecode rejects it outright with no useful message.
    if (raw.isNotEmpty && raw.codeUnitAt(0) == 0xFEFF) {
      raw = raw.substring(1);
    }
    final parsed = jsonDecode(raw);
    if (parsed is! Map<String, dynamic>) {
      await logOlideskDeploy('$_kDeployFileName does not contain a JSON object');
      return null;
    }
    return parsed;
  } catch (e) {
    await logOlideskDeploy('failed to parse $_kDeployFileName: $e');
    return null;
  }
}

Future<File?> _deployFile() async {
  final exeDir = _exeDir();
  if (exeDir == null) return null;
  return File('${exeDir.path}${Platform.pathSeparator}$_kDeployFileName');
}

Directory? _exeDir() {
  try {
    return File(Platform.resolvedExecutable).parent;
  } catch (_) {
    return null;
  }
}

Future<String?> waitForOlideskId() async {
  for (var i = 0; i < _kIdWaitAttempts; i++) {
    final id = await bind.mainGetMyId();
    if (id.isNotEmpty) return id;
    await Future.delayed(_kIdWaitInterval);
  }
  return null;
}

String olideskHostname() {
  try {
    return Platform.localHostname;
  } catch (_) {
    return '';
  }
}

String olideskOsName() {
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

Future<void> logOlideskDeploy(String line) async {
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
