class ApiError implements Exception {
  final String message;
  final int? statusCode;
  final bool isFromBackend;

  const ApiError({
    required this.message,
    this.statusCode,
    this.isFromBackend = false,
  });

  @override
  String toString() => message;
}
