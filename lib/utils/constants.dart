class AppConstants {
  static const String appName = 'Tunio Radio Player';
  static const String apiBaseUrl = 'https://api.tunio.ai';
  static const String streamConfigEndpoint = '/v1/stream-params';

  static const Duration apiTimeout = Duration(seconds: 30);
  static const Duration reconnectInterval = Duration(seconds: 5);
  static const Duration configRefreshInterval = Duration(seconds: 30);

  static const int maxReconnectAttempts = 10;
  static const int bufferSizeMs = 5000;

  static const String userAgent = 'TunioRadioPlayer/1.0';

  static const String storageKeyApiKey = 'api_key';
  static const String storageKeyLastStreamUrl = 'last_stream_url';
  static const String storageKeyLastVolume = 'last_volume';
  static const String storageKeyAutoStartEnabled = 'auto_start_enabled';
}

class AudioConstants {
  static const Map<String, String> defaultHeaders = {
    'User-Agent': AppConstants.userAgent,
    'Icy-MetaData': '1',
    'Connection': 'close',
  };

  static const double minVolume = 0.0;
  static const double maxVolume = 1.0;
  static const double defaultVolume = 1.0;
}
