import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tunio_radio_player/services/audio/hls_stream_audio_source.dart';

void main() {
  test('surfaces a network error after a sustained playlist outage', () async {
    // A server that always fails the playlist request simulates an outage on
    // the path to the CDN (the "Playlist failed [network]" case seen in the
    // field diagnostics).
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) {
      req.response.statusCode = HttpStatus.serviceUnavailable;
      unawaited(req.response.close());
    });
    addTearDown(() => server.close(force: true));

    final source = HlsStreamAudioSource(
      playlistUri: Uri.parse('http://127.0.0.1:${server.port}/playlist.m3u8'),
      refreshInterval: const Duration(milliseconds: 30),
      segmentRequestTimeout: const Duration(milliseconds: 300),
      maxPlaylistOutage: const Duration(milliseconds: 300),
    );
    addTearDown(source.close);

    final response = await source.request();

    Object? captured;
    final done = Completer<void>();
    response.stream.listen(
      (_) {},
      onError: (Object error) {
        captured = error;
        if (!done.isCompleted) done.complete();
      },
      onDone: () {
        if (!done.isCompleted) done.complete();
      },
    );

    await done.future.timeout(const Duration(seconds: 5));
    expect(captured, isNotNull);
    expect(captured.toString(), contains('Network error'));
  });

  test('does not surface an error for a brief outage within the window',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) {
      req.response.statusCode = HttpStatus.serviceUnavailable;
      unawaited(req.response.close());
    });
    addTearDown(() => server.close(force: true));

    // Outage window far larger than the observation window: the source must
    // keep retrying silently and must NOT pre-empt buffered playback.
    final source = HlsStreamAudioSource(
      playlistUri: Uri.parse('http://127.0.0.1:${server.port}/playlist.m3u8'),
      refreshInterval: const Duration(milliseconds: 30),
      segmentRequestTimeout: const Duration(milliseconds: 300),
      maxPlaylistOutage: const Duration(seconds: 30),
    );
    addTearDown(source.close);

    final response = await source.request();

    Object? captured;
    var done = false;
    final subscription = response.stream.listen(
      (_) {},
      onError: (Object error) => captured = error,
      onDone: () => done = true,
    );
    addTearDown(subscription.cancel);

    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(captured, isNull);
    expect(done, isFalse);
  });
}
