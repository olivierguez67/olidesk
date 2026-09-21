import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:get/get.dart';

import '../../common.dart';
import '../../models/platform_model.dart';
import '../../utils/http_service.dart' as http_svc;

// ---------------------------------------------------------------------------
// Enrollment code management — short-lived, revocable codes that replace
// the old long-lived DEPLOY_TOKEN baked into every client MSI. Minted here,
// consumed by a client's "Register this device" dialog
// (common/widgets/olidesk_register_device.dart) or a silent install's
// ENROLLCODE msiexec property. Mirrors olidesk_admin_devices.dart in both
// UI shape and the local-option keys it reads (same address-book API
// URL/token this admin app is already configured with).
// ---------------------------------------------------------------------------

const _kApiUrlKey = 'olidesk-ab-api-url';
const _kTokenKey = 'olidesk-ab-token';
const _kDefaultApiUrl = 'https://olidesk.olisys.co.il';

class _EnrollmentCode {
  final int id;
  final String code;
  final String createdAt;
  final String expiresAt;
  final String? revokedAt;
  final String? createdBy;
  final String? lastUsedAt;
  final int useCount;

  _EnrollmentCode.fromJson(Map<String, dynamic> j)
      : id = j['id'] as int,
        code = j['code'] as String? ?? '',
        createdAt = j['created_at'] as String? ?? '',
        expiresAt = j['expires_at'] as String? ?? '',
        revokedAt = j['revoked_at'] as String?,
        createdBy = j['created_by'] as String?,
        lastUsedAt = j['last_used_at'] as String?,
        useCount = j['use_count'] as int? ?? 0;

  bool get isRevoked => revokedAt != null && revokedAt!.isNotEmpty;

  bool get isExpired {
    try {
      return DateTime.parse(expiresAt).isBefore(DateTime.now().toUtc());
    } catch (_) {
      return false;
    }
  }

  String get status {
    if (isRevoked) return 'Revoked';
    if (isExpired) return 'Expired';
    return 'Active';
  }
}

Future<void> showOlideskEnrollmentCodesDialog(BuildContext context) {
  return showDialog(
    context: context,
    builder: (_) => const _EnrollmentCodesDialog(),
  );
}

class _EnrollmentCodesDialog extends StatefulWidget {
  const _EnrollmentCodesDialog();

  @override
  State<_EnrollmentCodesDialog> createState() => _EnrollmentCodesDialogState();
}

class _EnrollmentCodesDialogState extends State<_EnrollmentCodesDialog> {
  final _codes = <_EnrollmentCode>[].obs;
  final _loading = true.obs;
  final _error = ''.obs;
  final _creating = false.obs;

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
          .get(Uri.parse('$_apiUrl/api/admin/enrollment-codes'), headers: _headers)
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
      final list = data
          .map((d) => _EnrollmentCode.fromJson(d as Map<String, dynamic>))
          .toList();
      // Active codes first, then most-recently-created within each group.
      list.sort((a, b) {
        final aActive = a.status == 'Active';
        final bActive = b.status == 'Active';
        if (aActive != bActive) return aActive ? -1 : 1;
        return b.createdAt.compareTo(a.createdAt);
      });
      _codes.value = list;
    } catch (e) {
      _error.value = _friendlyError(e);
    } finally {
      _loading.value = false;
    }
  }

  Future<void> _createCode() async {
    _creating.value = true;
    try {
      final resp = await http_svc
          .post(
            Uri.parse('$_apiUrl/api/admin/enrollment-codes'),
            headers: _headers,
            body: jsonEncode({}),
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
      await _load();
      if (mounted) {
        _showNewCodeDialog(
          created['code'] as String? ?? '',
          created['expires_at'] as String? ?? '',
        );
      }
    } catch (e) {
      _error.value = _friendlyError(e);
    } finally {
      _creating.value = false;
    }
  }

  void _showNewCodeDialog(String code, String expiresAt) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Enrollment code created'),
        content: SizedBox(
          width: 380,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Give this code to whoever is deploying — type it into the '
                'client\'s "Register this device" dialog, or pass '
                'ENROLLCODE="$code" to a silent msiexec install. '
                'Expires ${_formatTimestamp(expiresAt)}.',
                style: const TextStyle(fontSize: 13),
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
                  code,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      fontFamily: 'monospace', fontSize: 20, letterSpacing: 2),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton.icon(
            icon: const Icon(Icons.copy, size: 16),
            label: const Text('Copy'),
            onPressed: () => Clipboard.setData(ClipboardData(text: code)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Done'),
          ),
        ],
      ),
    );
  }

  void _confirmRevoke(_EnrollmentCode code) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Revoke Enrollment Code'),
        content: Text(
            'Revoke "${code.code}"? Any device that hasn\'t used it yet will '
            'no longer be able to. This cannot be undone.'),
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
                      Uri.parse('$_apiUrl/api/admin/enrollment-codes/${code.id}'),
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

  Color _statusColor(String status, BuildContext context) {
    switch (status) {
      case 'Active':
        return Colors.green;
      case 'Expired':
        return Theme.of(context).hintColor;
      default:
        return Colors.redAccent;
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Enrollment Codes'),
      content: SizedBox(
        width: 520,
        height: 380,
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
          return _codes.isEmpty
              ? const Center(child: Text('No enrollment codes yet.'))
              : ListView.separated(
                  itemCount: _codes.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (ctx, i) {
                    final c = _codes[i];
                    return ListTile(
                      dense: true,
                      title: Row(
                        children: [
                          Text(c.code, style: const TextStyle(fontFamily: 'monospace')),
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                            decoration: BoxDecoration(
                              color: _statusColor(c.status, ctx).withOpacity(0.15),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              c.status,
                              style: TextStyle(
                                  fontSize: 10, color: _statusColor(c.status, ctx)),
                            ),
                          ),
                        ],
                      ),
                      subtitle: Text(
                        'Expires ${_formatTimestamp(c.expiresAt)}  ·  used ${c.useCount}x'
                        '${c.createdBy != null ? '  ·  by ${c.createdBy}' : ''}',
                        style: const TextStyle(fontSize: 11),
                      ),
                      trailing: c.isRevoked
                          ? null
                          : IconButton(
                              icon: const Icon(Icons.block, color: Colors.redAccent),
                              tooltip: 'Revoke',
                              onPressed: () => _confirmRevoke(c),
                            ),
                    );
                  },
                );
        }),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(translate('Close')),
        ),
        Obx(() => ElevatedButton.icon(
              icon: _creating.value
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    )
                  : const Icon(Icons.add, size: 16),
              label: const Text('New Code'),
              onPressed: _creating.value ? null : _createCode,
            )),
      ],
    );
  }
}
