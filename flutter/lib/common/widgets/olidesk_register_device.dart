import 'dart:async';

import 'package:flutter/material.dart';

import '../../common.dart';
import '../../models/platform_model.dart';
import '../olidesk_deploy.dart';

// ---------------------------------------------------------------------------
// "Register this device" — the interactive fallback for device registration
// (see olidesk_deploy.dart's tryOlideskAutoRegister for the silent path).
// Shown once per app start, after the silent path has had a chance to run,
// if the device still isn't registered (see main.dart). Skipping just
// closes the dialog for this run; it's offered again next launch, same as
// a failed silent registration is retried next launch.
// ---------------------------------------------------------------------------

const _kNewGroupSentinel = '__add_new_group__';

Future<void> maybeShowOlideskRegisterDialog() async {
  if (bind.mainGetLocalOption(key: kOlideskRegisteredOptionKey) == 'Y') {
    return;
  }
  final ctx = await _waitForNavigatorContext();
  if (ctx == null || !ctx.mounted) return;
  // The caller (main.dart) only invokes this after windowManager.show(),
  // but that's an async OS-level resize -- give Flutter's own layout a
  // couple of frames to actually pick up the real window size before
  // measuring a dialog against it. Without this, an early call could still
  // land mid-resize and render the dialog squeezed into a tiny transient
  // size, same as calling this before window show did.
  await Future.delayed(const Duration(milliseconds: 300));
  if (!ctx.mounted) return;
  // Re-check right before showing: the silent path (or a previous instance
  // of this dialog, on a fast restart) could have registered in the
  // meantime.
  if (bind.mainGetLocalOption(key: kOlideskRegisteredOptionKey) == 'Y') {
    return;
  }
  await showDialog(
    context: ctx,
    barrierDismissible: false,
    builder: (_) => const _RegisterDeviceDialog(),
  );
}

// Bounded, like every other wait in this feature: the main window should
// show up well within this on any machine that isn't already broken in
// some other way, and this must never hang app startup forever.
Future<BuildContext?> _waitForNavigatorContext() async {
  for (var i = 0; i < 120; i++) {
    final ctx = globalKey.currentContext;
    if (ctx != null) return ctx;
    await Future.delayed(const Duration(milliseconds: 250));
  }
  return null;
}

class _RegisterDeviceDialog extends StatefulWidget {
  const _RegisterDeviceDialog();

  @override
  State<_RegisterDeviceDialog> createState() => _RegisterDeviceDialogState();
}

class _RegisterDeviceDialogState extends State<_RegisterDeviceDialog> {
  final _codeCtrl = TextEditingController();
  final _newGroupCtrl = TextEditingController();
  late final TextEditingController _nameCtrl;

  String _apiUrl = kOlideskDefaultApiUrl;
  List<String> _groups = [];
  // '' = no group, _kNewGroupSentinel = typing a new one, else a real
  // group name from the server.
  String? _selectedGroup;

