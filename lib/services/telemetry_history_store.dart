import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/pump_telemetry.dart';

class ManualWorkoutSession {
  final String activityTypeName;
  final DateTime startTime;
  final DateTime? endTime;

  const ManualWorkoutSession({
    required this.activityTypeName,
    required this.startTime,
    this.endTime,
  });

  bool get isOngoing => endTime == null;

  Map<String, dynamic> toJson() => {
        'activityTypeName': activityTypeName,
        'startTime': startTime.toUtc().toIso8601String(),
        if (endTime != null) 'endTime': endTime!.toUtc().toIso8601String(),
      };

  factory ManualWorkoutSession.fromJson(Map<String, dynamic> json) {
    return ManualWorkoutSession(
      activityTypeName: json['activityTypeName']?.toString() ?? 'OTHER',
      startTime: DateTime.tryParse(json['startTime']?.toString() ?? '') ??
          DateTime.now().toUtc(),
      endTime: json['endTime'] != null
          ? DateTime.tryParse(json['endTime'].toString())
          : null,
    );
  }
}

/// Manages persistent 14-day glycemic history, target range settings, and
/// manual workout state across app restarts and WorkManager isolates.
class TelemetryHistoryStore {
  static const String prefKeySgHistory14d = 'persistent_sg_history_14d_json';
  static const String prefKeyMealHistory = 'persistent_meal_history_json';
  static const String prefKeyBolusHistory = 'persistent_bolus_history_json';
  static const String prefKeyTargetRange = 'target_glucose_range_json';
  static const String prefKeyManualWorkout = 'manual_sport_session_json';
  static const Duration retentionWindow = Duration(days: 15);
  static const int maxStoredReadings = 4500;

  final Future<SharedPreferences?> Function() _prefsProvider;
  final DateTime Function() _nowProvider;

  TelemetryHistoryStore({
    Future<SharedPreferences?> Function()? prefsProvider,
    DateTime Function()? nowProvider,
  })  : _prefsProvider = prefsProvider ?? _defaultPrefs,
        _nowProvider = nowProvider ?? DateTime.now;

  static Future<SharedPreferences?> _defaultPrefs() async {
    try {
      return await SharedPreferences.getInstance();
    } catch (_) {
      return null;
    }
  }

  Future<TargetRangeConfig> loadTargetRange() async {
    final prefs = await _prefsProvider();
    final raw = prefs?.getString(prefKeyTargetRange);
    if (raw == null || raw.isEmpty) return TargetRangeConfig.defaultRange;
    try {
      return TargetRangeConfig.fromJson(
        Map<String, dynamic>.from(jsonDecode(raw) as Map),
      );
    } catch (_) {
      return TargetRangeConfig.defaultRange;
    }
  }

  Future<void> saveTargetRange(TargetRangeConfig config) async {
    final prefs = await _prefsProvider();
    if (prefs == null) return;
    await prefs.setString(
      prefKeyTargetRange,
      jsonEncode(config.sanitized().toJson()),
    );
  }

