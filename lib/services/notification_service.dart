import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:home_widget/home_widget.dart';
import '../models/pump_telemetry.dart';

class InterceptedSgNotification {
  final String eventType; // 'notification' or 'accessibility'
  final String packageName;
  final int? sgValue;
  final String trend;
  final String trendArrow;
  final double? activeInsulin;
  final double? carbsGrams;
  final String? carbsTime;
  final double? reservoirRemaining;
  final String? pumpBatteryLabel;
  final int? pumpBatteryPercent;
  final String? sensorBatteryLabel;
  final String? sensorDaysRemaining;
  final DateTime timestamp;
  final String rawTitle;
  final String rawText;
  final String rawSubText;
  final String rawBigText;
  final String rawAccessibility;

  const InterceptedSgNotification({
    required this.eventType,
    required this.packageName,
    this.sgValue,
    required this.trend,
    required this.trendArrow,
    this.activeInsulin,
    this.carbsGrams,
    this.carbsTime,
    this.reservoirRemaining,
    this.pumpBatteryLabel,
    this.pumpBatteryPercent,
    this.sensorBatteryLabel,
    this.sensorDaysRemaining,
    required this.timestamp,
    this.rawTitle = '',
    this.rawText = '',
    this.rawSubText = '',
    this.rawBigText = '',
    this.rawAccessibility = '',
  });
}

class NotificationService {
  static const String targetPackage = 'com.medtronic.diabetes.minimedmobile.eu';

  static const MethodChannel _methodChannel =
      MethodChannel('com.minimed.bridge/notifications');
  static const EventChannel _eventChannel =
      EventChannel('com.minimed.bridge/notification_stream');

  static final RegExp _explicitSgRegex = RegExp(
    r'\b([4-9]\d|[1-3]\d{2}|400)\s*(?:mg/dL|mg/dl)\b',
    caseSensitive: false,
  );
  static final RegExp _labeledSgRegex = RegExp(
    r'(?:SG|Glucose|Glicemia|Sensor|BG)[:\s]*([4-9]\d|[1-3]\d{2}|400)\b',
    caseSensitive: false,
  );
  static final RegExp _iobRegex = RegExp(
    r'(?:Insulina\s+ativa|Active\s+Insulin|IOB)[:\s]*(\d+[.,]\d+|\d+)\s*U\b',
    caseSensitive: false,
  );

  final StreamController<InterceptedSgNotification> _controller =
      StreamController<InterceptedSgNotification>.broadcast();
  StreamSubscription<dynamic>? _nativeSubscription;

  Stream<InterceptedSgNotification> get onSgIntercepted => _controller.stream;

