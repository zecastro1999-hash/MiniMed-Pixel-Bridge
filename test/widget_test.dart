import 'package:flutter_test/flutter_test.dart';
import 'package:health/health.dart';
import 'package:minimed_pixel_bridge/models/pump_telemetry.dart';
import 'package:minimed_pixel_bridge/services/carelink_service.dart';
import 'package:minimed_pixel_bridge/services/notification_service.dart';
import 'package:minimed_pixel_bridge/services/sport_prediction_service.dart';
import 'package:minimed_pixel_bridge/services/glucose_prediction_service.dart';
import 'package:minimed_pixel_bridge/services/widget_service.dart';

void main() {
  test('PumpTelemetry.empty has no fake or invented defaults', () {
    final empty = PumpTelemetry.empty();
    expect(empty.sgValue, isNull);
    expect(empty.sgDateTime, isNull);
    expect(empty.activeInsulin, isNull);
    expect(empty.reservoirRemaining, isNull);
    expect(empty.pumpBatteryPercent, isNull);
    expect(empty.pumpBatteryDisplay, '--');
    expect(empty.meanGlucose, isNull);
    expect(empty.sgHistory, isEmpty);
    expect(empty.mealMarkers, isEmpty);
    expect(empty.bolusMarkers, isEmpty);
    expect(empty.autoBasalMarkers, isEmpty);
  });

  test('CareLink EU JSON parser extracts exact clinical fields safely', () {
    final now = DateTime.utc(2026, 11, 17, 19, 0);
    final service = CareLinkService(nowProvider: () => now);
    final sampleJson = {
      'patientData': {
        'lastSG': {
          'sg': 124,
          'datetime': '2026-11-17T18:30:00.000Z',
        },
        'lastSGTrend': 'UP',
        'activeInsulin': {
          'amount': 1.65,
        },
        'sensorDurationMinutes': 7260,
        'medicalDeviceInformation': {
          'reservoirRemainingUnits': 192.5,
          'pumpBatteryLevel': 88,
        },
        'markers': [
          {
            'type': 'MEAL',
            'amount': 50,
            'timestamp': '2026-11-17T17:15:00.000Z',
          },
          {
            'type': 'INSULIN',
            'deliveredFastAmount': 4.0,
            'deliveredExtendedAmount': 1.2,
            'activationType': 'AUTOCORRECTION',
            'timestamp': '2026-11-17T17:15:00.000Z',
          },
          {
            'type': 'AUTO_BASAL_DELIVERY',
            'bolusAmount': 0.125,
            'timestamp': '2026-11-17T18:05:00.000Z',
          },
        ],
        'sgs': [
          {'sg': 115, 'datetime': '2026-11-17T18:25:00.000Z'},
          {'sg': 124, 'datetime': '2026-11-17T18:30:00.000Z'},
        ],
      },
    };

    final telemetry = service.parseCareLinkMessageJson(sampleJson);
    expect(telemetry.currentSg, 124);
    expect(telemetry.sgTrend, 'UP');
    expect(telemetry.trendArrow, '↑');
    expect(telemetry.iob, 1.65);
    expect(telemetry.reservoirUnits, 192.5);
    expect(telemetry.pumpBatteryPercent, 88);
    expect(telemetry.pumpBatteryDisplay, '88%');
    expect(telemetry.sensorRemainingDisplay, '5d 1h');
    expect(telemetry.lastCarbsGrams, 50.0);
    expect(telemetry.lastBolusUnits, closeTo(5.2, 0.001));
    expect(telemetry.sgOrigin, TelemetryOrigin.carelink);
  });

  test('Qualitative battery labels never invent exact numerical percentages', () {
    final merged = NotificationService.mergeLocalBridgeState(
      PumpTelemetry.empty(),
      {
        'sgValue': 134,
        'lastTimestampMs': DateTime.now().millisecondsSinceEpoch,
        'pumpBatteryLabel': 'Alta',
        'pumpBatteryPercent': 100, // should be stripped when label is qualitative
        'sourceBadge': '780G Screen',
      },
    );

    expect(merged.pumpBatteryPercent, isNull);
    expect(merged.pumpBatteryDisplay, 'Alta');
  });

  test('Notification Regex parser extracts Portuguese SG, trend, and IOB', () {
    const title = ' 195 mg/dl';
    const text = 'Insulina ativa 2,80 U';
    expect(NotificationService.parseSgFromText(title), 195);
    expect(NotificationService.parseIobFromText(text), 2.80);

    const sampleTrend = 'MiniMed Mobile: SG 136 mg/dL ↑↑ SmartGuard';
    expect(NotificationService.parseSgFromText(sampleTrend), 136);
    expect(NotificationService.parseTrendFromText(sampleTrend), 'UP_DOUBLE');
  });

  test('FitbitHealthMetrics caches partial authorization state cleanly', () {
    final now = DateTime.utc(2026, 11, 17, 20, 0);
    final workout = FitbitWorkoutSummary(
      activityType: HealthWorkoutActivityType.RUNNING,
      activeKcal: 260,
      avgHr: 148,
      startTime: now.subtract(const Duration(minutes: 35)),
      endTime: now,
    );
    final partial = FitbitHealthMetrics(
      workouts24h: [workout],
      steps24h: 8420,
      latestHeartRate: 76,
      latestHeartRateAt: now,
      restingHeartRate: 58,
      fetchedAt: now,
      authorized: true,
      grantedTypeCount: 6,
      totalRequestedTypeCount: 7,
    );

    expect(partial.authorized, isTrue);
    expect(partial.isPartialAuthorization, isTrue);

    final decoded = FitbitHealthMetrics.decode(partial.encode());
    expect(decoded, isNotNull);
    expect(decoded!.authorized, isTrue);
    expect(decoded.steps24h, 8420);
    expect(decoded.workouts24h.first.displayActivityName, 'Corrida');
  });

  test('WidgetService rejects low-confidence or qualitative predictions for persistent notification', () {
    const lowConf = GlucosePredictionResult(
      availability: PredictionAvailability.available,
      direction: EstimatedTrendDirection.falling,
      confidence: PredictionConfidence.low,
      estimatedSg30m: 95,
      lowerBoundSg30m: 65,
      upperBoundSg30m: 125,
      reason: 'Incerteza elevada',
    );
    const qualOnly = GlucosePredictionResult(
      availability: PredictionAvailability.qualitativeOnly,
      direction: EstimatedTrendDirection.falling,
      confidence: PredictionConfidence.low,
      reason: 'Apenas qualitativa',
    );
    const validMod = GlucosePredictionResult(
      availability: PredictionAvailability.available,
      direction: EstimatedTrendDirection.falling,
      confidence: PredictionConfidence.moderate,
      estimatedSg30m: 155,
      lowerBoundSg30m: 138,
      upperBoundSg30m: 172,
      reason: 'Confiança moderada',
    );

    expect(WidgetService.isValidatedNumericPrediction(null), isFalse);
    expect(WidgetService.isValidatedNumericPrediction(lowConf), isFalse);
    expect(WidgetService.isValidatedNumericPrediction(qualOnly), isFalse);
    expect(WidgetService.isValidatedNumericPrediction(validMod), isTrue);
  });
}
