import 'dart:async';

/// Simple, efficient dependency injection container
class DependencyInjection {
  static final DependencyInjection _instance = DependencyInjection._();
  static DependencyInjection get instance => _instance;

  DependencyInjection._();

  final Map<Type, _ServiceRegistration> _services = {};
  final Map<Type, dynamic> _singletonInstances = {};

  /// Register a factory that creates a new instance each time
  void registerFactory<T>(T Function() factory) {
    _services[T] = _ServiceRegistration.factory(factory);
  }

  /// Register a singleton - created once and reused
  void registerSingleton<T>(T Function() factory) {
    _services[T] = _ServiceRegistration.singleton(factory);
  }

  /// Register an already created instance as singleton
  void registerInstance<T>(T instance) {
    _singletonInstances[T] = instance;
  }

  /// Get service instance
  T get<T>() {
    // Check for already created singleton instances
    if (_singletonInstances.containsKey(T)) {
      return _singletonInstances[T] as T;
    }

    final registration = _services[T];
    if (registration == null) {
      throw DIException('Service $T not registered');
    }

    final instance = registration.factory() as T;

    // Cache singleton instances
    if (registration.isSingleton) {
      _singletonInstances[T] = instance;
    }

    return instance;
  }

  /// Check if service is registered
  bool isRegistered<T>() =>
      _services.containsKey(T) || _singletonInstances.containsKey(T);

  /// Clear all registrations (useful for testing)
  void clear() {
    _services.clear();
    _singletonInstances.clear();
  }

  /// Dispose all singleton instances that implement Disposable
  Future<void> dispose() async {
    for (final instance in _singletonInstances.values) {
      if (instance is Disposable) {
        await instance.dispose();
      }
    }
    _singletonInstances.clear();
  }
}

class _ServiceRegistration {
  final Function factory;
  final bool isSingleton;

  _ServiceRegistration.factory(this.factory) : isSingleton = false;
  _ServiceRegistration.singleton(this.factory) : isSingleton = true;
}

class DIException implements Exception {
  final String message;
  DIException(this.message);

  @override
  String toString() => 'DIException: $message';
}

/// Interface for disposable services
abstract interface class Disposable {
  Future<void> dispose();
}

/// Convenience extension for easier access
extension DIExtension on DependencyInjection {
  /// Register async factory for services that need async initialization
  void registerAsyncFactory<T>(Future<T> Function() factory) {
    registerFactory<Future<T>>(factory);
  }

  /// Get async service
  Future<T> getAsync<T>() async {
    final future = get<Future<T>>();
    return await future;
  }
}

/// Global getter for convenience
DependencyInjection get di => DependencyInjection.instance;
