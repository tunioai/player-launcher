import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../core/audio_state.dart';
import '../utils/cli_args.dart';
import '../utils/logger.dart';
import '../utils/platform_info.dart';
import 'desktop_lifecycle_service.dart';
import 'radio_service.dart';
import 'storage_service.dart';

/// A command sent by a short-lived console process to the running player.
class CliCommand {
  const CliCommand(this.name, [this.value]);

  final String name;
  final String? value;

  static CliCommand? parse(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;

    final separator = trimmed.indexOf(' ');
    if (separator < 0) {
      return CliCommand(trimmed.toLowerCase());
    }
    final value = trimmed.substring(separator + 1).trim();
    return CliCommand(
      trimmed.substring(0, separator).toLowerCase(),
      value.isEmpty ? null : value,
    );
  }

  @override
  String toString() => value == null ? name : '$name $value';
}

/// The Dart half of the console interface.
///
/// Two jobs, both of which only make sense on desktop:
///  * act on commands the console front end sends into a running player, and
///  * keep `status.txt` current so `--status` can answer without an IPC round
///    trip — which also means a wedged player still reports something, with a
///    timestamp that gives it away.
class CliService {
  CliService({
    required IRadioService radioService,
    required StorageService storageService,
  })  : _radioService = radioService,
        _storageService = storageService;

  static const MethodChannel _channel =
      MethodChannel('com.example.tunio_radio_player/cli');

  // Bumped if the meaning of a field changes, so an old console front end
  // paired with a new player can tell rather than misreport.
  static const String _schemaVersion = '1';

  // Even with nothing happening, a heartbeat keeps `updated_at` fresh enough
  // that a stale file is evidence the player died rather than went quiet.
  static const Duration _heartbeat = Duration(seconds: 30);

  final IRadioService _radioService;
  final StorageService _storageService;

  StreamSubscription<RadioState>? _stateSubscription;
  Timer? _heartbeatTimer;
  Directory? _directory;
  Future<void> _pendingWrite = Future<void>.value();

  static bool get isSupported => Platform.isWindows;

  Future<void> initialize() async {
    if (!isSupported) return;

    _channel.setMethodCallHandler(_handleMethodCall);

    try {
      // The same directory windows/runner/app_paths.cpp resolves, so the
      // console front end reads exactly what is written here.
      _directory = await getApplicationSupportDirectory();
    } catch (e, stackTrace) {
      Logger.error('CliService: no support directory, status file disabled',
          'cli', e, stackTrace);
    }

    _stateSubscription = _radioService.stateStream.listen(
      (_) => _writeStatus(),
      onError: (Object e) =>
          Logger.error('CliService: state stream: $e', 'cli'),
    );
    _heartbeatTimer = Timer.periodic(_heartbeat, (_) => _writeStatus());
    await _writeStatus();
  }

  Future<void> dispose() async {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    await _stateSubscription?.cancel();
    _stateSubscription = null;
    if (isSupported) {
      _channel.setMethodCallHandler(null);
    }
  }

  /// Applies binding commands that arrived as startup arguments.
  ///
  /// Storage only, deliberately: this runs before the radio service starts,
  /// and its own initialize() connects using whatever token it finds. Doing
  /// the connect here as well would produce two competing attempts.
  Future<void> applyStartupArgs(CliArgs args) async {
    if (args.pin != null) {
      Logger.info('CliService: binding to a point from --pin', 'cli');
      await _storageService.saveToken(args.pin!);
      return;
    }
    if (args.unbind) {
      Logger.info('CliService: clearing the binding from --unbind', 'cli');
      await _storageService.clearToken();
    }
  }

  Future<dynamic> _handleMethodCall(MethodCall call) async {
    if (call.method != 'command') return null;

    final command = CliCommand.parse(call.arguments as String? ?? '');
    if (command == null) return null;

    Logger.info('CliService: console command "$command"', 'cli');
    try {
      await _dispatch(command);
    } catch (e, stackTrace) {
      Logger.error(
          'CliService: command "$command" failed', 'cli', e, stackTrace);
    }
    return null;
  }

  Future<void> _dispatch(CliCommand command) async {
    switch (command.name) {
      case 'show':
        await DesktopLifecycleService.instance.showWindow();
      case 'hide':
        await DesktopLifecycleService.instance.hideWindow();
      case 'quit':
        await DesktopLifecycleService.instance.quit();
      case 'volume':
        final level = int.tryParse(command.value ?? '');
        if (level == null || level < 0 || level > 100) {
          Logger.warning(
              'CliService: ignoring out-of-range volume "${command.value}"',
              'cli');
          return;
        }
        await _radioService.setVolume(level / 100);
      case 'pin':
        if (command.value != null) {
          await _bind(command.value!);
        }
      case 'unbind':
        await _unbind();
      default:
        Logger.warning('CliService: unknown command "${command.name}"', 'cli');
    }
    await _writeStatus();
  }

  Future<void> _bind(String pin) async {
    await _storageService.saveToken(pin);
    await _radioService.connect(pin);
    await _writeStatus();
  }

  Future<void> _unbind() async {
    await _radioService.disconnect();
    await _storageService.clearToken();
    await _writeStatus();
  }

  // ---------------------------------------------------------------------------
  // status.txt
  // ---------------------------------------------------------------------------

  /// TAB-separated key/value lines rather than JSON: the console front end has
  /// no JSON parser, and rendering `--status --json` back out from these pairs
  /// is far less code than parsing JSON in C++.
  Future<void> _writeStatus() {
    final directory = _directory;
    if (directory == null) return Future<void>.value();

    final state = _radioService.currentState;
    final token = _storageService.getToken();

    final fields = <String, String>{
      'schema': _schemaVersion,
      'pid': '$pid',
      'version': PlatformInfo.appVersion,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
      'bound': (token != null && token.isNotEmpty).toString(),
      'playing': state.isConnected.toString(),
      'source': switch (state) {
        RadioStateFailover() => 'cache',
        RadioStateConnected() => 'live',
        _ => 'none',
      },
    };

    final title = state.config?.title;
    if (title != null && title.isNotEmpty) {
      fields['point'] = title;
    }
    final streamUrl = state.config?.streamUrl;
    if (streamUrl != null && streamUrl.isNotEmpty) {
      fields['stream'] = streamUrl;
    }

    final contents = StringBuffer();
    for (final entry in fields.entries) {
      // A tab or newline in a value would desync every following line, and a
      // point name is server-supplied text we do not control.
      final value = entry.value.replaceAll(RegExp(r'[\t\r\n]'), ' ');
      contents.writeln('${entry.key}\t$value');
    }

    // Serialised and written through a temp file for the same reason as the
    // credential store: a reader must never catch a half-written file.
    _pendingWrite = _pendingWrite.then((_) async {
      try {
        final tmp =
            File('${directory.path}${Platform.pathSeparator}status.txt.tmp');
        await tmp.writeAsString(contents.toString(), flush: true);
        await tmp
            .rename('${directory.path}${Platform.pathSeparator}status.txt');
      } catch (e) {
        // Status reporting must never take the player down with it.
        Logger.error('CliService: failed to write status file: $e', 'cli');
      }
    });
    return _pendingWrite;
  }
}
