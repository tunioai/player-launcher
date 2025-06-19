import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import '../models/stream_config.dart';
import '../models/api_error.dart';
import '../utils/logger.dart';

class ApiService {
  static const String baseUrl = 'https://api.tunio.ai';
  static const Duration timeout = Duration(seconds: 30);

  Future<StreamConfig?> getStreamConfig(String token) async {
    if (token.isEmpty) return null;

    try {
      final uri = Uri.parse('$baseUrl/v1/stream-params?token=$token');

      Logger.debug('Making API request to: $uri', 'ApiService');
      Logger.debug(
          'Request headers: Content-Type: application/json, User-Agent: TunioRadioPlayer/1.0',
          'ApiService');

      final response = await http.get(
        uri,
        headers: {
          'Content-Type': 'application/json',
          'User-Agent': 'TunioRadioPlayer/1.0',
        },
      ).timeout(timeout);

      Logger.debug(
          'API Response Status Code: ${response.statusCode}', 'ApiService');
      Logger.debug('API Response Headers: ${response.headers}', 'ApiService');
      Logger.debug('API Response Body: ${response.body}', 'ApiService');

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        Logger.info('Successfully received API response: $data', 'ApiService');

        // Check success field
        final success = data['success'] ?? false;
        if (!success) {
          final errorMessage = data['message'] ?? 'Unknown error';
          Logger.warning(
              'API returned success=false: $errorMessage', 'ApiService');
          throw ApiError(
            message: errorMessage,
            statusCode: response.statusCode,
            isFromBackend: true,
          );
        }

        // Extract stream data
        final streamData = data['stream'];
        if (streamData == null) {
          Logger.error('No stream data found in API response', 'ApiService');
          throw Exception('No stream data available');
        }

        print('🌐 ApiService: Raw API response: $data');
        print('🌐 ApiService: Stream data: $streamData');

        final streamConfig = StreamConfig.fromJson(streamData);
        print(
            '🌐 ApiService: Created StreamConfig with URL: ${streamConfig.streamUrl}');
        return streamConfig;
      } else {
        // Try to parse error message from response body for non-200 status codes
        String errorMessage;
        try {
          final errorData = json.decode(response.body);
          errorMessage = errorData['message'] ??
              _getDefaultErrorMessage(response.statusCode);
        } catch (_) {
          errorMessage = _getDefaultErrorMessage(response.statusCode);
        }

        Logger.error(
            'API returned error status: ${response.statusCode}, body: ${response.body}',
            'ApiService');
        throw ApiError(
          message: errorMessage,
          statusCode: response.statusCode,
          isFromBackend: true,
        );
      }
    } on SocketException catch (e) {
      Logger.error('Socket exception during API call', 'ApiService', e);
      throw const ApiError(message: 'No internet connection');
    } on http.ClientException catch (e) {
      Logger.error('HTTP client exception during API call', 'ApiService', e);
      throw const ApiError(message: 'Network error');
    } on ApiError {
      rethrow; // Re-throw ApiError as-is
    } catch (e) {
      Logger.error('Unexpected error during API call', 'ApiService', e);
      throw ApiError(message: 'Failed to fetch stream config: $e');
    }
  }

  Future<bool> validateToken(String token) async {
    Logger.debug(
        'Validating token: ${token.length >= 6 ? token.substring(0, 3) + "***" : token}',
        'ApiService');
    try {
      await getStreamConfig(token);
      Logger.info('Token validation successful', 'ApiService');
      return true;
    } catch (e) {
      Logger.warning('Token validation failed: $e', 'ApiService');
      return false;
    }
  }

  String _getDefaultErrorMessage(int statusCode) {
    switch (statusCode) {
      case 401:
        return 'Invalid code';
      case 403:
        return 'Access denied';
      case 404:
        return 'Service not found';
      case 429:
        return 'Too many requests';
      case 500:
        return 'Server error';
      case 502:
        return 'Bad gateway';
      case 503:
        return 'Service unavailable';
      default:
        return 'Server error ($statusCode)';
    }
  }
}
