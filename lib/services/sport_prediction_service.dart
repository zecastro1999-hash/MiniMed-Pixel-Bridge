import 'dart:convert';
import 'dart:math' as math;
import 'package:health/health.dart';
import '../models/pump_telemetry.dart';
import 'glucose_prediction_service.dart';
import 'telemetry_history_store.dart';

enum SportBucket {
  cardio,
  strength,
  mixed,
  none,
}

enum SportActivityState {
  active('Treino em curso'),
  recovery('Recuperação'),
  none('Sem treino');

  final String labelPt;
  const SportActivityState(this.labelPt);
}

enum SportRiskLevel {
  stable('Glicose estável'),
  falling('Glicose a descer'),
  elevatedDropRisk('Possível aumento do risco de descida'),
  insufficientData('Dados insuficientes para avaliar');

  final String labelPt;
  const SportRiskLevel(this.labelPt);
}

class FitbitWorkoutSummary {
  final HealthWorkoutActivityType activityType;
  final double activeKcal;
  final double avgHr;
  final DateTime startTime;
  final DateTime endTime;
  final bool isOngoingManual;

  const FitbitWorkoutSummary({
    required this.activityType,
    required this.activeKcal,
    required this.avgHr,
    required this.startTime,
    required this.endTime,
    this.isOngoingManual = false,
  });

  int get durationMinutes =>
      math.max(1, endTime.difference(startTime).inMinutes);

  String get displayActivityName =>
      workoutDisplayNamePt(activityType);

  static String workoutDisplayNamePt(HealthWorkoutActivityType type) {
    switch (type) {
      case HealthWorkoutActivityType.RUNNING:
      case HealthWorkoutActivityType.RUNNING_TREADMILL:
        return 'Corrida';
      case HealthWorkoutActivityType.BIKING:
      case HealthWorkoutActivityType.BIKING_STATIONARY:
        return 'Ciclismo';
      case HealthWorkoutActivityType.SWIMMING:
      case HealthWorkoutActivityType.SWIMMING_OPEN_WATER:
      case HealthWorkoutActivityType.SWIMMING_POOL:
        return 'Natação';
      case HealthWorkoutActivityType.WALKING:
      case HealthWorkoutActivityType.WALKING_TREADMILL:
        return 'Caminhada';
      case HealthWorkoutActivityType.HIKING:
        return 'Caminhada / Trilho';
      case HealthWorkoutActivityType.STRENGTH_TRAINING:
      case HealthWorkoutActivityType.TRADITIONAL_STRENGTH_TRAINING:
      case HealthWorkoutActivityType.FUNCTIONAL_STRENGTH_TRAINING:
      case HealthWorkoutActivityType.WEIGHTLIFTING:
      case HealthWorkoutActivityType.CALISTHENICS:
        return 'Musculação';
      case HealthWorkoutActivityType.TENNIS:
        return 'Ténis';
      case HealthWorkoutActivityType.BADMINTON:
        return 'Badminton';
      case HealthWorkoutActivityType.TABLE_TENNIS:
        return 'Ténis de Mesa';
      case HealthWorkoutActivityType.SQUASH:
        return 'Squash';
      case HealthWorkoutActivityType.ROWING:
      case HealthWorkoutActivityType.ROWING_MACHINE:
        return 'Remo';
      case HealthWorkoutActivityType.SAILING:
        return 'Vela';
      case HealthWorkoutActivityType.HIGH_INTENSITY_INTERVAL_TRAINING:
      case HealthWorkoutActivityType.CROSS_TRAINING:
        return 'HIIT / Cross-Training';
      case HealthWorkoutActivityType.ELLIPTICAL:
        return 'Elíptica';
      case HealthWorkoutActivityType.STAIR_CLIMBING:
      case HealthWorkoutActivityType.STAIR_CLIMBING_MACHINE:
        return 'Escadas';
      case HealthWorkoutActivityType.YOGA:
        return 'Yoga';
      case HealthWorkoutActivityType.PILATES:
        return 'Pilates';
      case HealthWorkoutActivityType.CARDIO_DANCE:
      case HealthWorkoutActivityType.DANCING:
        return 'Dança';
      case HealthWorkoutActivityType.BASKETBALL:
        return 'Basquetebol';
      case HealthWorkoutActivityType.VOLLEYBALL:
        return 'Voleibol';
      case HealthWorkoutActivityType.OTHER:
        return 'Outro exercício';
      default:
        return type.name
            .toLowerCase()
            .split('_')
            .map((w) => w.isEmpty ? '' : '${w[0].toUpperCase()}${w.substring(1)}')
            .join(' ');
    }
  }
}

