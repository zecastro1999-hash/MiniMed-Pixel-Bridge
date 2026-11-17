import 'dart:math' as math;
import '../models/pump_telemetry.dart';

enum PredictionAvailability {
  available,
  qualitativeOnly,
  unavailable,
}

enum PredictionConfidence {
  high('Confiança alta'),
  moderate('Confiança moderada'),
  low('Confiança reduzida');

  final String labelPt;
  const PredictionConfidence(this.labelPt);
}

enum EstimatedTrendDirection {
  risingFast('a subir rapidamente'),
  rising('a subir'),
  stable('estável'),
  falling('a descer'),
  fallingFast('a descer rapidamente'),
  uncertain('incerta');

  final String phrasePt;
  const EstimatedTrendDirection(this.phrasePt);
}

class GlucosePredictionResult {
  final PredictionAvailability availability;
  final EstimatedTrendDirection direction;
  final PredictionConfidence? confidence;
  final int? estimatedSg30m;
  final int? lowerBoundSg30m;
  final int? upperBoundSg30m;
  final double? slopeMgDlPerMin;
  final double? residualRms;
  final Duration? readingAge;
  final int pointsUsed;
  final String reason;
  final List<String> contextFactors;

  const GlucosePredictionResult({
    required this.availability,
    required this.direction,
    this.confidence,
    this.estimatedSg30m,
    this.lowerBoundSg30m,
    this.upperBoundSg30m,
    this.slopeMgDlPerMin,
    this.residualRms,
    this.readingAge,
    this.pointsUsed = 0,
    required this.reason,
    this.contextFactors = const [],
  });

  bool get isAvailable => availability != PredictionAvailability.unavailable;

  bool get hasNumericEstimate =>
      availability == PredictionAvailability.available &&
      estimatedSg30m != null &&
      lowerBoundSg30m != null &&
      upperBoundSg30m != null;

  String get trendHeadlinePt {
    if (!isAvailable) return 'Previsão indisponível';
    return 'Tendência estimada: ${direction.phrasePt}';
  }

  String get numericRangeLabelPt {
    if (!hasNumericEstimate) {
      return isAvailable
          ? 'Estimativa numérica omitida (incerteza elevada)'
          : reason;
    }
    return 'Estimativa ~ $estimatedSg30m mg/dL ($lowerBoundSg30m–$upperBoundSg30m)';
  }

  String get shortWidgetLabelPt {
    if (!isAvailable) return 'indisponível';
    if (hasNumericEstimate) {
      return '${direction.phrasePt} (~$estimatedSg30m mg/dL)';
    }
    return direction.phrasePt;
  }
}

class PredictionBacktestMetrics {
  final int evaluatedCount;
  final int skippedUnavailableCount;
  final double? maeMgDl;
  final double? rmseMgDl;
  final double? directionAccuracyPercent;
  final double? intervalCoveragePercent;

  const PredictionBacktestMetrics({
    required this.evaluatedCount,
    required this.skippedUnavailableCount,
    this.maeMgDl,
    this.rmseMgDl,
    this.directionAccuracyPercent,
    this.intervalCoveragePercent,
  });
}

class GlucosePredictionService {
  static const Duration maxReadingAge = Duration(minutes: 15);
  static const Duration lookbackWindow = Duration(minutes: 35);
  static const Duration maxInternalGap = Duration(minutes: 12);
  static const double minSpanMinutes = 10.0;
  static const int minPointsRequired = 3;

