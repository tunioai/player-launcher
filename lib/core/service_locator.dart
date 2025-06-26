import 'dart:async';

import '../core/dependency_injection.dart';
import '../services/api_service.dart';
import '../services/storage_service.dart';
import '../services/audio_service.dart';
import '../services/radio_service.dart';

/// Service locator for dependency injection setup
class ServiceLocator {
  static bool _isInitialized = false;

  /// Initialize all services and dependencies
  static Future<void> initialize() async {
    if (_isInitialized) return;

    // Initialize storage service first (async)
    final storageService = await StorageService.getInstance();

    // Core services
    di.registerInstance<ApiService>(ApiService());
    di.registerInstance<StorageService>(storageService);

    // Audio service with interface
    di.registerSingleton<IAudioService>(() => EnhancedAudioService());

    // Radio service with dependencies
    di.registerSingleton<IRadioService>(() => EnhancedRadioService(
          audioService: di.get<IAudioService>(),
          apiService: di.get<ApiService>(),
          storageService: di.get<StorageService>(),
        ));

    // Initialize radio service to enable auto-reconnect
    // Don't await to prevent blocking app startup if network unavailable
    final radioService = di.get<IRadioService>();
    unawaited(radioService.initialize());

    _isInitialized = true;
  }

  /// Dispose all services
  static Future<void> dispose() async {
    await di.dispose();
    _isInitialized = false;
  }

  /// Reset for testing
  static void reset() {
    di.clear();
    _isInitialized = false;
  }
}

/// Convenience getters for commonly used services
extension ServiceLocatorExtensions on DependencyInjection {
  IRadioService get radioService => get<IRadioService>();
  IAudioService get audioService => get<IAudioService>();
  ApiService get apiService => get<ApiService>();
  StorageService get storageService => get<StorageService>();
}

/// Helper to fire and forget async operations
void unawaited(Future<void> future) {
  future.catchError((error, stackTrace) {
    // Log error but don't crash the app
    // Error handled by service internally
  });
}
