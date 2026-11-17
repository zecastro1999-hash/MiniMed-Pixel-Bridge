import 'package:flutter_test/flutter_test.dart';
import 'package:minimed_pixel_bridge/models/pump_telemetry.dart';
import 'package:minimed_pixel_bridge/services/telemetry_history_store.dart';
import 'package:minimed_pixel_bridge/services/time_in_range_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('Inclusive 70 and 180 mg/dL boundaries count inside target range', () {
    final t0 = DateTime.utc(2026, 11, 17, 10, 0);
    final readings = [
      SgReading(sg: 69, timestamp: t0),
      SgReading(sg: 70, timestamp: t0.add(const Duration(minutes: 5))),
      SgReading(sg: 180, timestamp: t0.add(const Duration(minutes: 10))),
      SgReading(sg: 181, timestamp: t0.add(const Duration(minutes: 15))),
    ];

    final streakAt70 = TimeInRangeService.computeInRangeStreak(
      readings: readings.sublist(0, 2),
      asOf: t0.add(const Duration(minutes: 6)),
    );
    expect(streakAt70.status, StreakStatus.inRange);

    final streakAt180 = TimeInRangeService.computeInRangeStreak(
      readings: readings.sublist(0, 3),
      asOf: t0.add(const Duration(minutes: 11)),
    );
    expect(streakAt180.status, StreakStatus.inRange);
    expect(streakAt180.duration.inMinutes, 6);

    final streakOut181 = TimeInRangeService.computeInRangeStreak(
      readings: readings,
      asOf: t0.add(const Duration(minutes: 16)),
    );
    expect(streakOut181.status, StreakStatus.outOfRange);
    expect(streakOut181.isBelowRange, isFalse);
  });

  test('Continuous streak starts on entry, resets on exit, and stops at gaps', () {
    final t0 = DateTime.utc(2026, 11, 17, 10, 0);
    // Out at 10:00 (195), enter at 10:05 (175), stay in at 10:10..10:25, query at 10:27
    final readings = [
      SgReading(sg: 195, timestamp: t0),
      SgReading(sg: 175, timestamp: t0.add(const Duration(minutes: 5))),
      SgReading(sg: 140, timestamp: t0.add(const Duration(minutes: 10))),
      SgReading(sg: 120, timestamp: t0.add(const Duration(minutes: 20))),
      SgReading(sg: 115, timestamp: t0.add(const Duration(minutes: 25))),
    ];

    final streak = TimeInRangeService.computeInRangeStreak(
      readings: readings,
      asOf: t0.add(const Duration(minutes: 27)),
    );
    expect(streak.status, StreakStatus.inRange);
    expect(streak.duration.inMinutes, 22);
    expect(streak.interruptedByPriorGap, isFalse);

    // Insert 40-minute gap before 11:05 reading -> streak limited by prior gap
    final withGap = [
      ...readings,
      SgReading(sg: 110, timestamp: t0.add(const Duration(minutes: 65))),
      SgReading(sg: 112, timestamp: t0.add(const Duration(minutes: 70))),
    ];
    final afterGap = TimeInRangeService.computeInRangeStreak(
      readings: withGap,
      asOf: t0.add(const Duration(minutes: 72)),
    );
    expect(afterGap.status, StreakStatus.inRange);
    expect(afterGap.interruptedByPriorGap, isTrue);
    expect(afterGap.duration.inMinutes, 7);

    // If no recent reading for 25 min -> continuity declared unknown
    final staleStreak = TimeInRangeService.computeInRangeStreak(
      readings: withGap,
      asOf: t0.add(const Duration(minutes: 95)),
    );
    expect(staleStreak.status, StreakStatus.unknownDueToGap);
  });

  test('Time-weighted TIR prevents irregular timestamp bursts from skewing percentages and omits large gaps',
      () {
    final t0 = DateTime.utc(2026, 11, 17, 10, 0);
    // Burst of 4 rapid readings (1 min apart) at 100 mg/dL = only 3 min real span,
    // followed by 205 mg/dL for 5 min -> must weight by TIME, not count!
    final readings = [
      SgReading(sg: 100, timestamp: t0),
      SgReading(sg: 100, timestamp: t0.add(const Duration(minutes: 1))),
      SgReading(sg: 100, timestamp: t0.add(const Duration(minutes: 2))),
      SgReading(sg: 100, timestamp: t0.add(const Duration(minutes: 3))),
      SgReading(sg: 205, timestamp: t0.add(const Duration(minutes: 8))),
      SgReading(sg: 210, timestamp: t0.add(const Duration(minutes: 13))),
    ];

    final summary = TimeInRangeService.computeWindowMetrics(
      readings: readings,
      period: TirPeriod.h24,
      asOf: t0.add(const Duration(minutes: 13)),
    );

    expect(summary.hasSufficientData, isTrue);
    // In range: 0..3m (3m) + half of 3..8m (2.5m) = 5.5m
    // Above range: 2.5m + 5m = 7.5m -> total 13m covered
    expect(summary.coveredDuration.inSeconds, 13 * 60);
    expect(summary.inRangePercent!, closeTo((5.5 / 13.0) * 100.0, 0.2));
    expect(summary.aboveRangePercent!, closeTo((7.5 / 13.0) * 100.0, 0.2));

    // Gap test: 60m gap MUST not be counted inside coveredDuration
    final gapped = [
      ...readings,
      SgReading(sg: 120, timestamp: t0.add(const Duration(minutes: 73))),
      SgReading(sg: 120, timestamp: t0.add(const Duration(minutes: 78))),
    ];
    final gappedSummary = TimeInRangeService.computeWindowMetrics(
      readings: gapped,
      period: TirPeriod.h24,
      asOf: t0.add(const Duration(minutes: 78)),
    );
    expect(gappedSummary.gapCount, 1);
    expect(gappedSummary.coveredDuration.inMinutes, 18); // 13m + 5m, 60m gap excluded
  });

  test('Day boundary rollover & app restart reconstruction via TelemetryHistoryStore',
      () async {
    final beforeMidnight = DateTime.utc(2026, 11, 17, 23, 55);
    final afterMidnight = DateTime.utc(2026, 11, 18, 0, 5);
    final asOf = DateTime.utc(2026, 11, 18, 0, 10);

    final store1 = TelemetryHistoryStore(nowProvider: () => asOf);
    await store1.saveTargetRange(const TargetRangeConfig(lowMgDl: 70, highMgDl: 180));
    await store1.mergeAndSaveSgHistory([
      SgReading(sg: 190, timestamp: beforeMidnight.subtract(const Duration(minutes: 5))),
      SgReading(sg: 120, timestamp: beforeMidnight),
      SgReading(sg: 118, timestamp: afterMidnight),
    ]);

    // Restarted store instance reads persisted data
    final store2 = TelemetryHistoryStore(nowProvider: () => asOf);
    final reloaded = await store2.loadSgHistory();
    final range = await store2.loadTargetRange();

    expect(reloaded.length, 3);
    final streak = TimeInRangeService.computeInRangeStreak(
      readings: reloaded,
      range: range,
      asOf: asOf,
    );
    expect(streak.status, StreakStatus.inRange);
    expect(streak.duration.inMinutes, 15);
  });

  test('Insufficient data returns unavailable metrics gracefully', () {
    final now = DateTime.utc(2026, 11, 17, 12, 0);
    final emptySummary = TimeInRangeService.computeWindowMetrics(
      readings: const [],
      period: TirPeriod.h24,
      asOf: now,
    );
    expect(emptySummary.hasSufficientData, isFalse);
    expect(emptySummary.inRangePercent, isNull);

    final emptyStreak = TimeInRangeService.computeInRangeStreak(
      readings: const [],
      asOf: now,
    );
    expect(emptyStreak.status, StreakStatus.insufficientData);
  });

  test('Custom target range updates TIR, TBR, TAR and streak evaluation accurately',
      () {
    final t0 = DateTime.utc(2026, 11, 17, 14, 0);
    final readings = [
      SgReading(sg: 75, timestamp: t0),
      SgReading(sg: 120, timestamp: t0.add(const Duration(minutes: 5))),
      SgReading(sg: 160, timestamp: t0.add(const Duration(minutes: 10))),
      SgReading(sg: 170, timestamp: t0.add(const Duration(minutes: 15))),
    ];
    const customRange = TargetRangeConfig(lowMgDl: 80, highMgDl: 160);

    final summary = TimeInRangeService.computeWindowMetrics(
      readings: readings,
      period: TirPeriod.h24,
      range: customRange,
      asOf: t0.add(const Duration(minutes: 15)),
    );

    // Covered = 15m: [0..5] half 75 (2.5m below) + half 120 (2.5m in),
    // [5..10] 120..160 (5m in), [10..15] half 160 (2.5m in) + half 170 (2.5m above)
    expect(summary.coveredDuration.inMinutes, 15);
    expect(summary.belowRangePercent!, closeTo((2.5 / 15.0) * 100.0, 0.2));
    expect(summary.inRangePercent!, closeTo((10.0 / 15.0) * 100.0, 0.2));
    expect(summary.aboveRangePercent!, closeTo((2.5 / 15.0) * 100.0, 0.2));

    final streakAt170 = TimeInRangeService.computeInRangeStreak(
      readings: readings,
      range: customRange,
      asOf: t0.add(const Duration(minutes: 16)),
    );
    expect(streakAt170.status, StreakStatus.outOfRange);
  });
}
