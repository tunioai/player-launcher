import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

import '../utils/logger.dart';

/// Status message surfaced to the UI while Windows reports zero active audio
/// output devices. Also used as a marker to recognize this failure in wrapped
/// error strings, so keep it stable.
const String kNoAudioOutputMessage =
    'No audio output device - connect speakers or headphones';

/// Detects whether the OS has at least one active audio output device.
///
/// Windows only: with zero render endpoints (e.g. a Bluetooth-only setup with
/// the speaker disconnected) the WinRT MediaPlayer fails every load - even of
/// local files - with `sourceNotSupported`, which by the error alone is
/// indistinguishable from a network or codec problem. Checking the endpoint
/// list lets us tell the user what is actually wrong before touching the
/// player.
final class AudioOutputService {
  Timer? _pollTimer;
  bool? _lastAvailability;
  final StreamController<bool> _availabilityController =
      StreamController<bool>.broadcast();

  /// Fires when availability flips; true means an output device appeared.
  Stream<bool> get onAvailabilityChanged => _availabilityController.stream;

  bool get isSupported => Platform.isWindows;

  /// True/false when Windows answered, null when the check is unsupported or
  /// failed. Callers must treat null as "unknown" and proceed (fail open).
  bool? hasActiveOutputDevice() {
    if (!isSupported) return null;
    try {
      return _countActiveRenderDevices() > 0;
    } catch (e) {
      Logger.warning('🔊 AUDIO_OUTPUT: Device enumeration failed: $e');
      return null;
    }
  }

  /// Starts polling for output-device arrival/removal. No-op off Windows or
  /// when already monitoring.
  void startMonitoring({Duration interval = const Duration(seconds: 5)}) {
    if (!isSupported || _pollTimer != null) return;
    _pollOnce();
    _pollTimer = Timer.periodic(interval, (_) => _pollOnce());
  }

  void _pollOnce() {
    final available = hasActiveOutputDevice();
    if (available == null) return;
    final previous = _lastAvailability;
    _lastAvailability = available;
    if (previous != null && previous != available) {
      Logger.info(
          '🔊 AUDIO_OUTPUT: Output device ${available ? 'connected' : 'disconnected'}');
      _availabilityController.add(available);
    }
  }

  int _countActiveRenderDevices() {
    final initResult = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    // RPC_E_CHANGED_MODE means COM is already initialized on this thread with
    // a different threading model: usable as-is, but without a matching
    // CoUninitialize from us.
    if (FAILED(initResult) && initResult != RPC_E_CHANGED_MODE) {
      throw WindowsException(initResult);
    }
    final ownsComInit = initResult == S_OK || initResult == S_FALSE;

    MMDeviceEnumerator? enumerator;
    IMMDeviceCollection? collection;
    final ppDevices = calloc<Pointer<COMObject>>();
    final pCount = calloc<Uint32>();
    try {
      enumerator = MMDeviceEnumerator.createInstance();
      final enumResult = enumerator.enumAudioEndpoints(
          eRender, DEVICE_STATE_ACTIVE, ppDevices);
      if (FAILED(enumResult)) throw WindowsException(enumResult);

      collection = IMMDeviceCollection(ppDevices.value);
      final countResult = collection.getCount(pCount);
      if (FAILED(countResult)) throw WindowsException(countResult);
      return pCount.value;
    } finally {
      collection?.release();
      enumerator?.release();
      calloc.free(ppDevices);
      calloc.free(pCount);
      if (ownsComInit) CoUninitialize();
    }
  }

  void dispose() {
    _pollTimer?.cancel();
    _pollTimer = null;
    _availabilityController.close();
  }
}
