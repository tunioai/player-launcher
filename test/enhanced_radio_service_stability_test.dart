import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tunio_radio_player/core/audio_state.dart';
import 'package:tunio_radio_player/core/result.dart';
import 'package:tunio_radio_player/core/system_state.dart';
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

    test(
        'a transient pause during a transition does not permanently suspend recovery',
        () async {
      // Regression: the player emits a brief AudioStatePaused (playing=false
      // with a retained position) mid-transition. Treating it as a real user
      // pause suspended auto recovery forever (dead air), because the follow-up
      // state was not "playing" and never re-enabled it. Recovery must survive.
      final context = await _createContext(
        liveConfig: liveConfig,
        cachedTracksCount: 2,
      );
      addTearDown(context.dispose);

      // connect (1) + a failed live restart so a later network error falls
      // through to local failover.
      context.audioService.enqueuePlayStreamResult(const Success(null));
      context.audioService
          .enqueuePlayStreamResult(const Failure<void>('restart failed'));

      final connectResult = await context.radioService.connect('112233');
      expect(connectResult.isSuccess, isTrue);
      await _waitUntil(
          () => context.radioService.currentState is RadioStateConnected);

      // Transient pause blip immediately followed by a non-playing transition
      // state (as happens between stop() and play() while switching sources).
      context.audioService.emitState(
        const AudioStatePaused(config: liveConfig, position: Duration(seconds: 3)),
      );
      context.audioService.emitState(
        const AudioStateLoading(config: liveConfig),
      );

      // Wait past the external-pause confirm debounce; recovery must remain on.
      await Future<void>.delayed(const Duration(milliseconds: 2600));

      // A real network error should now still drive failover to local cache.
      context.audioService.emitState(
        AudioStateError(
          message: 'Network error',
          config: liveConfig,
          isRetryable: true,
        ),
      );
      await _waitUntil(
        () => context.radioService.currentState is RadioStateFailover,
        timeout: const Duration(seconds: 8),
      );
      expect(context.audioService.playLocalFileCalls, greaterThanOrEqualTo(1));
    });

    test('an external Stop (idle) is respected and not auto-restarted',
        () async {
      // A notification/Bluetooth Stop unloads the source → the player reports a
      // clean idle. On HLS that is a user action (real failures surface as an
      // error), so auto recovery must suspend and NOT restart or failover.
      const hlsConfig = StreamConfig(
        streamUrl: 'https://example.com/live.m3u8',
        volume: 1.0,
      );
      final context = await _createContext(
        liveConfig: hlsConfig,
        cachedTracksCount: 2,
      );
      addTearDown(context.dispose);

      final connectResult = await context.radioService.connect('445566');
      expect(connectResult.isSuccess, isTrue);
      await _waitUntil(
          () => context.radioService.currentState is RadioStateConnected);
      await _waitUntil(
          () => context.audioService.currentState is AudioStatePlaying);
      final playStreamCallsBefore = context.audioService.playStreamCalls;

      // External transport Stop → clean idle.
      context.audioService.emitState(const AudioStateIdle());
      // Past the confirm debounce; recovery must now be suspended.
      await Future<void>.delayed(const Duration(milliseconds: 2600));

      // A network error afterwards must NOT restart the live stream nor fail
      // over to cache — the user deliberately stopped playback.
      context.audioService.emitState(
        AudioStateError(
          message: 'Network error',
          config: hlsConfig,
          isRetryable: true,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 600));

      expect(context.audioService.playStreamCalls, playStreamCallsBefore);
      expect(context.audioService.playLocalFileCalls, 0);
      expect(context.radioService.currentState, isA<RadioStateConnected>());
    });

    test('restarts live before failover after a network stall', () async {
      final context = await _createContext(
        liveConfig: liveConfig,
        cachedTracksCount: 2,
      );

      addTearDown(() async {
        await context.dispose();
      });

      context.audioService.enqueuePlayStreamResult(const Success(null));
      context.audioService.enqueuePlayStreamResult(const Success(null));

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

      await _waitUntil(() => context.audioService.playStreamCalls >= 2);
      await Future<void>.delayed(const Duration(milliseconds: 400));

      expect(context.audioService.playLocalFileCalls, 0);
      expect(context.radioService.currentState, isA<RadioStateConnected>());
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
        () => context.radioService.currentState is RadioStateFailover,
        timeout: const Duration(seconds: 8),
      );
      expect(context.audioService.playLocalFileCalls, 1);
      context.audioService.emitNetworkState(const NetworkState(
        isConnected: true,
        type: ConnectionType.wifi,
      ));
      context.audioService.playLocalFileDelay =
          const Duration(milliseconds: 500);

      context.audioService.emitState(
        AudioStateError(
          message: 'Format error',
          config: liveConfig,
          isRetryable: false,
        ),
      );

      await _waitUntil(() => context.audioService.playLocalFileCalls >= 2);

      // The stale restore finally block must not unlock the new local-track
      // operation. A duplicate completion signal while that track is loading
      // must therefore be ignored.
      final playStreamCallsDuringNextTrack =
          context.audioService.playStreamCalls;
      context.audioService.emitState(
        AudioStateError(
          message: 'Duplicate track completion',
          config: liveConfig,
          isRetryable: false,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(
          context.audioService.playStreamCalls, playStreamCallsDuringNextTrack);

      expect(context.apiService.getStreamConfigCalls, greaterThanOrEqualTo(2));
      expect(context.radioService.currentState, isA<RadioStateFailover>());
    });

    test('continues cache immediately when the background HLS probe fails',
        () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        request.response.statusCode = HttpStatus.serviceUnavailable;
        await request.response.close();
      });
      addTearDown(() => server.close(force: true));

      final hlsConfig = StreamConfig(
        streamUrl: 'http://${server.address.address}:${server.port}/live.m3u8',
        volume: 1.0,
      );
      final context = await _createContext(
        liveConfig: hlsConfig,
        cachedTracksCount: 3,
      );
      addTearDown(context.dispose);

      context.audioService.enqueuePlayStreamResult(const Success(null));
      context.audioService
          .enqueuePlayStreamResult(const Failure<void>('restart failed'));
      final connectResult = await context.radioService.connect('998877');
      expect(connectResult.isSuccess, isTrue);
      await _waitUntil(
          () => context.radioService.currentState is RadioStateConnected);

      context.audioService.emitState(AudioStateError(
        message: 'Network error',
        config: hlsConfig,
        isRetryable: true,
      ));
      await _waitUntil(
          () => context.radioService.currentState is RadioStateFailover);
      await _waitUntil(() => context.apiService.getStreamConfigCalls >= 2);
      await Future<void>.delayed(const Duration(milliseconds: 100));

      final stopwatch = Stopwatch()..start();
      context.audioService.emitState(AudioStateError(
        message: 'Failover track completed',
        config: hlsConfig,
        isRetryable: false,
      ));
      await _waitUntil(
        () => context.audioService.playLocalFileCalls >= 2,
        timeout: const Duration(seconds: 2),
      );
      stopwatch.stop();

      expect(context.audioService.playStreamCalls, 2);
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 1)));
      expect(context.radioService.currentState, isA<RadioStateFailover>());
    });

    test('restores when a network probe finishes just after a track boundary',
        () async {
      final context = await _createContext(
        liveConfig: liveConfig,
        cachedTracksCount: 3,
      );
      addTearDown(context.dispose);

      context.audioService.enqueuePlayStreamResult(const Success(null));
      context.audioService
          .enqueuePlayStreamResult(const Failure<void>('restart failed'));
      context.audioService.enqueuePlayStreamResult(const Success(null));

      final connectResult = await context.radioService.connect('887766');
      expect(connectResult.isSuccess, isTrue);
      await _waitUntil(
          () => context.radioService.currentState is RadioStateConnected);

      context.apiService.getConfigError = const SocketException('offline');
      context.audioService.emitState(AudioStateError(
        message: 'Network error',
        config: liveConfig,
        isRetryable: true,
      ));
      await _waitUntil(
          () => context.radioService.currentState is RadioStateFailover);

      context.audioService.emitNetworkState(const NetworkState(
        isConnected: false,
        type: ConnectionType.unknown,
      ));
      context.apiService.getConfigError = null;
      context.apiService.getStreamConfigDelay =
          const Duration(milliseconds: 300);
      context.audioService.playLocalFileDelay =
          const Duration(milliseconds: 500);
      context.audioService.emitNetworkState(const NetworkState(
        isConnected: true,
        type: ConnectionType.wifi,
      ));

      // The track boundary arrives before the restored-network probe. The
      // service may start another cached track to avoid silence, but must use
      // the late successful probe immediately instead of waiting for that
      // entire track to end.
      context.audioService.emitState(AudioStateError(
        message: 'Failover track completed',
        config: liveConfig,
        isRetryable: false,
      ));

      await _waitUntil(
        () => context.radioService.currentState is RadioStateConnected,
        timeout: const Duration(seconds: 3),
      );
      expect(context.audioService.playStreamCalls, 3);
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

    test('starts the restore progress timeout after live source preparation',
        () async {
      final context = await _createContext(
        liveConfig: liveConfig,
        cachedTracksCount: 3,
      );
      addTearDown(context.dispose);

      context.audioService.enqueuePlayStreamResult(const Success(null));
      context.audioService
          .enqueuePlayStreamResult(const Failure<void>('restart failed'));
      context.audioService.enqueuePlayStreamResult(const Success(null));

      final connectResult = await context.radioService.connect('334455');
      expect(connectResult.isSuccess, isTrue);
      await _waitUntil(
          () => context.radioService.currentState is RadioStateConnected);

      context.audioService.emitState(AudioStateError(
        message: 'Network error',
        config: liveConfig,
        isRetryable: true,
      ));
      await _waitUntil(
          () => context.radioService.currentState is RadioStateFailover);
      await _waitUntil(() => context.apiService.getStreamConfigCalls >= 2);

      // Reproduces the device trace: the live source installation is queued
      // behind the ending local play operation for longer than the 8-second
      // audible-progress window. That wait must not consume the progress
      // timeout or force another local track.
      context.audioService.liveSourcePreparationDelay =
          const Duration(milliseconds: 8500);
      context.audioService.emitState(AudioStateError(
        message: 'Failover track completed',
        config: liveConfig,
        isRetryable: false,
      ));
      Future<void>.delayed(const Duration(seconds: 9), () {
        context.audioService.emitState(AudioStatePlaying(
          config: liveConfig,
          position: const Duration(seconds: 4),
        ));
      }).ignore();

      await _waitUntil(
        () => context.radioService.currentState is RadioStateConnected,
        timeout: const Duration(seconds: 12),
      );
      expect(context.audioService.playLocalFileCalls, 1);
      expect(context.audioService.playStreamCalls, 3);
    });

    test('ignores a stale failover error while native audio is still playing',
        () async {
      final context = await _createContext(
        liveConfig: liveConfig,
        cachedTracksCount: 3,
      );
      addTearDown(context.dispose);

      context.audioService.enqueuePlayStreamResult(const Success(null));
      context.audioService
          .enqueuePlayStreamResult(const Failure<void>('restart failed'));
      context.audioService.enqueuePlayStreamResult(const Success(null));

      final connectResult = await context.radioService.connect('556677');
      expect(connectResult.isSuccess, isTrue);
      await _waitUntil(
          () => context.radioService.currentState is RadioStateConnected);

      context.audioService.emitState(AudioStateError(
        message: 'Network error',
        config: liveConfig,
        isRetryable: true,
      ));
      await _waitUntil(
          () => context.radioService.currentState is RadioStateFailover);
      await _waitUntil(() => context.apiService.getStreamConfigCalls >= 2);

      context.audioService.playbackActiveOverride = true;
      context.audioService.emitState(AudioStateError(
        message: 'Stale decoder error',
        config: liveConfig,
        isRetryable: false,
      ));
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(context.audioService.playStreamCalls, 2);

      context.audioService.playbackActiveOverride = false;
      context.audioService.emitState(const AudioStateIdle());
      await _waitUntil(
          () => context.radioService.currentState is RadioStateConnected);
      expect(context.audioService.playStreamCalls, 3);
    });

    test('does not spend the progress timeout while switching sources',
        () async {
      final context = await _createContext(
        liveConfig: liveConfig,
        cachedTracksCount: 3,
      );
      addTearDown(context.dispose);

      context.audioService.enqueuePlayStreamResult(const Success(null));
      context.audioService
          .enqueuePlayStreamResult(const Failure<void>('restart failed'));
      context.audioService.enqueuePlayStreamResult(const Success(null));

      final connectResult = await context.radioService.connect('667788');
      expect(connectResult.isSuccess, isTrue);
      await _waitUntil(
          () => context.radioService.currentState is RadioStateConnected);

      context.audioService.emitState(AudioStateError(
        message: 'Network error',
        config: liveConfig,
        isRetryable: true,
      ));
      await _waitUntil(
          () => context.radioService.currentState is RadioStateFailover);
      await _waitUntil(() => context.apiService.getStreamConfigCalls >= 2);

      // Model the Android local-source drain and setAudioSource work inside
      // playStream. The audible-progress timeout must begin only after that
      // operation has installed and started the live source.
      context.audioService.liveSourcePreparationDelay =
          const Duration(seconds: 9);
      context.audioService.emitState(AudioStateError(
        message: 'Failover source completed before output drain',
        config: liveConfig,
        isRetryable: false,
      ));

      await _waitUntil(
        () => context.radioService.currentState is RadioStateConnected,
        timeout: const Duration(seconds: 12),
      );
      expect(context.audioService.playLocalFileCalls, 1);
      expect(context.audioService.playStreamCalls, 3);
    });

    test(
        'keeps playing cache when live reports playing without position progress',
        () async {
      final context = await _createContext(
        liveConfig: liveConfig,
        cachedTracksCount: 3,
      );

      addTearDown(() async {
        await context.dispose();
      });

      context.audioService.enqueuePlayStreamResult(const Success(null));
      context.audioService.autoAdvanceLivePosition = false;
      context.audioService.enqueuePlayStreamResult(const Success(null));

      final connectResult = await context.radioService.connect('223344');
      expect(connectResult.isSuccess, isTrue);
      await _waitUntil(
          () => context.radioService.currentState is RadioStateConnected);

      context.audioService.playbackActiveOverride = false;
      context.audioService.emitState(
        AudioStateError(
          message: 'Network error: playback stalled',
          config: liveConfig,
          isRetryable: true,
        ),
      );
      await _waitUntil(
        () => context.radioService.currentState is RadioStateFailover,
        timeout: const Duration(seconds: 8),
      );
      expect(context.audioService.playLocalFileCalls, 1);

      // The live source accepts play() but never advances. It must not be
      // accepted as restored merely because its Dart state says Playing when
      // the native player itself is not active.
      context.audioService.enqueuePlayStreamResult(const Success(null));
      context.audioService.emitState(
        AudioStateError(
          message: 'Failover track completed',
          config: liveConfig,
          isRetryable: false,
        ),
      );

      await _waitUntil(
        () => context.audioService.playLocalFileCalls >= 2,
        timeout: const Duration(seconds: 20),
      );
      expect(context.radioService.currentState, isA<RadioStateFailover>());

      // At the next boundary a genuinely progressing live stream restores the
      // connected state, completing a second local -> live attempt cycle.
      context.audioService.playbackActiveOverride = null;
      context.audioService.autoAdvanceLivePosition = true;
      context.audioService.enqueuePlayStreamResult(const Success(null));
      context.audioService.emitState(
        AudioStateError(
          message: 'Second failover track completed',
          config: liveConfig,
          isRetryable: false,
        ),
      );

      await _waitUntil(
        () => context.radioService.currentState is RadioStateConnected,
        timeout: const Duration(seconds: 3),
      );
    });

    test('recovers from a stuck failover (cache track ended via Error->Idle)',
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

      final connectResult = await context.radioService.connect('445566');
      expect(connectResult.isSuccess, isTrue);
      await _waitUntil(
          () => context.radioService.currentState is RadioStateConnected);

      // Drop into failover.
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

      // Simulate a cache track that ends via Error -> Idle: this slips past the
      // normal track-end restore trigger (which requires Playing/Paused -> Idle)
      // and would otherwise leave failover stuck silent.
      context.audioService.emitState(
        AudioStateError(
          message: 'decode glitch',
          config: liveConfig,
          isRetryable: true,
        ),
      );
      context.audioService.emitState(const AudioStateIdle());

      // The stuck-failover backstop in the state monitor must force recovery.
      await _waitUntil(
        () => context.radioService.currentState is RadioStateConnected,
        timeout: const Duration(seconds: 20),
      );
      expect(context.radioService.currentState, isA<RadioStateConnected>());
    });

    test('starts from local cache when backend offline mode is enabled',
        () async {
      final context = await _createContext(
        liveConfig: liveConfig,
        cachedTracksCount: 2,
      );

      addTearDown(() async {
        SystemState.instance.setOfflineMode(false);
        await context.dispose();
      });

      // Backend signalled offline mode: connecting must go straight to the
      // local cache instead of starting the live stream and waiting for an
      // interruption.
      SystemState.instance.setOfflineMode(true);

      final connectResult = await context.radioService.connect('778899');
      expect(connectResult.isSuccess, isTrue);

      await _waitUntil(
          () => context.radioService.currentState is RadioStateFailover);

      expect(context.audioService.playStreamCalls, 0);
      expect(context.audioService.playLocalFileCalls, greaterThanOrEqualTo(1));
      expect(context.radioService.currentState, isA<RadioStateFailover>());
    });

    test('connects in screen-only mode when the backend sends no stream_url',
        () async {
      // A point with only a screen attached (no stream_url). The app must reach
      // a valid Connected state so the webview opens, WITHOUT initializing music
      // and WITHOUT falling into the connection retry loop.
      const screenOnlyConfig = StreamConfig(
        streamUrl: '',
        visualizerUrl: 'https://example.com/screen-player/abc',
        volume: 1.0,
      );
      final context = await _createContext(
        liveConfig: screenOnlyConfig,
        cachedTracksCount: 0,
      );
      addTearDown(context.dispose);

      final connectResult = await context.radioService.connect('556677');
      expect(connectResult.isSuccess, isTrue);
      await _waitUntil(
          () => context.radioService.currentState is RadioStateConnected);

      expect(context.audioService.playStreamCalls, 0);
      expect(context.audioService.playLocalFileCalls, 0);

      // Must settle in Connected (screen-only), not churn into failover/reconnect.
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(context.radioService.currentState, isA<RadioStateConnected>());
      expect(context.audioService.playStreamCalls, 0);
      expect(context.audioService.playLocalFileCalls, 0);
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
  Duration playLocalFileDelay = Duration.zero;
  bool autoAdvanceLivePosition = true;
  Duration liveSourcePreparationDelay = Duration.zero;
  bool? playbackActiveOverride;
  bool _disposed = false;
  bool _isLiveSourceActive = false;

  _FakeAudioService({this.initDelay = Duration.zero});

  @override
  Stream<AudioState> get stateStream => _stateController.stream;

  @override
  Stream<NetworkState> get networkStream => _networkController.stream;

  @override
  AudioState get currentState => _currentState;

  @override
  Duration get position => switch (_currentState) {
        AudioStatePlaying(:final position) => position,
        AudioStatePaused(:final position) => position,
        _ => Duration.zero,
      };

  @override
  bool get isPlaybackActive =>
      playbackActiveOverride ?? _currentState is AudioStatePlaying;

  @override
  bool get isLiveSourceActive => _isLiveSourceActive;

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
    if (liveSourcePreparationDelay > Duration.zero) {
      await Future<void>.delayed(liveSourcePreparationDelay);
      if (_disposed) return const Failure<void>('disposed');
    }
    final result = _playStreamResults.isNotEmpty
        ? _playStreamResults.removeFirst()
        : const Success(null);
    if (result.isSuccess) {
      _isLiveSourceActive = true;
      emitState(AudioStatePlaying(config: config));
      Future<void>.delayed(const Duration(milliseconds: 50), () {
        if (!_disposed && _isLiveSourceActive && autoAdvanceLivePosition) {
          emitState(AudioStatePlaying(
            config: config,
            position: const Duration(seconds: 2),
          ));
        }
      }).ignore();
    } else {
      _isLiveSourceActive = false;
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
    if (playLocalFileDelay > Duration.zero) {
      await Future<void>.delayed(playLocalFileDelay);
      if (_disposed) {
        return const Failure<void>('disposed');
      }
    }
    final result = _playLocalResults.isNotEmpty
        ? _playLocalResults.removeFirst()
        : const Success(null);
    final config = originalConfig ?? StreamConfig(streamUrl: filePath);
    if (result.isSuccess) {
      _isLiveSourceActive = false;
      emitState(AudioStatePlaying(config: config));
    } else {
      _isLiveSourceActive = false;
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
    _isLiveSourceActive = false;
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
  Duration getStreamConfigDelay = Duration.zero;

  _FakeApiService({
    required super.storageService,
    required this.config,
  });

  @override
  Future<StreamConfig?> getStreamConfig(String pin, {int? currentPing}) async {
    getStreamConfigCalls++;
    if (getStreamConfigDelay > Duration.zero) {
      await Future<void>.delayed(getStreamConfigDelay);
    }
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
  Future<String?> cacheWarningMessage(String warningUrl) async {
    return null;
  }

  @override
  Future<String?> getCachedWarningMessagePath() async {
    return null;
  }

  @override
  Future<void> clearWarningMessageCache() async {}

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
