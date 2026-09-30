import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../utils/logger.dart';

class DesktopLifecycleService with TrayListener, WindowListener {
  DesktopLifecycleService._();

  static final DesktopLifecycleService instance = DesktopLifecycleService._();

  static bool get isSupported =>
      !kIsWeb && (Platform.isWindows || Platform.isMacOS);

  bool _initialized = false;
  bool _isQuitting = false;
  bool _fullScreenForVisualizer = false;

  Future<void> initialize({required bool startHidden}) async {
    if (!isSupported || _initialized) return;

    await windowManager.ensureInitialized();
    windowManager.addListener(this);
    trayManager.addListener(this);

    await windowManager.setPreventClose(true);
    await _initializeTray();

    await windowManager.waitUntilReadyToShow(
      WindowOptions(skipTaskbar: startHidden),
      () async {
        if (startHidden) {
          await hideWindow();
          Logger.info('DesktopLifecycle: started in the system tray');
        } else {
          await showWindow();
        }
      },
    );

    _initialized = true;
  }

  Future<void> _initializeTray() async {
    try {
      // macOS draws the status item as a template image: it keeps the alpha and
      // paints the shape itself, dark on a light menu bar and white on a dark
      // one. Handing it the square app icon filled the whole 18pt box, so it
      // takes the bare Tunio mark instead. Windows tray icons are full colour,
      // so there the app icon is the right thing.
      await trayManager.setIcon(
        Platform.isWindows
            ? 'windows/runner/resources/app_icon.ico'
            : 'assets/icon/tray_icon.png',
        isTemplate: Platform.isMacOS,
      );
      await trayManager.setToolTip('Tunio Spot');
      await trayManager.setContextMenu(
        Menu(
          items: [
            MenuItem(key: 'show_window', label: 'Open Tunio Spot'),
            MenuItem.separator(),
            MenuItem(key: 'exit_app', label: 'Quit'),
          ],
        ),
      );
    } catch (e, stackTrace) {
      Logger.error('DesktopLifecycle: failed to initialize tray: $e');
      Logger.error('Stack trace: $stackTrace');
    }
  }

  Future<void> showWindow() async {
    if (!isSupported) return;

    await windowManager.setSkipTaskbar(false);
    if (await windowManager.isMinimized()) {
      await windowManager.restore();
    }
    await windowManager.show();
    await windowManager.focus();
  }

  Future<void> hideWindow() async {
    if (!isSupported) return;

    await windowManager.setSkipTaskbar(true);
    await windowManager.hide();
  }

  /// Takes the whole display for the screen attached to the stream, the way the
  /// Android launcher opens the visualizer edge to edge. Brings the window back
  /// from the tray first, so a point that autostarted hidden still lights up its
  /// screen.
  Future<void> enterVisualizerFullScreen() async {
    if (!isSupported) return;

    await showWindow();

    // Someone already fullscreened the window by hand — leave their state
    // alone, and with it the flag that decides whether we may undo it.
    if (await windowManager.isFullScreen()) return;

    _fullScreenForVisualizer = true;
    await windowManager.setFullScreen(true);
  }

  /// Undoes [enterVisualizerFullScreen] when the screen goes away. A fullscreen
  /// the user switched on themselves is left as it is.
  Future<void> exitVisualizerFullScreen() async {
    if (!isSupported || !_fullScreenForVisualizer) return;

    _fullScreenForVisualizer = false;
    if (await windowManager.isFullScreen()) {
      await windowManager.setFullScreen(false);
    }
  }

  Future<void> quit() async {
    if (!isSupported || _isQuitting) return;

    _isQuitting = true;
    await trayManager.destroy();
    await windowManager.setPreventClose(false);
    await windowManager.destroy();
  }

  @override
  void onWindowClose() {
    if (!_isQuitting) {
      hideWindow();
    }
  }

  @override
  void onTrayIconMouseDown() {
    showWindow();
  }

  @override
  void onTrayIconRightMouseDown() {
    trayManager.popUpContextMenu();
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'show_window':
        showWindow();
      case 'exit_app':
        quit();
    }
  }
}
