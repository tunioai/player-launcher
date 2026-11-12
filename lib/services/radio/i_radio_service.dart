import 'dart:async';

import '../../core/audio_state.dart';
import '../../core/dependency_injection.dart';
import '../../core/result.dart';

/// Interface for radio service.
abstract interface class IRadioService implements Disposable {
  Stream<RadioState> get stateStream;
  Stream<NetworkState> get networkStream;
  Stream<int?> get pingStream;
  RadioState get currentState;

  Future<Result<void>> initialize();
  Future<Result<void>> connect(String token);
  Future<Result<void>> disconnect();
  Future<Result<void>> playPause();

  /// Silences the music on the listener's request, as the in-app pause does.
  Future<Result<void>> pause();

  /// Brings the music back after a pause, as the in-app play does.
  Future<Result<void>> play();
  Future<Result<void>> setVolume(double volume);
  Future<Result<void>> reconnect();

  bool get isConnected;
  double get volume;
  int? get currentPing;
}
