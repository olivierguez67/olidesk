import 'dart:async';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../common.dart';
import '../../consts.dart';
import '../../main.dart' show kWindowId;
import '../../models/platform_model.dart';
import '../../models/server_model.dart' show kUsePermanentPassword;
import '../../utils/multi_window_manager.dart';
import '../olidesk_deploy.dart';
import 'custom_password.dart';
import 'dialog.dart' show Dialog2FaField;

// ---------------------------------------------------------------------------
// First-launch onboarding — three steps, client build only (see
// kOlideskClientBuild): Register (enrollment code, optional/skippable) ->
// Password (mandatory) -> Two-factor authentication (mandatory).
//
// Runs as its own window (WindowType.Onboarding, ~900x700), not a dialog
// inside the main window. A real machine at 1366x768 with the client's
// small default window size couldn't fit this content without scrolling
// or the action buttons overlapping fields -- constraining it to whatever
// the main window happened to be sized at was the actual bug, not
// anything about the content's own layout. A dedicated window sidesteps
// that entirely: fixed size, set once at creation
// (RustDeskMultiWindowManager.newOnboardingWindow), independent of
// whatever the main window is doing.
//
// The client build hides the whole Settings page (address book, and
// everything else), so this wizard is the ONLY place a permanent password
// or 2FA can ever be set on a client install -- hence Password/2FA aren't
// skippable the way Register is. "Skip" on the Register step only skips
// address-book registration; it advances to Password, never closes the
// window.
// ---------------------------------------------------------------------------

const kOlideskOnboardedOptionKey = 'olidesk-onboarded';
const _kNewGroupSentinel = '__add_new_group__';

Future<void> maybeOpenOlideskOnboardingWindow() async {
  if (bind.mainGetLocalOption(key: kOlideskOnboardedOptionKey) == 'Y') {
    return;
  }
  await rustDeskWinManager.newOnboardingWindow();
}

void _closeThisWindow() {
  if (kWindowId == null) return;
  WindowController.fromWindowId(kWindowId!).close();
}

// ---------------------------------------------------------------------------
// Shared step chrome: an AppBar-titled body area with plenty of room (this
// window is a fixed ~900x700, set at creation -- see
// RustDeskMultiWindowManager.newOnboardingWindow), and actions pinned to a
// dedicated bottom bar that can never overlap the body's fields. The
// SingleChildScrollView is defensive only: content is sized to fit
// comfortably without ever needing to actually scroll.
// ---------------------------------------------------------------------------

class _WizardScaffold extends StatelessWidget {
  final String title;
  final Widget body;
  final List<Widget> actions;
  const _WizardScaffold({
    required this.title,
    required this.body,
    required this.actions,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title), automaticallyImplyLeading: false),
      body: Padding(
        padding: const EdgeInsets.all(28),
        child: SingleChildScrollView(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 620),
              child: body,
            ),
          ),
        ),
      ),
      bottomNavigationBar: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 18),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            for (var i = 0; i < actions.length; i++) ...[
              if (i > 0) const SizedBox(width: 12),
              actions[i],
            ],
          ],
        ),
      ),
    );
  }
}

class OlideskOnboardingWindow extends StatefulWidget {
  const OlideskOnboardingWindow({super.key});

  @override
  State<OlideskOnboardingWindow> createState() => _OlideskOnboardingWindowState();
}

enum _Step { register, password, twoFa }

class _OlideskOnboardingWindowState extends State<OlideskOnboardingWindow> {
  late _Step _step;
  late final TextEditingController _deviceNameCtrl;

  @override
  void initState() {
    super.initState();
    final alreadyRegistered =
        bind.mainGetLocalOption(key: kOlideskRegisteredOptionKey) == 'Y';
    _step = alreadyRegistered ? _Step.password : _Step.register;
    _deviceNameCtrl = TextEditingController(text: olideskHostname());
    unawaited(_prefillDeviceName());
  }

  Future<void> _prefillDeviceName() async {
    final config = await readOlideskDeployFile();
    final deviceName = (config?['device_name'] as String?)?.trim();
    if (deviceName != null && deviceName.isNotEmpty && mounted) {
      setState(() => _deviceNameCtrl.text = deviceName);
    }
  }

