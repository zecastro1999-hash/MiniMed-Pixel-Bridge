import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:home_widget/home_widget.dart';
import '../models/pump_telemetry.dart';
import 'glucose_prediction_service.dart';
import 'sport_prediction_service.dart';
import 'time_in_range_service.dart';

class WidgetService {
  static const String androidProviderName = 'MinimedWidgetProvider';
  static const String qualifiedAndroidName =
      'com.minimed.bridge.minimed_pixel_bridge.MinimedWidgetProvider';
  static const MethodChannel _notifChannel =
      MethodChannel('com.minimed.bridge/notifications');

  /// Helper returning true only when [prediction30m] holds a sufficiently
  /// validated numeric 30-minute estimate suitable for display on the
  /// persistent notification.
  static bool isValidatedNumericPrediction(
    GlucosePredictionResult? prediction30m,
  ) {
    if (prediction30m == null) return false;
    return prediction30m.hasNumericEstimate &&
        prediction30m.confidence != null &&
        prediction30m.confidence != PredictionConfidence.low;
  }

  /// Pushes prioritized, uncluttered [PumpTelemetry], [TimeInRangeSummary], and
  /// [GlucosePredictionResult] data to `HomeWidget`, triggers native widget
  /// redraw, and refreshes the ongoing silent persistent notification.
  static Future<bool> syncWidgetWithTelemetry(
    PumpTelemetry telemetry, {
    TimeInRangeSummary? tir24h,
    GlucosePredictionResult? prediction30m,
    SportEvaluationResult? sportEvaluation,
    TargetRangeConfig range = TargetRangeConfig.defaultRange,
    bool careLinkReauthRequired = false,
  }) async {
    try {
      final sanitizedRange = range.sanitized();
      final futures = <Future<bool?>>[
        HomeWidget.saveWidgetData<String>(
          'target_low_mgdl',
          sanitizedRange.lowMgDl.toString(),
        ),
        HomeWidget.saveWidgetData<String>(
          'target_high_mgdl',
          sanitizedRange.highMgDl.toString(),
        ),
        HomeWidget.saveWidgetData<String>(
          'carelink_reauth_required',
          careLinkReauthRequired ? 'true' : 'false',
        ),
      ];

      final hasAnyRealData = telemetry.sgValue != null ||
          telemetry.activeInsulin != null ||
          telemetry.reservoirRemaining != null ||
          telemetry.pumpBatteryPercent != null ||
          telemetry.pumpBatteryLabel != null;

      if (hasAnyRealData) {
        if (telemetry.sgValue != null) {
          futures.add(HomeWidget.saveWidgetData<String>(
            'sg_value',
            telemetry.sgValue.toString(),
          ));
          futures.add(HomeWidget.saveWidgetData<String>(
            'sg_trend',
            telemetry.sgTrend,
          ));
          futures.add(HomeWidget.saveWidgetData<String>(
            'sg_trend_arrow',
            telemetry.trendArrow,
          ));
          futures.add(HomeWidget.saveWidgetData<String>(
            'sg_state_pt',
            telemetry.glycemicStatePt(sanitizedRange),
          ));
          futures.add(HomeWidget.saveWidgetData<String>(
            'sg_trend_text_pt',
            telemetry.trendDescriptionPt(),
          ));
          futures.add(HomeWidget.saveWidgetData<String>(
            'last_updated',
            telemetry.timeSinceReadingLabel,
          ));
          if (telemetry.sgDateTime != null) {
            futures.add(HomeWidget.saveWidgetData<String>(
              'last_timestamp_ms',
              telemetry.sgDateTime!.millisecondsSinceEpoch.toString(),
            ));
          }
        }

        final predLabel = prediction30m != null
            ? prediction30m.shortWidgetLabelPt
            : 'indisponível';
        futures.add(HomeWidget.saveWidgetData<String>(
          'predicted_30m_label',
          predLabel,
        ));

        final validatedPred = isValidatedNumericPrediction(prediction30m);
        futures.add(HomeWidget.saveWidgetData<String>(
          'predicted_30m_validated',
          validatedPred ? 'true' : 'false',
        ));
        futures.add(HomeWidget.saveWidgetData<String>(
          'predicted_30m_sg',
          validatedPred ? prediction30m!.estimatedSg30m!.toString() : '',
        ));
        futures.add(HomeWidget.saveWidgetData<String>(
          'predicted_30m_reading_ts_ms',
          validatedPred && telemetry.sgDateTime != null
              ? telemetry.sgDateTime!.millisecondsSinceEpoch.toString()
              : '',
        ));

        final tirPct = tir24h?.inRangePercent;
        futures.add(HomeWidget.saveWidgetData<String>(
          'tir_percent',
          tirPct != null ? '${tirPct.round()}%' : '--%',
        ));

        if (telemetry.activeInsulin != null) {
          final iobPt = telemetry.activeInsulin!
              .toStringAsFixed(2)
              .replaceAll('.', ',');
          futures.add(HomeWidget.saveWidgetData<String>(
            'active_insulin',
            '$iobPt U',
          ));
        }

        if (telemetry.reservoirRemaining != null) {
          final resPt = telemetry.reservoirRemaining!
              .toStringAsFixed(1)
              .replaceAll('.', ',');
          futures.add(HomeWidget.saveWidgetData<String>(
            'reservoir',
            '$resPt U',
          ));
        }

        if (telemetry.pumpBatteryDisplay != '--') {
          futures.add(HomeWidget.saveWidgetData<String>(
            'pump_battery',
            telemetry.pumpBatteryDisplay,
          ));
        }

        final sportSummary = (sportEvaluation != null &&
                sportEvaluation.isExerciseActiveOrRecovery)
            ? '${sportEvaluation.state.labelPt} • ${sportEvaluation.riskLevel.labelPt}'
            : '';
        futures.add(HomeWidget.saveWidgetData<String>(
          'sport_status',
          sportSummary,
        ));

        futures.add(HomeWidget.saveWidgetData<String>(
          'source_badge',
          telemetry.dataSource,
        ));
      } else {
        futures.add(HomeWidget.saveWidgetData<String>(
          'predicted_30m_validated',
          'false',
        ));
        futures.add(HomeWidget.saveWidgetData<String>(
          'predicted_30m_sg',
          '',
        ));
      }

      await Future.wait(futures);

      final result = await HomeWidget.updateWidget(
        name: androidProviderName,
        androidName: androidProviderName,
        qualifiedAndroidName: qualifiedAndroidName,
      );

      try {
        await _notifChannel.invokeMethod('refreshRichNotification');
      } catch (_) {
        // Ignored inside headless background WorkManager isolates;
        // MinimedWidgetProvider.onUpdate also triggers rich notification update natively!
      }

      return result ?? false;
    } catch (e) {
      debugPrint('WidgetService.syncWidgetWithTelemetry error: ${e.runtimeType}');
      return false;
    }
  }

  static Future<void> requestPinToHomeScreen() async {
    try {
      final supported = await HomeWidget.isRequestPinWidgetSupported();
      if (supported == true) {
        await HomeWidget.requestPinWidget(
          name: androidProviderName,
          androidName: androidProviderName,
          qualifiedAndroidName: qualifiedAndroidName,
        );
      }
    } catch (e) {
      debugPrint('WidgetService.requestPinToHomeScreen error: ${e.runtimeType}');
    }
  }
}
