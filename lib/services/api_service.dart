import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import '../models/stream_config.dart';
import '../utils/logger.dart';

class ApiService {
  static const String baseUrl = 'https://api.tunio.ai';
  static const Duration timeout = Duration(seconds: 30);

  Future<StreamConfig?> getStreamConfig(String apiKey) async {
    if (apiKey.isEmpty) return null;

    try {
      final uri = Uri.parse('$baseUrl/v1/stream-params?token=$apiKey');

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
        Logger.info('Successfully parsed stream config: $data', 'ApiService');
        return StreamConfig.fromJson(data);
      } else if (response.statusCode == 401) {
        Logger.warning('API returned 401: Invalid API key', 'ApiService');
        throw Exception('Invalid API key');
      } else if (response.statusCode == 403) {
        Logger.warning('API returned 403: Access denied', 'ApiService');
        throw Exception('Access denied');
      } else {
        Logger.error(
            'API returned error status: ${response.statusCode}, body: ${response.body}',
            'ApiService');
        throw Exception('Server error: ${response.statusCode}');
      }
    } on SocketException catch (e) {
      Logger.error('Socket exception during API call', 'ApiService', e);
      throw Exception('No internet connection');
    } on http.ClientException catch (e) {
      Logger.error('HTTP client exception during API call', 'ApiService', e);
      throw Exception('Network error');
    } catch (e) {
      Logger.error('Unexpected error during API call', 'ApiService', e);
      throw Exception('Failed to fetch stream config: $e');
    }
  }

  Future<bool> validateApiKey(String apiKey) async {
    Logger.debug(
        'Validating API key: ${apiKey.substring(0, 8)}...', 'ApiService');
    try {
      await getStreamConfig(apiKey);
      Logger.info('API key validation successful', 'ApiService');
      return true;
    } catch (e) {
      Logger.warning('API key validation failed: $e', 'ApiService');
      return false;
    }
  }
}
