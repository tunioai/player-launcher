import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../core/audio_state.dart';
import '../core/dependency_injection.dart';
import '../core/system_state.dart';
import '../utils/logger.dart';
import '../utils/platform_info.dart';
import 'storage_service.dart';
import 'failover_service.dart';
import 'radio/i_radio_service.dart';

class LocalWebServer implements Disposable {
  LocalWebServer({
    required StorageService storageService,
    required IRadioService radioService,
    required IFailoverService failoverService,
    this.port = 9292,
  })  : _storageService = storageService,
        _radioService = radioService,
        _failoverService = failoverService;

  static const String _authCookieName = 'tunio_key';

  final StorageService _storageService;
  final IRadioService _radioService;
  final IFailoverService _failoverService;
  final int port;
  HttpServer? _server;

  Future<void> start() async {
    if (kIsWeb) {
      return;
    }
    if (_server != null) {
      return;
    }

    try {
      _server = await HttpServer.bind(InternetAddress.anyIPv4, port);
      _server!.listen(_handleRequest, onError: (error, stackTrace) {
        Logger.error('LOCAL_WEB: Server error: $error');
      });

      final ip = PlatformInfo.bestEffortIp;
      Logger.info(
          'LOCAL_WEB: Listening on ${ip ?? '0.0.0.0'}:$port (auth = admin key)');
    } catch (e) {
      Logger.error('LOCAL_WEB: Failed to bind :$port - $e');
    }
  }

  Future<void> stop() async {
    final server = _server;
    _server = null;
    await server?.close(force: true);
  }

  @override
  Future<void> dispose() async {
    await stop();
  }

  Future<void> _handleRequest(HttpRequest request) async {
    try {
      final path = request.uri.path;
      if (request.method == 'GET' && (path == '/' || path.isEmpty)) {
        return _serveIndex(request);
      }

      if (request.method == 'POST' && path == '/login') {
        final key = await _readAuthKey(request);
        if (_isValidKey(key)) {
          return _sendRedirect(request, '/', authCookieValue: key);
        }
        return _sendHtml(
          request,
          _renderLoginHtml(showError: true),
          statusCode: HttpStatus.unauthorized,
        );
      }

      if (request.method == 'GET' && path == '/logout') {
        return _sendRedirect(request, '/', clearAuthCookie: true);
      }

      if (!_isAuthorized(request)) {
        return _sendUnauthorized(request);
      }

      if (request.method == 'GET' && path == '/api/state') {
        return _sendJson(request, _buildStatePayload());
      }

      if (request.method == 'GET' && path == '/api/reports') {
        final perPage = _readPerPage(request, 50, 200);
        final page = _readPage(request, 1);
        final directionFilter =
            request.uri.queryParameters['direction']?.toLowerCase();
        final sentFilter = request.uri.queryParameters['sent']?.toLowerCase();

        final events = _storageService.getFailoverEvents(includeSent: true);
        final filtered = events.where((event) {
          if (directionFilter == 'failover' &&
              event.direction.name != 'failover') {
            return false;
          }
          if (directionFilter == 'restore' &&
              event.direction.name != 'restore') {
            return false;
          }
          if (sentFilter == 'true' && !event.sent) {
            return false;
          }
          if (sentFilter == 'false' && event.sent) {
            return false;
          }
          return true;
        }).toList(growable: false);

        final newestFirst = filtered.reversed.toList(growable: false);
        final total = newestFirst.length;
        final totalPages = total == 0 ? 1 : ((total + perPage - 1) ~/ perPage);
        final safePage = page < 1 ? 1 : (page > totalPages ? totalPages : page);
        final start = (safePage - 1) * perPage;
        final end = start + perPage > total ? total : start + perPage;
        final slice =
            start >= total ? <dynamic>[] : newestFirst.sublist(start, end);
        final items =
            slice.map((event) => event.toJson()).toList(growable: false);
        return _sendJson(request, {
          'ok': true,
          'count': total,
          'page': safePage,
          'per_page': perPage,
          'total_pages': totalPages,
          'items': items,
        });
      }

      if (request.method == 'POST' && path == '/api/offline') {
        final enabled = await _readEnabledFlag(request);
        if (enabled == null) {
          return _sendJson(
            request,
            {'ok': false, 'error': 'Missing enabled flag'},
            statusCode: HttpStatus.badRequest,
          );
        }

        if (enabled) {
          SystemState.instance.setOfflineModeLocalOverride(true);
        } else {
          SystemState.instance.clearOfflineOverride();
          SystemState.instance.setOfflineMode(false);
        }
        final accept = request.headers.value(HttpHeaders.acceptHeader) ?? '';
        final contentType = request.headers.contentType?.mimeType ?? '';
        final wantsHtml =
            accept.contains('text/html') && contentType != 'application/json';
        if (wantsHtml) {
          return _sendRedirect(request, '/');
        }
        return _sendJson(
          request,
          {
            'ok': true,
            'offlineMode': SystemState.instance.offlineMode,
          },
        );
      }

      if (request.method == 'POST' && path == '/api/pin') {
        final pin = await _readPin(request);
        if (pin == null || pin.isEmpty) {
          return _sendJson(
            request,
            {'ok': false, 'error': 'Missing PIN'},
            statusCode: HttpStatus.badRequest,
          );
        }

        final result = await _radioService.connect(pin);
        if (result.isSuccess) {
          return _sendJson(request, {'ok': true});
        }
        return _sendJson(
          request,
          {'ok': false, 'error': result.error ?? 'Connection failed'},
          statusCode: HttpStatus.badRequest,
        );
      }

      return _sendNotFound(request);
    } catch (e) {
      Logger.error('LOCAL_WEB: Request failed: $e');
      return _sendJson(
        request,
        {'ok': false, 'error': 'Internal error'},
        statusCode: HttpStatus.internalServerError,
      );
    }
  }