class FitbitHealthMetrics {
  final List<FitbitWorkoutSummary> workouts24h;
  final double? activeCalories24h;
  final double? totalCalories24h;
  final int? latestHeartRate;
  final DateTime? latestHeartRateAt;
  final int? restingHeartRate;
  final int? steps24h;
  final int? sleepMinutes24h;
  final DateTime? fetchedAt;
  final bool authorized;
  final int grantedTypeCount;
  final int totalRequestedTypeCount;
  final bool permissionsRevoked;
  final String? errorMessage;

  const FitbitHealthMetrics({
    this.workouts24h = const [],
    this.activeCalories24h,
    this.totalCalories24h,
    this.latestHeartRate,
    this.latestHeartRateAt,
    this.restingHeartRate,
    this.steps24h,
    this.sleepMinutes24h,
    this.fetchedAt,
    this.authorized = false,
    this.grantedTypeCount = 0,
    this.totalRequestedTypeCount = 7,
    this.permissionsRevoked = false,
    this.errorMessage,
  });

  bool get hasAnyData =>
      workouts24h.isNotEmpty ||
      activeCalories24h != null ||
      totalCalories24h != null ||
      latestHeartRate != null ||
      restingHeartRate != null ||
      steps24h != null ||
      sleepMinutes24h != null;

  bool get isPartialAuthorization =>
      authorized &&
      grantedTypeCount > 0 &&
      grantedTypeCount < totalRequestedTypeCount;

  FitbitWorkoutSummary? get latestWorkout {
    if (workouts24h.isEmpty) return null;
    final sorted = List<FitbitWorkoutSummary>.from(workouts24h)
      ..sort((a, b) => b.endTime.compareTo(a.endTime));
    return sorted.first;
  }

  int? recentHeartRateAt(DateTime now) {
    if (latestHeartRate == null || latestHeartRateAt == null) return null;
    if (now.difference(latestHeartRateAt!) > const Duration(minutes: 25)) {
      return null;
    }
    return latestHeartRate;
  }

  String get sleepFormatted {
    if (sleepMinutes24h == null || sleepMinutes24h! <= 0) return '--';
    final h = sleepMinutes24h! ~/ 60;
    final m = sleepMinutes24h! % 60;
    return '${h}h ${m.toString().padLeft(2, '0')}m';
  }

  Map<String, dynamic> toJson() => {
        'workouts24h': workouts24h
            .map((w) => {
                  'activityType': w.activityType.name,
                  'activeKcal': w.activeKcal,
                  'avgHr': w.avgHr,
                  'startTime': w.startTime.toUtc().toIso8601String(),
                  'endTime': w.endTime.toUtc().toIso8601String(),
                })
            .toList(),
        if (activeCalories24h != null) 'activeCalories24h': activeCalories24h,
        if (totalCalories24h != null) 'totalCalories24h': totalCalories24h,
        if (latestHeartRate != null) 'latestHeartRate': latestHeartRate,
        if (latestHeartRateAt != null)
          'latestHeartRateAt': latestHeartRateAt!.toUtc().toIso8601String(),
        if (restingHeartRate != null) 'restingHeartRate': restingHeartRate,
        if (steps24h != null) 'steps24h': steps24h,
        if (sleepMinutes24h != null) 'sleepMinutes24h': sleepMinutes24h,
        if (fetchedAt != null) 'fetchedAt': fetchedAt!.toUtc().toIso8601String(),
        'authorized': authorized,
        'grantedTypeCount': grantedTypeCount,
        'totalRequestedTypeCount': totalRequestedTypeCount,
      };

