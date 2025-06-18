import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import '../models/stream_config.dart';

class ApiService {
  static const String baseUrl = 'https://api.tunio.ai';
  static const Duration timeout = Duration(seconds: 30);

  Future<StreamConfig?> getStreamConfig(String apiKey) async {
    if (apiKey.isEmpty) return null;

    try {
      final uri = Uri.parse('$baseUrl/stream/config?token=$apiKey');

      final response = await http.get(
        uri,
        headers: {
          'Content-Type': 'application/json',
          'User-Agent': 'TunioRadioPlayer/1.0',
        },
      ).timeout(timeout);

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        return StreamConfig.fromJson(data);
      } else if (response.statusCode == 401) {
        throw Exception('Invalid API key');
      } else if (response.statusCode == 403) {
        throw Exception('Access denied');
      } else {
        throw Exception('Server error: ${response.statusCode}');
      }
    } on SocketException {
      throw Exception('No internet connection');
    } on http.ClientException {
      throw Exception('Network error');
    } catch (e) {
      throw Exception('Failed to fetch stream config: $e');
    }
  }

  Future<bool> validateApiKey(String apiKey) async {
    try {
      await getStreamConfig(apiKey);
      return true;
    } catch (e) {
      return false;
    }
  }
}