  bool _isAuthorized(HttpRequest request) {
    final headerKey = request.headers.value('x-auth-key');
    final queryKey = request.uri.queryParameters['key'];
    final cookieKey = _readCookieKey(request);
    return _isValidKey(headerKey) ||
        _isValidKey(queryKey) ||
        _isValidKey(cookieKey);
  }

  bool _isValidKey(String? value) {
    if (value == null || value.isEmpty) {
      return false;
    }
    return _verifyAdminKey(value);
  }

  String? _readCookieKey(HttpRequest request) {
    for (final cookie in request.cookies) {
      if (cookie.name == _authCookieName) {
        return cookie.value;
      }
    }
    return null;
  }

  String _resolvePin() {
    final token = _storageService.getToken();
    if (token == null || token.trim().isEmpty) {
      return '000000';
    }
    return token.trim();
  }

  Future<void> _serveIndex(HttpRequest request) async {
    final authorized = _isAuthorized(request);
    final key = request.uri.queryParameters['key'] ?? '';
    final html = authorized
        ? _renderDashboardHtml()
        : _renderLoginHtml(
            showError: key.isNotEmpty,
          );
    final cookieKey = _resolveCookieKey(request);
    return _sendHtml(request, html, authCookieValue: cookieKey);
  }

  String? _resolveCookieKey(HttpRequest request) {
    final headerKey = request.headers.value('x-auth-key');
    if (_isValidKey(headerKey)) {
      return headerKey;
    }
    final queryKey = request.uri.queryParameters['key'];
    if (_isValidKey(queryKey)) {
      return queryKey;
    }
    return null;
  }

