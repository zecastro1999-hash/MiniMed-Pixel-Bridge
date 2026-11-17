import 'dart:convert';
import 'dart:math' as math;

enum TelemetryOrigin {
  carelink,
  notification,
  accessibility,
  xdrip,
  healthConnect,
  unknown;

  static TelemetryOrigin fromString(String? raw) {
    final lower = (raw ?? '').trim().toLowerCase();
    for (final v in TelemetryOrigin.values) {
      if (v.name.toLowerCase() == lower) return v;
    }
    if (lower.contains('carelink')) return TelemetryOrigin.carelink;
    if (lower.contains('notif')) return TelemetryOrigin.notification;
    if (lower.contains('screen') || lower.contains('access')) {
      return TelemetryOrigin.accessibility;
    }
    if (lower.contains('xdrip')) return TelemetryOrigin.xdrip;
    if (lower.contains('health')) return TelemetryOrigin.healthConnect;
    return TelemetryOrigin.unknown;
  }
}

class TargetRangeConfig {
  final int lowMgDl;
  final int highMgDl;

  const TargetRangeConfig({
    this.lowMgDl = 70,
    this.highMgDl = 180,
  });

  static const TargetRangeConfig defaultRange = TargetRangeConfig();

  TargetRangeConfig sanitized() {
    final safeLow = lowMgDl.clamp(50, 140);
    final safeHigh = math.max(safeLow + 20, highMgDl.clamp(100, 300));
    return TargetRangeConfig(lowMgDl: safeLow, highMgDl: safeHigh);
  }

  Map<String, dynamic> toJson() => {
        'lowMgDl': lowMgDl,
        'highMgDl': highMgDl,
      };

  factory TargetRangeConfig.fromJson(Map<String, dynamic> json) {
    return TargetRangeConfig(
      lowMgDl: (json['lowMgDl'] as num?)?.toInt() ?? 70,
      highMgDl: (json['highMgDl'] as num?)?.toInt() ?? 180,
    ).sanitized();
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TargetRangeConfig &&
          lowMgDl == other.lowMgDl &&
          highMgDl == other.highMgDl;

  @override
  int get hashCode => Object.hash(lowMgDl, highMgDl);
}

class SgReading {
  final int sg;
  final DateTime timestamp;
  final TelemetryOrigin origin;
  final String? sourceId;

  const SgReading({
    required this.sg,
    required this.timestamp,
    this.origin = TelemetryOrigin.unknown,
    this.sourceId,
  });

  bool isValidAt(DateTime now) {
    if (sg < 20 || sg > 600) return false;
    // Reject absurd timestamps before 2020 or too far in the future.
    if (timestamp.year < 2020) return false;
    if (timestamp.isAfter(now.add(const Duration(minutes: 5)))) return false;
    return true;
  }

  int get utcEpochMinute => timestamp.toUtc().millisecondsSinceEpoch ~/ 60000;

  Map<String, dynamic> toJson() => {
        'sg': sg,
        'timestamp': timestamp.toUtc().toIso8601String(),
        'origin': origin.name,
        if (sourceId != null) 'sourceId': sourceId,
      };

  factory SgReading.fromJson(Map<String, dynamic> json) => SgReading(
        sg: (json['sg'] as num?)?.toInt() ?? 0,
        timestamp: DateTime.tryParse(json['timestamp']?.toString() ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
        origin: TelemetryOrigin.fromString(json['origin']?.toString()),
        sourceId: json['sourceId']?.toString(),
      );
}

class MealMarker {
  final double carbsGrams;
  final DateTime timestamp;
  final String? displayTime;
  final TelemetryOrigin origin;
  final String? sourceId;

  const MealMarker({
    required this.carbsGrams,
    required this.timestamp,
    this.displayTime,
    this.origin = TelemetryOrigin.unknown,
    this.sourceId,
  });

  bool isValidAt(DateTime now) {
    if (carbsGrams <= 0 || carbsGrams > 500) return false;
    if (timestamp.year < 2020) return false;
    if (timestamp.isAfter(now.add(const Duration(minutes: 5)))) return false;
    return true;
  }

