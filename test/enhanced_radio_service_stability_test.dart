import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tunio_radio_player/core/audio_state.dart';
import 'package:tunio_radio_player/core/result.dart';
import 'package:tunio_radio_player/models/current_track.dart';
import 'package:tunio_radio_player/models/failover_event.dart';
import 'package:tunio_radio_player/models/stream_config.dart';
import 'package:tunio_radio_player/services/api_service.dart';
import 'package:tunio_radio_player/services/audio_service.dart';
import 'package:tunio_radio_player/services/failover_reporting_service.dart';
import 'package:tunio_radio_player/services/failover_service.dart';
import 'package:tunio_radio_player/services/radio/enhanced_radio_service.dart';
import 'package:tunio_radio_player/services/storage_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const liveConfig = StreamConfig(
    streamUrl: 'https://example.com/live.aac',
    volume: 1.0,
  );

  setUpAll(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final storage = await StorageService.getInstance();
    await storage.clear();
  });

  group('EnhancedRadioService stability', () {
    test('initialize is single-flight under concurrent calls', () async {
      final context = await _createContext(
        liveConfig: liveConfig,
        cachedTracksCount: 1,
        audioInitDelay: const Duration(milliseconds: 80),
      );

      addTearDown(() async {
        await context.dispose();
      });

      final results = await Future.wait<Result<void>>(
        List.generate(6, (_) => context.radioService.initialize()),
      );

      for (final result in results) {
        expect(result.isSuccess, isTrue);
      }
      expect(context.audioService.initializeCalls, 1);
    });

    test('falls back quickly when live stream restart fails', () async {
      final context = await _createContext(
        liveConfig: liveConfig,
        cachedTracksCount: 2,
      );

      addTearDown(() async {
        await context.dispose();
      });

      context.audioService.enqueuePlayStreamResult(const Success(null));
      context.audioService
          .enqueuePlayStreamResult(const Failure<void>('restart failed'));

      final connectResult = await context.radioService.connect('123456');
      expect(connectResult.isSuccess, isTrue);
      await _waitUntil(
          () => context.radioService.currentState is RadioStateConnected);

      context.audioService.emitState(
        AudioStateError(
          message: 'Network error',
          config: liveConfig,
          isRetryable: true,
        ),
      );

      await _waitUntil(
          () => context.radioService.currentState is RadioStateFailover);

      expect(context.audioService.playLocalFileCalls, greaterThanOrEqualTo(1));
      expect(context.radioService.currentState, isA<RadioStateFailover>());
    });

    test(
        'tries restoring after failover and continues cache on restore failure',
        () async {
      final context = await _createContext(
        liveConfig: liveConfig,
        cachedTracksCount: 3,
      );

      addTearDown(() async {
        await context.dispose();
      });

      context.audioService.enqueuePlayStreamResult(const Success(null));
      context.audioService
          .enqueuePlayStreamResult(const Failure<void>('restart failed'));
      context.audioService
          .enqueuePlayStreamResult(const Failure<void>('restore failed'));

      final connectResult = await context.radioService.connect('654321');
      expect(connectResult.isSuccess, isTrue);
      await _waitUntil(
          () => context.radioService.currentState is RadioStateConnected);

      context.audioService.emitState(
        AudioStateError(
          message: 'Network error',
          config: liveConfig,
          isRetryable: true,
        ),
      );
      await _waitUntil(
          () => context.radioService.currentState is RadioStateFailover);
      expect(context.audioService.playLocalFileCalls, 1);
      context.audioService.emitNetworkState(const NetworkState(
        isConnected: true,
        type: ConnectionType.wifi,
      ));

      context.audioService.emitState(
        AudioStateError(
          message: 'Format error',
          config: liveConfig,
          isRetryable: false,
        ),
      );

      await _waitUntil(() => context.audioService.playLocalFileCalls >= 2);

      expect(context.apiService.getStreamConfigCalls, greaterThanOrEqualTo(2));
      expect(context.radioService.currentState, isA<RadioStateFailover>());
    });

    test('restores from failover even when connectivity state is stale offline',
        () async {
      final context = await _createContext(
        liveConfig: liveConfig,
        cachedTracksCount: 3,
      );

      addTearDown(() async {
        await context.dispose();
      });

      context.audioService.enqueuePlayStreamResult(const Success(null));
      context.audioService
          .enqueuePlayStreamResult(const Failure<void>('restart failed'));
      context.audioService.enqueuePlayStreamResult(const Success(null));

      final connectResult = await context.radioService.connect('112233');
      expect(connectResult.isSuccess, isTrue);
      await _waitUntil(
          () => context.radioService.currentState is RadioStateConnected);

      context.audioService.emitState(
        AudioStateError(
          message: 'Network error',
          config: liveConfig,
          isRetryable: true,
        ),
      );
      await _waitUntil(
          () => context.radioService.currentState is RadioStateFailover);
      expect(context.audioService.playLocalFileCalls, 1);

      context.audioService.emitNetworkState(const NetworkState(
        isConnected: false,
        type: ConnectionType.unknown,
      ));

      context.audioService.emitState(
        AudioStateError(
          message: 'Failover track completed',
          config: liveConfig,
          isRetryable: false,
        ),
      );

      await _waitUntil(
          () => context.radioService.currentState is RadioStateConnected);

      expect(context.apiService.getStreamConfigCalls, greaterThanOrEqualTo(2));
      expect(context.radioService.currentState, isA<RadioStateConnected>());
    });
  });
}

