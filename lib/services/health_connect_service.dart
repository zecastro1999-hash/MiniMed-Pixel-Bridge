import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:health/health.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/pump_telemetry.dart';
import 'sport_prediction_service.dart';

enum HealthSyncStatus {
  completed('Sincronização concluída'),
  noNewData('Sem dados novos'),
  permissionDenied('Permissão negada'),
  duplicate('Registo duplicado'),
  invalidData('Dado inválido'),
  apiFailure('Falha da API Health Connect'),
  networkFailure('Falha de rede'),
  unavailable('Health Connect indisponível');

  final String labelPt;
  const HealthSyncStatus(this.labelPt);
}

class HealthSyncResult {
  final HealthSyncStatus status;
  final int sgWrittenCount;
  final int mealsWrittenCount;
  final int skippedDuplicates;
  final int invalidCount;
  final int pendingCount;
  final int failedCount;
  final bool glucoseWriteGranted;
  final bool nutritionWriteGranted;
  final bool healthConnectAvailable;
  final int? lastWrittenSg;
  final DateTime? lastWrittenAt;
  final bool? verifiedInHealthConnect;
  final String message;
  final String? errorDetail;

  const HealthSyncResult({
    required this.status,
    required this.sgWrittenCount,
    required this.mealsWrittenCount,
    required this.skippedDuplicates,
    this.invalidCount = 0,
    this.pendingCount = 0,
    this.failedCount = 0,
    required this.glucoseWriteGranted,
    required this.nutritionWriteGranted,
    this.healthConnectAvailable = true,
    this.lastWrittenSg,
    this.lastWrittenAt,
    this.verifiedInHealthConnect,
    required this.message,
    this.errorDetail,
  });

  bool get authorized => glucoseWriteGranted;
}

class SyncDiagnosticsSnapshot {
  final bool healthConnectAvailable;
  final bool glucoseWriteGranted;
  final bool glucoseReadGranted;
  final bool nutritionWriteGranted;
  final bool fitbitReadGranted;
  final int grantedFitbitCount;
  final bool backgroundReadGranted;
  final int? lastReceivedSg;
  final DateTime? lastReceivedSgAt;
  final int? lastSyncedSg;
  final DateTime? lastSyncedSgAt;
  final int pendingCount;
  final String? lastError;
  final HealthSyncStatus? lastStatus;
  final DateTime? lastBackgroundSyncAt;
  final String? lastBackgroundOutcome;

  const SyncDiagnosticsSnapshot({
    this.healthConnectAvailable = false,
    this.glucoseWriteGranted = false,
    this.glucoseReadGranted = false,
    this.nutritionWriteGranted = false,
    this.fitbitReadGranted = false,
    this.grantedFitbitCount = 0,
    this.backgroundReadGranted = false,
    this.lastReceivedSg,
    this.lastReceivedSgAt,
    this.lastSyncedSg,
    this.lastSyncedSgAt,
    this.pendingCount = 0,
    this.lastError,
    this.lastStatus,
    this.lastBackgroundSyncAt,
    this.lastBackgroundOutcome,
  });
}

/// Abstract Health Connect backend for testability without native channels.
abstract class HealthConnectGateway {
  String get ownPackageName;
  Future<void> ensureConfigured();
  Future<bool> isAvailable();
  Future<void> installHealthConnect();
  Future<bool?> hasPermissions(
    List<HealthDataType> types, {
    List<HealthDataAccess>? permissions,
  });
  Future<bool> requestAuthorization(
    List<HealthDataType> types, {
    List<HealthDataAccess>? permissions,
  });
  Future<bool> isHealthDataInBackgroundAuthorized();
  Future<bool> requestHealthDataInBackgroundAuthorization();
  Future<List<HealthDataPoint>> getHealthDataFromTypes({
    required List<HealthDataType> types,
    required DateTime startTime,
    required DateTime endTime,
  });
  Future<int?> getTotalStepsInInterval(DateTime startTime, DateTime endTime);
  Future<bool> writeGlucose({
    required double mgDl,
    required DateTime timestamp,
    required String clientRecordId,
    required double clientRecordVersion,
  });
  Future<bool> writeMeal({
    required double carbsGrams,
    required DateTime startTime,
    required DateTime endTime,
    required String name,
    required String clientRecordId,
    required double clientRecordVersion,
  });
}

class PluginHealthConnectGateway implements HealthConnectGateway {
  static const String androidPackageName =
      'com.minimed.bridge.minimed_pixel_bridge';

  final Health _health = Health();
  bool _configured = false;

  @override
  String get ownPackageName => androidPackageName;

  @override
  Future<void> ensureConfigured() async {
    if (!_configured) {
      await _health.configure();
      _configured = true;
    }
  }

  @override
  Future<bool> isAvailable() async {
    await ensureConfigured();
    return _health.isHealthConnectAvailable();
  }

  @override
  Future<void> installHealthConnect() async {
    await ensureConfigured();
    await _health.installHealthConnect();
  }

  @override
  Future<bool?> hasPermissions(
    List<HealthDataType> types, {
    List<HealthDataAccess>? permissions,
  }) async {
    await ensureConfigured();
    return _health.hasPermissions(types, permissions: permissions);
  }

  @override
  Future<bool> requestAuthorization(
    List<HealthDataType> types, {
    List<HealthDataAccess>? permissions,
  }) async {
    await ensureConfigured();
    return _health.requestAuthorization(types, permissions: permissions);
  }

  @override
  Future<bool> isHealthDataInBackgroundAuthorized() async {
    await ensureConfigured();
    return _health.isHealthDataInBackgroundAuthorized();
  }

  @override
  Future<bool> requestHealthDataInBackgroundAuthorization() async {
    await ensureConfigured();
    return _health.requestHealthDataInBackgroundAuthorization();
  }

  @override
  Future<List<HealthDataPoint>> getHealthDataFromTypes({
    required List<HealthDataType> types,
    required DateTime startTime,
    required DateTime endTime,
  }) async {
    await ensureConfigured();
    final raw = await _health.getHealthDataFromTypes(
      types: types,
      startTime: startTime,
      endTime: endTime,
    );
    return _health.removeDuplicates(raw);
  }

  @override
  Future<int?> getTotalStepsInInterval(DateTime startTime, DateTime endTime) {
    return _health.getTotalStepsInInterval(startTime, endTime);
  }