  static FitbitHealthMetrics? decode(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final json = Map<String, dynamic>.from(jsonDecode(raw) as Map);
      final rawWorkouts = json['workouts24h'] as List<dynamic>? ?? [];
      final workouts = <FitbitWorkoutSummary>[];
      for (final item in rawWorkouts) {
        if (item is! Map) continue;
        final w = Map<String, dynamic>.from(item);
        final typeName = w['activityType']?.toString() ?? 'OTHER';
        final activity = HealthWorkoutActivityType.values.firstWhere(
          (e) => e.name == typeName,
          orElse: () => HealthWorkoutActivityType.OTHER,
        );
        final start = DateTime.tryParse(w['startTime']?.toString() ?? '');
        final end = DateTime.tryParse(w['endTime']?.toString() ?? '');
        if (start == null || end == null) continue;
        workouts.add(
          FitbitWorkoutSummary(
            activityType: activity,
            activeKcal: (w['activeKcal'] as num?)?.toDouble() ?? 0.0,
            avgHr: (w['avgHr'] as num?)?.toDouble() ?? 0.0,
            startTime: start,
            endTime: end,
          ),
        );
      }
      return FitbitHealthMetrics(
        workouts24h: workouts,
        activeCalories24h: (json['activeCalories24h'] as num?)?.toDouble(),
        totalCalories24h: (json['totalCalories24h'] as num?)?.toDouble(),
        latestHeartRate: (json['latestHeartRate'] as num?)?.toInt(),
        latestHeartRateAt: json['latestHeartRateAt'] != null
            ? DateTime.tryParse(json['latestHeartRateAt'].toString())
            : null,
        restingHeartRate: (json['restingHeartRate'] as num?)?.toInt(),
        steps24h: (json['steps24h'] as num?)?.toInt(),
        sleepMinutes24h: (json['sleepMinutes24h'] as num?)?.toInt(),
        fetchedAt: DateTime.tryParse(json['fetchedAt']?.toString() ?? ''),
        authorized: json['authorized'] == true,
        grantedTypeCount: (json['grantedTypeCount'] as num?)?.toInt() ?? 0,
        totalRequestedTypeCount:
            (json['totalRequestedTypeCount'] as num?)?.toInt() ?? 7,
      );
    } catch (_) {
      return null;
    }
  }

  String encode() => jsonEncode(toJson());
}

class SportEvaluationResult {
  final SportActivityState state;
  final SportRiskLevel riskLevel;
  final SportBucket bucket;
  final FitbitWorkoutSummary? activeOrRecoveryWorkout;
  final Duration? activeElapsed;
  final Duration? timeSinceWorkoutEnded;
  final int? availableHeartRateBpm;
  final String? glucoseTrendLabel;
  final String summaryTextPt;
  final List<String> contributingFactors;
  final String experimentalDisclaimer;

  const SportEvaluationResult({
    required this.state,
    required this.riskLevel,
    required this.bucket,
    this.activeOrRecoveryWorkout,
    this.activeElapsed,
    this.timeSinceWorkoutEnded,
    this.availableHeartRateBpm,
    this.glucoseTrendLabel,
    required this.summaryTextPt,
    this.contributingFactors = const [],
    this.experimentalDisclaimer =
        'Aviso experimental: esta avaliação não recomenda doses de insulina nem hidratos e não substitui os alertas certificados da MiniMed 780G.',
  });

  bool get isExerciseActiveOrRecovery =>
      state == SportActivityState.active || state == SportActivityState.recovery;
}

class SportPredictionService {
  static const Duration activeGraceWindow = Duration(minutes: 5);
  static const Duration recoveryMaxWindow = Duration(hours: 6);
  static const Duration manualActiveMaxCap = Duration(hours: 8);