  @override
  void dispose() {
    _deviceNameCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    switch (_step) {
      case _Step.register:
        return _RegisterStep(
          deviceNameCtrl: _deviceNameCtrl,
          onAdvance: () => setState(() => _step = _Step.password),
        );
      case _Step.password:
        return _PasswordStep(
          onDone: () => setState(() => _step = _Step.twoFa),
        );
      case _Step.twoFa:
        return _TwoFaStep(
          deviceName: _deviceNameCtrl.text.trim(),
          onDone: () async {
            await bind.mainSetLocalOption(
                key: kOlideskOnboardedOptionKey, value: 'Y');
            _closeThisWindow();
          },
        );
    }
  }
}

// ---------------------------------------------------------------------------
// Step 1: Register (enrollment code, device name, group) -- the only
// skippable step. See olidesk_deploy.dart for the shared registration
// helpers this reuses.
// ---------------------------------------------------------------------------

class _RegisterStep extends StatefulWidget {
  final TextEditingController deviceNameCtrl;
  final VoidCallback onAdvance;
  const _RegisterStep({required this.deviceNameCtrl, required this.onAdvance});

  @override
  State<_RegisterStep> createState() => _RegisterStepState();
}

class _RegisterStepState extends State<_RegisterStep> {
  final _codeCtrl = TextEditingController();
  final _newGroupCtrl = TextEditingController();

