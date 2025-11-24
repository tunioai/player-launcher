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
  Future<Result<void>> setVolume(double volume);
  Future<Result<void>> reconnect();

  bool get isConnected;
  double get volume;
  int? get currentPing;
}