  String _renderLoginHtml({required bool showError}) {
    final error =
        showError ? '<p class="error">Wrong key. Use admin key.</p>' : '';
    return '''
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width,initial-scale=1" />
  <title>Tunio Spot</title>
  <style>
    body{font-family:Arial,sans-serif;background:#0f1115;color:#e8eaed;margin:0;padding:24px;min-height:100vh;display:flex;align-items:center;justify-content:center;}
    .card{width:100%;max-width:520px;margin:0 auto;background:#161a22;padding:24px;border-radius:12px;box-sizing:border-box;}
    .header{display:flex;align-items:center;justify-content:space-between;gap:12px;margin-bottom:8px;}
    .brand{display:flex;align-items:center;gap:12px;font-weight:600;font-size:22px;}
    input{width:100%;padding:12px;border-radius:8px;border:1px solid #2a3140;background:#0f1115;color:#e8eaed;box-sizing:border-box;}
    button{margin-top:16px;padding:10px 16px;border:0;border-radius:8px;background:#62a0f6;color:#0f1115;font-weight:700;cursor:pointer;}
    form{display:flex;flex-direction:column;gap:16px;}
    .align-right{align-self:center;}
    .spacer{height:16px;}
    .error{color:#ff6b6b;margin:8px 0;}
  </style>
</head>
<body>
    <div class="card">
      <div class="header">
        <div class="brand">
          <svg width="99" height="36" viewBox="0 0 99 36" fill="none" xmlns="http://www.w3.org/2000/svg"><g clip-path="url(#clip0_7_1526)"><path opacity="0.9" d="M30.1253 10.0129L30.0307 9.95309L29.9361 9.89333C28.008 8.58232 26.003 7.38823 23.932 6.31749C21.8289 5.20003 19.5801 4.382 17.2507 3.88711H17.0566C15.8436 3.6713 14.5987 3.71647 13.4046 4.01961C12.2105 4.32274 11.0947 4.87689 10.1314 5.64515C7.57738 7.73189 6.64639 10.9342 6.36759 14.1116C6.21823 15.7203 6.24811 17.2841 6.24811 18.8927C6.24811 22.6678 6.21326 26.9857 8.37893 30.188C8.8679 30.9081 9.45813 31.5539 10.1314 32.1054C11.095 32.8731 12.2107 33.4273 13.4046 33.7312C14.5985 34.0352 15.8433 34.0819 17.0566 33.8684H17.2507C21.6418 33.0467 26.242 30.3474 29.9361 27.8921L30.0307 27.8273L30.1253 27.7576C33.0576 25.6012 35.995 22.8919 36 18.9425C36.005 14.9931 33.0626 12.1743 30.1253 10.0129Z" fill="#62a0f6"></path><path opacity="0.9" d="M23.932 6.30753L23.8971 6.2627L23.8025 6.19796L23.7079 6.13322C19.9939 3.663 15.3987 0.988582 11.0026 0.136953H10.8085C9.59808 -0.0805852 8.3553 -0.0385788 7.16234 0.260194C5.96938 0.558966 4.85343 1.1077 3.88828 1.87009C1.33428 3.97675 0.408264 7.15418 0.119508 10.3067C2.22336e-05 11.9153 2.22367e-05 13.4791 2.22367e-05 15.0878C2.22367e-05 19.6896 -0.0447848 25.0882 3.88828 28.3005C5.1655 29.3451 6.72603 29.9834 8.36898 30.1332C9.17855 30.2118 9.99478 30.1883 10.7985 30.0635H10.9927C15.3888 29.2417 19.984 26.5374 23.6781 24.0871L23.7726 24.0224L23.8971 23.8979C26.8345 21.7414 29.7718 19.0322 29.7718 15.0778C29.7718 11.1235 26.8544 8.45901 23.932 6.30753Z" fill="#84b8ff"></path></g><path d="M58.251 9.332H53.435V27H51.335V9.332H46.519V7.4H58.251V9.332ZM59.7435 13V21.568C59.7435 22.9867 59.8835 24.004 60.1635 24.62C60.4622 25.2173 60.9942 25.516 61.7595 25.516C62.1515 25.4413 62.4968 25.4413 62.7955 25.292C63.1128 25.124 63.3928 24.9093 63.6355 24.648C63.8782 24.3867 64.0928 24.088 64.2795 23.752C64.4662 23.416 64.6155 23.0707 64.7275 22.716V13H66.7435V23.024C66.7435 23.696 66.7622 24.396 66.7995 25.124C66.8555 25.8333 66.9302 26.4587 67.0235 27H65.5955L65.0915 25.04H65.0075C64.6902 25.656 64.2328 26.1973 63.6355 26.664C63.0382 27.112 62.2915 27.336 61.3955 27.336C60.7982 27.336 60.2755 27.2613 59.8275 27.112C59.3795 26.9627 58.9968 26.692 58.6795 26.3C58.3622 25.908 58.1195 25.376 57.9515 24.704C57.8022 24.0133 57.7275 23.136 57.7275 22.072V13H59.7435ZM77.2321 27V18.46C77.2321 17.06 77.0641 16.052 76.7281 15.436C76.4108 14.8013 75.8321 14.484 74.9921 14.484C74.2454 14.484 73.6294 14.708 73.1441 15.156C72.6588 15.604 72.3041 16.1547 72.0801 16.808V27H70.0641V13H71.5201L71.8841 14.484H71.9681C72.3228 13.98 72.7988 13.5507 73.3961 13.196C74.0121 12.8413 74.7401 12.664 75.5801 12.664C76.1774 12.664 76.7001 12.748 77.1481 12.916C77.6148 13.084 77.9974 13.3733 78.2961 13.784C78.6134 14.176 78.8468 14.708 78.9961 15.38C79.1641 16.052 79.2481 16.9013 79.2481 17.928V27H77.2321ZM82.7048 13H84.7208V27H82.7048V13ZM82.3408 8.744C82.3408 8.296 82.4621 7.932 82.7048 7.652C82.9661 7.372 83.3021 7.232 83.7128 7.232C84.1235 7.232 84.4595 7.372 84.7208 7.652C85.0008 7.91333 85.1408 8.27733 85.1408 8.744C85.1408 9.192 85.0008 9.54667 84.7208 9.808C84.4595 10.0507 84.1235 10.172 83.7128 10.172C83.3021 10.172 82.9661 10.0413 82.7048 9.78C82.4621 9.51867 82.3408 9.17333 82.3408 8.744ZM87.8231 20C87.8231 17.48 88.2524 15.632 89.1111 14.456C89.9884 13.2613 91.2298 12.664 92.8351 12.664C94.5524 12.664 95.8124 13.2707 96.6151 14.484C97.4364 15.6973 97.8471 17.536 97.8471 20C97.8471 22.5387 97.4084 24.396 96.5311 25.572C95.6538 26.748 94.4218 27.336 92.8351 27.336C91.1178 27.336 89.8484 26.7293 89.0271 25.516C88.2244 24.3027 87.8231 22.464 87.8231 20ZM89.9231 20C89.9231 20.8213 89.9698 21.568 90.0631 22.24C90.1751 22.912 90.3431 23.4907 90.5671 23.976C90.8098 24.4613 91.1178 24.844 91.4911 25.124C91.8644 25.3853 92.3124 25.516 92.8351 25.516C93.8058 25.516 94.5338 25.0867 95.0191 24.228C95.5044 23.3507 95.7471 21.9413 95.7471 20C95.7471 19.1973 95.6911 18.46 95.5791 17.788C95.4858 17.0973 95.3178 16.5093 95.0751 16.024C94.8511 15.5387 94.5524 15.1653 94.1791 14.904C93.8058 14.624 93.3578 14.484 92.8351 14.484C91.8831 14.484 91.1551 14.9227 90.6511 15.8C90.1658 16.6773 89.9231 18.0773 89.9231 20Z" fill="white"></path><defs><clipPath id="clip0_7_1526"><rect width="36" height="34" fill="white"></rect></clipPath></defs></svg>
          <span>Spot</span>
        </div>
      </div>
    <div class="spacer"></div>
    $error
    <form method="post" action="/login">
      <input type="password" name="key" placeholder="Admin key" />
      <button class="align-right" type="submit">Open</button>
    </form>
  </div>
</body>
</html>
''';
  }

