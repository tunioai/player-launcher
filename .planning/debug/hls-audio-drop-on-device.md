# HLS audio drop on connected Android device

## Status

Checkpoint — root cause narrowed but the next audible drop has not yet been timestamped by a listener.

## Device / build

- Device: Xiaomi `24117RN76O` (`tanzanite`), Android device id `xw6hjrinnboj8xde`.
- App: `ai.tunio.radioplayer` `1.7.1+30`, release/non-debuggable, pid 926.
- Playback uses `HlsStreamAudioSource`, which fetches the playlist and AAC segments in Dart and concatenates them into one `StreamAudioSource`.

## Evidence captured 2026-07-14

- At 20:28–20:30 the media session advanced continuously and maintained 32–35 seconds of buffered audio. Example: position `289663`, buffered `322535`; later position `368584`, buffered `403174`.
- The active AudioTrack (session 937, piid 959) stayed `started`, unmuted, on the speaker. Vendor diagnostics repeatedly reported `fine` output, all mute/silence/starvation counters zero (`m:0 s:0 k:0 z:0`) and non-zero max amplitude.
- No audio-focus loss occurred. Tunio remained top focus owner. A System UI notification at 20:30:09 ducked it to 20% for about 1.7 seconds and it was explicitly unducked at 20:30:11. This is a separate, expected transient and not an HLS/network stall.
- Wi-Fi was validated, RSSI about -63 dBm, 96 Mbps link; Android advertised 30 Mbps downstream / 12 Mbps upstream. Thermal state was 0 (no throttling), with CPU/GPU about 48 C.
- App process load was high but not saturated: about 96% of one core equivalent; device total CPU 68%, iowait 0%. Memory RSS about 595 MB. This does not coincide with an AudioTrack starvation event.
- Historical `media.metrics` entries show real PCM starvation before several recovery cycles: `underrun=1`, with `underrunFrames=38617`, `64064`, and `64960` on tracks 86, 88, and 84 respectively. At 44.1 kHz those counters represent roughly 0.88–1.47 seconds of audio frames that were not supplied in time.
- Android AudioService history then shows that the app repeatedly paused/stopped/recreated the music AudioTrack before the current stable period. Examples:
  - 20:15:45 pause, 20:15:46 restart; 20:15:58 pause, 20:16:01 restart.
  - 20:16:41 pause, 20:16:43 restart; 20:16:53 pause, 20:16:55 restart.
  - 20:21:47 pause, 20:21:48 restart; 20:21:58 pause, 20:22:01 restart.
  - 20:23:06 pause, 20:23:09 restart; 20:23:23 pause, 20:23:26 restart.
- Therefore the audible gaps include genuine AudioTrack underruns and are followed by explicit app player stop/restart cycles. They are not explained by audio-focus loss. The 10–15 second secondary cycles closely match the HLS position-stall watchdog (`_playbackStallTimeoutHls = 12s`, checked every 5s).

## Leading hypothesis

The immediate audio failure is PCM starvation: the decoder/player did not feed AudioTrack fast enough, and the app subsequently entered recovery churn after the custom concatenated AAC source stopped advancing. The capture does not yet establish whether starvation begins in segment delivery, AAC parsing/decoding, Dart stream backpressure, or CPU scheduling; it is not attributable to audio focus. Image/video prefetch is not proven causal.

The pattern is compatible with one bad/discontinuous AAC segment remaining in the live playlist window: a restart begins again at the oldest playlist segment, encounters the same problematic segment about 10–15 seconds later, restarts again, and eventually succeeds after that segment rolls out. This mechanism is not yet proven because the installed release build does not emit info-level segment URI/timing logs and no warning/error line survived in logcat.

## Relevant code

- `lib/services/audio/hls_stream_audio_source.dart`: sequential playlist/segment fetch and raw AAC concatenation.
- `lib/services/audio_service.dart`: position watchdog raises a synthetic network error after 12 seconds without progress.
- `lib/services/radio/enhanced_radio_service.dart`: error handling explicitly stops and restarts the stream.

## Exact next capture needed

Keep filtered ADB logcat running and note the wall-clock second when sound disappears. At that instant capture:

1. Media session position and buffered position.
2. AudioService player events for the active piid.
3. AudioTrack vendor counters/amplitude.
4. Flutter warnings/errors (segment retry, playback stall, restart reason).
5. If release logs remain insufficient, install an instrumented build that logs playlist sequence, segment URI (redacted), download duration/status/bytes, controller backpressure, player position and raw buffer ahead. Do not change recovery behavior until that capture identifies whether the source, watchdog, or server segment initiated the restart.
