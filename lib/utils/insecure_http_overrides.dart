import 'dart:io';

/// Overrides the default [HttpClient] to skip TLS certificate validation.
/// Useful for development environments where self-signed certificates
/// are used by the radio source or backend. Do **not** ship this to
/// production environments unless you fully trust the endpoints.
class InsecureHttpOverrides extends HttpOverrides {
  InsecureHttpOverrides();

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    client.badCertificateCallback =
        (X509Certificate cert, String host, int port) => true;
    return client;
  }
}
