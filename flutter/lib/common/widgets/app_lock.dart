import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:get/get.dart';
import 'package:local_auth/local_auth.dart';

import '../../common.dart';
import '../../consts.dart';

/// Optional app-level lock (biometric, or whatever device PIN/pattern/
/// password the OS already has configured) gating the whole app -- client
/// list, saved credentials, everything -- for when the *phone* itself is
/// unlocked (stolen, borrowed, left somewhere) but Olidesk shouldn't be
/// immediately readable just from opening it. Off by default; see Settings.
/// Mobile only -- a stolen/borrowed-device threat model doesn't really
/// apply to a desktop machine the same way, and local_auth's desktop
/// support is inconsistent.
class AppLock {
  AppLock._();

  static final LocalAuthentication _auth = LocalAuthentication();

  /// True once unlocked for this "session" (app start, or since it last
  /// re-locked). Starts true when the lock is disabled, so the gate below
  /// never blocks anyone who hasn't opted in.
  static final RxBool unlocked = true.obs;

  /// Set when the app leaves the foreground while the lock is enabled, so
  /// resuming can tell how long it's actually been away -- a quick alt-tab
  /// to copy a 2FA code shouldn't re-lock the same as leaving it for an
  /// hour.
  static DateTime? _backgroundedAt;

  static bool get enabled =>
      isMobile && mainGetLocalBoolOptionSync(kOptionEnableAppLock);

  static int get timeoutMinutes {
    final raw = bind.mainGetLocalOption(key: kOptionAppLockTimeoutMinutes);
    return int.tryParse(raw) ?? kDefaultAppLockTimeoutMinutes;
  }

  /// Call once, early, at app start (see main.dart's _AppState.initState).
  static void init() {
    unlocked.value = !enabled;
  }

  /// Call this setting's own toggle handler, not just mainSetLocalBoolOption
  /// directly -- turning it on needs to actually lock immediately, and
  /// turning it off needs to release whatever's currently showing the lock
  /// screen.
  static Future<void> setEnabled(bool value) async {
    await mainSetLocalBoolOption(kOptionEnableAppLock, value);
    unlocked.value = !value;
  }

  /// Call from the root widget's didChangeAppLifecycleState.
  static void onLifecycleChanged(AppLifecycleState state) {
    if (!enabled) return;
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      _backgroundedAt ??= DateTime.now();
    } else if (state == AppLifecycleState.resumed) {
      final bgAt = _backgroundedAt;
      _backgroundedAt = null;
      if (bgAt == null) return;
      final away = DateTime.now().difference(bgAt);
      if (away >= Duration(minutes: timeoutMinutes)) {
        unlocked.value = false;
      }
    }
  }

  /// True, false, or null if authentication errored out (distinct from a
  /// plain "wrong PIN" false -- see AppLockScreen's handling).
  static Future<bool?> authenticate() async {
    try {
      final canCheck =
          await _auth.canCheckBiometrics || await _auth.isDeviceSupported();
      if (!canCheck) {
        // Nothing to authenticate against -- no biometric enrolled and no
        // device PIN/pattern/password set at all. Don't lock the user out
        // of their own app with literally no way back in.
        unlocked.value = true;
        return true;
      }
      final ok = await _auth.authenticate(
        localizedReason: translate('Unlock Olidesk'),
        options: const AuthenticationOptions(
          stickyAuth: true,
          biometricOnly: false,
        ),
      );
      if (ok) unlocked.value = true;
      return ok;
    } on PlatformException catch (e) {
      debugPrint('[app_lock] authenticate failed: $e');
      return null;
    }
  }
}

/// Full-screen gate shown in place of the app's real content while locked.
/// Prompts immediately on first build, and offers a retry button for when
/// the user dismisses the system prompt without completing it.
class AppLockScreen extends StatefulWidget {
  const AppLockScreen({Key? key}) : super(key: key);

  @override
  State<AppLockScreen> createState() => _AppLockScreenState();
}

class _AppLockScreenState extends State<AppLockScreen> {
  bool _authenticating = false;
  bool _lastAttemptErrored = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _tryUnlock());
  }

  Future<void> _tryUnlock() async {
    if (_authenticating) return;
    setState(() {
      _authenticating = true;
      _lastAttemptErrored = false;
    });
    final result = await AppLock.authenticate();
    if (!mounted) return;
    setState(() {
      _authenticating = false;
      _lastAttemptErrored = result == null;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.lock_outline,
                    size: 64, color: Theme.of(context).hintColor),
                const SizedBox(height: 24),
                Text(
                  translate('Olidesk is locked'),
                  style: Theme.of(context)
                      .textTheme
                      .titleMedium
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
                if (_lastAttemptErrored) ...[
                  const SizedBox(height: 8),
                  Text(
                    translate('Authentication failed, please try again.'),
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        fontSize: 12, color: Theme.of(context).hintColor),
                  ),
                ],
                const SizedBox(height: 24),
                if (_authenticating)
                  const CircularProgressIndicator()
                else
                  ElevatedButton.icon(
                    icon: const Icon(Icons.fingerprint),
                    label: Text(translate('Unlock')),
                    onPressed: _tryUnlock,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
