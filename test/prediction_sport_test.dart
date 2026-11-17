import 'package:flutter_test/flutter_test.dart';
import 'package:health/health.dart';
import 'package:minimed_pixel_bridge/models/pump_telemetry.dart';
import 'package:minimed_pixel_bridge/services/glucose_prediction_service.dart';
import 'package:minimed_pixel_bridge/services/sport_prediction_service.dart';
import 'package:minimed_pixel_bridge/services/telemetry_history_store.dart';

void main() {
  test('Regular downward readings produce falling trend and conservative estimate',
      () {
    final now = DateTime.utc(2026, 11, 17, 18, 0);
    final history = [
      SgReading(sg: 165, timestamp: now.subtract(const Duration(minutes: 25))),
      SgReading(sg: 158, timestamp: now.subtract(const Duration(minutes: 20))),
      SgReading(sg: 150, timestamp: now.subtract(const Duration(minutes: 15))),
      SgReading(sg: 142, timestamp: now.subtract(const Duration(minutes: 10))),
      SgReading(sg: 134, timestamp: now.subtract(const Duration(minutes: 5))),
      SgReading(sg: 126, timestamp: now),
    ];

    final telemetry = PumpTelemetry(
      sgValue: 126,
      sgDateTime: now,
      sgTrend: 'DOWN',
      activeInsulin: 1.0,
      reservoirRemaining: 120,
      pumpBatteryPercent: 80,
      sgHistory: history,
      mealMarkers: const [],
      bolusMarkers: const [],
      dataSource: 'CareLink EU',
    );

    final pred = GlucosePredictionService.predict(
      telemetry: telemetry,
      asOf: now,
    );

    expect(pred.isAvailable, isTrue);
    expect(pred.direction, EstimatedTrendDirection.falling);
    expect(pred.hasNumericEstimate, isTrue);
    expect(pred.estimatedSg30m!, lessThan(115));
    expect(pred.lowerBoundSg30m!, lessThan(pred.estimatedSg30m!));
    expect(pred.upperBoundSg30m!, greaterThan(pred.estimatedSg30m!));
  });

  test('Stale or missing readings report Previsão indisponível', () {
    final now = DateTime.utc(2026, 11, 17, 18, 0);
    final staleHistory = [
      SgReading(sg: 140, timestamp: now.subtract(const Duration(minutes: 35))),
      SgReading(sg: 145, timestamp: now.subtract(const Duration(minutes: 30))),
      SgReading(sg: 150, timestamp: now.subtract(const Duration(minutes: 25))),
    ];

    final staleTelemetry = PumpTelemetry(
      sgValue: 150,
      sgDateTime: now.subtract(const Duration(minutes: 25)),
      sgTrend: 'NONE',
      activeInsulin: null,
      reservoirRemaining: null,
      pumpBatteryPercent: null,
      sgHistory: staleHistory,
      mealMarkers: const [],
      bolusMarkers: const [],
      dataSource: 'CareLink EU',
    );

    final stalePred = GlucosePredictionService.predict(
      telemetry: staleTelemetry,
      asOf: now,
    );
    expect(stalePred.availability, PredictionAvailability.unavailable);
    expect(stalePred.trendHeadlinePt, 'Previsão indisponível');
    expect(stalePred.hasNumericEstimate, isFalse);

    final emptyPred = GlucosePredictionService.predict(
      telemetry: PumpTelemetry.empty(),
      asOf: now,
    );
    expect(emptyPred.availability, PredictionAvailability.unavailable);
  });

  test('Irregular timestamps use real elapsed minutes rather than fixed 5m intervals',
      () {
    final now = DateTime.utc(2026, 11, 17, 18, 0);
    // +10 mg/dL spread over 20 minutes (+0.5 mg/dL/min -> rising gently, NOT +60!)
    final irregularHistory = [
      SgReading(sg: 120, timestamp: now.subtract(const Duration(minutes: 20))),
      SgReading(sg: 124, timestamp: now.subtract(const Duration(minutes: 12))),
      SgReading(sg: 125, timestamp: now.subtract(const Duration(minutes: 10))),
      SgReading(sg: 130, timestamp: now),
    ];

    final telemetry = PumpTelemetry(
      sgValue: 130,
      sgDateTime: now,
      sgTrend: 'NONE',
      activeInsulin: null,
      reservoirRemaining: null,
      pumpBatteryPercent: null,
      sgHistory: irregularHistory,
      mealMarkers: const [],
      bolusMarkers: const [],
      dataSource: 'CareLink EU',
    );

    final pred = GlucosePredictionService.predict(
      telemetry: telemetry,
      asOf: now,
    );
    expect(pred.isAvailable, isTrue);
    expect(pred.direction, EstimatedTrendDirection.rising);
    expect(pred.estimatedSg30m!, inInclusiveRange(134, 152));
  });

  test('Abrupt erratic oscillations suppress unjustified numeric predictions',
      () {
    final now = DateTime.utc(2026, 11, 17, 18, 0);
    final chaoticHistory = [
      SgReading(sg: 110, timestamp: now.subtract(const Duration(minutes: 25))),
      SgReading(sg: 205, timestamp: now.subtract(const Duration(minutes: 20))),
      SgReading(sg: 95, timestamp: now.subtract(const Duration(minutes: 15))),
      SgReading(sg: 215, timestamp: now.subtract(const Duration(minutes: 10))),
      SgReading(sg: 102, timestamp: now.subtract(const Duration(minutes: 5))),
      SgReading(sg: 185, timestamp: now),
    ];

    final telemetry = PumpTelemetry(
      sgValue: 185,
      sgDateTime: now,
      sgTrend: 'NONE',
      activeInsulin: null,
      reservoirRemaining: null,
      pumpBatteryPercent: null,
      sgHistory: chaoticHistory,
      mealMarkers: const [],
      bolusMarkers: const [],
      dataSource: 'CareLink EU',
    );

    final pred = GlucosePredictionService.predict(
      telemetry: telemetry,
      asOf: now,
    );
    expect(pred.hasNumericEstimate, isFalse);
  });

  test('PredictionEvaluator computes MAE and direction accuracy on multi-hour series',
      () {
    final t0 = DateTime.utc(2026, 11, 17, 12, 0);
    // Smooth curve rising +1 mg/dL every 5 min for 2 hours
    final history = List<SgReading>.generate(25, (i) {
      return SgReading(
        sg: 110 + (i * 2),
        timestamp: t0.add(Duration(minutes: i * 5)),
      );
    });

    final metrics = PredictionEvaluator.evaluateHistory(history);
    expect(metrics.evaluatedCount, greaterThan(5));
    expect(metrics.maeMgDl, isNotNull);
    expect(metrics.maeMgDl!, lessThan(15.0));
    expect(metrics.directionAccuracyPercent!, greaterThanOrEqualTo(80.0));
  });

  test('Smart Sport Mode separates active, recovery, and ignores 20h-old workouts',
      () {
    final now = DateTime.utc(2026, 11, 17, 18, 0);
    final telemetry = PumpTelemetry(
      sgValue: 118,
      sgDateTime: now,
      sgTrend: 'NONE',
      activeInsulin: 1.8,
      reservoirRemaining: 100,
      pumpBatteryPercent: 75,
      sgHistory: [
        SgReading(sg: 122, timestamp: now.subtract(const Duration(minutes: 10))),
        SgReading(sg: 120, timestamp: now.subtract(const Duration(minutes: 5))),
        SgReading(sg: 118, timestamp: now),
      ],
      mealMarkers: const [],
      bolusMarkers: const [],
      dataSource: 'CareLink EU',
    );

    // 1. Active manual tennis session
    final activeEval = SportPredictionService.evaluate(
      telemetry: telemetry,
      manualSession: ManualWorkoutSession(
        activityTypeName: HealthWorkoutActivityType.TENNIS.name,
        startTime: now.subtract(const Duration(minutes: 25)),
      ),
      fitbitMetrics: FitbitHealthMetrics(
        latestHeartRate: 142,
        latestHeartRateAt: now.subtract(const Duration(minutes: 3)),
        authorized: true,
      ),
      asOf: now,
    );
    expect(activeEval.state, SportActivityState.active);
    expect(activeEval.activeOrRecoveryWorkout!.displayActivityName, 'Ténis');
    expect(activeEval.availableHeartRateBpm, 142);
    expect(activeEval.riskLevel, SportRiskLevel.elevatedDropRisk);

    // 2. Recovery window (finished 90 minutes ago)
    final recoveryEval = SportPredictionService.evaluate(
      telemetry: telemetry,
      fitbitMetrics: FitbitHealthMetrics(
        authorized: true,
        workouts24h: [
          FitbitWorkoutSummary(
            activityType: HealthWorkoutActivityType.RUNNING,
            activeKcal: 280,
            avgHr: 152,
            startTime: now.subtract(const Duration(minutes: 130)),
            endTime: now.subtract(const Duration(minutes: 90)),
          ),
        ],
      ),
      asOf: now,
    );
    expect(recoveryEval.state, SportActivityState.recovery);

    // 3. Old workout from 20 hours ago MUST be classified as Sem treino (none)!
    final oldEval = SportPredictionService.evaluate(
      telemetry: telemetry,
      fitbitMetrics: FitbitHealthMetrics(
        authorized: true,
        workouts24h: [
          FitbitWorkoutSummary(
            activityType: HealthWorkoutActivityType.RUNNING,
            activeKcal: 400,
            avgHr: 155,
            startTime: now.subtract(const Duration(hours: 21)),
            endTime: now.subtract(const Duration(hours: 20)),
          ),
        ],
      ),
      asOf: now,
    );
    expect(oldEval.state, SportActivityState.none);
  });
}