  String _renderDashboardHtml() {
    final state = _buildStatePayload();
    final offline = state['offlineMode'] == true;
    final stationName = state['station'] as String? ?? 'Unknown';
    final currentPin = state['pin'] as String? ?? '000000';
    final pingValue = _formatPing(state['ping'] as int?);
    final pingColor = _pingColor(state['ping'] as int?);
    final sourceLabel = state['source'] as String? ?? 'Unknown';
    final sourceColor = _sourceColor(sourceLabel);
    final cacheLabel = _formatCache(state['cachedTracks'] as int?);
    final statusColor = offline ? '#ffb86c' : '#31c36b';
    final statusText = offline ? 'Offline mode enabled' : 'Online mode enabled';
    return '''
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width,initial-scale=1" />
  <title>Tunio Spot</title>
  <style>
    body{font-family:Arial,sans-serif;background:#0f1115;color:#e8eaed;margin:0;padding:24px;}
    .card{max-width:680px;margin:0 auto;background:#161a22;padding:24px;border-radius:12px;}
    .header{display:flex;align-items:center;justify-content:space-between;gap:12px;}
    .header h1{margin:0;}
    .brand{display:flex;align-items:center;gap:12px;font-weight:600;font-size:22px;}
    .row{display:flex;gap:12px;flex-wrap:wrap;margin-top:16px;}
    .badges-row{margin-bottom:16px;}
    .pin-row{align-items:center;}
    @media (max-width: 520px){
      .pin-row{flex-wrap:nowrap;}
      .pin-row .input{flex:1 1 auto;min-width:0;}
      .pin-row .primary{flex:0 0 auto;white-space:nowrap;}
    }
    .badge{display:inline-block;padding:6px 10px;border-radius:999px;background:#232a36;color:#e8eaed;font-size:12px;}
    .status{color:$statusColor;font-weight:500;}
    button{padding:10px 16px;border:0;border-radius:8px;font-weight:700;cursor:pointer;}
    button[disabled]{opacity:.6;cursor:not-allowed;}
    .tabs{display:flex;gap:8px;margin-top:16px;margin-bottom:24px;}
    .tab{background:#1f242e;color:#c7cedb;border-radius:999px;padding:6px 12px;font-size:12px;}
    .tab.active{background:#62a0f6;color:#0f1115;}
    .tab-panel{display:none;}
    .tab-panel.active{display:block;}
    .select{padding:6px 10px;border-radius:8px;border:1px solid #2a3140;background:#0f1115;color:#e8eaed;font-size:12px;}
    .pager{display:flex;gap:8px;align-items:center;}
    .pager button{padding:6px 10px;border-radius:8px;background:#1f242e;color:#e8eaed;border:0;}
    .pager button[disabled]{opacity:.5;cursor:not-allowed;}
    .toggle{display:flex;align-items:center;gap:10px;}
    .switch{position:relative;display:inline-block;width:54px;height:30px;}
    .switch input{opacity:0;width:0;height:0;}
    .slider{position:absolute;cursor:pointer;top:0;left:0;right:0;bottom:0;background:#2b2f3a;border-radius:999px;transition:.2s;}
    .slider:before{position:absolute;content:"";height:22px;width:22px;left:4px;bottom:4px;background:#fff;border-radius:50%;transition:.2s;}
    .switch input:checked + .slider{background:#62a0f6;}
    .switch input:checked + .slider:before{transform:translateX(24px);}
    .switch input:disabled + .slider{opacity:.6;cursor:not-allowed;}
    .input{padding:10px 12px;border-radius:8px;border:1px solid #2a3140;background:#0f1115;color:#e8eaed;min-width:200px;}
    .primary{background:#62a0f6;color:#0f1115;}
    .muted{color:#9aa4b2;}
    .report-list{list-style:none;padding:0;margin:16px 0 0;display:flex;flex-direction:column;gap:10px;}
    .report-item{background:#1b2029;border:1px solid #2a3140;border-radius:12px;padding:10px 12px;}
    .report-meta{display:flex;gap:10px;flex-wrap:wrap;font-size:12px;color:#9aa4b2;}
    .report-title{font-weight:600;margin-top:4px;}
    .report-direction.failover{color:#ff6b6b;}
    .report-direction.restore{color:#31c36b;}
  </style>
</head>
<body>
  <div class="card">
    <div class="header">
      <div class="brand">
        <svg width="99" height="36" viewBox="0 0 99 36" fill="none" xmlns="http://www.w3.org/2000/svg"><g clip-path="url(#clip0_7_1526)"><path opacity="0.9" d="M30.1253 10.0129L30.0307 9.95309L29.9361 9.89333C28.008 8.58232 26.003 7.38823 23.932 6.31749C21.8289 5.20003 19.5801 4.382 17.2507 3.88711H17.0566C15.8436 3.6713 14.5987 3.71647 13.4046 4.01961C12.2105 4.32274 11.0947 4.87689 10.1314 5.64515C7.57738 7.73189 6.64639 10.9342 6.36759 14.1116C6.21823 15.7203 6.24811 17.2841 6.24811 18.8927C6.24811 22.6678 6.21326 26.9857 8.37893 30.188C8.8679 30.9081 9.45813 31.5539 10.1314 32.1054C11.095 32.8731 12.2107 33.4273 13.4046 33.7312C14.5985 34.0352 15.8433 34.0819 17.0566 33.8684H17.2507C21.6418 33.0467 26.242 30.3474 29.9361 27.8921L30.0307 27.8273L30.1253 27.7576C33.0576 25.6012 35.995 22.8919 36 18.9425C36.005 14.9931 33.0626 12.1743 30.1253 10.0129Z" fill="#62a0f6"></path><path opacity="0.9" d="M23.932 6.30753L23.8971 6.2627L23.8025 6.19796L23.7079 6.13322C19.9939 3.663 15.3987 0.988582 11.0026 0.136953H10.8085C9.59808 -0.0805852 8.3553 -0.0385788 7.16234 0.260194C5.96938 0.558966 4.85343 1.1077 3.88828 1.87009C1.33428 3.97675 0.408264 7.15418 0.119508 10.3067C2.22336e-05 11.9153 2.22367e-05 13.4791 2.22367e-05 15.0878C2.22367e-05 19.6896 -0.0447848 25.0882 3.88828 28.3005C5.1655 29.3451 6.72603 29.9834 8.36898 30.1332C9.17855 30.2118 9.99478 30.1883 10.7985 30.0635H10.9927C15.3888 29.2417 19.984 26.5374 23.6781 24.0871L23.7726 24.0224L23.8971 23.8979C26.8345 21.7414 29.7718 19.0322 29.7718 15.0778C29.7718 11.1235 26.8544 8.45901 23.932 6.30753Z" fill="#84b8ff"></path></g><path d="M58.251 9.332H53.435V27H51.335V9.332H46.519V7.4H58.251V9.332ZM59.7435 13V21.568C59.7435 22.9867 59.8835 24.004 60.1635 24.62C60.4622 25.2173 60.9942 25.516 61.7595 25.516C62.1515 25.4413 62.4968 25.4413 62.7955 25.292C63.1128 25.124 63.3928 24.9093 63.6355 24.648C63.8782 24.3867 64.0928 24.088 64.2795 23.752C64.4662 23.416 64.6155 23.0707 64.7275 22.716V13H66.7435V23.024C66.7435 23.696 66.7622 24.396 66.7995 25.124C66.8555 25.8333 66.9302 26.4587 67.0235 27H65.5955L65.0915 25.04H65.0075C64.6902 25.656 64.2328 26.1973 63.6355 26.664C63.0382 27.112 62.2915 27.336 61.3955 27.336C60.7982 27.336 60.2755 27.2613 59.8275 27.112C59.3795 26.9627 58.9968 26.692 58.6795 26.3C58.3622 25.908 58.1195 25.376 57.9515 24.704C57.8022 24.0133 57.7275 23.136 57.7275 22.072V13H59.7435ZM77.2321 27V18.46C77.2321 17.06 77.0641 16.052 76.7281 15.436C76.4108 14.8013 75.8321 14.484 74.9921 14.484C74.2454 14.484 73.6294 14.708 73.1441 15.156C72.6588 15.604 72.3041 16.1547 72.0801 16.808V27H70.0641V13H71.5201L71.8841 14.484H71.9681C72.3228 13.98 72.7988 13.5507 73.3961 13.196C74.0121 12.8413 74.7401 12.664 75.5801 12.664C76.1774 12.664 76.7001 12.748 77.1481 12.916C77.6148 13.084 77.9974 13.3733 78.2961 13.784C78.6134 14.176 78.8468 14.708 78.9961 15.38C79.1641 16.052 79.2481 16.9013 79.2481 17.928V27H77.2321ZM82.7048 13H84.7208V27H82.7048V13ZM82.3408 8.744C82.3408 8.296 82.4621 7.932 82.7048 7.652C82.9661 7.372 83.3021 7.232 83.7128 7.232C84.1235 7.232 84.4595 7.372 84.7208 7.652C85.0008 7.91333 85.1408 8.27733 85.1408 8.744C85.1408 9.192 85.0008 9.54667 84.7208 9.808C84.4595 10.0507 84.1235 10.172 83.7128 10.172C83.3021 10.172 82.9661 10.0413 82.7048 9.78C82.4621 9.51867 82.3408 9.17333 82.3408 8.744ZM87.8231 20C87.8231 17.48 88.2524 15.632 89.1111 14.456C89.9884 13.2613 91.2298 12.664 92.8351 12.664C94.5524 12.664 95.8124 13.2707 96.6151 14.484C97.4364 15.6973 97.8471 17.536 97.8471 20C97.8471 22.5387 97.4084 24.396 96.5311 25.572C95.6538 26.748 94.4218 27.336 92.8351 27.336C91.1178 27.336 89.8484 26.7293 89.0271 25.516C88.2244 24.3027 87.8231 22.464 87.8231 20ZM89.9231 20C89.9231 20.8213 89.9698 21.568 90.0631 22.24C90.1751 22.912 90.3431 23.4907 90.5671 23.976C90.8098 24.4613 91.1178 24.844 91.4911 25.124C91.8644 25.3853 92.3124 25.516 92.8351 25.516C93.8058 25.516 94.5338 25.0867 95.0191 24.228C95.5044 23.3507 95.7471 21.9413 95.7471 20C95.7471 19.1973 95.6911 18.46 95.5791 17.788C95.4858 17.0973 95.3178 16.5093 95.0751 16.024C94.8511 15.5387 94.5524 15.1653 94.1791 14.904C93.8058 14.624 93.3578 14.484 92.8351 14.484C91.8831 14.484 91.1551 14.9227 90.6511 15.8C90.1658 16.6773 89.9231 18.0773 89.9231 20Z" fill="white"></path><defs><clipPath id="clip0_7_1526"><rect width="36" height="34" fill="white"></rect></clipPath></defs></svg>
        <span>Spot</span>
      </div>
      <a class="badge" href="/logout">Logout</a>
    </div>
    <div class="tabs">
      <button class="tab active" type="button" data-tab="status">Status</button>
      <button class="tab" type="button" data-tab="reports">Reports</button>
    </div>
    <div id="tab-status" class="tab-panel active">
      <div class="row badges-row">
        <span class="badge" id="station-badge">Station: $stationName</span>
        <span class="badge" id="pin-badge">PIN: $currentPin</span>
        <span class="badge" id="ping-badge" style="color:$pingColor;">Ping: $pingValue</span>
        <span class="badge" id="source-badge" style="color:$sourceColor;">Source: $sourceLabel</span>
        <span class="badge" id="cache-badge">Cache: $cacheLabel</span>
      </div>
      <div class="row pin-row">
        <input id="pin-input" class="input" type="text" placeholder="New PIN" />
        <button id="pin-submit" class="primary" type="button">Apply PIN</button>
      </div>
      <div class="row">
        <span id="pin-status" class="muted">Ready</span>
      </div>
      <div class="row toggle">
        <label class="switch">
          <input id="offline-toggle" type="checkbox" ${offline ? 'checked' : ''} />
          <span class="slider"></span>
        </label>
        <span class="status" id="offline-status">$statusText</span>
      </div>
    </div>
    <div id="tab-reports" class="tab-panel">
      <div class="row">
        <span class="badge">Failover Reports</span>
        <span class="badge" id="reports-count">Count: 0</span>
      </div>
      <div class="row">
        <select id="filter-direction" class="select">
          <option value="">All</option>
          <option value="failover">Failover</option>
          <option value="restore">Restore</option>
        </select>
        <select id="filter-sent" class="select">
          <option value="">All</option>
          <option value="true">Sent</option>
          <option value="false">Pending</option>
        </select>
        <select id="filter-per-page" class="select">
          <option value="25">25</option>
          <option value="50" selected>50</option>
          <option value="100">100</option>
        </select>
        <div class="pager">
          <button id="reports-prev" type="button">Prev</button>
          <span id="reports-page" class="muted">Page 1 / 1</span>
          <button id="reports-next" type="button">Next</button>
        </div>
      </div>
      <div id="reports-empty" class="muted" style="margin-top:12px;">No events yet</div>
      <ul id="reports-list" class="report-list"></ul>
    </div>
  </div>
  <script>
    (function(){
      var statusEl = document.getElementById('offline-status');
      var toggle = document.getElementById('offline-toggle');
      var pinInput = document.getElementById('pin-input');
      var pinButton = document.getElementById('pin-submit');
      var pinStatus = document.getElementById('pin-status');
      var stationBadge = document.getElementById('station-badge');
      var pinBadge = document.getElementById('pin-badge');
      var pingBadge = document.getElementById('ping-badge');
      var sourceBadge = document.getElementById('source-badge');
      var cacheBadge = document.getElementById('cache-badge');
      var reportsList = document.getElementById('reports-list');
      var reportsEmpty = document.getElementById('reports-empty');
      var reportsCount = document.getElementById('reports-count');
      var reportsPage = document.getElementById('reports-page');
      var reportsPrev = document.getElementById('reports-prev');
      var reportsNext = document.getElementById('reports-next');
      var filterDirection = document.getElementById('filter-direction');
      var filterSent = document.getElementById('filter-sent');
      var filterPerPage = document.getElementById('filter-per-page');
      var tabs = document.querySelectorAll('.tab');
      var panels = document.querySelectorAll('.tab-panel');
      function setStatus(enabled){
        statusEl.textContent =
            enabled ? 'Offline mode enabled' : 'Online mode enabled';
        statusEl.style.color = enabled ? '#ffb86c' : '#31c36b';
      }

      tabs.forEach(function(tab){
        tab.addEventListener('click', function(){
          var target = tab.getAttribute('data-tab');
          tabs.forEach(function(btn){ btn.classList.remove('active'); });
          panels.forEach(function(panel){ panel.classList.remove('active'); });
          tab.classList.add('active');
          var activePanel = document.getElementById('tab-' + target);
          if (activePanel) activePanel.classList.add('active');
        });
      });

      if (!toggle) return;
      toggle.addEventListener('change', function(){
        var enabled = toggle.checked;
        toggle.disabled = true;
        fetch('/api/offline', {
          method: 'POST',
          headers: {
            'Content-Type': 'application/json',
            'Accept': 'application/json'
          },
          body: JSON.stringify({ enabled: enabled })
        })
        .then(function(res){ return res.json(); })
        .then(function(data){
          if (data && data.ok) {
            var serverValue = !!data.offlineMode;
            toggle.checked = serverValue;
            setStatus(serverValue);
            return;
          }
          toggle.checked = !enabled;
          alert((data && data.error) ? data.error : 'Request failed');
        })
        .catch(function(){
          toggle.checked = !enabled;
          alert('Network error');
        })
        .finally(function(){
          toggle.disabled = false;
        });
      });

      function setPinStatus(text, color){
        if (!pinStatus) return;
        pinStatus.textContent = text;
        if (color) pinStatus.style.color = color;
      }

      function formatPing(value){
        if (value === null || value === undefined) return '—';
        return value + 'ms';
      }

      function formatCache(value){
        if (value === null || value === undefined) return '—';
        return value + ' track' + (value === 1 ? '' : 's');
      }

      function refreshState(){
        fetch('/api/state', { headers: { 'Accept': 'application/json' } })
          .then(function(res){ return res.json(); })
          .then(function(data){
            if (!data || !data.ok) return;
            setStatus(!!data.offlineMode);
            if (toggle && !toggle.disabled) {
              toggle.checked = !!data.offlineMode;
            }
            if (stationBadge) stationBadge.textContent = 'Station: ' + (data.station || 'Unknown');
            if (pinBadge) pinBadge.textContent = 'PIN: ' + (data.pin || '000000');
            if (pingBadge) {
              var pingText = formatPing(data.ping);
              pingBadge.textContent = 'Ping: ' + pingText;
              var p = data.ping;
              if (p === null || p === undefined) {
                pingBadge.style.color = '#9aa4b2';
              } else if (p < 100) {
                pingBadge.style.color = '#31c36b';
              } else if (p < 300) {
                pingBadge.style.color = '#ffb86c';
              } else {
                pingBadge.style.color = '#ff6b6b';
              }
            }
            if (sourceBadge) {
              var sourceText = data.source || 'Unknown';
              sourceBadge.textContent = 'Source: ' + sourceText;
              sourceBadge.style.color = sourceText.indexOf('Online') === 0 ? '#31c36b' : '#ff6b6b';
            }
            if (cacheBadge) cacheBadge.textContent = 'Cache: ' + formatCache(data.cachedTracks);
          })
          .catch(function(){});
      }

      function formatTime(value){
        if (!value) return '—';
        var date = new Date(value);
        if (isNaN(date.getTime())) return value;
        return date.toLocaleString();
      }

      function renderReports(items){
        if (!reportsList || !reportsEmpty || !reportsCount) return;
        reportsList.innerHTML = '';
        if (!items || items.length === 0) {
          reportsEmpty.style.display = 'block';
          reportsCount.textContent = 'Count: 0';
          return;
        }
        reportsEmpty.style.display = 'none';
        reportsCount.textContent = 'Count: ' + items.length;
        items.forEach(function(item){
          var li = document.createElement('li');
          li.className = 'report-item';
          var dir = item.direction || 'failover';
          var dirClass = dir === 'restore' ? 'restore' : 'failover';
          li.innerHTML = '' +
            '<div class="report-meta">' +
              '<span class="report-direction ' + dirClass + '">' + dir + '</span>' +
              '<span>' + formatTime(item.timestampUtc) + '</span>' +
              '<span>' + (item.sent ? 'sent' : 'pending') + '</span>' +
            '</div>' +
            '<div class="report-title">' + (item.reason || 'unknown') + '</div>';
          reportsList.appendChild(li);
        });
      }

      var reportsState = { page: 1 };

      function buildReportsQuery(){
        var params = [];
        if (filterDirection && filterDirection.value) {
          params.push('direction=' + encodeURIComponent(filterDirection.value));
        }
        if (filterSent && filterSent.value) {
          params.push('sent=' + encodeURIComponent(filterSent.value));
        }
        if (filterPerPage && filterPerPage.value) {
          params.push('per_page=' + encodeURIComponent(filterPerPage.value));
        }
        params.push('page=' + encodeURIComponent(reportsState.page || 1));
        return params.length ? ('?' + params.join('&')) : '';
      }

      function refreshReports(){
        var url = '/api/reports' + buildReportsQuery();
        fetch(url, { headers: { 'Accept': 'application/json' } })
          .then(function(res){ return res.json(); })
          .then(function(data){
            if (!data || !data.ok) return;
            renderReports(data.items || []);
            if (reportsPage) {
              reportsPage.textContent = 'Page ' + (data.page || 1) + ' / ' + (data.total_pages || 1);
            }
            if (reportsPrev) {
              reportsPrev.disabled = (data.page || 1) <= 1;
            }
            if (reportsNext) {
              reportsNext.disabled = (data.page || 1) >= (data.total_pages || 1);
            }
          })
          .catch(function(){});
      }

      function submitPin(){
        if (!pinInput || !pinButton) return;
        var pin = pinInput.value.trim();
        if (!pin) {
          setPinStatus('Enter PIN', '#ffb86c');
          return;
        }
        pinButton.disabled = true;
        pinInput.disabled = true;
        setPinStatus('Connecting...', '#9aa4b2');
        fetch('/api/pin', {
          method: 'POST',
          headers: {
            'Content-Type': 'application/json',
            'Accept': 'application/json'
          },
          body: JSON.stringify({ pin: pin })
        })
        .then(function(res){ return res.json(); })
        .then(function(data){
          if (data && data.ok) {
            setPinStatus('PIN applied, connecting...', '#31c36b');
            pinInput.value = '';
            refreshState();
            return;
          }
          setPinStatus((data && data.error) ? data.error : 'Failed', '#ff6b6b');
        })
        .catch(function(){
          setPinStatus('Network error', '#ff6b6b');
        })
        .finally(function(){
          pinButton.disabled = false;
          pinInput.disabled = false;
        });
      }

      if (pinButton) {
        pinButton.addEventListener('click', submitPin);
      }
      if (pinInput) {
        pinInput.addEventListener('keydown', function(e){
          if (e.key === 'Enter') {
            submitPin();
          }
        });
      }

      refreshState();
      refreshReports();
      setInterval(refreshState, 5000);
      setInterval(refreshReports, 10000);

      if (filterDirection) {
        filterDirection.addEventListener('change', function(){
          reportsState.page = 1;
          refreshReports();
        });
      }
      if (filterSent) {
        filterSent.addEventListener('change', function(){
          reportsState.page = 1;
          refreshReports();
        });
      }
      if (filterPerPage) {
        filterPerPage.addEventListener('change', function(){
          reportsState.page = 1;
          refreshReports();
        });
      }
      if (reportsPrev) {
        reportsPrev.addEventListener('click', function(){
          if (reportsState.page > 1) {
            reportsState.page -= 1;
            refreshReports();
          }
        });
      }
      if (reportsNext) {
        reportsNext.addEventListener('click', function(){
          reportsState.page += 1;
          refreshReports();
        });
      }
    })();
  </script>
</body>
</html>
''';
  }