  Map<String, dynamic> toJson() => {
        'carbsGrams': carbsGrams,
        'timestamp': timestamp.toUtc().toIso8601String(),
        if (displayTime != null) 'displayTime': displayTime,
        'origin': origin.name,
        if (sourceId != null) 'sourceId': sourceId,
      };

  factory MealMarker.fromJson(Map<String, dynamic> json) => MealMarker(
        carbsGrams: (json['carbsGrams'] as num?)?.toDouble() ?? 0.0,
        timestamp: DateTime.tryParse(json['timestamp']?.toString() ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
        displayTime: json['displayTime']?.toString(),
        origin: TelemetryOrigin.fromString(json['origin']?.toString()),
        sourceId: json['sourceId']?.toString(),
      );
}

class BolusMarker {
  final double insulinUnits;
  final DateTime timestamp;
  final String bolusType;

  const BolusMarker({
    required this.insulinUnits,
    required this.timestamp,
    this.bolusType = 'BOLUS',
  });

  Map<String, dynamic> toJson() => {
        'insulinUnits': insulinUnits,
        'timestamp': timestamp.toUtc().toIso8601String(),
        'bolusType': bolusType,
      };

  factory BolusMarker.fromJson(Map<String, dynamic> json) => BolusMarker(
        insulinUnits: (json['insulinUnits'] as num?)?.toDouble() ?? 0.0,
        timestamp: DateTime.tryParse(json['timestamp']?.toString() ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
        bolusType: json['bolusType']?.toString() ?? 'BOLUS',
      );
}

class AutoBasalMarker {
  final double bolusAmount;
  final DateTime timestamp;

  const AutoBasalMarker({
    required this.bolusAmount,
    required this.timestamp,
  });

  Map<String, dynamic> toJson() => {
        'bolusAmount': bolusAmount,
        'timestamp': timestamp.toUtc().toIso8601String(),
      };

  factory AutoBasalMarker.fromJson(Map<String, dynamic> json) =>
      AutoBasalMarker(
        bolusAmount: (json['bolusAmount'] as num?)?.toDouble() ?? 0.0,
        timestamp: DateTime.tryParse(json['timestamp']?.toString() ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      );
}

class PumpTelemetry {
  static const Duration staleThreshold = Duration(minutes: 15);

  final int? sgValue;
  final DateTime? sgDateTime;
  final String sgTrend; // NONE, UP, UP_DOUBLE, DOWN, DOWN_DOUBLE
  final TelemetryOrigin sgOrigin;
  final double? activeInsulin;
  final double? reservoirRemaining;
  final int? pumpBatteryPercent;
  final String? pumpBatteryLabel;
  final String? sensorBatteryLabel;
  final String? sensorDaysRemaining;
  final int? sensorMinutesLeft;
  final List<SgReading> sgHistory;
  final List<MealMarker> mealMarkers;
  final List<BolusMarker> bolusMarkers;
  final List<AutoBasalMarker> autoBasalMarkers;
  final String dataSource;
  final String? rawNotificationSummary;
  final String? rawAccessibilitySummary;
  final String? errorMessage;

  const PumpTelemetry({
    required this.sgValue,
    required this.sgDateTime,
    required this.sgTrend,
    this.sgOrigin = TelemetryOrigin.unknown,
    required this.activeInsulin,
    required this.reservoirRemaining,
    required this.pumpBatteryPercent,
    this.pumpBatteryLabel,
    this.sensorBatteryLabel,
    this.sensorDaysRemaining,
    this.sensorMinutesLeft,
    required this.sgHistory,
    required this.mealMarkers,
    required this.bolusMarkers,
    this.autoBasalMarkers = const [],
    required this.dataSource,
    this.rawNotificationSummary,
    this.rawAccessibilitySummary,
    this.errorMessage,
  });