  /// Computes a conservative, timestamp-normalized 30-minute glucose trend
  /// prediction with explicit uncertainty and unavailability checks.
  static GlucosePredictionResult predict({
    required PumpTelemetry telemetry,
    DateTime? asOf,
    bool isExerciseActiveOrRecovery = false,
  }) {
    final now = asOf ?? DateTime.now();

    final candidates = <SgReading>[
      ...telemetry.sgHistory.where(
        (r) =>
            r.isValidAt(now) && !r.timestamp.isAfter(now.add(const Duration(minutes: 2))),
      ),
      if (telemetry.sgValue != null && telemetry.sgDateTime != null)
        SgReading(
          sg: telemetry.sgValue!,
          timestamp: telemetry.sgDateTime!,
          origin: telemetry.sgOrigin,
        ),
    ];

    candidates.sort((a, b) => a.timestamp.compareTo(b.timestamp));

    // Deduplicate near-identical timestamps cleanly
    final valid = <SgReading>[];
    for (final r in candidates) {
      if (valid.isEmpty) {
        valid.add(r);
      } else if (r.timestamp.difference(valid.last.timestamp).inSeconds < 15) {
        valid[valid.length - 1] = r;
      } else {
        valid.add(r);
      }
    }

    if (valid.isEmpty) {
      return const GlucosePredictionResult(
        availability: PredictionAvailability.unavailable,
        direction: EstimatedTrendDirection.uncertain,
        reason: 'Sem leituras de glicose recentes.',
      );
    }

    final latest = valid.last;
    final age = now.difference(latest.timestamp);
    if (age.isNegative && age.abs() > const Duration(minutes: 2)) {
      return GlucosePredictionResult(
        availability: PredictionAvailability.unavailable,
        direction: EstimatedTrendDirection.uncertain,
        readingAge: age,
        reason: 'Timestamp de leitura inválido.',
      );
    }
    final safeAge = age.isNegative ? Duration.zero : age;

    if (safeAge > maxReadingAge) {
      return GlucosePredictionResult(
        availability: PredictionAvailability.unavailable,
        direction: EstimatedTrendDirection.uncertain,
        readingAge: safeAge,
        reason: 'Última leitura demasiado antiga (${safeAge.inMinutes} min).',
      );
    }

    // Collect contiguous recent cluster back up to 35 min prior to latest reading
    final cutoff = latest.timestamp.subtract(lookbackWindow);
    final cluster = <SgReading>[latest];
    for (int i = valid.length - 2; i >= 0; i--) {
      final curr = cluster.first;
      final prev = valid[i];
      if (prev.timestamp.isBefore(cutoff)) break;
      final gap = curr.timestamp.difference(prev.timestamp);
      if (gap > maxInternalGap) break;
      cluster.insert(0, prev);
    }

    if (cluster.length < minPointsRequired) {
      return GlucosePredictionResult(
        availability: PredictionAvailability.unavailable,
        direction: EstimatedTrendDirection.uncertain,
        readingAge: safeAge,
        pointsUsed: cluster.length,
        reason: 'Histórico recente insuficiente (mínimo 3 leituras contínuas).',
      );
    }

    final spanMinutes =
        latest.timestamp.difference(cluster.first.timestamp).inSeconds / 60.0;
    if (spanMinutes < minSpanMinutes) {
      return GlucosePredictionResult(
        availability: PredictionAvailability.unavailable,
        direction: EstimatedTrendDirection.uncertain,
        readingAge: safeAge,
        pointsUsed: cluster.length,
        reason: 'Janela temporal demasiado curta para projetar tendência.',
      );
    }

    // Exponentially-weighted least squares regression using REAL elapsed minutes
    final tRef = latest.timestamp;
    double sumW = 0.0;
    double sumWX = 0.0;
    double sumWY = 0.0;

    final xs = <double>[];
    final ys = <double>[];
    final ws = <double>[];

    for (final r in cluster) {
      final x = -tRef.difference(r.timestamp).inSeconds / 60.0; // in [-35, 0]
      final y = r.sg.toDouble();
      final w = math.exp(0.07 * x); // higher weight near 0
      xs.add(x);
      ys.add(y);
      ws.add(w);
      sumW += w;
      sumWX += w * x;
      sumWY += w * y;
    }

    final meanX = sumWX / sumW;
    final meanY = sumWY / sumW;

    double num = 0.0;
    double den = 0.0;
    for (int i = 0; i < cluster.length; i++) {
      final dx = xs[i] - meanX;
      num += ws[i] * dx * (ys[i] - meanY);
      den += ws[i] * dx * dx;
    }

    if (den <= 1e-6) {
      return GlucosePredictionResult(
        availability: PredictionAvailability.unavailable,
        direction: EstimatedTrendDirection.uncertain,
        readingAge: safeAge,
        pointsUsed: cluster.length,
        reason: 'Timestamps insuficientemente espaçados.',
      );
    }

    final rawSlope = num / den; // mg/dL per minute
    final intercept = meanY - rawSlope * meanX;

    // Residual RMS error around the local linear trend
    double weightedSqErr = 0.0;
    for (int i = 0; i < cluster.length; i++) {
      final predY = intercept + rawSlope * xs[i];
      final err = ys[i] - predY;
      weightedSqErr += ws[i] * err * err;
    }
    final residualRms = math.sqrt(weightedSqErr / sumW);

    // Check most recent local step velocity to detect sudden reversal vs fit
    final prevReading = cluster[cluster.length - 2];
    final lastStepMins =
        math.max(0.5, latest.timestamp.difference(prevReading.timestamp).inSeconds / 60.0);
    final lastStepSlope = (latest.sg - prevReading.sg) / lastStepMins;

    final bool abruptReversal =
        (rawSlope.abs() > 0.5 &&
            lastStepSlope.abs() > 1.2 &&
            rawSlope.sign != lastStepSlope.sign) ||
        residualRms > 18.0;

    // Classify qualitative direction cleanly
    final double clampedSlope = rawSlope.clamp(-3.5, 3.5);
    final EstimatedTrendDirection direction;
    if (residualRms > 24.0) {
      direction = EstimatedTrendDirection.uncertain;
    } else if (clampedSlope >= 1.8) {
      direction = EstimatedTrendDirection.risingFast;
    } else if (clampedSlope >= 0.45) {
      direction = EstimatedTrendDirection.rising;
    } else if (clampedSlope <= -1.8) {
      direction = EstimatedTrendDirection.fallingFast;
    } else if (clampedSlope <= -0.45) {
      direction = EstimatedTrendDirection.falling;
    } else {
      direction = EstimatedTrendDirection.stable;
    }

    // Account conservatively for context without inventing arbitrary mg/dL formulas
    final contextFactors = <String>[];
    final double iob = telemetry.activeInsulin ?? 0.0;
    final bool hasRecentMeal = telemetry.mealMarkers.any(
      (m) =>
          !m.timestamp.isAfter(now) &&
          now.difference(m.timestamp) <= const Duration(minutes: 90),
    );

    if (safeAge.inMinutes >= 7) {
      contextFactors.add('Leitura com ${safeAge.inMinutes} min');
    }
    if (iob >= 0.5) {
      contextFactors.add(
        'Insulina ativa: ${iob.toStringAsFixed(1).replaceAll('.', ',')} U',
      );
    }
    if (hasRecentMeal) {
      contextFactors.add('Refeição recente (<90 min)');
    }
    if (isExerciseActiveOrRecovery) {
      contextFactors.add('Atividade física recente/ativa');
    }

    // If signal is too erratic / abruptly reversing or slope wildly extreme,
    // withhold a false numeric point prediction.
    if (direction == EstimatedTrendDirection.uncertain ||
        (abruptReversal && residualRms > 16.0)) {
      return GlucosePredictionResult(
        availability: PredictionAvailability.unavailable,
        direction: EstimatedTrendDirection.uncertain,
        confidence: PredictionConfidence.low,
        slopeMgDlPerMin: rawSlope,
        residualRms: residualRms,
        readingAge: safeAge,
        pointsUsed: cluster.length,
        reason: 'Variação demasiado irregular para estimar 30 min com fiabilidade.',
        contextFactors: contextFactors,
      );
    }

    // Conservative damped 30-minute projection from current smoothed level:
    // Project remaining minutes = 30 - safeAge (or full 30m from latest + age uncertainty)
    // Using a 0.78 damping factor reduces linear overshoot under AID (SmartGuard).
    const double damping = 0.78;
    final double horizonMins = math.max(15.0, 30.0 - safeAge.inMinutes * 0.5);
    final double centerAnchor = (0.7 * latest.sg + 0.3 * intercept);
    final double rawEstimate =
        centerAnchor + (clampedSlope * horizonMins * damping);
    final int estimatedSg = rawEstimate.round().clamp(40, 400);

    // Base uncertainty grows with residual noise, reading age, steepness, and context modifiers
    double baseHalfWidth = 10.0 +
        (residualRms * 1.1) +
        (safeAge.inMinutes * 1.0) +
        (clampedSlope.abs() * 4.5);

    double downsideExtra = 0.0;
    double upsideExtra = 0.0;
    if (iob >= 1.5) {
      downsideExtra += math.min(12.0, iob * 2.5);
    }
    if (isExerciseActiveOrRecovery) {
      downsideExtra += 10.0;
    }
    if (hasRecentMeal) {
      upsideExtra += 12.0;
    }
    if (abruptReversal) {
      baseHalfWidth += 10.0;
    }

    final int lowBound =
        (estimatedSg - baseHalfWidth - downsideExtra).round().clamp(35, 390);
    final int highBound =
        (estimatedSg + baseHalfWidth + upsideExtra).round().clamp(45, 420);

    final bool numericJustified =
        baseHalfWidth <= 34.0 && cluster.length >= 3 && !abruptReversal;

    final PredictionConfidence confidence;
    if (!numericJustified ||
        isExerciseActiveOrRecovery ||
        abruptReversal ||
        safeAge.inMinutes >= 10) {
      confidence = PredictionConfidence.low;
    } else if (cluster.length >= 5 &&
        residualRms < 6.0 &&
        safeAge.inMinutes <= 6 &&
        !hasRecentMeal &&
        iob < 2.5) {
      confidence = PredictionConfidence.high;
    } else {
      confidence = PredictionConfidence.moderate;
    }

    if (!numericJustified) {
      return GlucosePredictionResult(
        availability: PredictionAvailability.qualitativeOnly,
        direction: direction,
        confidence: confidence,
        slopeMgDlPerMin: rawSlope,
        residualRms: residualRms,
        readingAge: safeAge,
        pointsUsed: cluster.length,
        reason: 'Incerteza elevada — mostrada apenas tendência qualitativa.',
        contextFactors: contextFactors,
      );
    }

    return GlucosePredictionResult(
      availability: PredictionAvailability.available,
      direction: direction,
      confidence: confidence,
      estimatedSg30m: estimatedSg,
      lowerBoundSg30m: lowBound,
      upperBoundSg30m: highBound,
      slopeMgDlPerMin: rawSlope,
      residualRms: residualRms,
      readingAge: safeAge,
      pointsUsed: cluster.length,
      reason: confidence.labelPt,
      contextFactors: contextFactors,
    );
  }
}

