import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:health/health.dart';
import 'package:minimed_pixel_bridge/models/pump_telemetry.dart';
import 'package:minimed_pixel_bridge/services/health_connect_service.dart';
import 'package:minimed_pixel_bridge/services/notification_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FakeHealthConnectGateway implements HealthConnectGateway {
  @override
  String get ownPackageName => 'com.minimed.bridge.minimed_pixel_bridge';

  bool available = true;
  bool glucoseWriteGranted = true;
  bool glucoseReadGranted = true;
  bool nutritionWriteGranted = true;
  bool nutritionReadGranted = true;
  Set<HealthDataType> grantedFitbitTypes = {
    HealthDataType.WORKOUT,
    HealthDataType.HEART_RATE,
    HealthDataType.STEPS,
  };

  bool failNextGlucoseWrite = false;
  Object? throwOnWrite;

  final List<({double mgDl, DateTime timestamp, String clientRecordId, double version})>
      writtenGlucose = [];
  final List<({double carbs, DateTime startTime, String clientRecordId, double version})>
      writtenMeals = [];
  List<HealthDataPoint> existingHealthPoints = [];

  @override
  Future<void> ensureConfigured() async {}

  @override
  Future<bool> isAvailable() async => available;

  @override
  Future<void> installHealthConnect() async {}

  @override
  Future<bool?> hasPermissions(
    List<HealthDataType> types, {
    List<HealthDataAccess>? permissions,
  }) async {
    for (int i = 0; i < types.length; i++) {
      final t = types[i];
      final access =
          permissions != null ? permissions[i] : HealthDataAccess.READ;
      if (t == HealthDataType.BLOOD_GLUCOSE) {
        if (access == HealthDataAccess.WRITE && !glucoseWriteGranted) {
          return false;
        }
        if (access == HealthDataAccess.READ && !glucoseReadGranted) {
          return false;
        }
        if (access == HealthDataAccess.READ_WRITE &&
            (!glucoseWriteGranted || !glucoseReadGranted)) {
          return false;
        }
      } else if (t == HealthDataType.NUTRITION) {
        if (access == HealthDataAccess.WRITE && !nutritionWriteGranted) {
          return false;
        }
        if (access == HealthDataAccess.READ && !nutritionReadGranted) {
          return false;
        }
        if (access == HealthDataAccess.READ_WRITE &&
            (!nutritionWriteGranted || !nutritionReadGranted)) {
          return false;
        }
      } else {
        if (!grantedFitbitTypes.contains(t)) return false;
      }
    }
    return true;
  }

  @override
  Future<bool> requestAuthorization(
    List<HealthDataType> types, {
    List<HealthDataAccess>? permissions,
  }) async =>
      true;

  @override
  Future<bool> isHealthDataInBackgroundAuthorized() async => true;

  @override
  Future<bool> requestHealthDataInBackgroundAuthorization() async => true;

  @override
  Future<List<HealthDataPoint>> getHealthDataFromTypes({
    required List<HealthDataType> types,
    required DateTime startTime,
    required DateTime endTime,
  }) async {
    return existingHealthPoints
        .where((p) =>
            types.contains(p.type) &&
            !p.dateFrom.isBefore(startTime) &&
            !p.dateFrom.isAfter(endTime))
        .toList();
  }

  @override
  Future<int?> getTotalStepsInInterval(
      DateTime startTime, DateTime endTime) async {
    return grantedFitbitTypes.contains(HealthDataType.STEPS) ? 6420 : null;
  }

  @override
  Future<bool> writeGlucose({
    required double mgDl,
    required DateTime timestamp,
    required String clientRecordId,
    required double clientRecordVersion,
  }) async {
    if (throwOnWrite != null) throw throwOnWrite!;
    if (failNextGlucoseWrite) return false;
    writtenGlucose.add((
      mgDl: mgDl,
      timestamp: timestamp,
      clientRecordId: clientRecordId,
      version: clientRecordVersion,
    ));
    return true;
  }

  @override
  Future<bool> writeMeal({
    required double carbsGrams,
    required DateTime startTime,
    required DateTime endTime,
    required String name,
    required String clientRecordId,
    required double clientRecordVersion,
  }) async {
    writtenMeals.add((
      carbs: carbsGrams,
      startTime: startTime,
      clientRecordId: clientRecordId,
      version: clientRecordVersion,
    ));
    return true;
  }
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('Glucose writes succeed even when NUTRITION permission is denied',
      () async {
    final now = DateTime.utc(2026, 11, 17, 19, 30);
    final gateway = FakeHealthConnectGateway()
      ..glucoseWriteGranted = true
      ..nutritionWriteGranted = false;

    final service = HealthConnectService(
      gateway: gateway,
      nowProvider: () => now,
    );

    final telemetry = PumpTelemetry(
      sgValue: 138,
      sgDateTime: now.subtract(const Duration(minutes: 2)),
      sgTrend: 'NONE',
      sgOrigin: TelemetryOrigin.carelink,
      activeInsulin: 1.5,
      reservoirRemaining: 140,
      pumpBatteryPercent: 85,
      sgHistory: [
        SgReading(
          sg: 132,
          timestamp: now.subtract(const Duration(minutes: 7)),
          origin: TelemetryOrigin.carelink,
        ),
        SgReading(
          sg: 138,
          timestamp: now.subtract(const Duration(minutes: 2)),
          origin: TelemetryOrigin.carelink,
        ),
      ],
      mealMarkers: [
        MealMarker(
          carbsGrams: 40,
          timestamp: now.subtract(const Duration(minutes: 15)),
          origin: TelemetryOrigin.carelink,
        ),
      ],
      bolusMarkers: const [],
      dataSource: 'CareLink EU',
    );

    final result = await service.syncTelemetryToHealthConnect(telemetry);
    expect(result.status, HealthSyncStatus.completed);
    expect(result.glucoseWriteGranted, isTrue);
    expect(result.nutritionWriteGranted, isFalse);
    expect(result.sgWrittenCount, 2);
    expect(result.mealsWrittenCount, 0);
    expect(gateway.writtenGlucose.length, 2);
    expect(gateway.writtenGlucose.first.version, 1.0);
    expect(gateway.writtenGlucose.first.clientRecordId, startsWith('mm780g_sg_'));
    expect(result.pendingCount, 1); // meal stays pending cleanly
  });

  test('External app reading in the same minute does NOT cause false duplicate skip',
      () async {
    final now = DateTime.utc(2026, 11, 17, 19, 30);
    final readingTime = now.subtract(const Duration(minutes: 2));
    final gateway = FakeHealthConnectGateway();

    // Another app wrote a blood glucose reading in the exact same minute
    gateway.existingHealthPoints = [
      HealthDataPoint(
        uuid: 'other_app_1',
        value: NumericHealthValue(numericValue: 140),
        type: HealthDataType.BLOOD_GLUCOSE,
        unit: HealthDataUnit.MILLIGRAM_PER_DECILITER,
        dateFrom: readingTime,
        dateTo: readingTime,
        sourcePlatform: HealthPlatformType.googleHealthConnect,
        sourceDeviceId: 'dev',
        sourceId: 'other',
        sourceName: 'com.other.cgm.app',
      ),
    ];

    final service = HealthConnectService(
      gateway: gateway,
      nowProvider: () => now,
    );

    final telemetry = PumpTelemetry(
      sgValue: 142,
      sgDateTime: readingTime,
      sgTrend: 'NONE',
      sgOrigin: TelemetryOrigin.carelink,
      activeInsulin: null,
      reservoirRemaining: null,
      pumpBatteryPercent: null,
      sgHistory: [
        SgReading(
          sg: 142,
          timestamp: readingTime,
          origin: TelemetryOrigin.carelink,
        ),
      ],
      mealMarkers: const [],
      bolusMarkers: const [],
      dataSource: 'CareLink EU',
    );

    final result = await service.syncTelemetryToHealthConnect(telemetry);
    expect(result.sgWrittenCount, 1);
    expect(result.skippedDuplicates, 0);

    // Re-syncing the exact same telemetry MUST deduplicate properly now
    final secondRun = await service.syncTelemetryToHealthConnect(telemetry);
    expect(secondRun.sgWrittenCount, 0);
    expect(secondRun.status, HealthSyncStatus.duplicate);
    expect(secondRun.skippedDuplicates, 1);
    expect(gateway.writtenGlucose.length, 1);
  });

  test('Failed write keeps reading in pending queue across restart and recovers later',
      () async {
    final now = DateTime.utc(2026, 11, 17, 19, 30);
    final readingTime = now.subtract(const Duration(minutes: 3));
    final gateway = FakeHealthConnectGateway()..failNextGlucoseWrite = true;

    final firstService = HealthConnectService(
      gateway: gateway,
      nowProvider: () => now,
    );

    final telemetry = PumpTelemetry(
      sgValue: 164,
      sgDateTime: readingTime,
      sgTrend: 'UP',
      sgOrigin: TelemetryOrigin.notification,
      activeInsulin: null,
      reservoirRemaining: null,
      pumpBatteryPercent: null,
      sgHistory: [
        SgReading(
          sg: 164,
          timestamp: readingTime,
          origin: TelemetryOrigin.notification,
        ),
      ],
      mealMarkers: const [],
      bolusMarkers: const [],
      dataSource: 'MiniMed Notif.',
    );

    final failResult =
        await firstService.syncTelemetryToHealthConnect(telemetry);
    expect(failResult.status, HealthSyncStatus.apiFailure);
    expect(failResult.sgWrittenCount, 0);
    expect(failResult.pendingCount, 1);

    // Simulate app restart with new service instance & empty telemetry passed
    gateway.failNextGlucoseWrite = false;
    final restartedService = HealthConnectService(
      gateway: gateway,
      nowProvider: () => now.add(const Duration(minutes: 5)),
    );

    final recoveryResult = await restartedService
        .syncTelemetryToHealthConnect(PumpTelemetry.empty());
    expect(recoveryResult.status, HealthSyncStatus.completed);
    expect(recoveryResult.sgWrittenCount, 1);
    expect(recoveryResult.pendingCount, 0);
    expect(gateway.writtenGlucose.single.mgDl, 164.0);
  });

  test('Never re-inserts HealthConnect-origin glucose readings back into Health Connect',
      () async {
    final now = DateTime.utc(2026, 11, 17, 19, 30);
    final gateway = FakeHealthConnectGateway();
    final service = HealthConnectService(
      gateway: gateway,
      nowProvider: () => now,
    );

    final hcReadBack = PumpTelemetry(
      sgValue: 112,
      sgDateTime: now.subtract(const Duration(minutes: 4)),
      sgTrend: 'NONE',
      sgOrigin: TelemetryOrigin.healthConnect,
      activeInsulin: null,
      reservoirRemaining: null,
      pumpBatteryPercent: null,
      sgHistory: [
        SgReading(
          sg: 112,
          timestamp: now.subtract(const Duration(minutes: 4)),
          origin: TelemetryOrigin.healthConnect,
        ),
      ],
      mealMarkers: const [],
      bolusMarkers: const [],
      dataSource: 'Health Connect',
    );

    final res = await service.syncTelemetryToHealthConnect(hcReadBack);
    expect(res.sgWrittenCount, 0);
    expect(res.status, HealthSyncStatus.noNewData);
    expect(gateway.writtenGlucose, isEmpty);
  });

  test('Partial Fitbit authorization loads authorized metrics cleanly without failing',
      () async {
    final now = DateTime.utc(2026, 11, 17, 19, 30);
    final gateway = FakeHealthConnectGateway()
      ..grantedFitbitTypes = {HealthDataType.STEPS, HealthDataType.HEART_RATE};
    gateway.existingHealthPoints = [
      HealthDataPoint(
        uuid: 'hr1',
        value: NumericHealthValue(numericValue: 74),
        type: HealthDataType.HEART_RATE,
        unit: HealthDataUnit.BEATS_PER_MINUTE,
        dateFrom: now.subtract(const Duration(minutes: 5)),
        dateTo: now.subtract(const Duration(minutes: 5)),
        sourcePlatform: HealthPlatformType.googleHealthConnect,
        sourceDeviceId: 'fitbit',
        sourceId: 'fitbit',
        sourceName: 'com.fitbit.FitbitMobile',
      ),
    ];

    final service = HealthConnectService(
      gateway: gateway,
      nowProvider: () => now,
    );

    final metrics = await service.fetchFitbitMetrics24h();
    expect(metrics.authorized, isTrue);
    expect(metrics.isPartialAuthorization, isTrue);
    expect(metrics.grantedTypeCount, 2);
    expect(metrics.steps24h, 6420);
    expect(metrics.latestHeartRate, 74);
  });

  test('Headless background merge of local Notification/Accessibility history syncs to Health Connect',
      () async {
    final now = DateTime.now();
    final t1 = now.subtract(const Duration(minutes: 10)).millisecondsSinceEpoch;
    final t2 = now.subtract(const Duration(minutes: 5)).millisecondsSinceEpoch;

    final localState = {
      'sgValue': 148,
      'sgTrend': 'UP',
      'lastTimestampMs': t2,
      'sourceBadge': '780G Notif',
      'localSgHistoryJson': jsonEncode([
        {'sg': 140, 'ts': t1, 'src': 'notification'},
        {'sg': 148, 'ts': t2, 'src': 'notification'},
      ]),
    };

    final merged = NotificationService.mergeLocalBridgeState(
      PumpTelemetry.empty(),
      localState,
      now: now,
    );

    final gateway = FakeHealthConnectGateway();
    final service = HealthConnectService(
      gateway: gateway,
      nowProvider: () => now,
    );

    final result = await service.syncTelemetryToHealthConnect(
      merged,
      requestPermissionIfMissing: false,
    );

    expect(result.status, HealthSyncStatus.completed);
    expect(result.sgWrittenCount, 2);
    expect(gateway.writtenGlucose.map((e) => e.mgDl).toList(), [140.0, 148.0]);
  });
}