  factory PumpTelemetry.empty({
    String dataSource = 'A aguardar dados da 780G',
    String? errorMessage,
  }) {
    return PumpTelemetry(
      sgValue: null,
      sgDateTime: null,
      sgTrend: 'NONE',
      sgOrigin: TelemetryOrigin.unknown,
      activeInsulin: null,
      reservoirRemaining: null,
      pumpBatteryPercent: null,
      pumpBatteryLabel: null,
      sensorBatteryLabel: null,
      sensorDaysRemaining: null,
      sensorMinutesLeft: null,
      sgHistory: const [],
      mealMarkers: const [],
      bolusMarkers: const [],
      autoBasalMarkers: const [],
      dataSource: dataSource,
      rawNotificationSummary: null,
      rawAccessibilitySummary: null,
      errorMessage: errorMessage,
    );
  }

  int? get currentSg => sgValue;
  DateTime? get lastReadingTime => sgDateTime;
  String get trend => sgTrend;
  double? get iob => activeInsulin;
  double? get reservoirUnits => reservoirRemaining;

  bool isReadingStaleAt(DateTime now) {
    final dt = sgDateTime;
    if (dt == null) return true;
    return now.difference(dt) > staleThreshold;
  }

  bool get isReadingStale => isReadingStaleAt(DateTime.now());

  String get trendArrow {
    switch (sgTrend.toUpperCase()) {
      case 'UP':
        return '↑';
      case 'UP_DOUBLE':
      case 'DOUBLE_UP':
      case 'UP_TRIPLE':
        return '↑↑';
      case 'DOWN':
        return '↓';
      case 'DOWN_DOUBLE':
      case 'DOUBLE_DOWN':
      case 'DOWN_TRIPLE':
        return '↓↓';
      case 'NONE':
      default:
        return '→';
    }
  }

  String trendDescriptionPt() {
    switch (sgTrend.toUpperCase()) {
      case 'UP':
        return 'Glicose a subir';
      case 'UP_DOUBLE':
      case 'DOUBLE_UP':
      case 'UP_TRIPLE':
        return 'Glicose a subir rapidamente';
      case 'DOWN':
        return 'Glicose a descer';
      case 'DOWN_DOUBLE':
      case 'DOUBLE_DOWN':
      case 'DOWN_TRIPLE':
        return 'Glicose a descer rapidamente';
      case 'NONE':
      default:
        return 'Glicose estável';
    }
  }

  String glycemicStatePt([TargetRangeConfig range = TargetRangeConfig.defaultRange]) {
    final sg = sgValue;
    if (sg == null || sg <= 0) return 'Sem leitura';
    if (sg < 54) return 'Muito baixa';
    if (sg < range.lowMgDl) return 'Abaixo do alvo';
    if (sg <= range.highMgDl) return 'No alvo';
    if (sg <= 250) return 'Acima do alvo';
    return 'Muito alta';
  }

  MealMarker? get latestMealMarker {
    if (mealMarkers.isEmpty) return null;
    final sorted = List<MealMarker>.from(mealMarkers)
      ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return sorted.first;
  }

  double? get lastCarbsGrams => latestMealMarker?.carbsGrams;

  DateTime? get lastCarbsTime => latestMealMarker?.timestamp;

  String? get lastCarbsDisplayTime => latestMealMarker?.displayTime;

  double? get lastBolusUnits {
    if (bolusMarkers.isEmpty) return null;
    final sorted = List<BolusMarker>.from(bolusMarkers)
      ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return sorted.first.insulinUnits;
  }

  List<SgReading> get _sortedValidSgs {
    final valid = sgHistory.where((r) => r.sg >= 20 && r.sg <= 600).toList()
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
    return valid;
  }

  int get totalValidSgCount => _sortedValidSgs.length;

  /// Mean glucose over [sgHistory] (or filter window if passed).
  double? meanGlucoseInWindow(Duration window, {DateTime? now}) {
    final ref = now ?? DateTime.now();
    final cutoff = ref.subtract(window);
    final items = _sortedValidSgs.where((r) => !r.timestamp.isBefore(cutoff)).toList();
    if (items.isEmpty) return null;
    final sum = items.fold<int>(0, (acc, r) => acc + r.sg);
    return sum / items.length;
  }

