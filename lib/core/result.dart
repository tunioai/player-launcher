/// Functional error handling with Result pattern
sealed class Result<T> {
  const Result();

  bool get isSuccess => this is Success<T>;
  bool get isFailure => this is Failure<T>;

  T? get data => switch (this) {
        Success<T> s => s.data,
        Failure<T> _ => null,
      };

  String? get error => switch (this) {
        Success<T> _ => null,
        Failure<T> f => f.message,
      };

  /// Transform success value
  Result<R> map<R>(R Function(T) transform) => switch (this) {
        Success<T> s => Success(transform(s.data)),
        Failure<T> f => Failure(f.message, f.exception),
      };

  /// Chain operations that return Result
  Result<R> flatMap<R>(Result<R> Function(T) transform) => switch (this) {
        Success<T> s => transform(s.data),
        Failure<T> f => Failure(f.message, f.exception),
      };

  /// Handle both success and failure cases
  R fold<R>(
    R Function(T) onSuccess,
    R Function(String) onFailure,
  ) =>
      switch (this) {
        Success<T> s => onSuccess(s.data),
        Failure<T> f => onFailure(f.message),
      };
}

final class Success<T> extends Result<T> {
  final T data;
  const Success(this.data);

  @override
  String toString() => 'Success($data)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is Success<T> && data == other.data;

  @override
  int get hashCode => data.hashCode;
}

final class Failure<T> extends Result<T> {
  final String message;
  final Exception? exception;

  const Failure(this.message, [this.exception]);

  @override
  String toString() => 'Failure($message)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is Failure<T> && message == other.message;

  @override
  int get hashCode => message.hashCode;
}

/// Convenience extension for working with async Results
extension AsyncResult<T> on Future<Result<T>> {
  Future<Result<R>> mapAsync<R>(Future<R> Function(T) transform) async {
    final result = await this;
    return result.isSuccess
        ? Success(await transform(result.data!))
        : Failure(result.error!, (result as Failure).exception);
  }

  Future<Result<R>> flatMapAsync<R>(
      Future<Result<R>> Function(T) transform) async {
    final result = await this;
    return result.isSuccess
        ? await transform(result.data!)
        : Failure(result.error!, (result as Failure).exception);
  }
}

/// Helper to create Results from try-catch blocks
Result<T> tryResult<T>(T Function() operation) {
  try {
    return Success(operation());
  } catch (e) {
    return Failure(e.toString(), e is Exception ? e : Exception(e.toString()));
  }
}

/// Helper for async operations
Future<Result<T>> tryResultAsync<T>(Future<T> Function() operation) async {
  try {
    final result = await operation();
    return Success(result);
  } catch (e) {
    return Failure(e.toString(), e is Exception ? e : Exception(e.toString()));
  }
}