/// Evaluates prediction accuracy against later observed readings (backtesting).
class PredictionEvaluator {
  static PredictionBacktestMetrics evaluateHistory(
    List<SgReading> history, {
    Duration horizon = const Duration(minutes: 30),
    Duration matchTolerance = const Duration(minutes: 5),
  }) {
    final sorted = List<SgReading>.from(history)
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
    if (sorted.length < 5) {
      return const PredictionBacktestMetrics(
        evaluatedCount: 0,
        skippedUnavailableCount: 0,
      );
    }

    double sumAbsErr = 0.0;
    double sumSqErr = 0.0;
    int withinInterval = 0;
    int directionMatches = 0;
    int evaluated = 0;
    int skippedUnavailable = 0;

    for (int i = 0; i < sorted.length; i++) {
      final anchor = sorted[i];
      final targetTime = anchor.timestamp.add(horizon);

      // Find observed reading closest to targetTime within matchTolerance
      SgReading? observed;
      int bestDiffSec = matchTolerance.inSeconds + 1;
      for (int j = i + 1; j < sorted.length; j++) {
        final diff = sorted[j].timestamp.difference(targetTime).inSeconds.abs();
        if (diff <= matchTolerance.inSeconds && diff < bestDiffSec) {
          bestDiffSec = diff;
          observed = sorted[j];
        }
        if (sorted[j].timestamp.isAfter(targetTime.add(matchTolerance))) {
          break;
        }
      }
      if (observed == null) continue;

      final subset = sorted.sublist(0, i + 1);
      final fakeTelemetry = PumpTelemetry(
        sgValue: anchor.sg,
        sgDateTime: anchor.timestamp,
        sgTrend: 'NONE',
        activeInsulin: null,
        reservoirRemaining: null,
        pumpBatteryPercent: null,
        sgHistory: subset,
        mealMarkers: const [],
        bolusMarkers: const [],
        dataSource: 'Backtest',
      );

      final pred = GlucosePredictionService.predict(
        telemetry: fakeTelemetry,
        asOf: anchor.timestamp,
      );

      if (!pred.hasNumericEstimate) {
        skippedUnavailable++;
        continue;
      }

      final absErr = (pred.estimatedSg30m! - observed.sg).abs().toDouble();
      sumAbsErr += absErr;
      sumSqErr += absErr * absErr;
      if (observed.sg >= pred.lowerBoundSg30m! &&
          observed.sg <= pred.upperBoundSg30m!) {
        withinInterval++;
      }

      final actualDelta = observed.sg - anchor.sg;
      final predictedDelta = pred.estimatedSg30m! - anchor.sg;
      final bool dirOk = (actualDelta.abs() <= 12 && predictedDelta.abs() <= 15) ||
          (actualDelta > 10 && predictedDelta > 5) ||
          (actualDelta < -10 && predictedDelta < -5);
      if (dirOk) directionMatches++;

      evaluated++;
    }

    if (evaluated == 0) {
      return PredictionBacktestMetrics(
        evaluatedCount: 0,
        skippedUnavailableCount: skippedUnavailable,
      );
    }

    return PredictionBacktestMetrics(
      evaluatedCount: evaluated,
      skippedUnavailableCount: skippedUnavailable,
      maeMgDl: sumAbsErr / evaluated,
      rmseMgDl: math.sqrt(sumSqErr / evaluated),
      directionAccuracyPercent: (directionMatches / evaluated) * 100.0,
      intervalCoveragePercent: (withinInterval / evaluated) * 100.0,
    );
  }
}