  double? get meanGlucose {
    final valid = _sortedValidSgs;
    if (valid.isEmpty) return null;
    final sum = valid.fold<int>(0, (acc, r) => acc + r.sg);
    return sum / valid.length;
  }

  double? get standardDeviation {
    final valid = _sortedValidSgs;
    final mean = meanGlucose;
    if (valid.isEmpty || mean == null) return null;
    final variance = valid.fold<double>(
          0.0,
          (acc, r) => acc + math.pow(r.sg - mean, 2).toDouble(),
        ) /
        valid.length;
    return math.sqrt(variance);
  }

  double? get cvPercent {
    final sd = standardDeviation;
    final mean = meanGlucose;
    if (sd == null || mean == null || mean <= 0) return null;
    return (sd / mean) * 100.0;
  }

  /// Estimated HbA1c % (GMI formula: 3.31 + 0.02392 * meanGlucoseMgDl).
  double? get estimatedHbA1cPercent {
    final mean = meanGlucose;
    if (mean == null) return null;
    return 3.31 + (0.02392 * mean);
  }

  /// Recent change between the last two consecutive valid readings IF separated by <= 15 minutes.
  int? get sgDelta {
    final valid = _sortedValidSgs;
    if (valid.length < 2) return null;
    final latest = valid.last;
    final prev = valid[valid.length - 2];
    final diffMins = latest.timestamp.difference(prev.timestamp).inSeconds / 60.0;
    if (diffMins <= 0 || diffMins > 15.0) return null;
    return latest.sg - prev.sg;
  }

  /// Actual time-normalized rate of change (mg/dL/min) between the last two consecutive readings <= 15 min apart.
  double? get sgVelocityPerMin {
    final valid = _sortedValidSgs;
    if (valid.length < 2) return null;
    final latest = valid.last;
    final prev = valid[valid.length - 2];
    final diffMins = latest.timestamp.difference(prev.timestamp).inSeconds / 60.0;
    if (diffMins <= 0.25 || diffMins > 15.0) return null;
    return (latest.sg - prev.sg) / diffMins;
  }

  /// Rough linear heuristic for carbohydrate absorption still pending over a 3h window.
  /// Always displayed explicitly as an estimate.
  double? estimatedRemainingCarbsAt(DateTime now) {
    final meal = latestMealMarker;
    if (meal == null) return null;
    final minutesSinceMeal =
        math.max(0.0, now.difference(meal.timestamp).inSeconds / 60.0);
    if (minutesSinceMeal >= 180.0) return 0.0;
    return math.max(
      0.0,
      meal.carbsGrams * (1.0 - (minutesSinceMeal / 180.0)),
    );
  }

  double? get estimatedRemainingCarbs => estimatedRemainingCarbsAt(DateTime.now());

  double get totalBolusUnits =>
      bolusMarkers.fold<double>(0.0, (sum, b) => sum + b.insulinUnits);

  double get totalAutoBasalUnits =>
      autoBasalMarkers.fold<double>(0.0, (sum, b) => sum + b.bolusAmount);

  String get sensorRemainingDisplay {
    if (sensorMinutesLeft != null && sensorMinutesLeft! > 0) {
      final days = sensorMinutesLeft! ~/ (24 * 60);
      final hours = (sensorMinutesLeft! % (24 * 60)) ~/ 60;
      if (days > 0) return '${days}d ${hours}h';
      return '${hours}h';
    }
    if (sensorDaysRemaining != null && sensorDaysRemaining!.isNotEmpty) {
      return sensorDaysRemaining!;
    }
    return '--';
  }

