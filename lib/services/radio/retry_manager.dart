/// Retry management with fixed delay.
final class RetryManager {
  int _currentAttempt = 0;
  static const List<Duration> _backoffSchedule = [
    Duration(seconds: 5),
    Duration(seconds: 15),
    Duration(seconds: 30),
    Duration(minutes: 1),
    Duration(minutes: 2),
  ];

  int get currentAttempt => _currentAttempt;

  // Always allow retry - no maximum attempts for autonomous background operation
  bool get canRetry => true;

  void recordAttempt() {
    _currentAttempt++;
  }

  void reset() {
    _currentAttempt = 0;
  }

  Duration getNextDelay() {
    final index = _currentAttempt >= _backoffSchedule.length
        ? _backoffSchedule.length - 1
        : _currentAttempt;
    return _backoffSchedule[index];
  }
}
