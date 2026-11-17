import 'dart:math' as math;
import '../models/pump_telemetry.dart';

enum TirPeriod {
  h24(Duration(hours: 24), '24 horas', 'Últimas 24h'),
  d7(Duration(days: 7), '7 dias', 'Últimos 7 dias'),
  d14(Duration(days: 14), '14 dias', 'Últimos 14 dias');

  final Duration duration;
  final String shortLabel;
  final String fullLabel;
  const TirPeriod(this.duration, this.shortLabel, this.fullLabel);
}

enum StreakStatus {
  inRange,
  outOfRange,
  unknownDueToGap,
  insufficientData,
}

class InRangeStreakResult {
  final StreakStatus status;
  final Duration duration;
  final DateTime? startedAt;
  final DateTime? lastReadingAt;
  final bool interruptedByPriorGap;
  final bool isBelowRange;

  const InRangeStreakResult({
    required this.status,
    required this.duration,
    this.startedAt,
    this.lastReadingAt,
    this.interruptedByPriorGap = false,
    this.isBelowRange = false,
  });

  String formatDurationPt(Duration d) {
    final totalMins = math.max(0, d.inMinutes);
    final days = totalMins ~/ (24 * 60);
    final hours = (totalMins % (24 * 60)) ~/ 60;
    final mins = totalMins % 60;
    if (days > 0) return '${days}d ${hours}h ${mins}min';
    if (hours > 0) return '${hours}h ${mins.toString().padLeft(2, '0')}min';
    return '${mins}min';
  }

  String get displayLabelPt {
    switch (status) {
      case StreakStatus.inRange:
        final durText = formatDurationPt(duration);
        if (interruptedByPriorGap) {
          return 'No alvo há pelo menos $durText';
        }
        return 'Dentro do objetivo há $durText';
      case StreakStatus.outOfRange:
        final durText = formatDurationPt(duration);
        return isBelowRange
            ? 'Abaixo do alvo há $durText'
            : 'Acima do alvo há $durText';
      case StreakStatus.unknownDueToGap:
        return 'Continuidade desconhecida (lacuna de dados)';
      case StreakStatus.insufficientData:
        return 'Sem dados suficientes no alvo';
    }
  }
}

class TimeInRangeSummary {
  final TirPeriod period;
  final TargetRangeConfig range;
  final Duration coveredDuration;
  final Duration inRangeDuration;
  final Duration belowRangeDuration;
  final Duration aboveRangeDuration;
  final double coveragePercent;
  final int validReadingCount;
  final int gapCount;

  const TimeInRangeSummary({
    required this.period,
    required this.range,
    required this.coveredDuration,
    required this.inRangeDuration,
    required this.belowRangeDuration,
    required this.aboveRangeDuration,
    required this.coveragePercent,
    required this.validReadingCount,
    required this.gapCount,
  });

  bool get hasSufficientData =>
      validReadingCount >= 2 && coveredDuration.inSeconds >= 300;

  bool get isPartialCoverage => hasSufficientData && coveragePercent < 70.0;

  double? get inRangePercent {
    if (!hasSufficientData) return null;
    return (inRangeDuration.inMilliseconds / coveredDuration.inMilliseconds) *
        100.0;
  }

  double? get belowRangePercent {
    if (!hasSufficientData) return null;
    return (belowRangeDuration.inMilliseconds /
            coveredDuration.inMilliseconds) *
        100.0;
  }

  double? get aboveRangePercent {
    if (!hasSufficientData) return null;
    return (aboveRangeDuration.inMilliseconds /
            coveredDuration.inMilliseconds) *
        100.0;
  }

  static String formatDurationPt(Duration d) {
    final totalMins = math.max(0, d.inMinutes);
    final days = totalMins ~/ (24 * 60);
    final hours = (totalMins % (24 * 60)) ~/ 60;
    final mins = totalMins % 60;
    if (days > 0) return '${days}d ${hours}h ${mins}min';
    if (hours > 0) return '${hours}h ${mins.toString().padLeft(2, '0')}min';
    return '${mins}min';
  }
}