  Future<List<SgReading>> loadSgHistory() async {
    final prefs = await _prefsProvider();
    final raw = prefs?.getString(prefKeySgHistory14d);
    if (raw == null || raw.isEmpty) return const [];
    final now = _nowProvider();
    final cutoff = now.subtract(retentionWindow);
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      final parsed = <SgReading>[];
      for (final item in list) {
        if (item is! Map) continue;
        final reading = SgReading.fromJson(Map<String, dynamic>.from(item));
        if (reading.isValidAt(now) && !reading.timestamp.isBefore(cutoff)) {
          parsed.add(reading);
        }
      }
      parsed.sort((a, b) => a.timestamp.compareTo(b.timestamp));
      return parsed;
    } catch (_) {
      return const [];
    }
  }

  /// Merges [incoming] readings into the persisted 14-day timeline while
  /// rejecting invalid points and deduplicating noisy near-simultaneous copies.
  Future<List<SgReading>> mergeAndSaveSgHistory(
    List<SgReading> incoming, {
    bool overwriteAllWith = false,
  }) async {
    final now = _nowProvider();
    final cutoff = now.subtract(retentionWindow);
    final base = overwriteAllWith ? <SgReading>[] : await loadSgHistory();
    final merged = List<SgReading>.from(base);

    for (final candidate in incoming) {
      if (!candidate.isValidAt(now)) continue;
      if (candidate.timestamp.isBefore(cutoff)) continue;

      final existingIdx = merged.indexWhere(
        (r) =>
            r.timestamp.difference(candidate.timestamp).inSeconds.abs() < 45,
      );
      if (existingIdx == -1) {
        merged.add(candidate);
      } else {
        final existing = merged[existingIdx];
        if (_originPriority(candidate.origin) >
            _originPriority(existing.origin)) {
          merged[existingIdx] = candidate;
        }
      }
    }

    merged.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    final trimmed = merged.length > maxStoredReadings
        ? merged.sublist(merged.length - maxStoredReadings)
        : merged;

    final prefs = await _prefsProvider();
    if (prefs != null) {
      await prefs.setString(
        prefKeySgHistory14d,
        jsonEncode(trimmed.map((e) => e.toJson()).toList()),
      );
    }
    return trimmed;
  }

  static int _originPriority(TelemetryOrigin origin) {
    switch (origin) {
      case TelemetryOrigin.carelink:
        return 5;
      case TelemetryOrigin.xdrip:
        return 4;
      case TelemetryOrigin.notification:
        return 3;
      case TelemetryOrigin.accessibility:
        return 2;
      case TelemetryOrigin.healthConnect:
        return 1;
      case TelemetryOrigin.unknown:
        return 0;
    }
  }

  Future<List<MealMarker>> mergeAndSaveMeals(List<MealMarker> incoming) async {
    final now = _nowProvider();
    final cutoff = now.subtract(retentionWindow);
    final prefs = await _prefsProvider();
    final raw = prefs?.getString(prefKeyMealHistory);
    final merged = <MealMarker>[];
    if (raw != null && raw.isNotEmpty) {
      try {
        for (final item in (jsonDecode(raw) as List<dynamic>)) {
          if (item is! Map) continue;
          final m = MealMarker.fromJson(Map<String, dynamic>.from(item));
          if (m.isValidAt(now) && !m.timestamp.isBefore(cutoff)) {
            merged.add(m);
          }
        }
      } catch (_) {}
    }

    for (final candidate in incoming) {
      if (!candidate.isValidAt(now) || candidate.timestamp.isBefore(cutoff)) {
        continue;
      }
      final exists = merged.any(
        (m) =>
            (m.carbsGrams - candidate.carbsGrams).abs() < 0.5 &&
            m.timestamp.difference(candidate.timestamp).inMinutes.abs() <= 2,
      );
      if (!exists) {
        merged.add(candidate);
      }
    }

    merged.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    final trimmed =
        merged.length > 500 ? merged.sublist(merged.length - 500) : merged;
    if (prefs != null) {
      await prefs.setString(
        prefKeyMealHistory,
        jsonEncode(trimmed.map((e) => e.toJson()).toList()),
      );
    }
    return trimmed;
  }

  Future<ManualWorkoutSession?> loadManualWorkout() async {
    final prefs = await _prefsProvider();
    final raw = prefs?.getString(prefKeyManualWorkout);
    if (raw == null || raw.isEmpty) return null;
    try {
      final session = ManualWorkoutSession.fromJson(
        Map<String, dynamic>.from(jsonDecode(raw) as Map),
      );
      // Ignore abandoned manual sessions older than 12 hours when finished,
      // or cap > 12h ongoing manual sessions transparently.
      if (session.endTime != null &&
          _nowProvider().difference(session.endTime!) >
              const Duration(hours: 24)) {
        await clearManualWorkout();
        return null;
      }
      return session;
    } catch (_) {
      return null;
    }
  }

  Future<void> saveManualWorkout(ManualWorkoutSession session) async {
    final prefs = await _prefsProvider();
    if (prefs == null) return;
    await prefs.setString(prefKeyManualWorkout, jsonEncode(session.toJson()));
  }

  Future<void> clearManualWorkout() async {
    final prefs = await _prefsProvider();
    await prefs?.remove(prefKeyManualWorkout);
  }

  Future<void> clearAllHistory() async {
    final prefs = await _prefsProvider();
    if (prefs == null) return;
    await prefs.remove(prefKeySgHistory14d);
    await prefs.remove(prefKeyMealHistory);
    await prefs.remove(prefKeyBolusHistory);
    await prefs.remove(prefKeyManualWorkout);
  }
}