  String? _normalizeLabel(String? value) {
    if (value == null) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  String _formatPing(int? ping) {
    if (ping == null) return '—';
    return '${ping}ms';
  }

  String _pingColor(int? ping) {
    if (ping == null) return '#9aa4b2';
    if (ping < 100) return '#31c36b';
    if (ping < 300) return '#ffb86c';
    return '#ff6b6b';
  }

  String _formatCache(int? count) {
    if (count == null) return '—';
    return '$count track${count == 1 ? '' : 's'}';
  }

  String _sourceColor(String label) {
    return label.startsWith('Online') ? '#31c36b' : '#ff6b6b';
  }

  String _deriveSourceLabel(RadioState state) {
    if (state is RadioStateFailover) {
      return state.audioState.isPlaying ? 'Fallback' : 'Fallback (idle)';
    }
    if (state is RadioStateConnected) {
      return state.audioState.isPlaying ? 'Online' : 'Online (idle)';
    }
    if (state is RadioStateConnecting) {
      return 'Connecting';
    }
    if (state is RadioStateError) {
      return 'Error';
    }
    return 'Disconnected';
  }

  Map<String, dynamic> _buildStatePayload() {
    final state = _radioService.currentState;
    final config = state.config;
    final stationName = _normalizeLabel(config?.title) ??
        _normalizeLabel(config?.description) ??
        'Unknown';
    return {
      'ok': true,
      'offlineMode': SystemState.instance.offlineMode,
      'station': stationName,
      'pin': _resolvePin(),
      'ping': _radioService.currentPing,
      'source': _deriveSourceLabel(state),
      'cachedTracks': _failoverService.cachedTracksCount,
    };
  }

  Future<String?> _readAuthKey(HttpRequest request) async {
    final contentType = request.headers.contentType?.mimeType ?? '';
    final body = await utf8.decoder.bind(request).join();
    if (contentType == 'application/json') {
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) {
        final value = decoded['key'];
        if (value is String) return value;
      }
      return null;
    }

    if (body.isEmpty) {
      return null;
    }
    final form = Uri.splitQueryString(body);
    return form['key'];
  }

