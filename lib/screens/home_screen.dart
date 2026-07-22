import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart';
import 'package:webview_windows/webview_windows.dart' as ww;

import '../core/dependency_injection.dart';
import '../core/service_locator.dart';
import '../core/audio_state.dart';
import '../core/result.dart';
import '../core/system_state.dart';

import '../services/radio_service.dart';
import '../services/failover_service.dart';
import '../services/autostart_service.dart';
import '../services/app_update_service.dart';
import '../widgets/code_input_widget.dart';
import '../widgets/status_indicator.dart';
import '../utils/logger.dart';
import '../utils/platform_info.dart';
import '../main.dart' show TunioColors;

class HomeScreen extends StatefulWidget {
  final VoidCallback onThemeToggle;
  final ThemeMode themeMode;

  const HomeScreen({
    super.key,
    required this.onThemeToggle,
    required this.themeMode,
  });

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late IRadioService _radioService;
  late IFailoverService _failoverService;
  bool _serviceInitialized = false;
  final AppUpdateService _appUpdateService = AppUpdateService();
  bool _isCheckingForUpdates = false;
  bool _isDownloadingUpdate = false;
  bool _isUpdateAvailable = false;
  double? _updateDownloadProgress;
  String? _updateStatusText;
  Timer? _updateAvailabilityTimer;
  Timer? _updateAvailabilityRetryTimer;
  static const Duration _updateAvailabilityCheckInterval = Duration(hours: 6);
  static const Duration _updateAvailabilityRetryDelay = Duration(minutes: 5);

  // Focus nodes for TV remote navigation
  final FocusNode _codeFocusNode = FocusNode();
  final FocusNode _connectButtonFocusNode = FocusNode();
  final FocusNode _playButtonFocusNode = FocusNode();
  final FocusNode _themeButtonFocusNode = FocusNode();
  final FocusNode _updateButtonFocusNode = FocusNode();
  final FocusNode _visualizerButtonFocusNode = FocusNode();
  final FocusNode _visualizerCloseButtonFocusNode = FocusNode();

  // State
  String _currentCode = '';
  bool _isUserEditingCode =
      false; // Flag to prevent auto-updating during user input
  RadioState _radioState = const RadioStateDisconnected();
  NetworkState _networkState = const NetworkState();
  int? _currentPing;
  double _volume = 1.0;
  int _cachedTracksCount = 0;
  static const Duration _visualizerHeartbeatInterval = Duration(seconds: 10);

  bool _isVisualizerVisible = false;
  WebViewController? _visualizerController;
  ww.WebviewController? _windowsVisualizerController;
  StreamSubscription<ww.LoadingState>? _windowsLoadingSubscription;
  String? _loadedVisualizerUrl;
  bool _visualizerReady = false;
  bool _hasAutoOpenedVisualizer = false;
  String? _currentVisualizerUrl;
  String? _lastStreamUrl;
  bool _initialPlayFocusRequested = false;
  Timer? _visualizerHeartbeatTimer;
  static const MethodChannel _visualizerChannel =
      MethodChannel('ai.tunio/visualizer');
  static const bool _androidLowPerformanceVisualizerMode = true;

  // Subscriptions
  StreamSubscription<RadioState>? _radioStateSubscription;
  StreamSubscription<NetworkState>? _networkStateSubscription;
  StreamSubscription<int?>? _pingSubscription;
  StreamSubscription<int>? _cachedTracksCountSubscription;

