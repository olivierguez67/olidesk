import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bot_toast/bot_toast.dart';
import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hbb/common/widgets/overlay.dart';
import 'package:flutter_hbb/desktop/pages/desktop_tab_page.dart';
import 'package:flutter_hbb/desktop/pages/install_page.dart';
import 'package:flutter_hbb/desktop/pages/server_page.dart';
import 'package:flutter_hbb/desktop/screen/desktop_file_transfer_screen.dart';
import 'package:flutter_hbb/desktop/screen/desktop_view_camera_screen.dart';
import 'package:flutter_hbb/desktop/screen/desktop_port_forward_screen.dart';
import 'package:flutter_hbb/desktop/screen/desktop_remote_screen.dart';
import 'package:flutter_hbb/desktop/screen/desktop_terminal_screen.dart';
import 'package:flutter_hbb/desktop/widgets/refresh_wrapper.dart';
import 'package:flutter_hbb/models/state_model.dart';
import 'package:flutter_hbb/utils/multi_window_manager.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:get/get.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';

import 'common.dart';
import 'common/olidesk_deploy.dart';
import 'common/widgets/olidesk_register_device.dart';
import 'consts.dart';
import 'mobile/pages/home_page.dart';
import 'mobile/pages/server_page.dart';
import 'models/platform_model.dart';

import 'package:flutter_hbb/plugin/handlers.dart'
    if (dart.library.html) 'package:flutter_hbb/web/plugin/handlers.dart';

/// Basic window and launch properties.
int? kWindowId;
WindowType? kWindowType;
late List<String> kBootArgs;

Future<void> main(List<String> args) async {
  earlyAssert();
  WidgetsFlutterBinding.ensureInitialized();

  debugPrint("launch args: $args");
  kBootArgs = List.from(args);

  if (!isDesktop) {
    runMobileApp();
    return;
  }
  // main window
  if (args.isNotEmpty && args.first == 'multi_window') {
    kWindowId = int.parse(args[1]);
    stateGlobal.setWindowId(kWindowId!);
    final argument = args[2].isEmpty
        ? <String, dynamic>{}
        : jsonDecode(args[2]) as Map<String, dynamic>;
    int type = argument['type'] ?? -1;
    // to-do: No need to parse window id ?
    // Because stateGlobal.windowId is a global value.
    argument['windowId'] = kWindowId;
    kWindowType = type.windowType;
    // Every other sub-window type keeps the app's frameless custom-chrome
    // look; the onboarding wizard is a plain utility window with its own
    // native title bar (standard close/minimize controls) instead, since
    // it isn't built on the DesktopTab machinery that look depends on.
    if (!isMacOS && kWindowType != WindowType.Onboarding) {
      WindowController.fromWindowId(kWindowId!).showTitleBar(false);
    }
    switch (kWindowType) {
      case WindowType.RemoteDesktop:
        desktopType = DesktopType.remote;
        runMultiWindow(
          argument,
          kAppTypeDesktopRemote,
        );
        break;
      case WindowType.FileTransfer:
        desktopType = DesktopType.fileTransfer;
        runMultiWindow(
          argument,
          kAppTypeDesktopFileTransfer,
        );
        break;
      case WindowType.ViewCamera:
        desktopType = DesktopType.viewCamera;
        runMultiWindow(
          argument,
          kAppTypeDesktopViewCamera,
        );
        break;
      case WindowType.PortForward:
        desktopType = DesktopType.portForward;
        runMultiWindow(
          argument,
          kAppTypeDesktopPortForward,
        );
        break;
      case WindowType.Terminal:
        desktopType = DesktopType.terminal;
        runMultiWindow(
          argument,
          kAppTypeDesktopTerminal,
        );
        break;
      case WindowType.Onboarding:
        runMultiWindow(
          argument,
          kAppTypeOnboarding,
        );
        break;
      default:
        break;
    }
  } else if (args.isNotEmpty && args.first == '--cm') {
    debugPrint("--cm started");
    desktopType = DesktopType.cm;
    await windowManager.ensureInitialized();
    runConnectionManagerScreen();
  } else if (args.contains('--install')) {
    runInstallPage();
  } else {
    desktopType = DesktopType.main;
    await windowManager.ensureInitialized();
    windowManager.setPreventClose(true);
    if (isMacOS) {
      disableWindowMovable(kWindowId);
    }
    runMainApp(true);
  }
}

