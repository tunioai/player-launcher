/// Tracks unstable live-stream restores and decides how many failover tracks
/// should play before the next restore attempt.
final class FailoverRecoveryBackoff {
  static const Duration recentRestoreThreshold = Duration(minutes: 2);
  static const List<int> _trackSkipSchedule = [0, 1, 2, 4, 6];

  int _instabilityLevel = 0;
  int _pendingTrackSkips = 0;

  int get pendingTrackSkips => _pendingTrackSkips;
  int get instabilityLevel => _instabilityLevel;

  void recordFailoverActivation({required bool wasRecentRestore}) {
    if (wasRecentRestore) {
      _increaseInstability();
    } else {
      _coolDownInstability();
    }
    _resetPendingSkips();
  }

  void recordRestoreFailure() {
    _increaseInstability();
    _resetPendingSkips();
  }

  void recordSuccessfulRestore() {
    _instabilityLevel = 0;
    _pendingTrackSkips = 0;
  }

  int? consumePendingSkip() {
    if (_pendingTrackSkips <= 0) {
      return null;
    }
    final before = _pendingTrackSkips;
    _pendingTrackSkips--;
    return before;
  }

  void _resetPendingSkips() {
    final index = _instabilityLevel.clamp(0, _trackSkipSchedule.length - 1);
    _pendingTrackSkips = _trackSkipSchedule[index];
  }

  void _increaseInstability() {
    if (_instabilityLevel < _trackSkipSchedule.length - 1) {
      _instabilityLevel++;
    }
  }

  void _coolDownInstability() {
    if (_instabilityLevel > 0) {
      _instabilityLevel--;
    }
  }
}
