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
      await trayManager.setIcon(
        Platform.isWindows
            ? 'windows/runner/resources/app_icon.ico'
            : 'assets/icon/app_icon.png',
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