  @override
  Future<bool> writeGlucose({
    required double mgDl,
    required DateTime timestamp,
    required String clientRecordId,
    required double clientRecordVersion,
  }) async {
    await ensureConfigured();
    return _health.writeHealthData(
      value: mgDl,
      type: HealthDataType.BLOOD_GLUCOSE,
      unit: HealthDataUnit.MILLIGRAM_PER_DECILITER,
      startTime: timestamp,
      endTime: timestamp,
      clientRecordId: clientRecordId,
      clientRecordVersion: clientRecordVersion,
      recordingMethod: RecordingMethod.automatic,
    );
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
    await ensureConfigured();
    return _health.writeMeal(
      mealType: MealType.UNKNOWN,
      startTime: startTime,
      endTime: endTime,
      carbohydrates: carbsGrams,
      name: name,
      clientRecordId: clientRecordId,
      clientRecordVersion: clientRecordVersion,
      recordingMethod: RecordingMethod.automatic,
    );
  }
}

class HealthConnectService {
  static const String _prefConfirmedSgIds = 'hc_confirmed_sg_ids_v2';
  static const String _prefConfirmedMealIds = 'hc_confirmed_meal_ids_v2';
  static const String _prefPendingSgQueue = 'hc_pending_sg_queue_v2';
  static const String _prefPendingMealQueue = 'hc_pending_meal_queue_v2';
  static const String _prefLastReceivedSg = 'hc_diag_last_received_sg';
  static const String _prefLastReceivedAt = 'hc_diag_last_received_at';
  static const String _prefLastSyncedSg = 'hc_diag_last_synced_sg';
  static const String _prefLastSyncedAt = 'hc_diag_last_synced_at';
  static const String _prefLastSyncError = 'hc_diag_last_error';
  static const String _prefLastSyncStatus = 'hc_diag_last_status';
  static const String _prefLastBgSyncAt = 'hc_diag_last_bg_sync_at';
  static const String _prefLastBgSyncOutcome = 'hc_diag_last_bg_outcome';
  static const String _prefFitbitAuthCached = 'hc_fitbit_auth_cached';
  static const String _prefFitbitMetricsCache = 'hc_fitbit_cached_metrics';

  static const List<HealthDataType> fitbitReadTypes = [
    HealthDataType.WORKOUT,
    HealthDataType.ACTIVE_ENERGY_BURNED,
    HealthDataType.TOTAL_CALORIES_BURNED,
    HealthDataType.HEART_RATE,
    HealthDataType.RESTING_HEART_RATE,
    HealthDataType.STEPS,
    HealthDataType.SLEEP_SESSION,
  ];

  static const List<HealthDataType> allRequestedTypes = [
    HealthDataType.BLOOD_GLUCOSE,
    HealthDataType.NUTRITION,
    HealthDataType.WORKOUT,
    HealthDataType.ACTIVE_ENERGY_BURNED,
    HealthDataType.TOTAL_CALORIES_BURNED,
    HealthDataType.HEART_RATE,
    HealthDataType.RESTING_HEART_RATE,
    HealthDataType.STEPS,
    HealthDataType.SLEEP_SESSION,
  ];

  static const List<HealthDataAccess> allRequestedPermissions = [
    HealthDataAccess.READ_WRITE,
    HealthDataAccess.READ_WRITE,
    HealthDataAccess.READ,
    HealthDataAccess.READ,
    HealthDataAccess.READ,
    HealthDataAccess.READ,
    HealthDataAccess.READ,
    HealthDataAccess.READ,
    HealthDataAccess.READ,
  ];

  final HealthConnectGateway _gateway;
  final Future<SharedPreferences?> Function() _prefsProvider;
  final DateTime Function() _nowProvider;

  HealthConnectService({
    HealthConnectGateway? gateway,
    Future<SharedPreferences?> Function()? prefsProvider,
    DateTime Function()? nowProvider,
  })  : _gateway = gateway ?? PluginHealthConnectGateway(),
        _prefsProvider = prefsProvider ?? _defaultPrefs,
        _nowProvider = nowProvider ?? DateTime.now;

  static Future<SharedPreferences?> _defaultPrefs() async {
    try {
      return await SharedPreferences.getInstance();
    } catch (_) {
      return null;
    }
  }