  Timer? _debounce;
  bool _validatingCode = false;
  bool _codeValid = false;
  String _codeError = '';
  bool _registering = false;
  String _registerError = '';

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController(text: olideskHostname());
    unawaited(_prefillFromDeployFile());
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _codeCtrl.dispose();
    _newGroupCtrl.dispose();
    _nameCtrl.dispose();
    super.dispose();
  }

  // A deploy file can exist without a usable enroll_code (e.g. a silent
  // install that only passed DEVICENAME, or one whose code already
  // expired before first launch) -- if so, borrow its api_url/device_name
  // rather than make the user retype them.
  Future<void> _prefillFromDeployFile() async {
    final config = await readOlideskDeployFile();
    if (config == null || !mounted) return;
    final apiUrl = (config['api_url'] as String?)?.trim();
    final deviceName = (config['device_name'] as String?)?.trim();
    setState(() {
      if (apiUrl != null && apiUrl.isNotEmpty) _apiUrl = apiUrl;
      if (deviceName != null && deviceName.isNotEmpty) _nameCtrl.text = deviceName;
    });
  }

  String get _normalizedCode =>
      _codeCtrl.text.replaceAll(RegExp(r'[^A-Za-z0-9]'), '').toUpperCase();

  void _onCodeChanged(String _) {
    _debounce?.cancel();
    setState(() {
      _codeValid = false;
      _codeError = '';
      _groups = [];
      _selectedGroup = null;
    });
    final normalized = _normalizedCode;
    if (normalized.length < 8) return;
    _debounce = Timer(const Duration(milliseconds: 400), () => _validateCode(normalized));
  }

  Future<void> _validateCode(String normalized) async {
    setState(() {
      _validatingCode = true;
      _codeError = '';
    });
    final groups = await fetchOlideskGroups(apiUrl: _apiUrl, code: normalized);
    if (!mounted || normalized != _normalizedCode) return;
    setState(() {
      _validatingCode = false;
      if (groups == null) {
        _codeValid = false;
        _codeError = 'Invalid or expired code';
      } else {
        _codeValid = true;
        _groups = groups;
        _selectedGroup = '';
      }
    });
  }

  String get _effectiveGroup {
    if (_selectedGroup == _kNewGroupSentinel) return _newGroupCtrl.text.trim();
    return _selectedGroup ?? '';
  }

  Future<void> _register() async {
    if (!_codeValid || _registering) return;
    setState(() {
      _registering = true;
      _registerError = '';
    });

    final olideskId = await waitForOlideskId();
    if (!mounted) return;
    if (olideskId == null || olideskId.isEmpty) {
      setState(() {
        _registering = false;
        _registerError = 'No device ID yet — wait a moment and try again.';
      });
      return;
    }

    final hostname =
        _nameCtrl.text.trim().isNotEmpty ? _nameCtrl.text.trim() : olideskHostname();
    final result = await registerOlideskDevice(
      apiUrl: _apiUrl,
      code: _normalizedCode,
      olideskId: olideskId,
      hostname: hostname,
      os: olideskOsName(),
      group: _effectiveGroup.isNotEmpty ? _effectiveGroup : null,
    );
    if (!mounted) return;
    if (!result.ok) {
      setState(() {
        _registering = false;
        _registerError = result.message;
      });
      return;
    }

    await bind.mainSetLocalOption(key: kOlideskRegisteredOptionKey, value: 'Y');
    await logOlideskDeploy('registered via the "Register this device" dialog');
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Register this device'),
      // SingleChildScrollView: defense in depth against the dialog being
      // shown while the main window is still smaller than this content
      // needs (see the delay in maybeShowOlideskRegisterDialog for the
      // actual fix) -- scrolls instead of the actions row overlapping the
      // content if that ever happens again for some other reason.
      content: SingleChildScrollView(
        child: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Enter the enrollment code your administrator gave you to add '
              'this device to the address book.',
              style: TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _codeCtrl,
              autofocus: true,
              textCapitalization: TextCapitalization.characters,
              decoration: InputDecoration(
                labelText: 'Enrollment code',
                hintText: 'XXXX-XXXX',
                border: const OutlineInputBorder(),
                isDense: true,
                errorText: _codeError.isEmpty ? null : _codeError,
                suffixIcon: _validatingCode
                    ? const Padding(
                        padding: EdgeInsets.all(14),
                        child: SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    : (_codeValid
                        ? const Icon(Icons.check_circle, color: Colors.green)
                        : null),
              ),
              onChanged: _onCodeChanged,
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _nameCtrl,
              decoration: const InputDecoration(
                labelText: 'Device name',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 14),
            const Align(
              alignment: Alignment.centerLeft,
              child: Text('Client group', style: TextStyle(fontSize: 12)),
            ),
            const SizedBox(height: 4),
            if (_selectedGroup == _kNewGroupSentinel)
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _newGroupCtrl,
                      autofocus: true,
                      decoration: const InputDecoration(
                        hintText: 'New group name',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: () => setState(() => _selectedGroup = ''),
                    child: const Text('Back'),
                  ),
                ],
              )
            else
              DropdownButtonFormField<String>(
                value: _selectedGroup,
                isExpanded: true,
                hint: Text(_codeValid ? '(none)' : 'Enter a valid code first'),
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                items: [
                  const DropdownMenuItem(value: '', child: Text('(none)')),
                  ..._groups.map((g) => DropdownMenuItem(value: g, child: Text(g))),
                  const DropdownMenuItem(
                    value: _kNewGroupSentinel,
                    child: Text('+ Add new group...'),
                  ),
                ],
                onChanged: !_codeValid ? null : (v) => setState(() => _selectedGroup = v),
              ),
            if (_registerError.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(_registerError,
                  style: const TextStyle(color: Colors.redAccent, fontSize: 12)),
            ],
          ],
        ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _registering ? null : () => Navigator.of(context).pop(),
          child: const Text('Skip'),
        ),
        ElevatedButton(
          onPressed: (!_codeValid || _registering) ? null : _register,
          child: _registering
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                )
              : const Text('Register'),
        ),
      ],
    );
  }
}