class TimeInRangeService {
  /// Maximum gap tolerated between adjacent readings before treating the span
  /// as missing data (never assuming glucose remained in range across a gap).
  static const Duration defaultMaxGap = Duration(minutes: 15);
  static const Duration defaultTrailingCap = Duration(minutes: 5);

  /// Computes time-weighted Time in Range across [period] ending at [asOf].
  static TimeInRangeSummary computeWindowMetrics({
    required List<SgReading> readings,
    required TirPeriod period,
    TargetRangeConfig range = TargetRangeConfig.defaultRange,
    DateTime? asOf,
    Duration maxGap = defaultMaxGap,
  }) {
    final safeRange = range.sanitized();
    final ref = asOf ?? DateTime.now();
    final windowStart = ref.subtract(period.duration);
    final windowEnd = ref;

    // Normalize, validate, sort, and deduplicate exact/near-duplicate timestamps.
    final normalized = _normalizeSortedReadings(readings, asOf: ref);

    final relevant = normalized
        .where((r) =>
            !r.timestamp.isBefore(windowStart.subtract(maxGap)) &&
            !r.timestamp.isAfter(windowEnd.add(maxGap)))
        .toList();

    final inWindowCount = normalized
        .where((r) =>
            !r.timestamp.isBefore(windowStart) &&
            !r.timestamp.isAfter(windowEnd))
        .length;

    if (relevant.isEmpty || inWindowCount == 0) {
      return TimeInRangeSummary(
        period: period,
        range: safeRange,
        coveredDuration: Duration.zero,
        inRangeDuration: Duration.zero,
        belowRangeDuration: Duration.zero,
        aboveRangeDuration: Duration.zero,
        coveragePercent: 0.0,
        validReadingCount: inWindowCount,
        gapCount: 0,
      );
    }

    int inRangeMs = 0;
    int belowMs = 0;
    int aboveMs = 0;
    int gapCount = 0;

    void addSegment(DateTime segStart, DateTime segEnd, int sg) {
      final clippedStart =
          segStart.isAfter(windowStart) ? segStart : windowStart;
      final clippedEnd = segEnd.isBefore(windowEnd) ? segEnd : windowEnd;
      final overlapMs = clippedEnd.difference(clippedStart).inMilliseconds;
      if (overlapMs <= 0) return;

      if (sg < safeRange.lowMgDl) {
        belowMs += overlapMs;
      } else if (sg <= safeRange.highMgDl) {
        inRangeMs += overlapMs;
      } else {
        aboveMs += overlapMs;
      }
    }

    for (int i = 0; i < relevant.length - 1; i++) {
      final a = relevant[i];
      final b = relevant[i + 1];
      final dt = b.timestamp.difference(a.timestamp);
      if (dt <= Duration.zero) continue;

      if (dt > maxGap) {
        // Check if this gap overlaps the target evaluation window
        final overlapsWindow = b.timestamp.isAfter(windowStart) &&
            a.timestamp.isBefore(windowEnd);
        if (overlapsWindow) {
          gapCount++;
        }
        continue;
      }

      // Symmetric midpoint split weights intervals fairly across boundaries & irregular cadences.
      final halfMs = dt.inMilliseconds ~/ 2;
      final mid = a.timestamp.add(Duration(milliseconds: halfMs));
      addSegment(a.timestamp, mid, a.sg);
      addSegment(mid, b.timestamp, b.sg);
    }

    // Active tail coverage up to trailing cap (e.g. max 5m after last reading)
    final last = relevant.last;
    if (!last.timestamp.isAfter(windowEnd)) {
      final sinceLast = windowEnd.difference(last.timestamp);
      if (sinceLast > Duration.zero && sinceLast <= maxGap) {
        final tailEnd = sinceLast <= defaultTrailingCap
            ? windowEnd
            : last.timestamp.add(defaultTrailingCap);
        addSegment(last.timestamp, tailEnd, last.sg);
      }
    }

    final coveredMs = inRangeMs + belowMs + aboveMs;
    final coveragePct =
        ((coveredMs / period.duration.inMilliseconds) * 100.0).clamp(0.0, 100.0);

    return TimeInRangeSummary(
      period: period,
      range: safeRange,
      coveredDuration: Duration(milliseconds: coveredMs),
      inRangeDuration: Duration(milliseconds: inRangeMs),
      belowRangeDuration: Duration(milliseconds: belowMs),
      aboveRangeDuration: Duration(milliseconds: aboveMs),
      coveragePercent: coveragePct,
      validReadingCount: inWindowCount,
      gapCount: gapCount,
    );
  }