  String timeSinceReadingLabelAt(DateTime now) {
    final dt = sgDateTime;
    if (dt == null) return '--';
    final diff = now.difference(dt);
    if (diff.isNegative && diff.abs().inMinutes > 2) return 'hora inválida';
    final absDiff = diff.abs();
    if (absDiff.inMinutes < 1) return 'agora';
    if (absDiff.inMinutes < 60) return 'há ${absDiff.inMinutes} min';
    final hours = absDiff.inHours;
    final mins = absDiff.inMinutes % 60;
    return mins == 0 ? 'há ${hours}h' : 'há ${hours}h ${mins}m';
  }

  String get timeSinceReadingLabel => timeSinceReadingLabelAt(DateTime.now());

  /// Never fabricates percentages when only qualitative label exists.
  String get pumpBatteryDisplay {
    if (pumpBatteryLabel != null && pumpBatteryLabel!.isNotEmpty) {
      final trimmed = pumpBatteryLabel!.trim();
      final lower = trimmed.toLowerCase();
      if (lower == 'alta' ||
          lower == 'média' ||
          lower == 'media' ||
          lower == 'baixa' ||
          lower == 'high' ||
          lower == 'medium' ||
          lower == 'low') {
        return trimmed;
      }
      return trimmed;
    }
    if (pumpBatteryPercent != null) {
      return '$pumpBatteryPercent%';
    }
    return '--';
  }

  /// Used ONLY for graphical bar progress (never displayed as fake % text).
  double get pumpBatteryVisualFraction {
    if (pumpBatteryPercent != null) {
      return (pumpBatteryPercent! / 100.0).clamp(0.0, 1.0);
    }
    final lower = (pumpBatteryLabel ?? '').trim().toLowerCase();
    switch (lower) {
      case 'alta':
      case 'high':
        return 0.85;
      case 'média':
      case 'media':
      case 'medium':
        return 0.5;
      case 'baixa':
      case 'low':
        return 0.2;
      default:
        return 0.0;
    }
  }

  PumpTelemetry copyWith({
    int? sgValue,
    DateTime? sgDateTime,
    String? sgTrend,
    TelemetryOrigin? sgOrigin,
    double? activeInsulin,
    double? reservoirRemaining,
    int? pumpBatteryPercent,
    bool clearPumpBatteryPercent = false,
    String? pumpBatteryLabel,
    String? sensorBatteryLabel,
    String? sensorDaysRemaining,
    int? sensorMinutesLeft,
    List<SgReading>? sgHistory,
    List<MealMarker>? mealMarkers,
    List<BolusMarker>? bolusMarkers,
    List<AutoBasalMarker>? autoBasalMarkers,
    String? dataSource,
    String? rawNotificationSummary,
    String? rawAccessibilitySummary,
    String? errorMessage,
    bool clearError = false,
  }) {
    return PumpTelemetry(
      sgValue: sgValue ?? this.sgValue,
      sgDateTime: sgDateTime ?? this.sgDateTime,
      sgTrend: sgTrend ?? this.sgTrend,
      sgOrigin: sgOrigin ?? this.sgOrigin,
      activeInsulin: activeInsulin ?? this.activeInsulin,
      reservoirRemaining: reservoirRemaining ?? this.reservoirRemaining,
      pumpBatteryPercent: clearPumpBatteryPercent
          ? null
          : (pumpBatteryPercent ?? this.pumpBatteryPercent),
      pumpBatteryLabel: pumpBatteryLabel ?? this.pumpBatteryLabel,
      sensorBatteryLabel: sensorBatteryLabel ?? this.sensorBatteryLabel,
      sensorDaysRemaining: sensorDaysRemaining ?? this.sensorDaysRemaining,
      sensorMinutesLeft: sensorMinutesLeft ?? this.sensorMinutesLeft,
      sgHistory: sgHistory ?? this.sgHistory,
      mealMarkers: mealMarkers ?? this.mealMarkers,
      bolusMarkers: bolusMarkers ?? this.bolusMarkers,
      autoBasalMarkers: autoBasalMarkers ?? this.autoBasalMarkers,
      dataSource: dataSource ?? this.dataSource,
      rawNotificationSummary:
          rawNotificationSummary ?? this.rawNotificationSummary,
      rawAccessibilitySummary:
          rawAccessibilitySummary ?? this.rawAccessibilitySummary,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
    );
  }

