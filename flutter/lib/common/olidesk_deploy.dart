import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/platform_model.dart';
import '../utils/http_service.dart' as http_svc;

// ---------------------------------------------------------------------------
// Auto-registration from a deployment config dropped next to the installed
// executable (`olidesk-deploy.json`). Lets a per-site deployment package
// (client exe + json naming the site's group) register itself into the
// address book on first launch, instead of a manual address-book entry per
// machine. See olidesk-api/app.py's /api/clients/register for the server
// side.
// ---------------------------------------------------------------------------

const _kRegisteredOptionKey = 'olidesk-deploy-registered';
const _kDeployFileName = 'olidesk-deploy.json';

// Bounded: a machine with no network (or no id yet) on its very first boot
// should not hang app startup forever. Registration is retried on the next
// launch if it doesn't succeed within this window.
const _kIdWaitAttempts = 30;
const _kIdWaitInterval = Duration(seconds: 1);

Future<void> tryOlideskAutoRegister() async {
  try {
    // Fast path: already registered, skip the file check entirely.
    if (bind.mainGetLocalOption(key: _kRegisteredOptionKey) == 'Y') return;

    final file = _deployFile();
    if (file == null || !await file.exists()) return;

    final dynamic parsed = jsonDecode(await file.readAsString());
    if (parsed is! Map) {
      debugPrint(
          'olidesk-deploy.json is not a JSON object, skipping auto-registration');
      return;
    }
    final config = parsed;

    final apiUrl = ((config['api_url'] as String?) ?? '')
        .trim()
        .replaceAll(RegExp(r'/+$'), '');
    final deployToken = ((config['deploy_token'] as String?) ?? '').trim();
    final group = ((config['group'] as String?) ?? '').trim();

    if (apiUrl.isEmpty || deployToken.isEmpty) {
      debugPrint(
          'olidesk-deploy.json is missing api_url or deploy_token, skipping auto-registration');
      return;
    }

    final olideskId = await _waitForId();
    if (olideskId == null || olideskId.isEmpty) {
      debugPrint(
          'olidesk auto-registration: no RustDesk id available yet, will retry next launch');
      return;
    }

    final body = jsonEncode({
      'olidesk_id': olideskId,
      'hostname': _hostname(),
      'os': _osName(),
      if (group.isNotEmpty) 'group': group,
    });

    final resp = await http_svc
        .post(
          Uri.parse('$apiUrl/api/clients/register'),
          headers: {
            'Authorization': 'Bearer $deployToken',
            'Content-Type': 'application/json',
          },
          body: body,
        )
        .timeout(const Duration(seconds: 15));

    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      debugPrint(
          'olidesk auto-registration failed: HTTP ${resp.statusCode} ${resp.body}');
      return;
    }

    await bind.mainSetLocalOption(key: _kRegisteredOptionKey, value: 'Y');

    // Best-effort: the machine stays registered even if this fails, e.g.
    // because the file was copied from read-only removable media.
    try {
      await file.delete();
    } catch (_) {}
  } catch (e) {
    debugPrint('olidesk auto-registration error: $e');
  }
}

File? _deployFile() {
  try {
    final exeDir = File(Platform.resolvedExecutable).parent;
    return File('${exeDir.path}${Platform.pathSeparator}$_kDeployFileName');
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