Future<void> initEnv(String appType) async {
  // global shared preference
  await platformFFI.init(appType);
  // global FFI, use this **ONLY** for global configuration
  // for convenience, use global FFI on mobile platform
  // focus on multi-ffi on desktop first
  await initGlobalFFI();
  // await Firebase.initializeApp();
  _registerEventHandler();
  // Update the system theme.
  updateSystemWindowTheme();
}

void runMainApp(bool startService) async {
  // register uni links
  await initEnv(kAppTypeMain);
  checkUpdate();
  // trigger connection status updater
  await bind.mainCheckConnectStatus();
  if (startService) {
    gFFI.serverModel.startService();
    bind.pluginSyncUi(syncTo: kAppTypeMain);
    bind.pluginListReload();
  }
  // Fire-and-forget: a no-op unless a deployment package dropped
  // olidesk-deploy.json next to the executable (see olidesk_deploy.dart).
  // Runs after startService() so the background service (and the RustDesk
  // id it serves over IPC) is already coming up by the time this polls it.
  // The interactive onboarding wizard (olidesk_register_device.dart) is
  // triggered separately below, once the main window is shown -- it opens
  // as its own independent window now (see the comment there), so unlike
  // when it was a dialog constrained by the main window's own size, timing
  // relative to that window no longer affects its layout; kept at the same
  // trigger point anyway since that's already proven to work.
  unawaited(tryOlideskAutoRegister());
  await Future.wait([gFFI.abModel.loadCache(), gFFI.groupModel.loadCache()]);
  gFFI.userModel.refreshCurrentUser();
  runApp(App());

  bool? alwaysOnTop;
  if (isDesktop) {
    alwaysOnTop =
        bind.mainGetBuildinOption(key: "main-window-always-on-top") == 'Y';
  }

  // Set window option.
  WindowOptions windowOptions = getHiddenTitleBarWindowOptions(
      isMainWindow: true, alwaysOnTop: alwaysOnTop);
  windowManager.waitUntilReadyToShow(windowOptions, () async {
    // Restore the location of the main window before window hide or show.
    await restoreWindowPosition(WindowType.Main);
    // Check the startup argument, if we successfully handle the argument, we keep the main window hidden.
    final handledByUniLinks = await initUniLinks();
    debugPrint("handled by uni links: $handledByUniLinks");
    if (handledByUniLinks || handleUriLink(cmdArgs: kBootArgs)) {
      windowManager.hide();
    } else {
      windowManager.show();
      windowManager.focus();
      // Move registration of active main window here to prevent from async visible check.
      rustDeskWinManager.registerActiveWindow(kWindowMainId);
      // Client build only: the admin build has a full Settings page, so
      // this onboarding wizard (register / set a permanent password /
      // enable 2FA) has no reason to run there -- kOlideskClientBuild is a
      // compile-time constant, so this whole call is dead-code-eliminated
      // from the admin build entirely, same as the address book is. Opens
      // as its own window (WindowType.Onboarding), not a dialog inside
      // this one -- the main window's own default size is too small on
      // common laptop resolutions for the wizard's content to fit. A no-op
      // if the wizard already ran to completion before.
      if (kOlideskClientBuild) {
        unawaited(maybeOpenOlideskOnboardingWindow());
      }
    }
    windowManager.setOpacity(1);
    windowManager.setTitle(getWindowName());
    // Do not use `windowManager.setResizable()` here.
    setResizable(!bind.isIncomingOnly());
  });
}

void runMobileApp() async {
  await initEnv(kAppTypeMain);
  checkUpdate();
  if (isAndroid) androidChannelInit();
  if (isAndroid) platformFFI.syncAndroidServiceAppDirConfigPath();
  draggablePositions.load();
  await Future.wait([gFFI.abModel.loadCache(), gFFI.groupModel.loadCache()]);
  gFFI.userModel.refreshCurrentUser();
  runApp(App());
  await initUniLinks();
}

