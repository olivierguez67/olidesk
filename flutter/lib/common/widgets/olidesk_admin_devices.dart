import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:get/get.dart';

import '../../common.dart';
import '../../models/platform_model.dart';
import '../../utils/http_service.dart' as http_svc;

// ---------------------------------------------------------------------------
// Admin device management — one credential per admin device instead of a
// single shared token. Mirrors the constants in olidesk_address_book.dart
// (kept private per-file, like the rest of this codebase's local consts).
// ---------------------------------------------------------------------------

const _kApiUrlKey = 'olidesk-ab-api-url';
const _kTokenKey = 'olidesk-ab-token';
const _kDefaultApiUrl = 'https://olidesk.olisys.co.il';

// Matches MAX_ADMIN_DEVICES in olidesk-api/app.py. Informational only here —
// the server is the actual enforcer; this just disables "Add Device" early
// instead of waiting for a 403.
const _kMaxAdminDevices = 4;

class _AdminDevice {
  final int id;
  final String name;
  final String? olideskId;
  final String createdAt;
  final String? lastSeenAt;
  final String? lastIp;

  _AdminDevice.fromJson(Map<String, dynamic> j)
      : id = j['id'] as int,
        name = j['name'] as String? ?? '',
        olideskId = j['olidesk_id'] as String?,
        createdAt = j['created_at'] as String? ?? '',
        lastSeenAt = j['last_seen_at'] as String?,
        lastIp = j['last_ip'] as String?;
}

Future<void> showOlideskAdminDevicesDialog(BuildContext context) {
  return showDialog(
    context: context,
    builder: (_) => const _AdminDevicesDialog(),
  );
}

class _AdminDevicesDialog extends StatefulWidget {
  const _AdminDevicesDialog();

  @override
  State<_AdminDevicesDialog> createState() => _AdminDevicesDialogState();
}

class _AdminDevicesDialogState extends State<_AdminDevicesDialog> {
  final _devices = <_AdminDevice>[].obs;
  final _loading = true.obs;
  final _error = ''.obs;

  String get _apiUrl {
    final v = bind.mainGetLocalOption(key: _kApiUrlKey);
    return v.isNotEmpty ? v : _kDefaultApiUrl;
  }

  String get _token => bind.mainGetLocalOption(key: _kTokenKey);

  Map<String, String> get _headers => {
        'Authorization': 'Bearer $_token',
        'Content-Type': 'application/json',
      };

  @override
  void initState() {
    super.initState();
    _load();
  }

  String _friendlyError(Object e) {
    final msg = e.toString();
    if (msg.contains('timed out')) return 'Connection timed out.';
    return msg.replaceFirst('Exception: ', '');
  }

  Future<void> _load() async {
    _loading.value = true;
    _error.value = '';
    try {
      final resp = await http_svc
          .get(Uri.parse('$_apiUrl/api/admin/devices'), headers: _headers)
          .timeout(const Duration(seconds: 10),
              onTimeout: () =>
                  throw TimeoutException('Request timed out after 10 s'));
      if (resp.statusCode == 401) {
        throw Exception('Unauthorized — check API token');
      }
      if (resp.statusCode >= 400) {
        throw Exception('Request failed (${resp.statusCode})');
      }
      final data = jsonDecode(resp.body) as List;
      _devices.value = data
          .map((d) => _AdminDevice.fromJson(d as Map<String, dynamic>))
          .toList();
    } catch (e) {
      _error.value = _friendlyError(e);
    } finally {
      _loading.value = false;
    }
  }