  String _apiUrl = kOlideskDefaultApiUrl;
  List<String> _groups = [];
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
    unawaited(_prefillApiUrl());
  }

  Future<void> _prefillApiUrl() async {
    final config = await readOlideskDeployFile();
    final apiUrl = (config?['api_url'] as String?)?.trim();
    if (apiUrl != null && apiUrl.isNotEmpty && mounted) {
      setState(() => _apiUrl = apiUrl);
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _codeCtrl.dispose();
    _newGroupCtrl.dispose();
    super.dispose();
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

    final hostname = widget.deviceNameCtrl.text.trim().isNotEmpty
        ? widget.deviceNameCtrl.text.trim()
        : olideskHostname();
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
    await logOlideskDeploy('registered via the onboarding wizard');
    widget.onAdvance();
  }

  @override
  Widget build(BuildContext context) {
    return _WizardScaffold(
      title: 'Register this device (1 of 3)',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'Enter the enrollment code your administrator gave you to add '
            'this device to the address book.',
            style: TextStyle(fontSize: 14),
          ),
          const SizedBox(height: 20),
          TextField(
            controller: _codeCtrl,
            autofocus: true,
            textCapitalization: TextCapitalization.characters,
            decoration: InputDecoration(
              labelText: 'Enrollment code',
              hintText: 'XXXX-XXXX',
              border: const OutlineInputBorder(),
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
          const SizedBox(height: 20),
          TextField(
            controller: widget.deviceNameCtrl,
            decoration: const InputDecoration(
              labelText: 'Device name',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 20),
          const Align(
            alignment: Alignment.centerLeft,
            child: Text('Client group', style: TextStyle(fontSize: 13)),
          ),
          const SizedBox(height: 6),
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
                    ),
                  ),
                ),
                const SizedBox(width: 8),
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
              decoration: const InputDecoration(border: OutlineInputBorder()),
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
            const SizedBox(height: 14),
            Text(_registerError,
                style: const TextStyle(color: Colors.redAccent, fontSize: 13)),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: _registering ? null : widget.onAdvance,
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

// ---------------------------------------------------------------------------
// Step 2: permanent password. Mandatory -- no skip. Same validation rules
// and FFI call as the normal Settings "Set Password" dialog (see
// setPasswordDialog in desktop_home_page.dart), except a 10-character
// minimum instead of that dialog's 8. Also switches verification-method to
// permanent-password-only, since a password that can't actually be used to
// log in wouldn't be much of a "permanent password" -- matches this
// wizard's whole point of leaving the device fully usable in one pass.
// ---------------------------------------------------------------------------

class _PasswordStep extends StatefulWidget {
  final VoidCallback onDone;
  const _PasswordStep({required this.onDone});

  @override
  State<_PasswordStep> createState() => _PasswordStepState();
}

class _PasswordStepState extends State<_PasswordStep> {
  final _passCtrl = TextEditingController();
  final _confirmCtrl = TextEditingController();
  final RxString _rxPass = ''.obs;
  bool _obscure1 = true;
  bool _obscure2 = true;
  String _errMsg = '';
  bool _submitting = false;

  final _rules = [
    DigitValidationRule(),
    UppercaseValidationRule(),
    LowercaseValidationRule(),
    MinCharactersValidationRule(10),
  ];

  @override
  void dispose() {
    _passCtrl.dispose();
    _confirmCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final pass = _passCtrl.text.trim();
    final confirm = _confirmCtrl.text.trim();
    setState(() => _errMsg = '');

    final violations = _rules.where((r) => !r.validate(pass));
    if (violations.isNotEmpty) {
      setState(() => _errMsg = violations.map((r) => r.name).join(', '));
      return;
    }
    if (pass != confirm) {
      setState(() => _errMsg = translate('The confirmation is not identical.'));
      return;
    }

    setState(() => _submitting = true);
    final ok = await bind.mainSetPermanentPasswordWithResult(password: pass);
    if (!mounted) return;
    if (!ok) {
      setState(() {
        _submitting = false;
        _errMsg = translate('Failed');
      });
      return;
    }
    await bind.mainSetOption(
        key: kOptionVerificationMethod, value: kUsePermanentPassword);
    // Deliberately no logging of anything from this step -- pass/confirm
    // never appear in a log line anywhere in this file.
    widget.onDone();
  }

  @override
  Widget build(BuildContext context) {
    final maxLength = bind.mainMaxEncryptLen();
    return _WizardScaffold(
      title: 'Set a permanent password (2 of 3)',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'This password is required to remote-control this device. It '
            'can only be set here — the client has no Settings page.',
            style: TextStyle(fontSize: 14),
          ),
          const SizedBox(height: 20),
          TextField(
            controller: _passCtrl,
            autofocus: true,
            obscureText: _obscure1,
            maxLength: maxLength,
            decoration: InputDecoration(
              labelText: 'Password',
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                icon: Icon(_obscure1 ? Icons.visibility : Icons.visibility_off),
                onPressed: () => setState(() => _obscure1 = !_obscure1),
              ),
            ),
            onChanged: (v) {
              _rxPass.value = v.trim();
              setState(() => _errMsg = '');
            },
          ),
          PasswordStrengthIndicator(password: _rxPass),
          const SizedBox(height: 12),
          TextField(
            controller: _confirmCtrl,
            obscureText: _obscure2,
            maxLength: maxLength,
            decoration: InputDecoration(
              labelText: 'Confirm password',
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                icon: Icon(_obscure2 ? Icons.visibility : Icons.visibility_off),
                onPressed: () => setState(() => _obscure2 = !_obscure2),
              ),
            ),
            onChanged: (_) => setState(() => _errMsg = ''),
          ),
          const SizedBox(height: 12),
          Obx(() => Wrap(
                spacing: 6,
                runSpacing: 6,
                children: _rules.map((r) {
                  final checked = r.validate(_rxPass.value);
                  return Chip(
                    label: Text(r.name, style: const TextStyle(fontSize: 12)),
                    backgroundColor:
                        checked ? Colors.green.withOpacity(0.15) : null,
                    avatar: Icon(
                      checked ? Icons.check_circle : Icons.circle_outlined,
                      size: 16,
                      color: checked ? Colors.green : null,
                    ),
                  );
                }).toList(),
              )),
          if (_errMsg.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(_errMsg, style: const TextStyle(color: Colors.redAccent, fontSize: 13)),
          ],
        ],
      ),
      actions: [
        ElevatedButton(
          onPressed: _submitting ? null : _submit,
          child: _submitting
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                )
              : const Text('Continue'),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Step 3: two-factor authentication. Mandatory -- no skip.
//
// mainGenerate2Fa() returns a full otpauth:// URL, but its label/issuer are
// hardcoded server-side (Rust, auth_2fa.rs) to the numeric device ID and
// "Olidesk Connection" -- not this device's name. TOTP codes only depend
// on the secret (plus algorithm/digits/period, all standard defaults
// here), never on the label/issuer, which are purely cosmetic in the
// authenticator app -- so it's safe to extract just the secret and build
// our own otpauth URI with the label the user actually asked for
// ("Olidesk - <device name>") without touching the Rust side at all.
// mainVerify2Fa both verifies AND persists/enables 2FA -- there's no
// separate "enable" call.
// ---------------------------------------------------------------------------

class _TwoFaStep extends StatefulWidget {
  final String deviceName;
  final VoidCallback onDone;
  const _TwoFaStep({required this.deviceName, required this.onDone});

  @override
  State<_TwoFaStep> createState() => _TwoFaStepState();
}

class _TwoFaStepState extends State<_TwoFaStep> {
  final _codeCtrl = TextEditingController();
  String? _qrData;
  String? _secret;
  bool _loading = true;
  bool _submitting = false;
  String _errMsg = '';

  @override
  void initState() {
    super.initState();
    unawaited(_generate());
  }

  @override
  void dispose() {
    _codeCtrl.dispose();
    super.dispose();
  }

  Future<void> _generate() async {
    final raw = await bind.mainGenerate2Fa();
    final secret = RegExp(r'secret=([^&]+)').firstMatch(raw)?.group(1);
    if (!mounted) return;
    setState(() {
      _secret = secret;
      _qrData = (secret == null || secret.isEmpty) ? null : _buildOtpAuthUri(secret);
      _loading = false;
    });
  }

  String _buildOtpAuthUri(String secret) {
    final name = widget.deviceName.isNotEmpty ? widget.deviceName : olideskHostname();
    final label = Uri.encodeComponent('Olidesk - $name');
    final issuer = Uri.encodeComponent('Olidesk');
    final encodedSecret = Uri.encodeComponent(secret);
    return 'otpauth://totp/$label?secret=$encodedSecret&issuer=$issuer&algorithm=SHA1&digits=6&period=30';
  }

  Future<void> _submit() async {
    final code = _codeCtrl.text.trim();
    setState(() {
      _errMsg = '';
      _submitting = true;
    });
    final ok = await bind.mainVerify2Fa(code: code);
    if (!mounted) return;
    if (!ok) {
      setState(() {
        _submitting = false;
        _errMsg = translate('wrong-2fa-code');
      });
      return;
    }
    // Deliberately no logging of anything from this step -- the secret and
    // the submitted code never appear in a log line anywhere in this file.
    widget.onDone();
  }

  @override
  Widget build(BuildContext context) {
    final codeField = Dialog2FaField(
      controller: _codeCtrl,
      errorText: _errMsg.isEmpty ? null : _errMsg,
      onChanged: () => setState(() => _errMsg = ''),
      title: translate('Verification code'),
      readyCallback: _submitting ? null : _submit,
    );
    final ready = _codeCtrl.text.length == 6 &&
        _codeCtrl.text.codeUnits.every((c) => c >= 48 && c <= 57);

    return _WizardScaffold(
      title: 'Set up two-factor authentication (3 of 3)',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'Scan this code with your authenticator app, then enter the '
            'current 6-digit code below to confirm.',
            style: TextStyle(fontSize: 14),
          ),
          const SizedBox(height: 20),
          if (_loading)
            const Center(
                child: Padding(
              padding: EdgeInsets.all(24),
              child: CircularProgressIndicator(strokeWidth: 2),
            ))
          else if (_qrData == null)
            const Text('Could not generate a 2FA code. Please try again.',
                style: TextStyle(color: Colors.redAccent, fontSize: 13))
          else ...[
            Center(
              child: SizedBox(
                width: 220,
                height: 220,
                child: QrImageView(
                  backgroundColor: Colors.white,
                  data: _qrData!,
                  version: QrVersions.auto,
                  size: 220,
                  gapless: false,
                ),
              ),
            ).marginOnly(bottom: 10),
            if (_secret != null)
              Center(
                child: SelectableText(_secret!,
                    style: const TextStyle(fontSize: 13, fontFamily: 'monospace')),
              ).marginOnly(bottom: 18),
            Row(children: [Expanded(child: codeField)]),
          ],
        ],
      ),
      actions: [
        ElevatedButton(
          onPressed: (!ready || _submitting || _qrData == null) ? null : _submit,
          child: _submitting
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                )
              : const Text('Confirm & Finish'),
        ),
      ],
    );
  }
}