void runMultiWindow(
  Map<String, dynamic> argument,
  String appType,
) async {
  await initEnv(appType);
  final title = getWindowName();
  // set prevent close to true, we handle close event manually -- except
  // for the onboarding wizard, a plain one-shot window with no
  // DesktopTab/WindowListener machinery to handle that manual close, so it
  // just uses the OS's normal close behavior instead (see the comment on
  // the showTitleBar(false) call above for why it also skips that).
  if (appType != kAppTypeOnboarding) {
    WindowController.fromWindowId(kWindowId!).setPreventClose(true);
  }
  if (isMacOS) {
    disableWindowMovable(kWindowId);
  }
  late Widget widget;
  switch (appType) {
    case kAppTypeDesktopRemote:
      draggablePositions.load();
      widget = DesktopRemoteScreen(
        params: argument,
      );
      break;
    case kAppTypeDesktopFileTransfer:
      widget = DesktopFileTransferScreen(
        params: argument,
      );
      break;
    case kAppTypeDesktopViewCamera:
      draggablePositions.load();
      widget = DesktopViewCameraScreen(
        params: argument,
      );
      break;
    case kAppTypeDesktopPortForward:
      widget = DesktopPortForwardScreen(
        params: argument,
      );
      break;
    case kAppTypeDesktopTerminal:
      widget = DesktopTerminalScreen(
        params: argument,
      );
      break;
    case kAppTypeOnboarding:
      widget = const OlideskOnboardingWindow();
      break;
    default:
      // no such appType
      exit(0);
  }
  _runApp(
    title,
    widget,
    MyTheme.currentThemeMode(),
  );
  // we do not hide titlebar on win7 because of the frame overflow.
  if (kUseCompatibleUiMode) {
    WindowController.fromWindowId(kWindowId!).showTitleBar(true);
  }
  switch (appType) {
    case kAppTypeDesktopRemote:
      // If screen rect is set, the window will be moved to the target screen and then set fullscreen.
      if (argument['screen_rect'] == null) {
        // display can be used to control the offset of the window.
        await restoreWindowPosition(
          WindowType.RemoteDesktop,
          windowId: kWindowId!,
          peerId: argument['id'] as String?,
          display: argument['display'] as int?,
        );
      }
      break;
    case kAppTypeDesktopFileTransfer:
      await restoreWindowPosition(WindowType.FileTransfer,
          windowId: kWindowId!);
      break;
    case kAppTypeDesktopViewCamera:
      // If screen rect is set, the window will be moved to the target screen and then set fullscreen.
      if (argument['screen_rect'] == null) {
        // display can be used to control the offset of the window.
        await restoreWindowPosition(
          WindowType.ViewCamera,
          windowId: kWindowId!,
          peerId: argument['id'] as String?,
          // FIXME: fix display index.
          display: argument['display'] as int?,
        );
      }
      break;
    case kAppTypeDesktopPortForward:
      await restoreWindowPosition(WindowType.PortForward, windowId: kWindowId!);
      break;
    case kAppTypeDesktopTerminal:
      await restoreWindowPosition(WindowType.Terminal, windowId: kWindowId!);
      break;
    case kAppTypeOnboarding:
      // No restoreWindowPosition: newOnboardingWindow() (multi_window_
      // manager.dart) already set a fixed 900x700 centered frame at
      // creation time, and a one-shot wizard has no reason to remember a
      // size/position across runs the way a resizable session window does.
      break;
    default:
      // no such appType
      exit(0);
  }
  // show window from hidden status
  WindowController.fromWindowId(kWindowId!).show();
}

void runConnectionManagerScreen() async {
  await initEnv(kAppTypeConnectionManager);
  _runApp(
    '',
    const DesktopServerPage(),
    MyTheme.currentThemeMode(),
  );
  final hide = await bind.cmGetConfig(name: "hide_cm") == 'true';
  gFFI.serverModel.hideCm = hide;
  if (hide) {
    await hideCmWindow(isStartup: true);
  } else {
    await showCmWindow(isStartup: true);
  }
  setResizable(false);
  // Start the uni links handler and redirect links to Native, not for Flutter.
  listenUniLinks(handleByFlutter: false);
}

bool _isCmReadyToShow = false;