  static const List<HealthWorkoutActivityType> supportedManualTypes = [
    HealthWorkoutActivityType.RUNNING,
    HealthWorkoutActivityType.BIKING,
    HealthWorkoutActivityType.SWIMMING_POOL,
    HealthWorkoutActivityType.STRENGTH_TRAINING,
    HealthWorkoutActivityType.WALKING,
    HealthWorkoutActivityType.TENNIS,
    HealthWorkoutActivityType.OTHER,
  ];

  static final Set<HealthWorkoutActivityType> _cardioTypes = {
    HealthWorkoutActivityType.RUNNING,
    HealthWorkoutActivityType.RUNNING_TREADMILL,
    HealthWorkoutActivityType.BIKING,
    HealthWorkoutActivityType.BIKING_STATIONARY,
    HealthWorkoutActivityType.SWIMMING,
    HealthWorkoutActivityType.SWIMMING_OPEN_WATER,
    HealthWorkoutActivityType.SWIMMING_POOL,
    HealthWorkoutActivityType.ROWING,
    HealthWorkoutActivityType.ROWING_MACHINE,
    HealthWorkoutActivityType.SAILING,
    HealthWorkoutActivityType.WALKING,
    HealthWorkoutActivityType.WALKING_TREADMILL,
    HealthWorkoutActivityType.HIKING,
    HealthWorkoutActivityType.CARDIO_DANCE,
    HealthWorkoutActivityType.DANCING,
    HealthWorkoutActivityType.ELLIPTICAL,
    HealthWorkoutActivityType.STAIR_CLIMBING,
    HealthWorkoutActivityType.STAIR_CLIMBING_MACHINE,
  };

  static final Set<HealthWorkoutActivityType> _strengthTypes = {
    HealthWorkoutActivityType.STRENGTH_TRAINING,
    HealthWorkoutActivityType.TRADITIONAL_STRENGTH_TRAINING,
    HealthWorkoutActivityType.FUNCTIONAL_STRENGTH_TRAINING,
    HealthWorkoutActivityType.WEIGHTLIFTING,
    HealthWorkoutActivityType.CALISTHENICS,
    HealthWorkoutActivityType.GYMNASTICS,
    HealthWorkoutActivityType.YOGA,
    HealthWorkoutActivityType.PILATES,
  };

  static final Set<HealthWorkoutActivityType> _mixedTypes = {
    HealthWorkoutActivityType.TENNIS,
    HealthWorkoutActivityType.RACQUETBALL,
    HealthWorkoutActivityType.BADMINTON,
    HealthWorkoutActivityType.TABLE_TENNIS,
    HealthWorkoutActivityType.SQUASH,
    HealthWorkoutActivityType.HIGH_INTENSITY_INTERVAL_TRAINING,
    HealthWorkoutActivityType.CROSS_TRAINING,
    HealthWorkoutActivityType.BASKETBALL,
    HealthWorkoutActivityType.VOLLEYBALL,
  };

  static SportBucket classifyWorkout(HealthWorkoutActivityType type) {
    if (_cardioTypes.contains(type)) return SportBucket.cardio;
    if (_strengthTypes.contains(type)) return SportBucket.strength;
    if (_mixedTypes.contains(type)) return SportBucket.mixed;
    final upper = type.name.toUpperCase();
    if (upper.contains('RUN') ||
        upper.contains('BIK') ||
        upper.contains('SWIM') ||
        upper.contains('WALK') ||
        upper.contains('CARDIO')) {
      return SportBucket.cardio;
    }
    if (upper.contains('STRENGTH') || upper.contains('WEIGHT')) {
      return SportBucket.strength;
    }
    return SportBucket.mixed;
  }

