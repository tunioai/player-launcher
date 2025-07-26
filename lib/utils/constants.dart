class AppConstants {
  static const String userAgent = 'TunioRadioPlayer/1.0';

  // Failover cache settings
  static const int maxFailoverTracks = 20;
  static const String failoverCacheDir = 'failover_cache';
  static const Duration trackCacheTTL = Duration(days: 2);
}