showCmWindow({bool isStartup = false}) async {
  if (isStartup) {
    WindowOptions windowOptions = getHiddenTitleBarWindowOptions(
        size: kConnectionManagerWindowSizeClosedChat, alwaysOnTop: true);
    await windowManager.waitUntilReadyToShow(windowOptions, null);
    bind.mainHideDock();
    await Future.wait([
      windowManager.show(),
      windowManager.focus(),
      windowManager.setOpacity(1)
    ]);
    // ensure initial window size to be changed
    await windowManager.setSizeAlignment(
        kConnectionManagerWindowSizeClosedChat, Alignment.topRight);
    _isCmReadyToShow = true;
  } else if (_isCmReadyToShow) {
    if (await windowManager.getOpacity() != 1) {
      await windowManager.setOpacity(1);
      await windowManager.focus();
      await windowManager.minimize(); //needed
      await windowManager.setSizeAlignment(
          kConnectionManagerWindowSizeClosedChat, Alignment.topRight);
      windowOnTop(null);
    }
  }
}

hideCmWindow({bool isStartup = false}) async {
  if (isStartup) {
    WindowOptions windowOptions = getHiddenTitleBarWindowOptions(
        size: kConnectionManagerWindowSizeClosedChat);
    windowManager.setOpacity(0);
    await windowManager.waitUntilReadyToShow(windowOptions, null);
    bind.mainHideDock();
    await windowManager.minimize();
    await windowManager.hide();
    _isCmReadyToShow = true;
  } else if (_isCmReadyToShow) {
    if (await windowManager.getOpacity() != 0) {
      await windowManager.setOpacity(0);
      bind.mainHideDock();
      await windowManager.minimize();
      await windowManager.hide();
    }
  }
}

void _runApp(
  String title,
  Widget home,
  ThemeMode themeMode,
) {
  final botToastBuilder = BotToastInit();
  runApp(RefreshWrapper(
    builder: (context) => GetMaterialApp(
      navigatorKey: globalKey,
      debugShowCheckedModeBanner: false,
      title: title,
      theme: MyTheme.lightTheme,
      darkTheme: MyTheme.darkTheme,
      themeMode: themeMode,
      home: home,
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: supportedLocales,
      navigatorObservers: [
        // FirebaseAnalyticsObserver(analytics: analytics),
        BotToastNavigatorObserver(),
      ],
      builder: (context, child) {
        child = _keepScaleBuilder(context, child);
        child = botToastBuilder(context, child);
        return child;
      },
    ),
  ));
}

void runInstallPage() async {
  await windowManager.ensureInitialized();
  await initEnv(kAppTypeMain);
  _runApp('', const InstallPage(), MyTheme.currentThemeMode());
  WindowOptions windowOptions =
      getHiddenTitleBarWindowOptions(size: Size(800, 600), center: true);
  windowManager.waitUntilReadyToShow(windowOptions, () async {
    windowManager.show();
    windowManager.focus();
    windowManager.setOpacity(1);
    windowManager.setAlignment(Alignment.center); // ensure
  });
}

WindowOptions getHiddenTitleBarWindowOptions(
    {bool isMainWindow = false,
    Size? size,
    bool center = false,
    bool? alwaysOnTop}) {
  var defaultTitleBarStyle = TitleBarStyle.hidden;
  // we do not hide titlebar on win7 because of the frame overflow.
  if (kUseCompatibleUiMode) {
    defaultTitleBarStyle = TitleBarStyle.normal;
  }
  return WindowOptions(
    size: size,
    center: center,
    backgroundColor: (isMacOS && isMainWindow) ? null : Colors.transparent,
    skipTaskbar: false,
    titleBarStyle: defaultTitleBarStyle,
    alwaysOnTop: alwaysOnTop,
  );
}

class App extends StatefulWidget {
  @override
  State<App> createState() => _AppState();
}