Future<void> _waitUntil(
  bool Function() predicate, {
  Duration timeout = const Duration(seconds: 2),
  Duration step = const Duration(milliseconds: 20),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (predicate()) {
      return;
    }
    await Future<void>.delayed(step);
  }
  fail('Timed out waiting for condition');
}

Future<_TestContext> _createContext({
  required StreamConfig liveConfig,
  required int cachedTracksCount,
  Duration audioInitDelay = Duration.zero,
}) async {
  final storageService = await StorageService.getInstance();
  await storageService.clear();
  await storageService.saveLastVolume(0.9);

  final audioService = _FakeAudioService(initDelay: audioInitDelay);
  final apiService =
      _FakeApiService(storageService: storageService, config: liveConfig);
  final failoverService = _FakeFailoverService(
    cachedTracksCount: cachedTracksCount,
    randomTrack: File('/tmp/fallback_track.m4a'),
  );
  final reportingService = _FakeFailoverReportingService(
    storageService: storageService,
    apiService: apiService,
  );

  final radioService = EnhancedRadioService(
    audioService: audioService,
    apiService: apiService,
    storageService: storageService,
    failoverService: failoverService,
    failoverReportingService: reportingService,
  );

  return _TestContext(
    storageService: storageService,
    audioService: audioService,
    apiService: apiService,
    failoverService: failoverService,
    reportingService: reportingService,
    radioService: radioService,
  );
}

class _TestContext {
  final StorageService storageService;
  final _FakeAudioService audioService;
  final _FakeApiService apiService;
  final _FakeFailoverService failoverService;
  final _FakeFailoverReportingService reportingService;
  final EnhancedRadioService radioService;

  _TestContext({
    required this.storageService,
    required this.audioService,
    required this.apiService,
    required this.failoverService,
    required this.reportingService,
    required this.radioService,
  });

  Future<void> dispose() async {
    await radioService.dispose();
    await failoverService.dispose();
    await reportingService.dispose();
    await storageService.clear();
  }
}

class _FakeAudioService implements IAudioService {
  final Duration initDelay;
  final StreamController<AudioState> _stateController =
      StreamController<AudioState>.broadcast();
  final StreamController<NetworkState> _networkController =
      StreamController<NetworkState>.broadcast();
  final Queue<Result<void>> _playStreamResults = Queue<Result<void>>();
  final Queue<Result<void>> _playLocalResults = Queue<Result<void>>();

  AudioState _currentState = const AudioStateIdle();
  double _volume = 1.0;
  int initializeCalls = 0;
  int playStreamCalls = 0;
  int playLocalFileCalls = 0;
  bool _disposed = false;

  _FakeAudioService({this.initDelay = Duration.zero});

  @override
  Stream<AudioState> get stateStream => _stateController.stream;

  @override
  Stream<NetworkState> get networkStream => _networkController.stream;

  @override
  AudioState get currentState => _currentState;

  @override
  double get volume => _volume;

  void enqueuePlayStreamResult(Result<void> result) {
    _playStreamResults.add(result);
  }