  /// Evaluates current sport state (`Treino em curso`, `Recuperação`, `Sem treino`)
  /// and provides a prudent, conservative glycemic risk assessment without
  /// arbitrary calorie/HR mg/dL equations or medical dosing recommendations.
  static SportEvaluationResult evaluate({
    required PumpTelemetry telemetry,
    FitbitHealthMetrics? fitbitMetrics,
    ManualWorkoutSession? manualSession,
    FitbitWorkoutSummary? selectedWorkout,
    DateTime? asOf,
  }) {
    final now = asOf ?? DateTime.now();

    // 1. Determine current state from manual workout and Health Connect workouts.
    SportActivityState resolvedState = SportActivityState.none;
    FitbitWorkoutSummary? chosenWorkout;
    Duration? elapsed;
    Duration? timeSinceEnd;

    if (manualSession != null && manualSession.isOngoing) {
      final rawElapsed = now.difference(manualSession.startTime);
      if (!rawElapsed.isNegative && rawElapsed <= manualActiveMaxCap) {
        resolvedState = SportActivityState.active;
        elapsed = rawElapsed;
        final type = HealthWorkoutActivityType.values.firstWhere(
          (e) => e.name == manualSession.activityTypeName,
          orElse: () => HealthWorkoutActivityType.OTHER,
        );
        chosenWorkout = FitbitWorkoutSummary(
          activityType: type,
          activeKcal: 0.0,
          avgHr: fitbitMetrics?.recentHeartRateAt(now)?.toDouble() ?? 0.0,
          startTime: manualSession.startTime,
          endTime: now,
          isOngoingManual: true,
        );
      }
    }

    // Check finished manual session if no active manual session
    FitbitWorkoutSummary? finishedManualSummary;
    if (chosenWorkout == null &&
        manualSession != null &&
        manualSession.endTime != null) {
      final sinceEnd = now.difference(manualSession.endTime!);
      if (!sinceEnd.isNegative && sinceEnd <= recoveryMaxWindow) {
        final type = HealthWorkoutActivityType.values.firstWhere(
          (e) => e.name == manualSession.activityTypeName,
          orElse: () => HealthWorkoutActivityType.OTHER,
        );
        finishedManualSummary = FitbitWorkoutSummary(
          activityType: type,
          activeKcal: 0.0,
          avgHr: 0.0,
          startTime: manualSession.startTime,
          endTime: manualSession.endTime!,
        );
      }
    }

    if (chosenWorkout == null) {
      final hcCandidate = selectedWorkout ?? fitbitMetrics?.latestWorkout;
      // Pick whichever ended most recently between HC and finished manual session
      FitbitWorkoutSummary? bestCandidate = hcCandidate;
      if (finishedManualSummary != null) {
        if (bestCandidate == null ||
            finishedManualSummary.endTime.isAfter(bestCandidate.endTime)) {
          bestCandidate = finishedManualSummary;
        }
      }

      if (bestCandidate != null) {
        final sinceStart = now.difference(bestCandidate.startTime);
        final sinceEnd = now.difference(bestCandidate.endTime);

        // Ongoing right now in Health Connect (endTime >= now - 5m and startTime <= now)
        if (!sinceStart.isNegative &&
            sinceEnd <= activeGraceWindow &&
            sinceStart <= manualActiveMaxCap) {
          resolvedState = SportActivityState.active;
          chosenWorkout = bestCandidate;
          elapsed = sinceStart;
        } else if (sinceEnd > activeGraceWindow &&
            sinceEnd <= recoveryMaxWindow) {
          // Recovery window strictly capped at 6h (never confuse a 20h-old workout!)
          resolvedState = SportActivityState.recovery;
          chosenWorkout = bestCandidate;
          timeSinceEnd = sinceEnd;
        } else {
          resolvedState = SportActivityState.none;
        }
      }
    }

    final bucket = chosenWorkout != null
        ? classifyWorkout(chosenWorkout.activityType)
        : SportBucket.none;
    final int? recentHr = fitbitMetrics?.recentHeartRateAt(now) ??
        (chosenWorkout != null &&
                chosenWorkout.avgHr > 0 &&
                resolvedState == SportActivityState.active
            ? chosenWorkout.avgHr.round()
            : null);

    // 2. Assess current glucose & trend prudently
    final sg = telemetry.sgValue;
    if (sg == null || telemetry.isReadingStaleAt(now)) {
      return SportEvaluationResult(
        state: resolvedState,
        riskLevel: SportRiskLevel.insufficientData,
        bucket: bucket,
        activeOrRecoveryWorkout: chosenWorkout,
        activeElapsed: elapsed,
        timeSinceWorkoutEnded: timeSinceEnd,
        availableHeartRateBpm: recentHr,
        glucoseTrendLabel: null,
        summaryTextPt: sg == null
            ? 'Dados insuficientes para avaliar risco glicémico.'
            : 'Última leitura demasiado antiga (${telemetry.timeSinceReadingLabelAt(now)}).',
      );
    }

    final prediction = GlucosePredictionService.predict(
      telemetry: telemetry,
      asOf: now,
      isExerciseActiveOrRecovery: resolvedState != SportActivityState.none,
    );

    final double? slope = prediction.slopeMgDlPerMin ?? telemetry.sgVelocityPerMin;
    final double iob = telemetry.activeInsulin ?? 0.0;
    final trendLabel = telemetry.trendDescriptionPt();

    final factors = <String>[
      'Glicose atual: $sg mg/dL (${telemetry.trendArrow})',
      if (telemetry.activeInsulin != null)
        'Insulina ativa: ${telemetry.activeInsulin!.toStringAsFixed(1).replaceAll('.', ',')} U',
      if (recentHr != null) 'Frequência cardíaca recente: $recentHr bpm',
    ];

    final bool isFallingFastOrModerate =
        (slope != null && slope <= -0.6) ||
        prediction.direction == EstimatedTrendDirection.falling ||
        prediction.direction == EstimatedTrendDirection.fallingFast ||
        telemetry.sgTrend == 'DOWN' ||
        telemetry.sgTrend == 'DOWN_DOUBLE';

    final bool hasSlightDrop = slope != null && slope <= -0.35;
    final bool hasNotableIob = iob >= 1.0;
    final bool isBorderline = sg < 125;

    final SportRiskLevel riskLevel;
    final String summary;

    if (isFallingFastOrModerate) {
      riskLevel = SportRiskLevel.falling;
      summary = resolvedState == SportActivityState.active
          ? 'Glicose a descer durante o treino. Acompanha de perto a evolução no sensor.'
          : (resolvedState == SportActivityState.recovery
              ? 'Glicose a descer após o exercício. Mantém monitorização ativa.'
              : 'Tendência descendente observada nas leituras recentes.');
    } else if (resolvedState != SportActivityState.none &&
        (hasSlightDrop || hasNotableIob || isBorderline || bucket == SportBucket.cardio)) {
      riskLevel = SportRiskLevel.elevatedDropRisk;
      final stateCtx = resolvedState == SportActivityState.active
          ? 'durante o exercício'
          : 'no período de recuperação pós-treino';
      if (hasNotableIob && isBorderline) {
        factors.add('Insulina ativa associada a glicemia próxima do limite');
      } else if (bucket == SportBucket.cardio) {
        factors.add('Atividade aeróbia associada a maior captação de glicose');
      } else if (bucket == SportBucket.strength) {
        factors.add('Pós-treino pode aumentar sensibilidade à insulina nas horas seguintes');
      }
      summary = 'Possível aumento do risco de descida $stateCtx.';
    } else {
      riskLevel = SportRiskLevel.stable;
      summary = resolvedState == SportActivityState.none
          ? 'Sem treino ativo ou recente nas últimas 6 horas.'
          : 'Glicose estável até ao momento; continua a acompanhar as leituras.';
    }

    return SportEvaluationResult(
      state: resolvedState,
      riskLevel: riskLevel,
      bucket: bucket,
      activeOrRecoveryWorkout: chosenWorkout,
      activeElapsed: elapsed,
      timeSinceWorkoutEnded: timeSinceEnd,
      availableHeartRateBpm: recentHr,
      glucoseTrendLabel: trendLabel,
      summaryTextPt: summary,
      contributingFactors: factors,
    );
  }
}