  Future<void> _addDevice() async {
    final nameCtrl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add Device'),
        content: TextField(
          controller: nameCtrl,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Device name',
            hintText: "e.g. Olivier's laptop",
            border: OutlineInputBorder(),
            isDense: true,
          ),
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
        actions: [
          TextButton(
            autofocus: true,
            onPressed: () => Navigator.pop(ctx),
            child: Text(translate('Cancel')),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, nameCtrl.text.trim()),
            child: const Text('Add'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;

    try {
      final resp = await http_svc
          .post(
            Uri.parse('$_apiUrl/api/admin/devices'),
            headers: _headers,
            body: jsonEncode({'name': name}),
          )
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode >= 400) {
        String message = 'Request failed (${resp.statusCode})';
        try {
          final body = jsonDecode(resp.body);
          if (body is Map && body['error'] != null) message = body['error'].toString();
        } catch (_) {}
        throw Exception(message);
      }
      final created = jsonDecode(resp.body) as Map<String, dynamic>;
      final token = created['token'] as String? ?? '';
      await _load();
      if (mounted) _showNewTokenDialog(name, token);
    } catch (e) {
      _error.value = _friendlyError(e);
    }
  }

  void _showNewTokenDialog(String name, String token) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: Text('Device "$name" added'),
        content: SizedBox(
          width: 380,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Copy this token now — it is shown only this once and '
                "cannot be retrieved again. Paste it into that device's "
                'Address Book API Settings.',
                style: TextStyle(fontSize: 13),
              ),
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  border: Border.all(color: Theme.of(ctx).dividerColor),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: SelectableText(
                  token,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton.icon(
            icon: const Icon(Icons.copy, size: 16),
            label: const Text('Copy'),
            onPressed: () => Clipboard.setData(ClipboardData(text: token)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Done'),
          ),
        ],
      ),
    );
  }

  void _confirmRevoke(_AdminDevice device) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Revoke Device'),
        content: Text(
            'Revoke "${device.name}"? It will immediately lose address book '
            'access. This cannot be undone.'),
        actions: [
          TextButton(
            autofocus: true,
            onPressed: () => Navigator.pop(ctx),
            child: Text(translate('Cancel')),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () async {
              Navigator.pop(ctx);
              try {
                final resp = await http_svc
                    .delete(
                      Uri.parse('$_apiUrl/api/admin/devices/${device.id}'),
                      headers: _headers,
                    )
                    .timeout(const Duration(seconds: 10));
                if (resp.statusCode >= 400) {
                  throw Exception('Request failed (${resp.statusCode})');
                }
                await _load();
              } catch (e) {
                _error.value = _friendlyError(e);
              }
            },
            child: const Text('Revoke'),
          ),
        ],
      ),
    );
  }

  String _formatTimestamp(String? iso) {
    if (iso == null || iso.isEmpty) return 'never';
    try {
      final dt = DateTime.parse(iso).toLocal();
      String two(int n) => n.toString().padLeft(2, '0');
      return '${dt.year}-${two(dt.month)}-${two(dt.day)} ${two(dt.hour)}:${two(dt.minute)}';
    } catch (_) {
      return iso;
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Admin Devices'),
      content: SizedBox(
        width: 460,
        height: 360,
        child: Obx(() {
          if (_loading.value) {
            return const Center(child: CircularProgressIndicator(strokeWidth: 2));
          }
          if (_error.value.isNotEmpty) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(_error.value, textAlign: TextAlign.center),
                  const SizedBox(height: 8),
                  ElevatedButton(onPressed: _load, child: Text(translate('Retry'))),
                ],
              ),
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  '${_devices.length} / $_kMaxAdminDevices devices',
                  style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor),
                ),
              ),
              Expanded(
                child: _devices.isEmpty
                    ? const Center(child: Text('No devices yet.'))
                    : ListView.separated(
                        itemCount: _devices.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (ctx, i) {
                          final d = _devices[i];
                          return ListTile(
                            dense: true,
                            title: Text(d.name),
                            subtitle: Text(
                              'Last seen: ${_formatTimestamp(d.lastSeenAt)}'
                              '${d.lastIp != null && d.lastIp!.isNotEmpty ? '  ·  ${d.lastIp}' : ''}',
                              style: const TextStyle(fontSize: 11),
                            ),
                            trailing: IconButton(
                              icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
                              tooltip: 'Revoke',
                              onPressed: () => _confirmRevoke(d),
                            ),
                          );
                        },
                      ),
              ),
            ],
          );
        }),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(translate('Close')),
        ),
        Obx(() => ElevatedButton.icon(
              icon: const Icon(Icons.add, size: 16),
              label: const Text('Add Device'),
              onPressed: _devices.length >= _kMaxAdminDevices ? null : _addDevice,
            )),
      ],
    );
  }
}