  Future<bool?> _readEnabledFlag(HttpRequest request) async {
    final contentType = request.headers.contentType?.mimeType ?? '';
    final body = await utf8.decoder.bind(request).join();
    if (contentType == 'application/json') {
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) {
        final value = decoded['enabled'];
        if (value is bool) return value;
        if (value is String) return value.toLowerCase() == 'true';
      }
      return null;
    }

    if (body.isEmpty) {
      return null;
    }
    final form = Uri.splitQueryString(body);
    final value = form['enabled'];
    if (value == null) return null;
    return value.toLowerCase() == 'true' || value == '1';
  }

  int _readPage(HttpRequest request, int fallback) {
    final raw = request.uri.queryParameters['page'];
    if (raw == null || raw.isEmpty) {
      return fallback;
    }
    final value = int.tryParse(raw);
    if (value == null || value <= 0) {
      return fallback;
    }
    return value;
  }

  int _readPerPage(HttpRequest request, int fallback, int max) {
    final raw = request.uri.queryParameters['per_page'];
    if (raw == null || raw.isEmpty) {
      return fallback;
    }
    final value = int.tryParse(raw);
    if (value == null || value <= 0) {
      return fallback;
    }
    if (value > max) {
      return max;
    }
    return value;
  }

  Future<String?> _readPin(HttpRequest request) async {
    final contentType = request.headers.contentType?.mimeType ?? '';
    final body = await utf8.decoder.bind(request).join();
    if (contentType == 'application/json') {
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) {
        final value = decoded['pin'] ?? decoded['token'];
        if (value is String) return value.trim();
      }
      return null;
    }

    if (body.isEmpty) {
      return null;
    }
    final form = Uri.splitQueryString(body);
    final value = form['pin'] ?? form['token'];
    return value?.trim();
  }

  Future<void> _sendHtml(
    HttpRequest request,
    String html, {
    int statusCode = HttpStatus.ok,
    String? authCookieValue,
    bool clearAuthCookie = false,
  }) async {
    request.response.statusCode = statusCode;
    request.response.headers.contentType = ContentType.html;
    if (authCookieValue != null && authCookieValue.isNotEmpty) {
      _attachAuthCookie(request, authCookieValue);
    }
    if (clearAuthCookie) {
      _clearAuthCookie(request);
    }
    request.response.write(html);
    await request.response.close();
  }

  Future<void> _sendRedirect(
    HttpRequest request,
    String location, {
    String? authCookieValue,
    bool clearAuthCookie = false,
  }) async {
    request.response.statusCode = HttpStatus.found;
    request.response.headers.set(HttpHeaders.locationHeader, location);
    if (authCookieValue != null && authCookieValue.isNotEmpty) {
      _attachAuthCookie(request, authCookieValue);
    }
    if (clearAuthCookie) {
      _clearAuthCookie(request);
    }
    await request.response.close();
  }

  Future<void> _sendJson(
    HttpRequest request,
    Map<String, dynamic> body, {
    int statusCode = HttpStatus.ok,
  }) async {
    request.response.statusCode = statusCode;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(body));
    await request.response.close();
  }

  void _attachAuthCookie(HttpRequest request, String value) {
    final cookie = Cookie(_authCookieName, value)
      ..httpOnly = true
      ..path = '/'
      ..maxAge = 60 * 60 * 24 * 30;
    request.response.cookies.add(cookie);
  }

  bool _verifyAdminKey(String value) {
    final hash = _storageService.getAdminKeyHash();
    if (hash != null && hash.trim().isNotEmpty) {
      final computed = sha256.convert(utf8.encode(value)).toString();
      return computed == hash.trim();
    }

    final key = _storageService.getAdminKey();
    if (key != null && key.trim().isNotEmpty) {
      return value == key.trim();
    }
    return value == 'tunio';
  }

  void _clearAuthCookie(HttpRequest request) {
    final cookie = Cookie(_authCookieName, '')
      ..httpOnly = true
      ..path = '/'
      ..maxAge = 0;
    request.response.cookies.add(cookie);
  }

  Future<void> _sendUnauthorized(HttpRequest request) async {
    await _sendJson(
      request,
      {'ok': false, 'error': 'Unauthorized'},
      statusCode: HttpStatus.unauthorized,
    );
  }

  Future<void> _sendNotFound(HttpRequest request) async {
    await _sendJson(
      request,
      {'ok': false, 'error': 'Not found'},
      statusCode: HttpStatus.notFound,
    );
  }
}