class _AppState extends State<App> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.window.onPlatformBrightnessChanged = () {
      final userPreference = MyTheme.getThemeModePreference();
      if (userPreference != ThemeMode.system) return;
      WidgetsBinding.instance.handlePlatformBrightnessChanged();
      final systemIsDark =
          WidgetsBinding.instance.platformDispatcher.platformBrightness ==
              Brightness.dark;
      final ThemeMode to;
      if (systemIsDark) {
        to = ThemeMode.dark;
      } else {
        to = ThemeMode.light;
      }
      Get.changeThemeMode(to);
      // Synchronize the window theme of the system.
      updateSystemWindowTheme();
      if (desktopType == DesktopType.main) {
        bind.mainChangeTheme(dark: to.toShortString());
      }
    };
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _updateOrientation());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeMetrics() {
    _updateOrientation();
  }

  void _updateOrientation() {
    if (isDesktop) return;

    // Don't use `MediaQuery.of(context).orientation` in `didChangeMetrics()`,
    // my test (Flutter 3.19.6, Android 14) is always the reverse value.
    // https://github.com/flutter/flutter/issues/60899
    // stateGlobal.isPortrait.value =
    //     MediaQuery.of(context).orientation == Orientation.portrait;

    final orientation = View.of(context).physicalSize.aspectRatio > 1
        ? Orientation.landscape
        : Orientation.portrait;
    stateGlobal.isPortrait.value = orientation == Orientation.portrait;
  }

  @override
  Widget build(BuildContext context) {
    // final analytics = FirebaseAnalytics.instance;
    final botToastBuilder = BotToastInit();
    return RefreshWrapper(builder: (context) {
      return MultiProvider(
        providers: [
          // global configuration
          // use session related FFI when in remote control or file transfer page
          ChangeNotifierProvider.value(value: gFFI.ffiModel),
          ChangeNotifierProvider.value(value: gFFI.imageModel),
          ChangeNotifierProvider.value(value: gFFI.cursorModel),
          ChangeNotifierProvider.value(value: gFFI.canvasModel),
          ChangeNotifierProvider.value(value: gFFI.peerTabModel),
        ],
        child: GetMaterialApp(
          navigatorKey: globalKey,
          debugShowCheckedModeBanner: false,
          title: isWeb
              ? '${bind.mainGetAppNameSync()} Web Client V2 (Preview)'
              : bind.mainGetAppNameSync(),
          theme: MyTheme.lightTheme,
          darkTheme: MyTheme.darkTheme,
          themeMode: MyTheme.currentThemeMode(),
          home: isDesktop
              ? const DesktopTabPage()
              : isWeb
                  ? WebHomePage()
                  : HomePage(),
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: supportedLocales,
          navigatorObservers: [
            // FirebaseAnalyticsObserver(analytics: analytics),
            BotToastNavigatorObserver(),
          ],
          builder: isAndroid
              ? (context, child) => AccessibilityListener(
                    child: MediaQuery(
                      data: MediaQuery.of(context).copyWith(
                        textScaler: TextScaler.linear(1.0),
                      ),
                      child: child ?? Container(),
                    ),
                  )
              : (context, child) {
                  child = _keepScaleBuilder(context, child);
                  child = botToastBuilder(context, child);
                  if ((isDesktop && desktopType == DesktopType.main) ||
                      isWebDesktop) {
                    child = keyListenerBuilder(context, child);
                  }
                  if (isLinux) {
                    return buildVirtualWindowFrame(context, child);
                  } else {
                    return workaroundWindowBorder(context, child);
                  }
                },
        ),
      );
    });
  }
}

Widget _keepScaleBuilder(BuildContext context, Widget? child) {
  return MediaQuery(
    data: MediaQuery.of(context).copyWith(
      textScaler: TextScaler.linear(1.0),
    ),
    child: child ?? Container(),
  );
}

_registerEventHandler() {
  if (isDesktop && desktopType != DesktopType.main) {
    platformFFI.registerEventHandler('theme', 'theme', (evt) async {
      String? dark = evt['dark'];
      if (dark != null) {
        await MyTheme.changeDarkMode(MyTheme.themeModeFromString(dark));
      }
    });
    platformFFI.registerEventHandler('language', 'language', (_) async {
      reloadAllWindows();
    });
  }
  // Register native handlers.
  if (isDesktop) {
    platformFFI.registerEventHandler('native_ui', 'native_ui', (evt) async {
      NativeUiHandler.instance.onEvent(evt);
    });
  }
}

Widget keyListenerBuilder(BuildContext context, Widget? child) {
  return RawKeyboardListener(
    focusNode: FocusNode(),
    child: child ?? Container(),
    onKey: (RawKeyEvent event) {
      if (event.logicalKey == LogicalKeyboardKey.shiftLeft) {
        if (event is RawKeyDownEvent) {
          gFFI.peerTabModel.setShiftDown(true);
        } else if (event is RawKeyUpEvent) {
          gFFI.peerTabModel.setShiftDown(false);
        }
      }
    },
  );
}