  void startListening() {
    _nativeSubscription?.cancel();
    _nativeSubscription = _eventChannel.receiveBroadcastStream().listen(
      (dynamic rawEvent) {
        if (rawEvent is! Map) return;
        final map = Map<String, dynamic>.from(rawEvent);
        final pkg = map['packageName']?.toString() ?? '';
        if (pkg != targetPackage &&
            pkg != 'com.medtronic.diabetes.minimedmobile.us') {
          return;
        }

        final eventType = map['eventType']?.toString() ?? 'notification';
        final rawTitle = map['rawTitle']?.toString() ?? '';
        final rawText = map['rawText']?.toString() ?? '';
        final rawSubText = map['rawSubText']?.toString() ?? '';
        final rawBigText = map['rawBigText']?.toString() ?? '';
        final rawCombined = map['rawCombined']?.toString() ??
            '$rawTitle | $rawText | $rawBigText | $rawSubText';
        final rawAccessibility = map['rawAccessibility']?.toString() ?? '';

        final sg = (map['sg'] as num?)?.toInt() ?? parseSgFromText(rawCombined);
        final iob = (map['activeInsulin'] as num?)?.toDouble() ??
            parseIobFromText(rawCombined);
        final carbsGrams = (map['carbsGrams'] as num?)?.toDouble();
        final carbsTime = map['carbsTime']?.toString();
        final reservoir = (map['reservoirUnits'] as num?)?.toDouble();
        final pumpBattLabel = map['pumpBatteryLabel']?.toString();
        final rawBattPct = (map['pumpBatteryPercent'] as num?)?.toInt();
        final pumpBattPct = _isQualitativeBatteryLabel(pumpBattLabel)
            ? null
            : rawBattPct;
        final sensorBatt = map['sensorBattery']?.toString();
        final sensorDays = map['sensorDaysLeft']?.toString();

        final trend = map['trend']?.toString() ?? parseTrendFromText(rawCombined);
        final arrow = map['trendArrow']?.toString() ?? _trendToArrow(trend);
        final epochMs = (map['timestampMs'] as num?)?.toInt() ??
            DateTime.now().millisecondsSinceEpoch;
        final dt = DateTime.fromMillisecondsSinceEpoch(epochMs);

        _controller.add(
          InterceptedSgNotification(
            eventType: eventType,
            packageName: pkg,
            sgValue: sg,
            trend: trend,
            trendArrow: arrow,
            activeInsulin: iob,
            carbsGrams: carbsGrams,
            carbsTime: carbsTime,
            reservoirRemaining: reservoir,
            pumpBatteryLabel: pumpBattLabel,
            pumpBatteryPercent: pumpBattPct,
            sensorBatteryLabel: sensorBatt,
            sensorDaysRemaining: sensorDays,
            timestamp: dt,
            rawTitle: rawTitle,
            rawText: rawText,
            rawSubText: rawSubText,
            rawBigText: rawBigText,
            rawAccessibility: rawAccessibility,
          ),
        );
      },
      onError: (Object err) {
        debugPrint('NotificationService stream error: ${err.runtimeType}');
      },
    );
  }

  static bool _isQualitativeBatteryLabel(String? label) {
    if (label == null) return false;
    final lower = label.trim().toLowerCase();
    return lower == 'alta' ||
        lower == 'média' ||
        lower == 'media' ||
        lower == 'baixa' ||
        lower == 'high' ||
        lower == 'medium' ||
        lower == 'low';
  }

  static int? parseSgFromText(String text) {
    final explicitMatch = _explicitSgRegex.firstMatch(text);
    if (explicitMatch != null) {
      return int.tryParse(explicitMatch.group(1) ?? '');
    }
    final labeledMatch = _labeledSgRegex.firstMatch(text);
    if (labeledMatch != null) {
      return int.tryParse(labeledMatch.group(1) ?? '');
    }
    return null;
  }

  static double? parseIobFromText(String text) {
    final match = _iobRegex.firstMatch(text);
    if (match == null) return null;
    return double.tryParse((match.group(1) ?? '').replaceAll(',', '.'));
  }

  static String parseTrendFromText(String text) {
    if (text.contains('↑↑') ||
        text.contains('⇈') ||
        text.toUpperCase().contains('UP_DOUBLE')) {
      return 'UP_DOUBLE';
    }
    if (text.contains('↓↓') ||
        text.contains('⇊') ||
        text.toUpperCase().contains('DOWN_DOUBLE')) {
      return 'DOWN_DOUBLE';
    }
    if (text.contains('↑') ||
        text.contains('↗') ||
        text.toUpperCase().contains('UP')) {
      return 'UP';
    }
    if (text.contains('↓') ||
        text.contains('↘') ||
        text.toUpperCase().contains('DOWN')) {
      return 'DOWN';
    }
    return 'NONE';
  }

  static String _trendToArrow(String trend) {
    switch (trend.toUpperCase()) {
      case 'UP':
        return '↑';
      case 'UP_DOUBLE':
        return '↑↑';
      case 'DOWN':
        return '↓';
      case 'DOWN_DOUBLE':
        return '↓↓';
      default:
        return '→';
    }
  }

