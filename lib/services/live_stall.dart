/// A live source has stalled only when nothing shows it moving: the buffer
/// has not grown for [threshold] and neither has the playback position.
///
/// The position counts because some players never report the buffer: on
/// Windows just_audio emits no buffered position for a live HLS stream, so
/// the buffer alone read every audible stream as stalled a minute after it
/// started and restarted it every minute after that.
bool isLiveBufferStalled({
  required Duration sinceBufferUpdate,
  required Duration? sincePlaybackProgress,
  required Duration threshold,
}) {
  if (sinceBufferUpdate <= threshold) return false;
  return sincePlaybackProgress == null || sincePlaybackProgress > threshold;
}
