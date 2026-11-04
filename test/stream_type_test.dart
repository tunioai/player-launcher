import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tunio_radio_player/models/stream_config.dart';
import 'package:tunio_radio_player/services/stream_type.dart';

const hls = 'https://region-eu1.tunio.ai/hls/x/playlist.m3u8';
const aac = 'https://region-eu1.tunio.ai/stream/x.aac';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    StreamTypePreference.resetForTest();
  });

  test('auto plays HLS, the chosen type plays its stream', () async {
    expect(StreamTypePreference.resolve(hlsUrl: hls, aacUrl: aac), hls);
    await StreamTypePreference.choose(StreamType.aac);
    expect(StreamTypePreference.resolve(hlsUrl: hls, aacUrl: aac), aac);
    await StreamTypePreference.choose(StreamType.hls);
    expect(StreamTypePreference.resolve(hlsUrl: hls, aacUrl: aac), hls);
  });

  test('a missing stream falls back to the other one', () async {
    await StreamTypePreference.choose(StreamType.aac);
    expect(StreamTypePreference.resolve(hlsUrl: hls), hls);
    expect(StreamTypePreference.resolve(aacUrl: aac), aac);
  });

  test('auto leaves HLS after two hung loads in a row', () {
    final reasons = <String>[];
    StreamTypePreference.onFallback = reasons.add;
    StreamTypePreference.reportHlsLoadHang();
    StreamTypePreference.reportHlsLoaded();
    StreamTypePreference.reportHlsLoadHang();
    expect(StreamTypePreference.usingFallback, isFalse);
    StreamTypePreference.reportHlsLoadHang();
    expect(StreamTypePreference.usingFallback, isTrue);
    expect(StreamTypePreference.resolve(hlsUrl: hls, aacUrl: aac), aac);
    expect(reasons, hasLength(1));
  });

  test('auto leaves HLS after three stalls within fifteen minutes', () {
    final t = DateTime(2026, 11, 4, 12);
    StreamTypePreference.reportHlsStall(at: t);
    StreamTypePreference.reportHlsStall(at: t.add(const Duration(minutes: 10)));
    StreamTypePreference.reportHlsStall(at: t.add(const Duration(minutes: 20)));
    expect(StreamTypePreference.usingFallback, isFalse);
    StreamTypePreference.reportHlsStall(at: t.add(const Duration(minutes: 24)));
    expect(StreamTypePreference.usingFallback, isTrue);
  });

  test('a pinned HLS never falls back', () async {
    await StreamTypePreference.choose(StreamType.hls);
    StreamTypePreference.reportHlsLoadHang();
    StreamTypePreference.reportHlsLoadHang();
    expect(StreamTypePreference.fallbackReason.value, isNull);
    expect(StreamTypePreference.resolve(hlsUrl: hls, aacUrl: aac), hls);
  });

  test('the panel takes over when it changes, a panel left at auto does not',
      () async {
    await StreamTypePreference.choose(StreamType.aac);
    await StreamTypePreference.applyLinked(StreamType.auto);
    expect(StreamTypePreference.selected.value, StreamType.aac);
    await StreamTypePreference.applyLinked(StreamType.hls);
    expect(StreamTypePreference.selected.value, StreamType.hls);
    await StreamTypePreference.choose(StreamType.aac);
    await StreamTypePreference.applyLinked(StreamType.hls);
    expect(StreamTypePreference.selected.value, StreamType.aac);
  });

  test('the config keeps both streams and switches between them', () async {
    final config = StreamConfig.fromJson({
      'stream_url': aac,
      'stream_hls_url': hls,
      'stream_type': 'aac',
    });
    expect(config.streamUrl, hls);
    expect(config.streamType, StreamType.aac);
    await StreamTypePreference.choose(StreamType.aac);
    final switched = config.withResolvedStream();
    expect(switched.streamUrl, aac);
    final restored = StreamConfig.fromJson(switched.toJson());
    expect(restored.hlsUrl, hls);
    expect(restored.aacUrl, aac);
    expect(restored.streamUrl, aac);
  });
}