  @override
  void initState() {
    super.initState();
    if (_isAndroid) {
      _visualizerChannel.setMethodCallHandler(_handleVisualizerChannelCall);
      // Once the UI is up, make sure the OS won't freeze the app in the
      // background (battery optimization exemption) so background failover and
      // the foreground service keep running with the screen off.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _ensureBackgroundExecutionAllowed();
      });
    }
    _initializeService();
    _setupFocusNodes();
    if (_appUpdateService.isSupported) {
      _refreshUpdateAvailability();
      _updateAvailabilityTimer = Timer.periodic(
        _updateAvailabilityCheckInterval,
        (_) => _refreshUpdateAvailability(),
      );
    }
  }

  Future<void> _refreshUpdateAvailability() async {
    if (!_appUpdateService.isSupported ||
        _isCheckingForUpdates ||
        _isDownloadingUpdate) {
      return;
    }
    var manifestLoaded = false;
    try {
      final result = await _appUpdateService.checkForUpdate();
      if (!mounted) return;
      manifestLoaded = result.latestRelease != null;
      if (result.isUpdateAvailable != _isUpdateAvailable) {
        setState(() {
          _isUpdateAvailable = result.isUpdateAvailable;
        });
      }
    } catch (e) {
      Logger.error('HomeScreen: silent update check failed: $e');
    }
    if (!manifestLoaded && mounted) {
      // Boot-time checks often race the network coming up — retry soon
      // instead of waiting for the next periodic tick.
      _updateAvailabilityRetryTimer?.cancel();
      _updateAvailabilityRetryTimer =
          Timer(_updateAvailabilityRetryDelay, _refreshUpdateAvailability);
    }
  }

  Future<void> _ensureBackgroundExecutionAllowed() async {
    try {
      final ignoring = await AutoStartService.isIgnoringBatteryOptimizations();
      if (!ignoring) {
        Logger.info(
            'HomeScreen: requesting battery optimization exemption for reliable background playback');
        await AutoStartService.requestIgnoreBatteryOptimizations();
      } else {
        Logger.info('HomeScreen: battery optimization already disabled');
      }
    } catch (e) {
      Logger.error('HomeScreen: battery optimization check failed: $e');
    }
  }

  @override
  void dispose() {
    if (_isAndroid) {
      _visualizerChannel.setMethodCallHandler(null);
    }
    _radioStateSubscription?.cancel();
    _networkStateSubscription?.cancel();
    _pingSubscription?.cancel();
    _cachedTracksCountSubscription?.cancel();
    _codeFocusNode.dispose();
    _connectButtonFocusNode.dispose();
    _playButtonFocusNode.dispose();
    _themeButtonFocusNode.dispose();
    _updateButtonFocusNode.dispose();
    _visualizerButtonFocusNode.dispose();
    _visualizerCloseButtonFocusNode.dispose();
    _visualizerController = null;
    _windowsLoadingSubscription?.cancel();
    _windowsLoadingSubscription = null;
    _windowsVisualizerController?.dispose();
    _windowsVisualizerController = null;
    _visualizerHeartbeatTimer?.cancel();
    _visualizerHeartbeatTimer = null;
    _updateAvailabilityTimer?.cancel();
    _updateAvailabilityTimer = null;
    _updateAvailabilityRetryTimer?.cancel();
    _updateAvailabilityRetryTimer = null;
    super.dispose();
  }

  bool get _isAndroid => defaultTargetPlatform == TargetPlatform.android;

  bool get _isWindows => defaultTargetPlatform == TargetPlatform.windows;

  void _setupFocusNodes() {
    _codeFocusNode.addListener(() => setState(() {}));
    _connectButtonFocusNode.addListener(() => setState(() {}));
    _playButtonFocusNode.addListener(() => setState(() {}));
    _themeButtonFocusNode.addListener(() => setState(() {}));
    _updateButtonFocusNode.addListener(() => setState(() {}));
    _visualizerButtonFocusNode.addListener(() => setState(() {}));
    _visualizerCloseButtonFocusNode.addListener(() => setState(() {}));
  }

  Future<void> _openUpdateDialog() async {
    if (!_appUpdateService.isSupported ||
        _isCheckingForUpdates ||
        _isDownloadingUpdate) {
      return;
    }

    setState(() {
      _isCheckingForUpdates = true;
      _updateDownloadProgress = null;
      _updateStatusText = 'Checking for updates...';
    });

    try {
      final checkResult = await _appUpdateService.checkForUpdate();
      if (!mounted) return;

      final latestRelease = checkResult.latestRelease;
      if (latestRelease == null) {
        _showError('Unable to load update metadata from CDN.');
        setState(() {
          _updateStatusText = 'Failed to load manifest';
        });
        return;
      }

      setState(() {
        _isUpdateAvailable = checkResult.isUpdateAvailable;
      });

      final approved = await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('App updates'),
              content: Text(
                'Current: ${checkResult.currentVersion}\n'
                'Latest: ${latestRelease.version}+${latestRelease.build}\n\n'
                '${checkResult.isUpdateAvailable ? "Update is available." : "You already have the latest version."}',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: const Text('Close'),
                ),
                if (checkResult.isUpdateAvailable)
                  FilledButton(
                    onPressed: () => Navigator.of(context).pop(true),
                    child: const Text('Update'),
                  ),
              ],
            ),
          ) ??
          false;

      if (!approved) {
        setState(() {
          _updateStatusText = checkResult.isUpdateAvailable
              ? 'Update available: ${latestRelease.version}+${latestRelease.build}'
              : 'Current version: ${checkResult.currentVersion}';
        });
        return;
      }

      await _downloadAndInstallUpdate(latestRelease);
    } catch (e) {
      Logger.error('HomeScreen: App update failed: $e');
      _showError('Update failed: $e');
      setState(() {
        _updateStatusText = 'Update failed';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isCheckingForUpdates = false;
          _isDownloadingUpdate = false;
        });
      }
    }
  }

  Future<void> _downloadAndInstallUpdate(AppReleaseInfo latestRelease) async {
    final canInstall = await _appUpdateService.canRequestPackageInstalls();
    if (!canInstall) {
      await _appUpdateService.openUnknownSourcesSettings();
      _showError(
        'Allow "Install unknown apps" for Tunio Spot, then tap update again.',
      );
      setState(() {
        _updateStatusText = 'Permission required: Install unknown apps';
      });
      return;
    }

    setState(() {
      _isDownloadingUpdate = true;
      _updateDownloadProgress = 0;
      _updateStatusText =
          'Downloading ${latestRelease.version}+${latestRelease.build}...';
    });

    try {
      final apkFile = await _appUpdateService.downloadApk(
        latestRelease,
        onProgress: (received, total) {
          if (!mounted) return;
          setState(() {
            _updateDownloadProgress =
                total > 0 ? received.toDouble() / total.toDouble() : null;
          });
        },
      );

      await _appUpdateService.installApk(apkFile);
      _showSuccess('Installer opened. Confirm installation to update the app.');
      setState(() {
        _updateStatusText =
            'Installer opened for ${latestRelease.version}+${latestRelease.build}';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isDownloadingUpdate = false;
        });
      }
    }
  }

  void _resetVisualizerState({bool closeNative = false}) {
    if (closeNative && _isAndroid && _isVisualizerVisible) {
      _visualizerChannel.invokeMethod('closeVisualizer');
    }
    _isVisualizerVisible = false;
    _visualizerController = null;
    _windowsLoadingSubscription?.cancel();
    _windowsLoadingSubscription = null;
    _windowsVisualizerController?.dispose();
    _windowsVisualizerController = null;
    _loadedVisualizerUrl = null;
    _currentVisualizerUrl = null;
    _visualizerReady = false;
    _hasAutoOpenedVisualizer = false;
    _stopVisualizerHeartbeat();
  }

  Future<void> _handleVisualizerChannelCall(MethodCall call) async {
    if (!_isAndroid) {
      return;
    }

    switch (call.method) {
      case 'visualizerReady':
        setState(() {
          _visualizerReady = true;
        });
        _postVisualizerUpdate();
        _startVisualizerHeartbeat(forceRestart: true);
        break;
      case 'visualizerClosed':
        _handleVisualizerClosed();
        break;
      case 'visualizerError':
        final message = call.arguments as String?;
        if (message != null && message.isNotEmpty) {
          _showError(message);
        }
        _handleVisualizerClosed();
        break;
      default:
        break;
    }
  }

  void _initializeService() {
    try {
      _radioService = di.radioService;
      _failoverService = di.failoverService;

      // Load saved PIN code immediately for UI display
      final storageService = di.storageService;
      final savedToken = storageService.getToken();
      if (savedToken != null && savedToken.isNotEmpty) {
        setState(() {
          _currentCode = savedToken;
        });
        Logger.info('HomeScreen: Loaded saved PIN code for display');
      }

      // Get current state immediately
      final currentRadioState = _radioService.currentState;
      setState(() {
        _radioState = currentRadioState;
        _currentPing = _radioService.currentPing;
        _cachedTracksCount = _failoverService.cachedTracksCount;

        // Update code from current state only if field is empty and user is not editing
        final token = currentRadioState.token;
        if (token != null && token != _currentCode && !_isUserEditingCode) {
          _currentCode = token;
        }

        _lastStreamUrl = currentRadioState.config?.streamUrl;

        final initialVisualizerUrl = currentRadioState.config?.visualizerUrl;
        if (SystemState.instance.serviceSuspended ||
            initialVisualizerUrl == null ||
            initialVisualizerUrl.isEmpty) {
          _resetVisualizerState(closeNative: true);
        }

        if (!_radioState.isConnected) {
          _hasAutoOpenedVisualizer = false;
        }
      });

      _scheduleVisualizerUpdate();
      _maybeAutoOpenVisualizer();

      // Set up streams for future changes
      _radioStateSubscription = _radioService.stateStream.listen((state) {
        if (mounted) {
          setState(() {
            _radioState = state;

            // Update code from token only if field is empty and user is not editing
            final token = state.token;
            if (token != null && token != _currentCode && !_isUserEditingCode) {
              _currentCode = token;
            }

            if (state is RadioStateConnected && state.token == _currentCode) {
              _isUserEditingCode = false;
            }

            // Update volume from config
            final config = state.config;
            if (config != null) {
              _volume = config.failoverVolume;
            }

            final newStreamUrl = state.config?.streamUrl;
            final hasStreamChanged = newStreamUrl != null &&
                newStreamUrl.isNotEmpty &&
                newStreamUrl != _lastStreamUrl;
            if (hasStreamChanged) {
              _lastStreamUrl = newStreamUrl;
              _resetVisualizerState(closeNative: true);
            }

            final newVisualizerUrl = state.config?.visualizerUrl;
            if (SystemState.instance.serviceSuspended ||
                newVisualizerUrl == null ||
                newVisualizerUrl.isEmpty) {
              _resetVisualizerState(closeNative: true);
            } else if (_loadedVisualizerUrl != null &&
                _currentVisualizerUrl != null &&
                _currentVisualizerUrl != newVisualizerUrl) {
              _resetVisualizerState(closeNative: true);
            }

            if (!_radioState.isConnected) {
              _hasAutoOpenedVisualizer = false;
            }
          });

          _scheduleVisualizerUpdate();
          _maybeAutoOpenVisualizer();
        }
      });

      _networkStateSubscription = _radioService.networkStream.listen((state) {
        if (mounted) {
          setState(() {
            _networkState = state;
          });
        }
      });

      _pingSubscription = _radioService.pingStream.listen((ping) {
        if (mounted) {
          setState(() {
            _currentPing = ping;
          });
        }
      });

      _cachedTracksCountSubscription =
          _failoverService.cachedTracksCountStream.listen((count) {
        if (mounted) {
          setState(() {
            _cachedTracksCount = count;
          });
        }
      });

      setState(() {
        _serviceInitialized = true;
      });
      _requestInitialPlayFocus();

      Logger.info('HomeScreen: Service initialized successfully');
    } catch (e) {
      Logger.error('HomeScreen: Failed to initialize service: $e');
      _showError('Failed to initialize radio service');
    }
  }

  Future<void> _connect() async {
    if (_currentCode.isEmpty) {
      _showError('Please enter a PIN code');
      return;
    }

    // If a session/reconnect loop is active for a *different* PIN, tear it down
    // first. Otherwise a manual connect to a new stream gets queued behind the
    // current (possibly endlessly retrying) connection, so the player keeps
    // reconnecting to the old stream instead of switching to the new one.
    final activeToken = _radioState.token;
    if (_radioState is! RadioStateDisconnected && activeToken != _currentCode) {
      await _radioService.disconnect();
      if (!mounted) return;
    }

    final maskedCode = _currentCode.length >= 2
        ? '${_currentCode.substring(0, 2)}****'
        : '****';
    Logger.info('HomeScreen: Connecting with code: $maskedCode');

    final result = await _radioService.connect(_currentCode);
    result.fold(
      (_) {
        Logger.info('HomeScreen: Connection successful');
      },
      (error) {
        Logger.error('HomeScreen: Connection failed: $error');
        _showError(error);
      },
    );
  }

  Future<void> _changePin() async {
    // Stop the current stream (and any auto-reconnect loop) immediately, clear
    // the PIN field and focus it, so the user can calmly type a new code
    // without the player fighting to reconnect to the old stream.
    Logger.info('HomeScreen: Change PIN requested - stopping current stream');
    await _radioService.disconnect();
    if (!mounted) return;
    setState(() {
      _currentCode = '';
      _isUserEditingCode = true;
    });
    _codeFocusNode.requestFocus();
  }

  Widget _buildVisualizerOverlay() {
    final hasContent = _isWindows
        ? _windowsVisualizerController != null
        : _visualizerController != null;
    if (!hasContent) {
      return const SizedBox.shrink();
    }

    return Positioned.fill(
      child: FocusScope(
        autofocus: true,
        child: Shortcuts(
          shortcuts: const {
            SingleActivator(LogicalKeyboardKey.escape):
                _DismissVisualizerIntent(),
            SingleActivator(LogicalKeyboardKey.goBack):
                _DismissVisualizerIntent(),
            SingleActivator(LogicalKeyboardKey.gameButtonB):
                _DismissVisualizerIntent(),
            SingleActivator(LogicalKeyboardKey.backspace):
                _DismissVisualizerIntent(),
            SingleActivator(LogicalKeyboardKey.browserBack):
                _DismissVisualizerIntent(),
          },
          child: Actions(
            actions: {
              _DismissVisualizerIntent:
                  CallbackAction<_DismissVisualizerIntent>(
                onInvoke: (intent) {
                  _closeVisualizer();
                  return null;
                },
              ),
            },
            child: Focus(
              autofocus: true,
              child: Material(
                color: Colors.black.withValues(alpha: 0.92),
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: _buildVisualizerWebView(),
                    ),
                    Positioned(
                      bottom: 32,
                      right: 32,
                      child: _buildVisualizerCloseButton(),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildVisualizerWebView() {
    if (_isWindows) {
      final windowsController = _windowsVisualizerController;
      if (windowsController == null) {
        return const SizedBox.shrink();
      }
      return ww.Webview(windowsController);
    }

    final controller = _visualizerController;
    if (controller == null) {
      return const SizedBox.shrink();
    }

    if (defaultTargetPlatform == TargetPlatform.android) {
      final params = PlatformWebViewWidgetCreationParams(
        controller: controller.platform,
        layoutDirection: TextDirection.ltr,
        gestureRecognizers: const <Factory<OneSequenceGestureRecognizer>>{},
      );
      final androidParams = AndroidWebViewWidgetCreationParams
          .fromPlatformWebViewWidgetCreationParams(
        params,
        // Hybrid composition is required so the GPU visualizer renders instead
        // of showing a black SurfaceTexture.
        displayWithHybridComposition: true,
      );
      return WebViewWidget.fromPlatformCreationParams(params: androidParams);
    }
    return WebViewWidget(controller: controller);
  }

  Widget _buildVisualizerCloseButton() {
    final hasFocus = _visualizerCloseButtonFocusNode.hasFocus;

    return Focus(
      autofocus: true,
      focusNode: _visualizerCloseButtonFocusNode,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
        ),
        child: RawMaterialButton(
          onPressed: _closeVisualizer,
          constraints: const BoxConstraints.tightFor(width: 44, height: 44),
          shape: const CircleBorder(),
          fillColor: Colors.black.withValues(alpha: 0.10),
          elevation: 0,
          child: Icon(
            Icons.close,
            size: 18,
            color: hasFocus
                ? Colors.white.withValues(alpha: 0.5)
                : Colors.white.withValues(alpha: 0.3),
          ),
        ),
      ),
    );
  }

  Widget? _buildVisualizerButton() {
    if (SystemState.instance.serviceSuspended) {
      return null;
    }

    if (_visualizerUrl == null) {
      return null;
    }

    final backgroundColor =
        Theme.of(context).colorScheme.surfaceContainerHighest;
    final hasFocus = _visualizerButtonFocusNode.hasFocus;

    return Focus(
      focusNode: _visualizerButtonFocusNode,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(
            color: hasFocus ? TunioColors.primary : Colors.transparent,
            width: 2,
          ),
        ),
        child: Material(
          color: backgroundColor,
          shape: const CircleBorder(),
          clipBehavior: Clip.antiAlias,
          child: IconButton(
            onPressed: _openVisualizer,
            tooltip: 'Open visualizer',
            icon: Icon(
              Icons.graphic_eq,
              color: _isVisualizerVisible ? TunioColors.primary : null,
            ),
            iconSize: 28,
          ),
        ),
      ),
    );
  }

  Future<Result<void>> _playPause() async {
    final result = await _radioService.playPause();
    result.fold(
      (_) => Logger.info('HomeScreen: Play/pause successful'),
      (error) {
        Logger.error('HomeScreen: Play/pause failed: $error');
        if (error != 'No active connection') {
          _showError(error);
        }
      },
    );
    return result;
  }

  void _openVisualizer() async {
    if (SystemState.instance.serviceSuspended) {
      _resetVisualizerState(closeNative: true);
      return;
    }

    final url = _visualizerUrl;
    if (url == null) {
      return;
    }

    final uri = Uri.tryParse(url);
    if (uri == null) {
      _showError('Visualizer link is invalid');
      return;
    }

    final queryParameters = Map<String, String>.from(uri.queryParameters);
    queryParameters['embedded'] = '1';
    if (_isAndroid && _androidLowPerformanceVisualizerMode) {
      queryParameters['performance'] = 'low';
    }
    final targetUri = uri.replace(queryParameters: queryParameters);

    if (_isAndroid) {
      _stopVisualizerHeartbeat();
      await _openNativeVisualizer(targetUri, url);
      _scheduleVisualizerUpdate();
      return;
    }

    if (_isWindows) {
      await _openWindowsVisualizer(targetUri, url);
      return;
    }

    final needsNewController = _visualizerController == null ||
        _loadedVisualizerUrl != targetUri.toString();

    if (needsNewController) {
      _stopVisualizerHeartbeat();
      final controller = _createVisualizerWebViewController()
        ..setNavigationDelegate(
          NavigationDelegate(
            onPageFinished: (_) {
              _visualizerReady = true;
              _postVisualizerUpdate();
              _startVisualizerHeartbeat(forceRestart: true);
            },
          ),
        )
        ..loadRequest(targetUri);

      setState(() {
        _visualizerController = controller;
        _loadedVisualizerUrl = targetUri.toString();
        _currentVisualizerUrl = url;
        _isVisualizerVisible = true;
        _visualizerReady = false;
      });
    } else {
      setState(() {
        _isVisualizerVisible = true;
      });
      _startVisualizerHeartbeat(forceRestart: true);
    }

    _focusVisualizerCloseButton();
    _scheduleVisualizerUpdate();
  }

  Future<void> _openNativeVisualizer(Uri targetUri, String originalUrl) async {
    try {
      await _visualizerChannel.invokeMethod('openVisualizer', {
        'url': targetUri.toString(),
        'lowPerformanceMode': _androidLowPerformanceVisualizerMode,
      });
      setState(() {
        _visualizerController = null;
        _loadedVisualizerUrl = targetUri.toString();
        _currentVisualizerUrl = originalUrl;
        _isVisualizerVisible = true;
        _visualizerReady = false;
      });
    } catch (e) {
      Logger.error('HomeScreen: Failed to open native visualizer: $e');
      _showError('Failed to open visualizer');
    }
  }

  Future<void> _openWindowsVisualizer(Uri targetUri, String originalUrl) async {
    final needsNewController = _windowsVisualizerController == null ||
        _loadedVisualizerUrl != targetUri.toString();

    if (!needsNewController) {
      setState(() {
        _isVisualizerVisible = true;
      });
      _startVisualizerHeartbeat(forceRestart: true);
      _focusVisualizerCloseButton();
      _scheduleVisualizerUpdate();
      return;
    }

    _stopVisualizerHeartbeat();
    await _windowsLoadingSubscription?.cancel();
    _windowsLoadingSubscription = null;
    await _windowsVisualizerController?.dispose();
    _windowsVisualizerController = null;

    try {
      final controller = ww.WebviewController();
      await controller.initialize();
      await controller.setBackgroundColor(Colors.transparent);
      await controller
          .setPopupWindowPolicy(ww.WebviewPopupWindowPolicy.deny);

      _windowsLoadingSubscription = controller.loadingState.listen((state) {
        if (state == ww.LoadingState.navigationCompleted) {
          _visualizerReady = true;
          _postVisualizerUpdate();
          _startVisualizerHeartbeat(forceRestart: true);
        }
      });

      await controller.loadUrl(targetUri.toString());

      if (!mounted) {
        await controller.dispose();
        return;
      }

      setState(() {
        _windowsVisualizerController = controller;
        _loadedVisualizerUrl = targetUri.toString();
        _currentVisualizerUrl = originalUrl;
        _isVisualizerVisible = true;
        _visualizerReady = false;
      });

      _focusVisualizerCloseButton();
      _scheduleVisualizerUpdate();
    } catch (e) {
      Logger.error('HomeScreen: Failed to open Windows visualizer: $e');
      _showError('Failed to open visualizer');
    }
  }

  WebViewController _createVisualizerWebViewController() {
    PlatformWebViewControllerCreationParams params =
        const PlatformWebViewControllerCreationParams();

    if (defaultTargetPlatform == TargetPlatform.android) {
      params = AndroidWebViewControllerCreationParams();
    } else if (defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.macOS) {
      params = WebKitWebViewControllerCreationParams(
        allowsInlineMediaPlayback: true,
        mediaTypesRequiringUserAction: const <PlaybackMediaTypes>{},
      );
    }

    final controller = WebViewController.fromPlatformCreationParams(params)
      ..setJavaScriptMode(JavaScriptMode.unrestricted);

    if (defaultTargetPlatform != TargetPlatform.macOS) {
      controller.setBackgroundColor(Colors.transparent);
    }

    if (controller.platform is AndroidWebViewController) {
      final androidController = controller.platform as AndroidWebViewController;
      androidController.setMediaPlaybackRequiresUserGesture(false);
    }

    return controller;
  }

  void _closeVisualizer() {
    if (!_isVisualizerVisible) {
      return;
    }

    if (_isAndroid) {
      _visualizerChannel.invokeMethod('closeVisualizer');
    }

    _handleVisualizerClosed();
  }

  void _handleVisualizerClosed() {
    final wasVisible = _isVisualizerVisible;

    if (wasVisible) {
      setState(() {
        _isVisualizerVisible = false;
      });
    } else {
      _isVisualizerVisible = false;
    }

    _visualizerReady = false;
    _stopVisualizerHeartbeat();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      FocusScope.of(context).requestFocus(_visualizerButtonFocusNode);
    });
  }

  void _requestInitialPlayFocus() {
    if (_initialPlayFocusRequested || !_serviceInitialized) {
      return;
    }
    _initialPlayFocusRequested = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      FocusScope.of(context).requestFocus(_playButtonFocusNode);
    });
  }

  void _focusVisualizerCloseButton() {
    if (_isAndroid) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_isVisualizerVisible) return;
      _visualizerCloseButtonFocusNode.requestFocus();
    });
  }

  void _scheduleVisualizerUpdate() {
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _postVisualizerUpdate();
    });
  }

  void _startVisualizerHeartbeat({bool forceRestart = false}) {
    if (!_isVisualizerVisible || !_visualizerReady) {
      return;
    }
    if (!_isAndroid) {
      final hasController = _isWindows
          ? _windowsVisualizerController != null
          : _visualizerController != null;
      if (!hasController) {
        return;
      }
    }
    if (!forceRestart && _visualizerHeartbeatTimer?.isActive == true) {
      return;
    }

    _visualizerHeartbeatTimer?.cancel();
    _visualizerHeartbeatTimer = Timer.periodic(
      _visualizerHeartbeatInterval,
      (_) => _postVisualizerUpdate(),
    );
  }

  void _stopVisualizerHeartbeat() {
    _visualizerHeartbeatTimer?.cancel();
    _visualizerHeartbeatTimer = null;
  }

  Map<String, dynamic>? _buildVisualizerPayload() {
    final config = _radioState.config;
    if (config == null) return null;

    final currentTrack = config.current;
    final audioState = _getAudioState();

    final trackArtist = currentTrack?.artist.trim();
    final trackTitle = currentTrack?.title.trim();

    return {
      'artist': trackArtist != null && trackArtist.isNotEmpty
          ? trackArtist
          : (config.description ?? config.title ?? ''),
      'title': trackTitle != null && trackTitle.isNotEmpty
          ? trackTitle
          : (config.title ?? 'Tunio Radio'),
      'streamUrl': config.streamUrl,
      'station': config.title ?? 'Tunio',
      'isPlaying': audioState?.isPlaying ?? false,
      'isFailoverMode': _radioState is RadioStateFailover,
      'volume': _volume,
      'timestamp': DateTime.now().toIso8601String(),
      'showAudioVisualization': false,
    };
  }

  Future<void> _postVisualizerUpdate() async {
    if (!_visualizerReady) return;

    final payload = _buildVisualizerPayload();
    if (payload == null) return;

    final message = jsonEncode({
      'type': 'tunio-visualizer-update',
      'payload': payload,
    });
    final script = 'window.postMessage($message, "*");';

    if (_isWindows) {
      final controller = _windowsVisualizerController;
      if (controller == null) return;
      try {
        await controller.executeScript(script);
      } catch (e) {
        Logger.error('HomeScreen: Failed to send visualizer update: $e');
      }
      return;
    }

    final controller = _visualizerController;
    if (controller == null) return;

    try {
      if (_isAndroid) {
        await _visualizerChannel.invokeMethod('updateVisualizer', {
          'script': script,
        });
      } else {
        await controller.runJavaScript(script);
      }
    } catch (e) {
      Logger.error('HomeScreen: Failed to send visualizer update: $e');
    }
  }

  void _maybeAutoOpenVisualizer() {
    if (!mounted) return;
    if (_isVisualizerVisible) return;
    if (SystemState.instance.serviceSuspended) {
      _hasAutoOpenedVisualizer = false;
      _resetVisualizerState(closeNative: true);
      return;
    }
    if (!_radioState.isConnected) {
      _hasAutoOpenedVisualizer = false;
      return;
    }

    if (_hasAutoOpenedVisualizer) {
      return;
    }

    final url = _visualizerUrl;
    if (url == null || url.isEmpty) {
      _hasAutoOpenedVisualizer = false;
      return;
    }

    _hasAutoOpenedVisualizer = true;
    _openVisualizer();
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.red.withValues(alpha: 0.9),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 4),
        action: SnackBarAction(
          label: 'Dismiss',
          textColor: Colors.white,
          onPressed: () => ScaffoldMessenger.of(context).hideCurrentSnackBar(),
        ),
      ),
    );
  }

  void _showSuccess(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.green.withValues(alpha: 0.9),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 3),
        action: SnackBarAction(
          label: 'OK',
          textColor: Colors.white,
          onPressed: () => ScaffoldMessenger.of(context).hideCurrentSnackBar(),
        ),
      ),
    );
  }

  Future<void> _clearFailoverCache() async {
    try {
      Logger.info('HomeScreen: Clearing failover cache...');
      await _failoverService.clearCache();
      _showSuccess('Failover tracks cleared and will be re-downloaded');
    } catch (e) {
      Logger.error('HomeScreen: Failed to clear failover cache: $e');
      _showError('Failed to clear failover cache: $e');
    }
  }

  void _showVolumeInfo() {
    _showSuccess(
        'Volume is controlled from Tunio Link in your personal cabinet');
  }

  Future<void> _launchPersonalCabinet() async {
    const url = 'https://cp.tunio.ai/spot-links';
    if (await canLaunchUrl(Uri.parse(url))) {
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    }
  }

  IconData _getThemeIcon() {
    return widget.themeMode == ThemeMode.dark
        ? Icons.light_mode
        : Icons.dark_mode;
  }

  String _getThemeTooltip() {
    return widget.themeMode == ThemeMode.dark
        ? 'Switch to light theme'
        : 'Switch to dark theme';
  }

  IconData _getPlayPauseIcon() {
    final audioState = _getAudioState();
    if (audioState?.isPlaying ?? false) {
      return Icons.pause;
    }
    return Icons.play_arrow;
  }

  /// The play/pause control is only meaningful when the backend attached a
  /// stream. In screen-only mode (no stream_url) there is nothing to play, so
  /// the button is hidden; it appears as soon as a stream_url arrives from the
  /// backend (or if audio is somehow already playing).
  bool get _shouldShowPlayButton {
    final isPlaying = _getAudioState()?.isPlaying ?? false;
    final hasStream = _radioState.config?.hasStream ?? false;
    return hasStream || isPlaying;
  }

  Future<void> _onPlayButtonPressed() async {
    if (_radioState.isConnecting) {
      return;
    }

    final audioState = _getAudioState();
    final isPlaying = audioState?.isPlaying ?? false;

    if (_radioState.isConnected && isPlaying) {
      await _playPause();
      return;
    }

    final reconnectResult = await _radioService.reconnect();
    if (reconnectResult.isSuccess) {
      return;
    }

    reconnectResult.fold(
      (_) {},
      (error) {
        Logger.error('HomeScreen: Reconnect failed: $error');
        if (error != 'No stored token available') {
          _showError(error);
        }
      },
    );

    await _connect();
  }

  AudioState? _getAudioState() {
    final audioState = switch (_radioState) {
      RadioStateConnected(:final audioState) => audioState,
      RadioStateFailover(:final audioState) => audioState,
      _ => null,
    };

    // Buffer value available for UI use

    return audioState;
  }

  String? get _visualizerUrl {
    if (SystemState.instance.serviceSuspended) {
      return null;
    }

    final url = _radioState.config?.visualizerUrl;
    if (url == null || url.isEmpty) {
      return null;
    }

    final uri = Uri.tryParse(url);
    if (uri == null || uri.scheme.isEmpty) {
      return null;
    }

    return url;
  }

  String _getStatusText() {
    return switch (_radioState) {
      RadioStateDisconnected(:final message) => message,
      RadioStateConnecting(:final message, :final attempt) =>
        '$message (attempt $attempt)',
      RadioStateConnected(:final audioState) => audioState.displayMessage,
      RadioStateFailover(:final audioState) =>
        'Failover: ${audioState.displayMessage}',
      RadioStateError(:final message, :final attemptCount) =>
        'Error: $message (attempt $attemptCount)',
    };
  }

  String _getDiagnosticText() {
    return switch (_radioState) {
      RadioStateConnecting(:final attempt) =>
        'Connecting... (attempt $attempt/∞)',
      RadioStateError(:final attemptCount, :final canRetry) => canRetry
          ? 'Retrying in 5s... (attempt $attemptCount/∞)'
          : 'Failed (attempt $attemptCount)',
      _ => '',
    };
  }

  @override
  Widget build(BuildContext context) {
    if (!_serviceInitialized) {
      return const Scaffold(
        body: Center(
          child: CircularProgressIndicator(),
        ),
      );
    }

    final visualizerButton = _buildVisualizerButton();
    final isUpdateBusy = _isCheckingForUpdates || _isDownloadingUpdate;

    return PopScope(
      canPop: !_isVisualizerVisible,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _isVisualizerVisible) {
          _closeVisualizer();
        }
      },
      child: Stack(
        children: [
          Scaffold(
            appBar: AppBar(
              title: const Text('Tunio Spot'),
              actions: [
                if (_appUpdateService.isSupported)
                  Focus(
                    focusNode: _updateButtonFocusNode,
                    child: Container(
                      decoration: BoxDecoration(
                        border: Border.all(
                          color: _updateButtonFocusNode.hasFocus
                              ? TunioColors.primary
                              : Colors.transparent,
                          width: 2,
                        ),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: IconButton(
                        onPressed: isUpdateBusy ? null : _openUpdateDialog,
                        icon: isUpdateBusy
                            ? SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  value: _updateDownloadProgress,
                                  valueColor:
                                      const AlwaysStoppedAnimation<Color>(
                                    Colors.white,
                                  ),
                                ),
                              )
                            : Stack(
                                clipBehavior: Clip.none,
                                children: [
                                  const Icon(Icons.system_update_alt),
                                  if (_isUpdateAvailable)
                                    Positioned(
                                      top: -3,
                                      right: -3,
                                      child: Container(
                                        width: 9,
                                        height: 9,
                                        decoration: const BoxDecoration(
                                          color: Colors.red,
                                          shape: BoxShape.circle,
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                        tooltip: _updateStatusText ?? 'Check updates',
                      ),
                    ),
                  ),
                Focus(
                  focusNode: _themeButtonFocusNode,
                  child: Container(
                    decoration: BoxDecoration(
                      border: Border.all(
                        color: _themeButtonFocusNode.hasFocus
                            ? TunioColors.primary
                            : Colors.transparent,
                        width: 2,
                      ),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: IconButton(
                      onPressed: widget.onThemeToggle,
                      icon: Icon(_getThemeIcon()),
                      tooltip: _getThemeTooltip(),
                    ),
                  ),
                ),
              ],
            ),
            body: _buildMainContent(visualizerButton),
          ),
          if (_isVisualizerVisible) _buildVisualizerOverlay(),
        ],
      ),
    );
  }

  Widget _buildMainContent(Widget? visualizerButton) {
    return SafeArea(
      child: LayoutBuilder(
        builder: (context, constraints) {
          return SingleChildScrollView(
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight),
              child: Padding(
                padding: const EdgeInsets.all(12.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // TIP Card - compact version
                    Card(
                      color: Colors.grey[300],
                      child: InkWell(
                        onTap: _launchPersonalCabinet,
                        borderRadius: BorderRadius.circular(8),
                        child: Padding(
                          padding: const EdgeInsets.all(8.0),
                          child: Row(
                            children: [
                              Icon(
                                Icons.lightbulb_outline,
                                color: TunioColors.primary,
                                size: 18,
                              ),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  'TIP: Get PIN code at cp.tunio.ai/spot-links',
                                  style: TextStyle(
                                    color: Colors.black87,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ),
                              Icon(
                                Icons.open_in_new,
                                color: TunioColors.primary,
                                size: 14,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),

                    // Connection Card - compact version
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(12.0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            CodeInputWidget(
                              value: _currentCode,
                              onChanged: (code) {
                                setState(() {
                                  _currentCode = code;
                                  _isUserEditingCode =
                                      true; // Mark that user is editing
                                });
                              },
                              onTap: () {
                                setState(() {
                                  _isUserEditingCode =
                                      true; // Mark that user is editing
                                });
                              },
                              onSubmitted: () {
                                _connect();
                              },
                              // Keep the field editable at all times. Disabling
                              // it while a (re)connection was in progress made the
                              // input drop focus and close the keyboard mid-edit,
                              // so the user could not switch to another stream
                              // while the current one was reconnecting.
                              enabled: true,
                              focusNode: _codeFocusNode,
                            ),
                            const SizedBox(height: 12),
                            Focus(
                              focusNode: _connectButtonFocusNode,
                              child: ElevatedButton.icon(
                                // Disconnected -> "Connect". Any active session
                                // (connected, failover, connecting, or stuck in a
                                // retry loop) -> "Change PIN", which stops the
                                // current stream and clears the field for a new
                                // code. The button is never disabled, so the user
                                // can always break out of a reconnect loop.
                                onPressed: _radioState is RadioStateDisconnected
                                    ? _connect
                                    : _changePin,
                                icon: Icon(_radioState is RadioStateDisconnected
                                    ? Icons.login
                                    : Icons.edit),
                                label: Text(
                                    _radioState is RadioStateDisconnected
                                        ? 'Connect'
                                        : 'Change PIN'),
                                style: ElevatedButton.styleFrom(
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 10),
                                  backgroundColor: TunioColors.primary,
                                  foregroundColor: Colors.white,
                                  side: _connectButtonFocusNode.hasFocus
                                      ? BorderSide(
                                          color: TunioColors.primary, width: 2)
                                      : null,
                                ),
                              ),
                            ),

                            // Show connected status if connected
                            if (_radioState.isConnected)
                              Container(
                                margin: const EdgeInsets.only(top: 8),
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 12, vertical: 8),
                                decoration: BoxDecoration(
                                  color: Colors.green.withValues(alpha: 0.1),
                                  borderRadius: BorderRadius.circular(6),
                                  border: Border.all(
                                    color: Colors.green.withValues(alpha: 0.3),
                                  ),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Icon(Icons.check_circle,
                                        color: Colors.green, size: 16),
                                    const SizedBox(width: 6),
                                    Text(
                                      'Connected - Running in Background',
                                      style: TextStyle(
                                        color: Colors.green,
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),

                    // Player Card (compact layout)
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16.0),
                        child: Column(
                          children: [
                            Text(
                              _radioState.config?.title ?? '',
                              style: const TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 16),
                            FocusTraversalGroup(
                              policy: WidgetOrderTraversalPolicy(),
                              child: Row(
                                children: [
                                  if (_shouldShowPlayButton) ...[
                                    // Circular play/pause button
                                    FocusTraversalOrder(
                                      order: const NumericFocusOrder(1),
                                      child: Focus(
                                        focusNode: _playButtonFocusNode,
                                        child: ElevatedButton(
                                          onPressed: _radioState.isConnecting
                                              ? null
                                              : () => _onPlayButtonPressed(),
                                          style: ElevatedButton.styleFrom(
                                            shape: const CircleBorder(),
                                            padding: const EdgeInsets.all(16),
                                            side: _playButtonFocusNode.hasFocus
                                                ? BorderSide(
                                                    color: TunioColors.primary,
                                                    width: 3)
                                                : null,
                                          ),
                                          child: Icon(
                                            _getPlayPauseIcon(),
                                            size: 32,
                                          ),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                  ],

                                  if (visualizerButton != null) ...[
                                    FocusTraversalOrder(
                                      order: const NumericFocusOrder(2),
                                      child: visualizerButton,
                                    ),
                                    const SizedBox(width: 12),
                                  ],

                                  // Compact indicators wrap to multiple rows on small screens
                                  Expanded(
                                    child: _buildCompactIndicators(),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),

                    // Status indicator and metrics
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16.0),
                        child: LayoutBuilder(
                          builder: (context, constraints) {
                            final isMobile = constraints.maxWidth < 600;

                            if (isMobile) {
                              // Mobile layout: Column (status above, metrics below)
                              return Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  // Status indicator
                                  StatusIndicator(
                                    audioState: _getAudioState() ??
                                        const AudioStateIdle(),
                                    isConnected: _radioState.isConnected,
                                    statusMessage: _getStatusText(),
                                  ),
                                  const SizedBox(height: 16),

                                  // Metrics chips in wrapped layout
                                  _buildMetricsChips(),
                                ],
                              );
                            } else {
                              // Tablet/Desktop layout: Row (status left, metrics right)
                              return Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  // Status indicator (left side) - takes only needed space
                                  StatusIndicator(
                                    audioState: _getAudioState() ??
                                        const AudioStateIdle(),
                                    isConnected: _radioState.isConnected,
                                    statusMessage: _getStatusText(),
                                  ),

                                  // Metrics chips (right side) - aligned to right
                                  _buildMetricsChips(),
                                ],
                              );
                            }
                          },
                        ),
                      ),
                    ),

                    // Diagnostic indicator at the bottom
                    if (_radioState.isConnecting ||
                        _radioState is RadioStateError)
                      Container(
                        padding: const EdgeInsets.symmetric(
                            vertical: 4, horizontal: 8),
                        margin: const EdgeInsets.only(top: 8),
                        decoration: BoxDecoration(
                          color: _radioState.isConnecting
                              ? Colors.blue.withValues(alpha: 0.1)
                              : Colors.red.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: _radioState.isConnecting
                                ? Colors.blue.withValues(alpha: 0.3)
                                : Colors.red.withValues(alpha: 0.3),
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (_radioState.isConnecting)
                              SizedBox(
                                width: 12,
                                height: 12,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  valueColor: AlwaysStoppedAnimation<Color>(
                                      Colors.blue),
                                ),
                              )
                            else
                              Icon(Icons.error_outline,
                                  size: 12, color: Colors.red),
                            const SizedBox(width: 6),
                            Text(
                              _getDiagnosticText(),
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w500,
                                color: _radioState.isConnecting
                                    ? Colors.blue
                                    : Colors.red,
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  // Status chip widget with icon and color
  Widget _buildStatusChip({
    required IconData icon,
    required String label,
    required String value,
    required Color color,
    Color? backgroundColor,
    VoidCallback? onTap,
  }) {
    final borderRadius = BorderRadius.circular(16);
    final chip = Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: backgroundColor ?? color.withValues(alpha: 0.1),
        borderRadius: borderRadius,
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 6),
          Text(
            '$label: $value',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ],
      ),
    );

    if (onTap == null) return chip;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: borderRadius,
          onTap: onTap,
          child: chip,
        ),
      ),
    );
  }

  Widget _buildCompactIndicators() {
    final indicators = <Widget>[
      // Failover cache indicator (clickable to clear cache)
      GestureDetector(
        onTap: _clearFailoverCache,
        child: _buildSimpleLabel(
          icon: Icons.offline_pin,
          value: 'Cached: $_cachedTracksCount',
          color: _cachedTracksCount >= 5
              ? Colors.green
              : _cachedTracksCount >= 3
                  ? Colors.orange
                  : Colors.red,
        ),
      ),
    ];

    // Playback mode indicator
    if (_radioState.isConnected) {
      final isHlsStream = _isHlsStream(_radioState.config?.streamUrl);
      indicators.add(
        _buildSimpleLabel(
          icon: _radioState is RadioStateFailover
              ? Icons.offline_bolt
              : Icons.live_tv,
          value: _radioState is RadioStateFailover
              ? 'Failover'
              : isHlsStream
                  ? 'Live (HLS)'
                  : 'Live',
          color:
              _radioState is RadioStateFailover ? Colors.orange : Colors.green,
        ),
      );

      // Volume indicator (clickable with info)
      indicators.add(
        GestureDetector(
          onTap: _showVolumeInfo,
          child: _buildSimpleLabel(
            icon: Icons.volume_up,
            value: 'Music ${(_volume * 100).round()}%',
            color: Colors.blue,
          ),
        ),
      );
    }

    return Wrap(
      spacing: 12,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: indicators,
    );
  }

  bool _isHlsStream(String? url) {
    if (url == null || url.isEmpty) return false;
    final lower = url.toLowerCase();
    return lower.endsWith('.m3u8') ||
        lower.contains('.m3u8?') ||
        lower.endsWith('.m3u');
  }

  Widget _buildSimpleLabel({
    required IconData icon,
    required String value,
    required Color color,
  }) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 4),
        Text(
          value,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: color,
          ),
        ),
      ],
    );
  }

  Widget _buildMetricsChips() {
    // ✅ Check if live stream is actually playing despite failover state
    final audioState = _getAudioState();
    final isFailoverPlaying =
        _radioState is RadioStateFailover && audioState?.isPlaying == true;

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        // Network status - show "Offline Mode" during failover
        _buildStatusChip(
          icon: isFailoverPlaying
              ? Icons.offline_bolt
              : (_networkState.isConnected ? Icons.wifi : Icons.wifi_off),
          label: 'Network',
          value: isFailoverPlaying
              ? 'Offline Mode'
              : (_networkState.isConnected ? 'Connected' : 'Disconnected'),
          color: isFailoverPlaying
              ? Colors.orange
              : (_networkState.isConnected ? Colors.green : Colors.red),
        ),

        // Stream ping if available
        if (_currentPing != null)
          _buildStatusChip(
            icon: Icons.speed,
            label: 'Ping',
            value: '${_currentPing}ms',
            color: _currentPing! < 100
                ? Colors.green
                : _currentPing! < 300
                    ? Colors.orange
                    : Colors.red,
          ),

        // IP status if playing
        if (_radioState is RadioStateConnected ||
            _radioState is RadioStateFailover)
          ..._buildAudioMetricChips(),
      ],
    );
  }

  List<Widget> _buildAudioMetricChips() {
    final audioState = _getAudioState();
    if (audioState is! AudioStatePlaying) return [];

    final wifiIp = PlatformInfo.localWifiIp;
    final bestIp = PlatformInfo.bestEffortIp;
    final ipLabel = wifiIp != null && wifiIp.isNotEmpty ? 'Local IP' : 'IP';
    final ipValue = bestIp ?? 'Unknown';
    final isLocalLanIp = ipValue.startsWith('192.');

    return [
      // Local/Wi-Fi IP
      _buildStatusChip(
        icon: Icons.lan,
        label: ipLabel,
        value: ipValue,
        color: bestIp != null ? Colors.green : Colors.orange,
        onTap: isLocalLanIp ? () => _openLocalWebUi(ipValue) : null,
      ),
    ];
  }

  Future<void> _openLocalWebUi(String ip) async {
    final trimmed = ip.trim();
    if (!trimmed.startsWith('192.')) return;

    final uri = Uri.parse('http://$trimmed:9292/');
    try {
      final ok = await canLaunchUrl(uri);
      if (!ok) {
        _showError('Failed to open $uri');
        return;
      }
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (e) {
      _showError('Failed to open $uri: $e');
    }
  }
}

class _DismissVisualizerIntent extends Intent {
  const _DismissVisualizerIntent();
}