  /// Generates a deterministic `clientRecordId` incorporating origin, timestamp,
  /// and optional upstream identifier so Health Connect upsert/dedup stays
  /// accurate even when other apps write in the same minute.
  static String stableGlucoseRecordId(SgReading reading) {
    final epochSec = reading.timestamp.toUtc().millisecondsSinceEpoch ~/ 1000;
    final cleanSource = (reading.sourceId ?? '')
        .replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '')
        .trim();
    if (cleanSource.isNotEmpty) {
      return 'mm780g_sg_${reading.origin.name}_${epochSec}_$cleanSource';
    }
    return 'mm780g_sg_${reading.origin.name}_$epochSec';
  }

  static String stableMealRecordId(MealMarker meal) {
    final epochSec = meal.timestamp.toUtc().millisecondsSinceEpoch ~/ 1000;
    final carbsInt = (meal.carbsGrams * 10).round();
    final cleanSource = (meal.sourceId ?? '')
        .replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '')
        .trim();
    if (cleanSource.isNotEmpty) {
      return 'mm780g_meal_${meal.origin.name}_${epochSec}_${carbsInt}_$cleanSource';
    }
    return 'mm780g_meal_${meal.origin.name}_${epochSec}_$carbsInt';
  }

  Future<bool> isAvailable() async {
    try {
      return await _gateway.isAvailable();
    } catch (e) {
      debugPrint('HealthConnectService.isAvailable error: ${e.runtimeType}');
      return false;
    }
  }

  Future<bool> hasGlucoseWritePermission() async {
    try {
      if (!await _gateway.isAvailable()) return false;
      final ok = await _gateway.hasPermissions(
        const [HealthDataType.BLOOD_GLUCOSE],
        permissions: const [HealthDataAccess.WRITE],
      );
      return ok ?? false;
    } catch (e) {
      debugPrint('hasGlucoseWritePermission error: ${e.runtimeType}');
      return false;
    }
  }

  Future<bool> hasGlucoseReadPermission() async {
    try {
      if (!await _gateway.isAvailable()) return false;
      final ok = await _gateway.hasPermissions(
        const [HealthDataType.BLOOD_GLUCOSE],
        permissions: const [HealthDataAccess.READ],
      );
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<bool> hasNutritionWritePermission() async {
    try {
      if (!await _gateway.isAvailable()) return false;
      final ok = await _gateway.hasPermissions(
        const [HealthDataType.NUTRITION],
        permissions: const [HealthDataAccess.WRITE],
      );
      return ok ?? false;
    } catch (e) {
      debugPrint('hasNutritionWritePermission error: ${e.runtimeType}');
      return false;
    }
  }

  Future<bool> hasNutritionReadPermission() async {
    try {
      if (!await _gateway.isAvailable()) return false;
      final ok = await _gateway.hasPermissions(
        const [HealthDataType.NUTRITION],
        permissions: const [HealthDataAccess.READ],
      );
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<bool> hasWritePermissions() => hasGlucoseWritePermission();

  Future<List<HealthDataType>> getGrantedFitbitTypes() async {
    try {
      if (!await _gateway.isAvailable()) return const [];
      final checks = await Future.wait(
        fitbitReadTypes.map((type) async {
          try {
            final ok = await _gateway.hasPermissions(
              [type],
              permissions: const [HealthDataAccess.READ],
            );
            return ok == true ? type : null;
          } catch (_) {
            return null;
          }
        }),
      );
      return checks.whereType<HealthDataType>().toList();
    } catch (_) {
      return const [];
    }
  }

  Future<bool> requestPermissions() async {
    try {
      final available = await _gateway.isAvailable();
      if (!available) {
        await _gateway.installHealthConnect();
        return false;
      }

      await _gateway.requestAuthorization(
        allRequestedTypes,
        permissions: allRequestedPermissions,
      );

      final glucoseOk = await hasGlucoseWritePermission();
      final nutritionOk = await hasNutritionWritePermission();
      final fitbitTypes = await getGrantedFitbitTypes();
      await _saveFitbitAuthCache(fitbitTypes.isNotEmpty);
      return glucoseOk || nutritionOk || fitbitTypes.isNotEmpty;
    } catch (e) {
      debugPrint('requestPermissions error: ${e.runtimeType}');
      return false;
    }
  }

  Future<bool> requestGlucoseWritePermissionOnly() async {
    try {
      final available = await _gateway.isAvailable();
      if (!available) {
        await _gateway.installHealthConnect();
        return false;
      }
      await _gateway.requestAuthorization(
        const [HealthDataType.BLOOD_GLUCOSE],
        permissions: const [HealthDataAccess.READ_WRITE],
      );
      return await hasGlucoseWritePermission();
    } catch (_) {
      return false;
    }
  }

  Future<bool> requestBackgroundReadPermission() async {
    try {
      if (!await _gateway.isAvailable()) return false;
      return await _gateway.requestHealthDataInBackgroundAuthorization();
    } catch (_) {
      return false;
    }
  }

  Future<bool> isBackgroundReadGranted() async {
    try {
      if (!await _gateway.isAvailable()) return false;
      return await _gateway.isHealthDataInBackgroundAuthorized();
    } catch (_) {
      return false;
    }
  }

  Future<FitbitHealthMetrics?> loadCachedFitbitMetrics() async {
    try {
      final prefs = await _prefsProvider();
      final authCached = prefs?.getBool(_prefFitbitAuthCached) ?? false;
      if (!authCached) return null;
      return FitbitHealthMetrics.decode(
        prefs?.getString(_prefFitbitMetricsCache),
      );
    } catch (_) {
      return null;
    }
  }

  Future<bool> getCachedFitbitAuthorized() async {
    try {
      final prefs = await _prefsProvider();
      return prefs?.getBool(_prefFitbitAuthCached) ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<void> _saveFitbitAuthCache(
    bool granted, {
    FitbitHealthMetrics? metrics,
  }) async {
    try {
      final prefs = await _prefsProvider();
      if (prefs == null) return;
      await prefs.setBool(_prefFitbitAuthCached, granted);
      if (!granted) {
        await prefs.remove(_prefFitbitMetricsCache);
      } else if (metrics != null) {
        await prefs.setString(_prefFitbitMetricsCache, metrics.encode());
      }
    } catch (_) {}
  }

  Future<FitbitHealthMetrics> fetchFitbitMetrics24h({
    bool requestPermissionIfMissing = false,
  }) async {
    try {
      final available = await _gateway.isAvailable();
      if (!available) {
        return const FitbitHealthMetrics(
          authorized: false,
          errorMessage: 'Health Connect indisponível neste dispositivo.',
        );
      }

      var grantedTypes = await getGrantedFitbitTypes();
      if (grantedTypes.isEmpty && requestPermissionIfMissing) {
        await requestPermissions();
        grantedTypes = await getGrantedFitbitTypes();
      }

      if (grantedTypes.isEmpty) {
        final wasCached = await getCachedFitbitAuthorized();
        await _saveFitbitAuthCache(false);
        return FitbitHealthMetrics(
          authorized: false,
          grantedTypeCount: 0,
          totalRequestedTypeCount: fitbitReadTypes.length,
          permissionsRevoked: wasCached,
          errorMessage: wasCached
              ? 'As permissões Fitbit no Health Connect foram revogadas.'
              : 'Autoriza acesso ao exercício, frequência cardíaca, calorias, passos e sono no Health Connect.',
        );
      }

      final now = _nowProvider();
      final startTime = now.subtract(const Duration(hours: 24));

      final points = await _gateway.getHealthDataFromTypes(
        types: grantedTypes,
        startTime: startTime,
        endTime: now,
      );

      final List<HealthDataPoint> hrPoints = [];
      final List<HealthDataPoint> restingHrPoints = [];
      final List<HealthDataPoint> activeEnergyPoints = [];
      final List<HealthDataPoint> workoutPoints = [];

      double activeCaloriesSum = 0.0;
      bool hasActiveCalories = false;
      double totalCaloriesSum = 0.0;
      bool hasTotalCalories = false;
      int stepsSum = 0;
      bool hasSteps = false;
      int sleepMinutesSum = 0;
      bool hasSleep = false;

      for (final point in points) {
        switch (point.type) {
          case HealthDataType.WORKOUT:
            workoutPoints.add(point);
            break;
          case HealthDataType.ACTIVE_ENERGY_BURNED:
            activeEnergyPoints.add(point);
            final val = _extractNumericValue(point);
            if (val != null && val > 0) {
              activeCaloriesSum += val;
              hasActiveCalories = true;
            }
            break;
          case HealthDataType.TOTAL_CALORIES_BURNED:
            final val = _extractNumericValue(point);
            if (val != null && val > 0) {
              totalCaloriesSum += val;
              hasTotalCalories = true;
            }
            break;
          case HealthDataType.HEART_RATE:
            hrPoints.add(point);
            break;
          case HealthDataType.RESTING_HEART_RATE:
            restingHrPoints.add(point);
            break;
          case HealthDataType.STEPS:
            final val = _extractNumericValue(point);
            if (val != null && val > 0) {
              stepsSum += val.round();
              hasSteps = true;
            }
            break;
          case HealthDataType.SLEEP_SESSION:
            final numericMins = _extractNumericValue(point);
            final durationMins =
                point.dateTo.difference(point.dateFrom).inMinutes;
            final mins = (numericMins != null && numericMins > 0)
                ? numericMins.round()
                : (durationMins > 0 ? durationMins : 0);
            if (mins > 0) {
              sleepMinutesSum += mins;
              hasSleep = true;
            }
            break;
          default:
            break;
        }
      }

      if (grantedTypes.contains(HealthDataType.STEPS)) {
        try {
          final intervalSteps =
              await _gateway.getTotalStepsInInterval(startTime, now);
          if (intervalSteps != null && intervalSteps > 0) {
            stepsSum = intervalSteps;
            hasSteps = true;
          }
        } catch (_) {}
      }

      hrPoints.sort((a, b) => a.dateTo.compareTo(b.dateTo));
      restingHrPoints.sort((a, b) => a.dateTo.compareTo(b.dateTo));

      final int? latestHr = hrPoints.isNotEmpty
          ? _extractNumericValue(hrPoints.last)?.round()
          : null;
      final int? restingHr = restingHrPoints.isNotEmpty
          ? _extractNumericValue(restingHrPoints.last)?.round()
          : null;

      final List<FitbitWorkoutSummary> workouts = [];
      for (final wp in workoutPoints) {
        final wv = wp.value;
        if (wv is! WorkoutHealthValue) continue;

        double activeKcal = (wv.totalEnergyBurned ?? 0).toDouble();
        if (activeKcal <= 0) {
          for (final ap in activeEnergyPoints) {
            if (_overlaps(ap.dateFrom, ap.dateTo, wp.dateFrom, wp.dateTo)) {
              activeKcal += _extractNumericValue(ap) ?? 0.0;
            }
          }
        }

        final windowHrValues = <double>[];
        for (final hp in hrPoints) {
          if (_overlaps(
            hp.dateFrom,
            hp.dateTo,
            wp.dateFrom.subtract(const Duration(minutes: 2)),
            wp.dateTo.add(const Duration(minutes: 2)),
          )) {
            final hrVal = _extractNumericValue(hp);
            if (hrVal != null && hrVal > 0) {
              windowHrValues.add(hrVal);
            }
          }
        }
        final double? avgHr = windowHrValues.isNotEmpty
            ? windowHrValues.reduce((a, b) => a + b) / windowHrValues.length
            : null;

        workouts.add(
          FitbitWorkoutSummary(
            activityType: wv.workoutActivityType,
            activeKcal: activeKcal,
            avgHr: avgHr ?? 0.0,
            startTime: wp.dateFrom,
            endTime: wp.dateTo,
          ),
        );
      }

      workouts.sort((a, b) => b.endTime.compareTo(a.endTime));

      final metrics = FitbitHealthMetrics(
        workouts24h: workouts,
        activeCalories24h: hasActiveCalories ? activeCaloriesSum : null,
        totalCalories24h: hasTotalCalories ? totalCaloriesSum : null,
        latestHeartRate: latestHr,
        latestHeartRateAt: hrPoints.isNotEmpty ? hrPoints.last.dateTo : null,
        restingHeartRate: restingHr,
        steps24h: hasSteps ? stepsSum : null,
        sleepMinutes24h: hasSleep ? sleepMinutesSum : null,
        fetchedAt: now,
        authorized: true,
        grantedTypeCount: grantedTypes.length,
        totalRequestedTypeCount: fitbitReadTypes.length,
      );
      await _saveFitbitAuthCache(true, metrics: metrics);
      return metrics;
    } catch (e) {
      final lowerErr = e.toString().toLowerCase();
      final isAuthError = lowerErr.contains('securityexception') ||
          lowerErr.contains('permission') ||
          lowerErr.contains('unauthorized');
      if (isAuthError) {
        await _saveFitbitAuthCache(false);
        return const FitbitHealthMetrics(
          authorized: false,
          permissionsRevoked: true,
          errorMessage:
              'Permissões Fitbit revogadas ou expiradas no Health Connect.',
        );
      }

      final cached = await loadCachedFitbitMetrics();
      if (cached != null) {
        return FitbitHealthMetrics(
          workouts24h: cached.workouts24h,
          activeCalories24h: cached.activeCalories24h,
          totalCalories24h: cached.totalCalories24h,
          latestHeartRate: cached.latestHeartRate,
          latestHeartRateAt: cached.latestHeartRateAt,
          restingHeartRate: cached.restingHeartRate,
          steps24h: cached.steps24h,
          sleepMinutes24h: cached.sleepMinutes24h,
          fetchedAt: cached.fetchedAt,
          authorized: true,
          grantedTypeCount: cached.grantedTypeCount,
          totalRequestedTypeCount: cached.totalRequestedTypeCount,
          errorMessage: 'Leitura em cache (falha temporária).',
        );
      }

      return FitbitHealthMetrics(
        authorized: false,
        errorMessage: 'Erro ao ler dados Fitbit do Health Connect.',
      );
    }
  }

  static double? _extractNumericValue(HealthDataPoint point) {
    final val = point.value;
    if (val is NumericHealthValue) {
      return val.numericValue.toDouble();
    }
    return null;
  }

  static bool _overlaps(
    DateTime aStart,
    DateTime aEnd,
    DateTime bStart,
    DateTime bEnd,
  ) {
    return !aEnd.isBefore(bStart) && !aStart.isAfter(bEnd);
  }

  /// Synchronizes eligible glucose readings and nutrition meals to Google Health
  /// Connect using **independent per-type permissions**, persistent pending retry
  /// queues, `clientRecordId` + `clientRecordVersion: 1.0`, and strict origin
  /// filtering so external apps never block writes and Health Connect data is never
  /// re-inserted.
  Future<HealthSyncResult> syncTelemetryToHealthConnect(
    PumpTelemetry telemetry, {
    bool requestPermissionIfMissing = false,
  }) async {
    final prefs = await _prefsProvider();
    final now = _nowProvider();

    // Always track latest non-HC glucose received for Sync Diagnostics
    if (telemetry.sgValue != null &&
        telemetry.sgValue! >= 20 &&
        telemetry.sgValue! <= 600 &&
        telemetry.sgOrigin != TelemetryOrigin.healthConnect) {
      await prefs?.setInt(_prefLastReceivedSg, telemetry.sgValue!);
      await prefs?.setString(
        _prefLastReceivedAt,
        (telemetry.sgDateTime ?? now).toUtc().toIso8601String(),
      );
    }

    // Build incoming glucose candidates (excluding any data read FROM Health Connect!)
    final confirmedSgIds =
        (prefs?.getStringList(_prefConfirmedSgIds) ?? <String>[]).toSet();
    final confirmedMealIds =
        (prefs?.getStringList(_prefConfirmedMealIds) ?? <String>[]).toSet();

    final pendingSgQueue = _loadPendingSgQueue(prefs);
    final pendingMealQueue = _loadPendingMealQueue(prefs);

    int invalidCount = 0;
    int skippedDuplicates = 0;
    final seenIncomingSgIds = <String>{};
    final seenIncomingMealIds = <String>{};

    final incomingReadings = <SgReading>[
      ...telemetry.sgHistory.where(
        (r) =>
            r.origin != TelemetryOrigin.healthConnect &&
            r.timestamp.isAfter(now.subtract(const Duration(hours: 24))),
      ),
      if (telemetry.sgValue != null &&
          telemetry.sgDateTime != null &&
          telemetry.sgOrigin != TelemetryOrigin.healthConnect)
        SgReading(
          sg: telemetry.sgValue!,
          timestamp: telemetry.sgDateTime!,
          origin: telemetry.sgOrigin == TelemetryOrigin.unknown
              ? TelemetryOrigin.fromString(telemetry.dataSource)
              : telemetry.sgOrigin,
        ),
    ];

    for (final r in incomingReadings) {
      if (!r.isValidAt(now)) {
        invalidCount++;
        continue;
      }
      final recordId = stableGlucoseRecordId(r);
      if (!seenIncomingSgIds.add(recordId)) continue;
      if (confirmedSgIds.contains(recordId)) {
        skippedDuplicates++;
        continue;
      }
      if (!pendingSgQueue.containsKey(recordId)) {
        pendingSgQueue[recordId] = r;
      }
    }

    for (final meal in telemetry.mealMarkers) {
      if (meal.origin == TelemetryOrigin.healthConnect) continue;
      if (!meal.isValidAt(now)) {
        invalidCount++;
        continue;
      }
      if (meal.timestamp.isBefore(now.subtract(const Duration(hours: 24)))) {
        continue;
      }
      final recordId = stableMealRecordId(meal);
      if (!seenIncomingMealIds.add(recordId)) continue;
      if (confirmedMealIds.contains(recordId)) {
        skippedDuplicates++;
        continue;
      }
      if (!pendingMealQueue.containsKey(recordId)) {
        pendingMealQueue[recordId] = meal;
      }
    }

    // Check Health Connect availability
    bool available = false;
    try {
      available = await _gateway.isAvailable();
    } catch (_) {
      available = false;
    }

    if (!available) {
      await _savePendingSgQueue(prefs, pendingSgQueue);
      await _savePendingMealQueue(prefs, pendingMealQueue);
      final totalPending = pendingSgQueue.length + pendingMealQueue.length;
      const err = 'Google Health Connect indisponível neste dispositivo.';
      await _saveDiagOutcome(
        prefs,
        status: HealthSyncStatus.unavailable,
        pendingCount: totalPending,
        error: err,
      );
      return HealthSyncResult(
        status: HealthSyncStatus.unavailable,
        sgWrittenCount: 0,
        mealsWrittenCount: 0,
        skippedDuplicates: 0,
        invalidCount: invalidCount,
        pendingCount: totalPending,
        glucoseWriteGranted: false,
        nutritionWriteGranted: false,
        healthConnectAvailable: false,
        message: err,
        errorDetail: err,
      );
    }

    // Independent permission checks: glucose writing NEVER depends on nutrition permission!
    var glucoseWriteGranted = await hasGlucoseWritePermission();
    var nutritionWriteGranted = await hasNutritionWritePermission();

    if ((!glucoseWriteGranted || !nutritionWriteGranted) &&
        requestPermissionIfMissing) {
      await requestPermissions();
      glucoseWriteGranted = await hasGlucoseWritePermission();
      nutritionWriteGranted = await hasNutritionWritePermission();
    }

    if (!glucoseWriteGranted && !nutritionWriteGranted) {
      await _savePendingSgQueue(prefs, pendingSgQueue);
      await _savePendingMealQueue(prefs, pendingMealQueue);
      final totalPending = pendingSgQueue.length + pendingMealQueue.length;
      const err =
          'Permissão de escrita no Health Connect negada (glicose e refeições).';
      await _saveDiagOutcome(
        prefs,
        status: HealthSyncStatus.permissionDenied,
        pendingCount: totalPending,
        error: err,
      );
      return HealthSyncResult(
        status: HealthSyncStatus.permissionDenied,
        sgWrittenCount: 0,
        mealsWrittenCount: 0,
        skippedDuplicates: 0,
        invalidCount: invalidCount,
        pendingCount: totalPending,
        glucoseWriteGranted: false,
        nutritionWriteGranted: false,
        message: err,
        errorDetail: err,
      );
    }

    // Build existing OWN-APP record set if read permission exists (NEVER match other apps!)
    final Set<int> ownAppSgEpochSecs = {};
    final Set<int> ownAppMealEpochSecs = {};
    if (glucoseWriteGranted && await hasGlucoseReadPermission()) {
      try {
        final existingGlucose = await _gateway.getHealthDataFromTypes(
          types: const [HealthDataType.BLOOD_GLUCOSE],
          startTime: now.subtract(const Duration(hours: 25)),
          endTime: now.add(const Duration(minutes: 5)),
        );
        for (final p in existingGlucose) {
          if (p.sourceName == _gateway.ownPackageName) {
            ownAppSgEpochSecs.add(p.dateFrom.toUtc().millisecondsSinceEpoch ~/ 1000);
          }
        }
      } catch (e) {
        debugPrint('Glucose read-back skipped: ${e.runtimeType}');
      }
    }
    if (nutritionWriteGranted && await hasNutritionReadPermission()) {
      try {
        final existingMeals = await _gateway.getHealthDataFromTypes(
          types: const [HealthDataType.NUTRITION],
          startTime: now.subtract(const Duration(hours: 25)),
          endTime: now.add(const Duration(minutes: 5)),
        );
        for (final p in existingMeals) {
          if (p.sourceName == _gateway.ownPackageName) {
            ownAppMealEpochSecs.add(p.dateFrom.toUtc().millisecondsSinceEpoch ~/ 1000);
          }
        }
      } catch (e) {
        debugPrint('Nutrition read-back skipped: ${e.runtimeType}');
      }
    }

    int sgWritten = 0;
    int mealsWritten = 0;
    int failedCount = 0;
    String? lastError;
    HealthSyncStatus? failureStatus;
    int? lastWrittenSg;
    DateTime? lastWrittenAt;

    // 1. Write Blood Glucose entries (completely independent from Nutrition permission!)
    if (glucoseWriteGranted) {
      final sortedEntries = pendingSgQueue.entries.toList()
        ..sort((a, b) => a.value.timestamp.compareTo(b.value.timestamp));

      for (final entry in sortedEntries) {
        final recordId = entry.key;
        final reading = entry.value;
        final epochSec = reading.timestamp.toUtc().millisecondsSinceEpoch ~/ 1000;

        if (confirmedSgIds.contains(recordId) ||
            ownAppSgEpochSecs.contains(epochSec)) {
          confirmedSgIds.add(recordId);
          pendingSgQueue.remove(recordId);
          skippedDuplicates++;
          continue;
        }

        try {
          final ok = await _gateway.writeGlucose(
            mgDl: reading.sg.toDouble(),
            timestamp: reading.timestamp,
            clientRecordId: recordId,
            clientRecordVersion: 1.0,
          );
          if (ok) {
            confirmedSgIds.add(recordId);
            pendingSgQueue.remove(recordId);
            sgWritten++;
            lastWrittenSg = reading.sg;
            lastWrittenAt = reading.timestamp;
          } else {
            failedCount++;
            failureStatus ??= HealthSyncStatus.apiFailure;
            lastError ??=
                'Health Connect devolveu false ao gravar glicemia (${reading.sg} mg/dL).';
          }
        } catch (e) {
          failedCount++;
          final classified = _classifyException(e);
          failureStatus ??= classified.$1;
          lastError ??= classified.$2;
        }
      }
    } else if (pendingSgQueue.isNotEmpty) {
      failureStatus ??= HealthSyncStatus.permissionDenied;
      lastError ??= 'Permissão de escrita de glicose negada.';
    }

    // 2. Write Nutrition entries independently (NEVER blocks glucose!)
    if (nutritionWriteGranted) {
      final sortedMeals = pendingMealQueue.entries.toList()
        ..sort((a, b) => a.value.timestamp.compareTo(b.value.timestamp));

      for (final entry in sortedMeals) {
        final recordId = entry.key;
        final meal = entry.value;
        final epochSec = meal.timestamp.toUtc().millisecondsSinceEpoch ~/ 1000;

        if (confirmedMealIds.contains(recordId) ||
            ownAppMealEpochSecs.contains(epochSec)) {
          confirmedMealIds.add(recordId);
          pendingMealQueue.remove(recordId);
          skippedDuplicates++;
          continue;
        }

        try {
          final ok = await _gateway.writeMeal(
            carbsGrams: meal.carbsGrams,
            startTime: meal.timestamp,
            endTime: meal.timestamp.add(const Duration(minutes: 1)),
            name: 'MiniMed 780G (${meal.carbsGrams.round()}g hidratos)',
            clientRecordId: recordId,
            clientRecordVersion: 1.0,
          );
          if (ok) {
            confirmedMealIds.add(recordId);
            pendingMealQueue.remove(recordId);
            mealsWritten++;
          } else {
            failedCount++;
            failureStatus ??= HealthSyncStatus.apiFailure;
            lastError ??= 'Health Connect devolveu false ao gravar refeição.';
          }
        } catch (e) {
          failedCount++;
          final classified = _classifyException(e);
          failureStatus ??= classified.$1;
          lastError ??= classified.$2;
        }
      }
    }

    // Persist confirmed sets & pending queues AFTER confirmation
    if (prefs != null) {
      final sgList = confirmedSgIds.toList();
      final mealList = confirmedMealIds.toList();
      await prefs.setStringList(
        _prefConfirmedSgIds,
        sgList.length > 800 ? sgList.sublist(sgList.length - 800) : sgList,
      );
      await prefs.setStringList(
        _prefConfirmedMealIds,
        mealList.length > 500
            ? mealList.sublist(mealList.length - 500)
            : mealList,
      );
      await _savePendingSgQueue(prefs, pendingSgQueue);
      await _savePendingMealQueue(prefs, pendingMealQueue);
    }

    if (lastWrittenSg != null && lastWrittenAt != null) {
      await prefs?.setInt(_prefLastSyncedSg, lastWrittenSg);
      await prefs?.setString(
        _prefLastSyncedAt,
        lastWrittenAt.toUtc().toIso8601String(),
      );
    }

    final totalPending = pendingSgQueue.length + pendingMealQueue.length;
    final HealthSyncStatus finalStatus;
    final String message;

    if (sgWritten > 0 || mealsWritten > 0) {
      finalStatus = HealthSyncStatus.completed;
      final extra = !nutritionWriteGranted
          ? ' (escrita de refeições sem permissão)'
          : (failedCount > 0 ? ' ($failedCount pendente(s))' : '');
      message = '$sgWritten glicose(s) e $mealsWritten refeição(ões) gravadas$extra.';
    } else if (failureStatus != null) {
      finalStatus = failureStatus;
      message = lastError ?? failureStatus.labelPt;
    } else if (skippedDuplicates > 0 && invalidCount == 0) {
      finalStatus = HealthSyncStatus.duplicate;
      message = 'Sem novos registos ($skippedDuplicates duplicado(s) ignorados).';
    } else if (invalidCount > 0 && pendingSgQueue.isEmpty) {
      finalStatus = HealthSyncStatus.invalidData;
      message = '$invalidCount registo(s) inválido(s) ignorados.';
    } else {
      finalStatus = HealthSyncStatus.noNewData;
      message = 'Sem dados novos para sincronizar.';
    }

    await _saveDiagOutcome(
      prefs,
      status: finalStatus,
      pendingCount: totalPending,
      error: failureStatus != null ? lastError : null,
      clearError: failureStatus == null && (sgWritten > 0 || mealsWritten > 0),
    );

    return HealthSyncResult(
      status: finalStatus,
      sgWrittenCount: sgWritten,
      mealsWrittenCount: mealsWritten,
      skippedDuplicates: skippedDuplicates,
      invalidCount: invalidCount,
      pendingCount: totalPending,
      failedCount: failedCount,
      glucoseWriteGranted: glucoseWriteGranted,
      nutritionWriteGranted: nutritionWriteGranted,
      lastWrittenSg: lastWrittenSg,
      lastWrittenAt: lastWrittenAt,
      message: message,
      errorDetail: lastError,
    );
  }

  /// Diagnostics action for Settings ("Testar sincronização"):
  /// Synchronizes a real eligible reading (never invents fake clinical records)
  /// and optionally verifies read-back when `READ_BLOOD_GLUCOSE` is granted.
  Future<HealthSyncResult> testSynchronization({
    PumpTelemetry? currentTelemetry,
  }) async {
    final prefs = await _prefsProvider();
    final available = await isAvailable();
    if (!available) {
      return const HealthSyncResult(
        status: HealthSyncStatus.unavailable,
        sgWrittenCount: 0,
        mealsWrittenCount: 0,
        skippedDuplicates: 0,
        glucoseWriteGranted: false,
        nutritionWriteGranted: false,
        healthConnectAvailable: false,
        message: 'Google Health Connect não está instalado/disponível.',
      );
    }

    final glucoseWriteGranted = await hasGlucoseWritePermission();
    final nutritionWriteGranted = await hasNutritionWritePermission();
    if (!glucoseWriteGranted) {
      return HealthSyncResult(
        status: HealthSyncStatus.permissionDenied,
        sgWrittenCount: 0,
        mealsWrittenCount: 0,
        skippedDuplicates: 0,
        glucoseWriteGranted: false,
        nutritionWriteGranted: nutritionWriteGranted,
        message: 'Permissão para escrever glicose não concedida no Health Connect.',
      );
    }

    // 1. Flush real pending items first if available
    if (currentTelemetry != null) {
      final syncRes = await syncTelemetryToHealthConnect(
        currentTelemetry,
        requestPermissionIfMissing: false,
      );
      if (syncRes.sgWrittenCount > 0 || syncRes.failedCount > 0) {
        return syncRes;
      }
    }

    // 2. Otherwise verify upsert on the latest real non-HC reading
    final pendingMap = _loadPendingSgQueue(prefs);
    SgReading? realCandidate =
        pendingMap.values.isNotEmpty ? pendingMap.values.last : null;

    if (realCandidate == null &&
        currentTelemetry != null &&
        currentTelemetry.sgValue != null &&
        currentTelemetry.sgDateTime != null &&
        currentTelemetry.sgOrigin != TelemetryOrigin.healthConnect) {
      realCandidate = SgReading(
        sg: currentTelemetry.sgValue!,
        timestamp: currentTelemetry.sgDateTime!,
        origin: currentTelemetry.sgOrigin == TelemetryOrigin.unknown
            ? TelemetryOrigin.carelink
            : currentTelemetry.sgOrigin,
      );
    }

    if (realCandidate == null && currentTelemetry != null) {
      final validHistory = currentTelemetry.sgHistory
          .where((r) =>
              r.origin != TelemetryOrigin.healthConnect &&
              r.isValidAt(_nowProvider()))
          .toList();
      if (validHistory.isNotEmpty) {
        realCandidate = validHistory.last;
      }
    }

    if (realCandidate == null || !realCandidate.isValidAt(_nowProvider())) {
      return HealthSyncResult(
        status: HealthSyncStatus.noNewData,
        sgWrittenCount: 0,
        mealsWrittenCount: 0,
        skippedDuplicates: 0,
        glucoseWriteGranted: glucoseWriteGranted,
        nutritionWriteGranted: nutritionWriteGranted,
        message:
            'Sem leituras reais elegíveis disponíveis para testar (não foram criados registos fictícios).',
      );
    }

    final recordId = stableGlucoseRecordId(realCandidate);
    try {
      final ok = await _gateway.writeGlucose(
        mgDl: realCandidate.sg.toDouble(),
        timestamp: realCandidate.timestamp,
        clientRecordId: recordId,
        clientRecordVersion: 1.0,
      );
      if (!ok) {
        const err = 'Falha da API: writeHealthData devolveu false.';
        await _saveDiagOutcome(
          prefs,
          status: HealthSyncStatus.apiFailure,
          pendingCount: pendingMap.length,
          error: err,
        );
        return HealthSyncResult(
          status: HealthSyncStatus.apiFailure,
          sgWrittenCount: 0,
          mealsWrittenCount: 0,
          skippedDuplicates: 0,
          failedCount: 1,
          pendingCount: pendingMap.length,
          glucoseWriteGranted: glucoseWriteGranted,
          nutritionWriteGranted: nutritionWriteGranted,
          message: err,
          errorDetail: err,
        );
      }

      // Mark confirmed cleanly now that write succeeded
      final confirmed =
          (prefs?.getStringList(_prefConfirmedSgIds) ?? <String>[]).toSet();
      confirmed.add(recordId);
      await prefs?.setStringList(_prefConfirmedSgIds, confirmed.toList());
      pendingMap.remove(recordId);
      await _savePendingSgQueue(prefs, pendingMap);

      await prefs?.setInt(_prefLastSyncedSg, realCandidate.sg);
      await prefs?.setString(
        _prefLastSyncedAt,
        realCandidate.timestamp.toUtc().toIso8601String(),
      );

      bool? verified;
      if (await hasGlucoseReadPermission()) {
        try {
          final check = await _gateway.getHealthDataFromTypes(
            types: const [HealthDataType.BLOOD_GLUCOSE],
            startTime:
                realCandidate.timestamp.subtract(const Duration(minutes: 2)),
            endTime: realCandidate.timestamp.add(const Duration(minutes: 2)),
          );
          verified = check.any(
            (p) =>
                p.sourceName == _gateway.ownPackageName &&
                ((_extractNumericValue(p) ?? -1) - realCandidate!.sg).abs() < 1,
          );
        } catch (_) {
          verified = null;
        }
      }

      await _saveDiagOutcome(
        prefs,
        status: HealthSyncStatus.completed,
        pendingCount: pendingMap.length,
        clearError: true,
      );

      final verifyLabel = verified == true
          ? ' (verificado no histórico Health Connect)'
          : '';
      return HealthSyncResult(
        status: HealthSyncStatus.completed,
        sgWrittenCount: 1,
        mealsWrittenCount: 0,
        skippedDuplicates: 0,
        pendingCount: pendingMap.length,
        glucoseWriteGranted: glucoseWriteGranted,
        nutritionWriteGranted: nutritionWriteGranted,
        lastWrittenSg: realCandidate.sg,
        lastWrittenAt: realCandidate.timestamp,
        verifiedInHealthConnect: verified,
        message:
            'Leitura real (${realCandidate.sg} mg/dL) sincronizada com sucesso$verifyLabel.',
      );
    } catch (e) {
      final classified = _classifyException(e);
      await _saveDiagOutcome(
        prefs,
        status: classified.$1,
        pendingCount: pendingMap.length,
        error: classified.$2,
      );
      return HealthSyncResult(
        status: classified.$1,
        sgWrittenCount: 0,
        mealsWrittenCount: 0,
        skippedDuplicates: 0,
        failedCount: 1,
        pendingCount: pendingMap.length,
        glucoseWriteGranted: glucoseWriteGranted,
        nutritionWriteGranted: nutritionWriteGranted,
        message: classified.$2,
        errorDetail: classified.$2,
      );
    }
  }

  Future<void> recordBackgroundSyncAttempt(String outcome) async {
    final prefs = await _prefsProvider();
    if (prefs == null) return;
    await prefs.setString(
      _prefLastBgSyncAt,
      _nowProvider().toUtc().toIso8601String(),
    );
    await prefs.setString(_prefLastBgSyncOutcome, outcome);
  }

  Future<SyncDiagnosticsSnapshot> loadDiagnosticsSnapshot() async {
    final prefs = await _prefsProvider();
    final available = await isAvailable();
    final glucoseWrite = available ? await hasGlucoseWritePermission() : false;
    final glucoseRead = available ? await hasGlucoseReadPermission() : false;
    final nutritionWrite =
        available ? await hasNutritionWritePermission() : false;
    final fitbitTypes = available ? await getGrantedFitbitTypes() : const [];
    final bgRead = available ? await isBackgroundReadGranted() : false;

    final pendingSg = _loadPendingSgQueue(prefs);
    final pendingMeals = _loadPendingMealQueue(prefs);
    final lastStatusName = prefs?.getString(_prefLastSyncStatus);
    HealthSyncStatus? lastStatus;
    for (final s in HealthSyncStatus.values) {
      if (s.name == lastStatusName) lastStatus = s;
    }

    return SyncDiagnosticsSnapshot(
      healthConnectAvailable: available,
      glucoseWriteGranted: glucoseWrite,
      glucoseReadGranted: glucoseRead,
      nutritionWriteGranted: nutritionWrite,
      fitbitReadGranted: fitbitTypes.isNotEmpty,
      grantedFitbitCount: fitbitTypes.length,
      backgroundReadGranted: bgRead,
      lastReceivedSg: prefs?.getInt(_prefLastReceivedSg),
      lastReceivedSgAt: prefs?.getString(_prefLastReceivedAt) != null
          ? DateTime.tryParse(prefs!.getString(_prefLastReceivedAt)!)
          : null,
      lastSyncedSg: prefs?.getInt(_prefLastSyncedSg),
      lastSyncedSgAt: prefs?.getString(_prefLastSyncedAt) != null
          ? DateTime.tryParse(prefs!.getString(_prefLastSyncedAt)!)
          : null,
      pendingCount: pendingSg.length + pendingMeals.length,
      lastError: prefs?.getString(_prefLastSyncError),
      lastStatus: lastStatus,
      lastBackgroundSyncAt: prefs?.getString(_prefLastBgSyncAt) != null
          ? DateTime.tryParse(prefs!.getString(_prefLastBgSyncAt)!)
          : null,
      lastBackgroundOutcome: prefs?.getString(_prefLastBgSyncOutcome),
    );
  }

  static (HealthSyncStatus, String) _classifyException(Object e) {
    final lower = e.toString().toLowerCase();
    if (lower.contains('securityexception') ||
        lower.contains('permission') ||
        lower.contains('unauthorized')) {
      return (
        HealthSyncStatus.permissionDenied,
        'Permissão negada pelo Android Health Connect.'
      );
    }
    if (lower.contains('socket') ||
        lower.contains('network') ||
        lower.contains('timeout')) {
      return (HealthSyncStatus.networkFailure, 'Erro de ligação durante sincronização.');
    }
    if (lower.contains('argument') || lower.contains('invalid')) {
      return (HealthSyncStatus.invalidData, 'Dado rejeitado por formato inválido.');
    }
    return (HealthSyncStatus.apiFailure, 'Falha na API Health Connect: $e');
  }

  Map<String, SgReading> _loadPendingSgQueue(SharedPreferences? prefs) {
    final result = <String, SgReading>{};
    final raw = prefs?.getString(_prefPendingSgQueue);
    if (raw == null || raw.isEmpty) return result;
    try {
      final map = Map<String, dynamic>.from(jsonDecode(raw) as Map);
      map.forEach((key, val) {
        if (val is Map) {
          result[key] = SgReading.fromJson(Map<String, dynamic>.from(val));
        }
      });
    } catch (_) {}
    return result;
  }

  Future<void> _savePendingSgQueue(
    SharedPreferences? prefs,
    Map<String, SgReading> queue,
  ) async {
    if (prefs == null) return;
    final entries = queue.entries.toList()
      ..sort((a, b) => a.value.timestamp.compareTo(b.value.timestamp));
    final trimmed = entries.length > 300
        ? entries.sublist(entries.length - 300)
        : entries;
    final encoded = <String, dynamic>{
      for (final e in trimmed) e.key: e.value.toJson(),
    };
    await prefs.setString(_prefPendingSgQueue, jsonEncode(encoded));
  }

  Map<String, MealMarker> _loadPendingMealQueue(SharedPreferences? prefs) {
    final result = <String, MealMarker>{};
    final raw = prefs?.getString(_prefPendingMealQueue);
    if (raw == null || raw.isEmpty) return result;
    try {
      final map = Map<String, dynamic>.from(jsonDecode(raw) as Map);
      map.forEach((key, val) {
        if (val is Map) {
          result[key] = MealMarker.fromJson(Map<String, dynamic>.from(val));
        }
      });
    } catch (_) {}
    return result;
  }

  Future<void> _savePendingMealQueue(
    SharedPreferences? prefs,
    Map<String, MealMarker> queue,
  ) async {
    if (prefs == null) return;
    final entries = queue.entries.toList()
      ..sort((a, b) => a.value.timestamp.compareTo(b.value.timestamp));
    final trimmed = entries.length > 100
        ? entries.sublist(entries.length - 100)
        : entries;
    final encoded = <String, dynamic>{
      for (final e in trimmed) e.key: e.value.toJson(),
    };
    await prefs.setString(_prefPendingMealQueue, jsonEncode(encoded));
  }

  Future<void> _saveDiagOutcome(
    SharedPreferences? prefs, {
    required HealthSyncStatus status,
    required int pendingCount,
    String? error,
    bool clearError = false,
  }) async {
    if (prefs == null) return;
    await prefs.setString(_prefLastSyncStatus, status.name);
    if (clearError) {
      await prefs.remove(_prefLastSyncError);
    } else if (error != null) {
      await prefs.setString(_prefLastSyncError, error);
    }
  }
}

/// Extension keeping duration calculation clean for Sport metrics.
extension WorkoutDurationExt on FitbitWorkoutSummary {
  int get safeDurationMinutes => math.max(1, durationMinutes);
}