  Future<bool> isNotificationAccessGranted() async {
    try {
      final granted = await _methodChannel
          .invokeMethod<bool>('isNotificationListenerEnabled');
      return granted ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<void> openNotificationAccessSettings() async {
    try {
      await _methodChannel.invokeMethod('openNotificationListenerSettings');
    } catch (_) {}
  }

  Future<bool> isAccessibilityAccessGranted() async {
    try {
      final granted = await _methodChannel
          .invokeMethod<bool>('isAccessibilityServiceEnabled');
      return granted ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<void> openAccessibilitySettings() async {
    try {
      await _methodChannel.invokeMethod('openAccessibilitySettings');
    } catch (_) {}
  }

  Future<bool> isPostNotificationsGranted() async {
    try {
      final granted =
          await _methodChannel.invokeMethod<bool>('isPostNotificationsGranted');
      return granted ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<bool> requestPostNotificationsPermission() async {
    try {
      final requested = await _methodChannel
          .invokeMethod<bool>('requestPostNotificationsPermission');
      return requested ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<bool> isIgnoringBatteryOptimizations() async {
    try {
      final ok = await _methodChannel
          .invokeMethod<bool>('isIgnoringBatteryOptimizations');
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<void> openBatteryOptimizationSettings() async {
    try {
      await _methodChannel.invokeMethod('openBatteryOptimizationSettings');
    } catch (_) {}
  }

  Future<void> refreshRichNotification() async {
    try {
      await _methodChannel.invokeMethod('refreshRichNotification');
    } catch (_) {}
  }

  Future<void> clearBridgeState() async {
    try {
      await _methodChannel.invokeMethod('clearLocalBridgeState');
    } catch (_) {}
  }

  Future<Map<String, dynamic>?> scanActiveNotifications() async {
    try {
      return await _methodChannel
          .invokeMapMethod<String, dynamic>('scanActiveNotifications');
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, dynamic>?> getLocalBridgeState() async {
    try {
      return await _methodChannel
          .invokeMapMethod<String, dynamic>('getLocalBridgeState');
    } catch (_) {
      return readLocalBridgeStateFromHomeWidget();
    }
  }

  /// Headless/background-safe reader for `HomeWidgetPreferences`, usable
  /// inside WorkManager isolates where MainActivity MethodChannel isn't mounted.
  static Future<Map<String, dynamic>?> readLocalBridgeStateFromHomeWidget() async {
    try {
      final sgStr = await HomeWidget.getWidgetData<String>('sg_value');
      final sgTrend = await HomeWidget.getWidgetData<String>('sg_trend');
      final sgTrendArrow =
          await HomeWidget.getWidgetData<String>('sg_trend_arrow');
      final iobNumStr =
          await HomeWidget.getWidgetData<String>('active_insulin_num');
      final carbsGramsStr =
          await HomeWidget.getWidgetData<String>('last_carbs_grams');
      final carbsTime =
          await HomeWidget.getWidgetData<String>('last_carbs_time');
      final reservoirNumStr =
          await HomeWidget.getWidgetData<String>('reservoir_num');
      final pumpBattLabel =
          await HomeWidget.getWidgetData<String>('pump_battery');
      final pumpBattPct =
          await HomeWidget.getWidgetData<int>('pump_battery_percent');
      final sensorBatt =
          await HomeWidget.getWidgetData<String>('sensor_battery');
      final sensorDays =
          await HomeWidget.getWidgetData<String>('sensor_days_left');
      final tsStr = await HomeWidget.getWidgetData<String>('last_timestamp_ms');
      final sourceBadge =
          await HomeWidget.getWidgetData<String>('source_badge');
      final localHistoryJson =
          await HomeWidget.getWidgetData<String>('local_sg_history_json');

      if (sgStr == null &&
          iobNumStr == null &&
          localHistoryJson == null &&
          carbsGramsStr == null) {
        return null;
      }

      return {
        'sgValue': int.tryParse(sgStr ?? ''),
        'sgTrend': sgTrend,
        'sgTrendArrow': sgTrendArrow,
        'activeInsulin': double.tryParse(iobNumStr ?? ''),
        'lastCarbsGrams': double.tryParse(carbsGramsStr ?? ''),
        'lastCarbsTime': carbsTime,
        'reservoirRemaining': double.tryParse(reservoirNumStr ?? ''),
        'pumpBatteryLabel': pumpBattLabel,
        'pumpBatteryPercent': pumpBattPct,
        'sensorBatteryLabel': sensorBatt,
        'sensorDaysRemaining': sensorDays,
        'lastTimestampMs': int.tryParse(tsStr ?? ''),
        'sourceBadge': sourceBadge,
        'localSgHistoryJson': localHistoryJson,
      };
    } catch (e) {
      debugPrint('readLocalBridgeStateFromHomeWidget error: ${e.runtimeType}');
      return null;
    }
  }

  Future<String?> tryLoadDownloadLoginData() async {
    try {
      return await _methodChannel
          .invokeMethod<String>('tryLoadDownloadLoginData');
    } catch (_) {
      return null;
    }
  }

  Future<String?> pickLoginDataFile() async {
    try {
      return await _methodChannel.invokeMethod<String>('pickLoginDataFile');
    } catch (_) {
      return null;
    }
  }

  /// Merges native NotificationListener & AccessibilityService state into [base]
  /// preserving accurate [TelemetryOrigin] and avoiding fake numeric battery %.
  static PumpTelemetry mergeLocalBridgeState(
    PumpTelemetry base,
    Map<String, dynamic>? localState, {
    DateTime? now,
  }) {
    if (localState == null || localState.isEmpty) return base;
    final refNow = now ?? DateTime.now();

    final sg = (localState['sgValue'] as num?)?.toInt();
    final trend = localState['sgTrend']?.toString();
    final iob = (localState['activeInsulin'] as num?)?.toDouble();
    final carbsGrams = (localState['lastCarbsGrams'] as num?)?.toDouble();
    final carbsTime = localState['lastCarbsTime']?.toString();
    final reservoir = (localState['reservoirRemaining'] as num?)?.toDouble();
    final pumpBattLabel = localState['pumpBatteryLabel']?.toString();
    final rawBattPct = (localState['pumpBatteryPercent'] as num?)?.toInt();
    final pumpBattPct = _isQualitativeBatteryLabel(pumpBattLabel)
        ? null
        : rawBattPct;
    final sensorBatt = localState['sensorBatteryLabel']?.toString();
    final sensorDays = localState['sensorDaysRemaining']?.toString();
    final tsMs = (localState['lastTimestampMs'] as num?)?.toInt();
    final sourceBadge = localState['sourceBadge']?.toString();
    final rawNotifSummary = localState['rawNotifSummary']?.toString();
    final rawAccessSummary = localState['rawAccessibilitySummary']?.toString();
    final localHistoryRaw = localState['localSgHistoryJson']?.toString();

    final localOrigin = TelemetryOrigin.fromString(sourceBadge);
    final localDt = tsMs != null && tsMs > 0
        ? DateTime.fromMillisecondsSinceEpoch(tsMs)
        : null;

    final mergedHistory = List<SgReading>.from(base.sgHistory);
    if (localHistoryRaw != null && localHistoryRaw.isNotEmpty) {
      try {
        final decodedList = jsonDecode(localHistoryRaw) as List<dynamic>;
        for (final entry in decodedList) {
          if (entry is! Map) continue;
          final readingSg = (entry['sg'] as num?)?.toInt() ?? 0;
          final readingTs = (entry['ts'] as num?)?.toInt() ?? 0;
          if (readingSg >= 20 && readingSg <= 600 && readingTs > 0) {
            final dt = DateTime.fromMillisecondsSinceEpoch(readingTs);
            final entryOrigin = entry['src'] != null
                ? TelemetryOrigin.fromString(entry['src']?.toString())
                : (localOrigin == TelemetryOrigin.unknown
                    ? TelemetryOrigin.notification
                    : localOrigin);
            final reading = SgReading(
              sg: readingSg,
              timestamp: dt,
              origin: entryOrigin,
            );
            if (!reading.isValidAt(refNow)) continue;
            final duplicate = mergedHistory.any(
              (r) => r.timestamp.difference(dt).inSeconds.abs() < 45,
            );
            if (!duplicate) {
              mergedHistory.add(reading);
            }
          }
        }
      } catch (_) {}
    }

    final mergedMeals = List<MealMarker>.from(base.mealMarkers);
    if (carbsGrams != null && carbsGrams > 0 && carbsGrams <= 500) {
      final hasMatch = mergedMeals.any(
        (m) =>
            (m.carbsGrams - carbsGrams).abs() < 0.5 &&
            (carbsTime == null || m.displayTime == carbsTime),
      );
      if (!hasMatch) {
        mergedMeals.add(
          MealMarker(
            carbsGrams: carbsGrams,
            timestamp: localDt ?? refNow,
            displayTime: carbsTime,
            origin: localOrigin == TelemetryOrigin.unknown
                ? TelemetryOrigin.accessibility
                : localOrigin,
          ),
        );
      }
    }

    final useLocalSg = sg != null &&
        sg >= 20 &&
        sg <= 600 &&
        localDt != null &&
        (base.sgValue == null ||
            base.sgDateTime == null ||
            localDt.isAfter(base.sgDateTime!));

    final resolvedSg = useLocalSg ? sg : (base.sgValue ?? sg);
    final resolvedDt = useLocalSg ? localDt : (base.sgDateTime ?? localDt);
    final resolvedOrigin = useLocalSg
        ? (localOrigin == TelemetryOrigin.unknown
            ? TelemetryOrigin.notification
            : localOrigin)
        : (base.sgValue == null
            ? (localOrigin == TelemetryOrigin.unknown
                ? TelemetryOrigin.notification
                : localOrigin)
            : base.sgOrigin);

    if (resolvedSg != null && resolvedDt != null) {
      final candidate = SgReading(
        sg: resolvedSg,
        timestamp: resolvedDt,
        origin: resolvedOrigin,
      );
      if (candidate.isValidAt(refNow)) {
        final exists = mergedHistory.any(
          (r) => r.timestamp.difference(resolvedDt).inSeconds.abs() < 45,
        );
        if (!exists) {
          mergedHistory.add(candidate);
        }
      }
    }
    mergedHistory.sort((a, b) => a.timestamp.compareTo(b.timestamp));

    final resolvedSource = useLocalSg && sourceBadge != null
        ? sourceBadge
        : (base.sgValue == null && sourceBadge != null
            ? sourceBadge
            : base.dataSource);

    // If incoming label is qualitative ("Alta", "Média", "Baixa") and CareLink
    // didn't already give a numeric %, ensure pumpBatteryPercent remains null.
    final resolvedBatteryPercent =
        (base.pumpBatteryPercent != null && base.sgOrigin == TelemetryOrigin.carelink)
            ? base.pumpBatteryPercent
            : pumpBattPct;

    return base.copyWith(
      sgValue: resolvedSg,
      sgDateTime: resolvedDt,
      sgTrend: useLocalSg && trend != null ? trend : base.sgTrend,
      sgOrigin: resolvedOrigin,
      activeInsulin: useLocalSg ? (iob ?? base.activeInsulin) : (base.activeInsulin ?? iob),
      reservoirRemaining: base.reservoirRemaining ?? reservoir,
      pumpBatteryPercent: resolvedBatteryPercent,
      clearPumpBatteryPercent: resolvedBatteryPercent == null,
      pumpBatteryLabel: base.pumpBatteryLabel ?? pumpBattLabel,
      sensorBatteryLabel: base.sensorBatteryLabel ?? sensorBatt,
      sensorDaysRemaining: base.sensorDaysRemaining ?? sensorDays,
      sgHistory: mergedHistory,
      mealMarkers: mergedMeals,
      dataSource: resolvedSource,
      rawNotificationSummary:
          rawNotifSummary ?? base.rawNotificationSummary,
      rawAccessibilitySummary:
          rawAccessSummary ?? base.rawAccessibilitySummary,
    );
  }

  void dispose() {
    _nativeSubscription?.cancel();
    _controller.close();
  }
}