  /// Reconstructs the continuous in-range (or out-of-range) duration directly
  /// from persistent reading history without relying on in-memory timers.
  static InRangeStreakResult computeInRangeStreak({
    required List<SgReading> readings,
    TargetRangeConfig range = TargetRangeConfig.defaultRange,
    DateTime? asOf,
    Duration maxGap = defaultMaxGap,
  }) {
    final safeRange = range.sanitized();
    final ref = asOf ?? DateTime.now();
    final valid = _normalizeSortedReadings(readings, asOf: ref);

    if (valid.isEmpty) {
      return const InRangeStreakResult(
        status: StreakStatus.insufficientData,
        duration: Duration.zero,
      );
    }

    final latest = valid.last;
    final ageSinceLatest = ref.difference(latest.timestamp);
    if (ageSinceLatest > maxGap) {
      return InRangeStreakResult(
        status: StreakStatus.unknownDueToGap,
        duration: Duration.zero,
        lastReadingAt: latest.timestamp,
      );
    }

    bool isInRange(int sg) => sg >= safeRange.lowMgDl && sg <= safeRange.highMgDl;
    final bool latestIn = isInRange(latest.sg);
    final bool latestBelow = latest.sg < safeRange.lowMgDl;

    DateTime streakStartedAt = latest.timestamp;
    bool interruptedByGap = false;

    for (int i = valid.length - 1; i >= 1; i--) {
      final curr = valid[i];
      final prev = valid[i - 1];
      final gap = curr.timestamp.difference(prev.timestamp);
      if (gap > maxGap) {
        interruptedByGap = true;
        break;
      }

      if (latestIn) {
        if (isInRange(prev.sg)) {
          streakStartedAt = prev.timestamp;
        } else {
          // Exact transition into range occurred between prev and curr.
          break;
        }
      } else {
        final prevSameSide = latestBelow
            ? prev.sg < safeRange.lowMgDl
            : prev.sg > safeRange.highMgDl;
        if (prevSameSide) {
          streakStartedAt = prev.timestamp;
        } else {
          break;
        }
      }
    }

    final duration = ref.difference(streakStartedAt);
    return InRangeStreakResult(
      status: latestIn ? StreakStatus.inRange : StreakStatus.outOfRange,
      duration: duration.isNegative ? Duration.zero : duration,
      startedAt: streakStartedAt,
      lastReadingAt: latest.timestamp,
      interruptedByPriorGap: interruptedByGap,
      isBelowRange: !latestIn && latestBelow,
    );
  }

  static List<SgReading> _normalizeSortedReadings(
    List<SgReading> readings, {
    required DateTime asOf,
  }) {
    final valid = readings
        .where((r) =>
            r.isValidAt(asOf) &&
            !r.timestamp.isAfter(asOf.add(const Duration(minutes: 2))))
        .toList()
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));

    if (valid.length <= 1) return valid;

    final deduped = <SgReading>[];
    for (final r in valid) {
      if (deduped.isEmpty) {
        deduped.add(r);
        continue;
      }
      final prev = deduped.last;
      if (r.timestamp.difference(prev.timestamp).inSeconds < 15) {
        // Keep the latest value for same-second duplicates cleanly.
        deduped[deduped.length - 1] = r;
      } else {
        deduped.add(r);
      }
    }
    return deduped;
  }
}
