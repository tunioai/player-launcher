import '../../core/audio_state.dart';
import '../../models/stream_config.dart';

extension RadioStateConnectedCopyWith on RadioStateConnected {
  RadioStateConnected copyWith({
    String? token,
    StreamConfig? config,
    AudioState? audioState,
    bool? isRetrying,
  }) =>
      RadioStateConnected(
        token: token ?? this.token,
        config: config ?? this.config,
        audioState: audioState ?? this.audioState,
        isRetrying: isRetrying ?? this.isRetrying,
      );
}