  Map<String, dynamic> toJson() => {
        if (sgValue != null) 'sgValue': sgValue,
        if (sgDateTime != null)
          'sgDateTime': sgDateTime!.toUtc().toIso8601String(),
        'sgTrend': sgTrend,
        'sgOrigin': sgOrigin.name,
        if (activeInsulin != null) 'activeInsulin': activeInsulin,
        if (reservoirRemaining != null)
          'reservoirRemaining': reservoirRemaining,
        if (pumpBatteryPercent != null)
          'pumpBatteryPercent': pumpBatteryPercent,
        if (pumpBatteryLabel != null) 'pumpBatteryLabel': pumpBatteryLabel,
        if (sensorBatteryLabel != null)
          'sensorBatteryLabel': sensorBatteryLabel,
        if (sensorDaysRemaining != null)
          'sensorDaysRemaining': sensorDaysRemaining,
        if (sensorMinutesLeft != null) 'sensorMinutesLeft': sensorMinutesLeft,
        'sgHistory': sgHistory.map((e) => e.toJson()).toList(),
        'mealMarkers': mealMarkers.map((e) => e.toJson()).toList(),
        'bolusMarkers': bolusMarkers.map((e) => e.toJson()).toList(),
        'autoBasalMarkers': autoBasalMarkers.map((e) => e.toJson()).toList(),
        'dataSource': dataSource,
        if (rawNotificationSummary != null)
          'rawNotificationSummary': rawNotificationSummary,
        if (rawAccessibilitySummary != null)
          'rawAccessibilitySummary': rawAccessibilitySummary,
        if (errorMessage != null) 'errorMessage': errorMessage,
      };

  factory PumpTelemetry.fromJson(Map<String, dynamic> json) {
    return PumpTelemetry(
      sgValue: (json['sgValue'] as num?)?.toInt(),
      sgDateTime: json['sgDateTime'] != null
          ? DateTime.tryParse(json['sgDateTime'].toString())
          : null,
      sgTrend: json['sgTrend']?.toString() ?? 'NONE',
      sgOrigin: TelemetryOrigin.fromString(json['sgOrigin']?.toString()),
      activeInsulin: (json['activeInsulin'] as num?)?.toDouble(),
      reservoirRemaining: (json['reservoirRemaining'] as num?)?.toDouble(),
      pumpBatteryPercent: (json['pumpBatteryPercent'] as num?)?.toInt(),
      pumpBatteryLabel: json['pumpBatteryLabel']?.toString(),
      sensorBatteryLabel: json['sensorBatteryLabel']?.toString(),
      sensorDaysRemaining: json['sensorDaysRemaining']?.toString(),
      sensorMinutesLeft: (json['sensorMinutesLeft'] as num?)?.toInt(),
      sgHistory: (json['sgHistory'] as List<dynamic>? ?? [])
          .map((e) => SgReading.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList(),
      mealMarkers: (json['mealMarkers'] as List<dynamic>? ?? [])
          .map((e) => MealMarker.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList(),
      bolusMarkers: (json['bolusMarkers'] as List<dynamic>? ?? [])
          .map((e) => BolusMarker.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList(),
      autoBasalMarkers: (json['autoBasalMarkers'] as List<dynamic>? ?? [])
          .map((e) =>
              AutoBasalMarker.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList(),
      dataSource: json['dataSource']?.toString() ?? 'A aguardar dados da 780G',
      rawNotificationSummary: json['rawNotificationSummary']?.toString(),
      rawAccessibilitySummary: json['rawAccessibilitySummary']?.toString(),
      errorMessage: json['errorMessage']?.toString(),
    );
  }

  String encode() => jsonEncode(toJson());

  static PumpTelemetry? decode(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      return PumpTelemetry.fromJson(
        Map<String, dynamic>.from(jsonDecode(raw) as Map),
      );
    } catch (_) {
      return null;
    }
  }
}
