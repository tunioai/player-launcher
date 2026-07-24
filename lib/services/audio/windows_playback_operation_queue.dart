/// Serializes Windows source mutations (`load`, `stop`, and source switches).
///
/// WinRT MediaPlayer reports `Loading interrupted` when a second mutation
/// overtakes an unfinished load. Android does not use this queue; callers gate
/// it with `Platform.isWindows` so ExoPlayer behavior remains unchanged.
final class WindowsPlaybackOperationQueue {
  Future<void> _tail = Future<void>.value();

  Future<T> run<T>(Future<T> Function() operation) {
    final result = _tail.then((_) => operation());
    _tail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return result;
  }
}
