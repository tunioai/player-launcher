import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import '../models/stream_config.dart';
import '../models/api_error.dart';
import '../utils/logger.dart';

class ApiService {
  static const String baseUrl = 'https://api.tunio.ai';
  static const Duration timeout = Duration(seconds: 30);

  Future<StreamConfig?> getStreamConfig(String pin) async {
    if (pin.isEmpty) return null;

    try {
      final uri = Uri.parse('$baseUrl/v1/spot?pin=$pin');

      Logger.debug('🔄 API_DEBUG: Starting API request to: $uri', 'ApiService');
      Logger.debug(
          '🔄 API_DEBUG: Current timestamp: ${DateTime.now().toIso8601String()}',
          'ApiService');
      Logger.debug(
          '🔄 API_DEBUG: Request headers: Content-Type: application/json, User-Agent: TunioRadioPlayer/1.0',
          'ApiService');
      Logger.debug('🔄 API_DEBUG: Timeout duration: ${timeout.inSeconds}s',
          'ApiService');

      Logger.debug(
          '🔄 API_DEBUG: About to make HTTP GET request...', 'ApiService');
      final requestStartTime = DateTime.now();

      final response = await http.get(
        uri,
        headers: {
          'Content-Type': 'application/json',
          'User-Agent': 'TunioRadioPlayer/1.0',
        },
      ).timeout(timeout);

      final requestDuration = DateTime.now().difference(requestStartTime);
      Logger.debug(
          '🔄 API_DEBUG: HTTP request completed in ${requestDuration.inMilliseconds}ms',
          'ApiService');

      Logger.debug(
          '🔄 API_DEBUG: API Response Status Code: ${response.statusCode}',
          'ApiService');
      Logger.debug('🔄 API_DEBUG: API Response Headers: ${response.headers}',
          'ApiService');
      Logger.debug(
          '🔄 API_DEBUG: API Response Body length: ${response.body.length} chars',
          'ApiService');
      Logger.debug(
          '🔄 API_DEBUG: API Response Body: ${response.body}', 'ApiService');

      if (response.statusCode == 200) {
        Logger.debug(
            '🔄 API_DEBUG: About to decode JSON response...', 'ApiService');
        final data = json.decode(response.body);
        Logger.info('🔄 API_DEBUG: Successfully decoded JSON response: $data',
            'ApiService');

        // Check success field
        final success = data['success'] ?? false;
        Logger.debug(
            '🔄 API_DEBUG: Success field value: $success', 'ApiService');
        if (!success) {
          final errorMessage = data['message'] ?? 'Unknown error';
          Logger.warning(
              '🔄 API_DEBUG: API returned success=false: $errorMessage',
              'ApiService');
          throw ApiError(
            message: errorMessage,
            statusCode: response.statusCode,
            isFromBackend: true,
          );
        }

        // Extract stream data
        Logger.debug(
            '🔄 API_DEBUG: About to extract stream data...', 'ApiService');
        final streamData = data['stream'];
        if (streamData == null) {
          Logger.error('🔄 API_DEBUG: No stream data found in API response',
              'ApiService');
          throw Exception('No stream data available');
        }

        Logger.debug('🔄 API_DEBUG: Raw API response: $data', 'ApiService');
        Logger.debug('🔄 API_DEBUG: Stream data: $streamData', 'ApiService');

        Logger.debug('🔄 API_DEBUG: About to create StreamConfig from JSON...',
            'ApiService');
        final streamConfig = StreamConfig.fromJson(streamData);
        Logger.debug(
            '🔄 API_DEBUG: Created StreamConfig with URL: ${streamConfig.streamUrl}',
            'ApiService');
        Logger.debug('🔄 API_DEBUG: StreamConfig title: ${streamConfig.title}',
            'ApiService');
        Logger.debug(
            '🔄 API_DEBUG: StreamConfig volume: ${streamConfig.volume}',
            'ApiService');
        Logger.debug(
            '🔄 API_DEBUG: API call completed successfully', 'ApiService');
        return streamConfig;
      } else {
        // Try to parse error message from response body for non-200 status codes
        String errorMessage;
        try {
          Logger.debug('🔄 API_DEBUG: Attempting to decode error response...',
              'ApiService');
          final errorData = json.decode(response.body);
          errorMessage = errorData['message'] ??
              _getDefaultErrorMessage(response.statusCode);
          Logger.debug('🔄 API_DEBUG: Decoded error message: $errorMessage',
              'ApiService');
        } catch (_) {
          errorMessage = _getDefaultErrorMessage(response.statusCode);
          Logger.debug(
              '🔄 API_DEBUG: Using default error message: $errorMessage',
              'ApiService');
        }

        Logger.error(
            '🔄 API_DEBUG: API returned error status: ${response.statusCode}, body: ${response.body}',
            'ApiService');
        throw ApiError(
          message: errorMessage,
          statusCode: response.statusCode,
          isFromBackend: true,
        );
      }
    } on SocketException catch (e) {
      Logger.error(
          '🔄 API_DEBUG: Socket exception during API call', 'ApiService', e);
      Logger.error('🔄 API_DEBUG: Socket exception details: ${e.toString()}',
          'ApiService');
      throw const ApiError(message: 'No internet connection');
    } on http.ClientException catch (e) {
      Logger.error('🔄 API_DEBUG: HTTP client exception during API call',
          'ApiService', e);
      Logger.error(
          '🔄 API_DEBUG: HTTP client exception details: ${e.toString()}',
          'ApiService');
      throw const ApiError(message: 'Network error');
    } on TimeoutException catch (e) {
      Logger.error(
          '🔄 API_DEBUG: Timeout exception during API call after ${timeout.inSeconds}s',
          'ApiService',
          e);
      throw const ApiError(message: 'Connection timeout');
    } on ApiError {
      Logger.debug('🔄 API_DEBUG: Rethrowing ApiError as-is', 'ApiService');
      rethrow; // Re-throw ApiError as-is
    } catch (e) {
      Logger.error(
          '🔄 API_DEBUG: Unexpected error during API call', 'ApiService', e);
      Logger.error('🔄 API_DEBUG: Unexpected error type: ${e.runtimeType}',
          'ApiService');
      Logger.error('🔄 API_DEBUG: Unexpected error details: ${e.toString()}',
          'ApiService');
      throw ApiError(message: 'Failed to fetch stream config: $e');
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