  void enqueuePlayLocalResult(Result<void> result) {
    _playLocalResults.add(result);
  }

  void emitState(AudioState state) {
    _currentState = state;
    _stateController.add(state);
  }

  void emitNetworkState(NetworkState state) {
    _networkController.add(state);
  }

  @override
  Future<Result<void>> initialize() async {
    initializeCalls++;
    if (initDelay > Duration.zero) {
      await Future<void>.delayed(initDelay);
    }
    _networkController.add(
      const NetworkState(
        isConnected: true,
        type: ConnectionType.wifi,
      ),
    );
    return const Success(null);
  }

  @override
  Future<Result<void>> playStream(StreamConfig config,
      {bool quickStart = false}) async {
    playStreamCalls++;
    final result = _playStreamResults.isNotEmpty
        ? _playStreamResults.removeFirst()
        : const Success(null);
    if (result.isSuccess) {
      emitState(AudioStatePlaying(config: config));
    } else {
      emitState(AudioStateError(
        message: result.error ?? 'playStream failed',
        config: config,
        isRetryable: true,
      ));
    }
    return result;
  }

  @override
  Future<Result<void>> playLocalFile(String filePath,
      {StreamConfig? originalConfig}) async {
    playLocalFileCalls++;
    final result = _playLocalResults.isNotEmpty
        ? _playLocalResults.removeFirst()
        : const Success(null);
    final config = originalConfig ?? StreamConfig(streamUrl: filePath);
    if (result.isSuccess) {
      emitState(AudioStatePlaying(config: config));
    } else {
      emitState(AudioStateError(
        message: result.error ?? 'playLocalFile failed',
        config: config,
        isRetryable: false,
      ));
    }
    return result;
  }

  @override
  Future<Result<void>> pause() async {
    return const Success(null);
  }

  @override
  Future<Result<void>> resume() async {
    return const Success(null);
  }

  @override
  Future<Result<void>> stop() async {
    emitState(const AudioStateIdle());
    return const Success(null);
  }

  @override
  Future<Result<void>> setVolume(double volume) async {
    _volume = volume;
    return const Success(null);
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _stateController.close();
    await _networkController.close();
  }
}

class _FakeApiService extends ApiService {
  StreamConfig config;
  int getStreamConfigCalls = 0;
  Object? getConfigError;

  _FakeApiService({
    required super.storageService,
    required this.config,
  });

  @override
  Future<StreamConfig?> getStreamConfig(String pin, {int? currentPing}) async {
    getStreamConfigCalls++;
    final error = getConfigError;
    if (error != null) {
      throw error;
    }
    return config;
  }

  @override
  Future<void> sendFailoverReport(
      String pin, List<FailoverEvent> events) async {}
}

class _FakeFailoverService implements IFailoverService {
  final StreamController<int> _cachedCountController =
      StreamController<int>.broadcast();

  int _cachedTracksCount;
  File? randomTrack;

  _FakeFailoverService({
    required int cachedTracksCount,
    this.randomTrack,
  }) : _cachedTracksCount = cachedTracksCount;

  @override
  Future<void> initialize() async {}

  @override
  Future<void> downloadTrack(CurrentTrack track) async {}

  @override
  Future<List<File>> getAvailableTracks() async {
    if (_cachedTracksCount <= 0 || randomTrack == null) {
      return <File>[];
    }
    return <File>[randomTrack!];
  }

  @override
  Future<File?> getRandomTrack() async {
    if (_cachedTracksCount <= 0) {
      return null;
    }
    return randomTrack;
  }

  @override
  Future<void> clearCache() async {
    _cachedTracksCount = 0;
    _cachedCountController.add(_cachedTracksCount);
  }

  @override
  int get cachedTracksCount => _cachedTracksCount;

  @override
  Stream<int> get cachedTracksCountStream => _cachedCountController.stream;

  @override
  Future<void> dispose() async {
    await _cachedCountController.close();
  }
}

class _FakeFailoverReportingService extends FailoverReportingService {
  int logEventCalls = 0;

  _FakeFailoverReportingService({
    required super.storageService,
    required super.apiService,
  });

  @override
  Future<void> logEvent(FailoverEvent event, {String? pin}) async {
    logEventCalls++;
  }

  @override
  Future<void> flush({String? pin}) async {}

  @override
  void scheduleFlush(String pin) {}
}
