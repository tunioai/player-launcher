import 'dart:async';

import '../core/dependency_injection.dart';
import '../models/failover_event.dart';
import '../utils/logger.dart';
import 'api_service.dart';
import 'storage_service.dart';

class FailoverReportingService implements Disposable {
  static const Duration _retryDelay = Duration(minutes: 5);

  final StorageService _storageService;
  final ApiService _apiService;

  Timer? _retryTimer;
  bool _isSending = false;
  String? _lastPin;

  FailoverReportingService({
    required StorageService storageService,
    required ApiService apiService,
  })  : _storageService = storageService,
        _apiService = apiService;

  Future<void> logEvent(FailoverEvent event, {String? pin}) async {
    await _storageService.appendFailoverEvent(event);

    if (pin != null && pin.isNotEmpty) {
      _lastPin = pin;
      await flush(pin: pin);
    }
  }

  Future<void> flush({String? pin}) async {
    final targetPin = pin ?? _lastPin;
    if (targetPin == null || targetPin.isEmpty) {
      return;
    }

    if (_isSending) {
      Logger.debug('Failover report already in progress',
          'FailoverReportingService');
      return;
    }

    final events =
        _storageService.getFailoverEvents(includeSent: false).toList();
    if (events.isEmpty) {
      Logger.debug('No failover events to report', 'FailoverReportingService');
      return;
    }

    _isSending = true;

    try {
      Logger.info(
          'Reporting ${events.length} failover events', 'FailoverReportingService');
      await _apiService.sendFailoverReport(targetPin, events);
      await _storageService
          .markFailoverEventsAsSent(events.map((event) => event.id).toList());
      await _storageService.clearSentFailoverEvents();
      _retryTimer?.cancel();
    } catch (e) {
      Logger.error('Failover report failed', 'FailoverReportingService', e);
      _scheduleRetry(targetPin);
    } finally {
      _isSending = false;
    }
  }

  void scheduleFlush(String pin) {
    _lastPin = pin;
    _scheduleRetry(pin);
  }

  void _scheduleRetry(String pin) {
    _retryTimer?.cancel();
    _retryTimer = Timer(_retryDelay, () {
      flush(pin: pin).catchError((error, stackTrace) {
        Logger.error('Deferred failover report failed',
            'FailoverReportingService', error, stackTrace);
      });
    });
  }

  @override
  Future<void> dispose() async {
    _retryTimer?.cancel();
  }
}
