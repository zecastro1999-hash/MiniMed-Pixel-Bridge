import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';
import 'carelink_service.dart';
import 'glucose_prediction_service.dart';
import 'health_connect_service.dart';
import 'notification_service.dart';
import 'sport_prediction_service.dart';
import 'telemetry_history_store.dart';
import 'time_in_range_service.dart';
import 'widget_service.dart';

const String kPeriodicSyncUniqueName = 'minimed_780g_periodic_sync_unique';
const String kPeriodicSyncTaskName = 'minimed_780g_periodic_sync_task';

@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((taskName, inputData) async {
    WidgetsFlutterBinding.ensureInitialized();
    try {
      await SharedPreferences.getInstance();

      final careLinkService = CareLinkService();
      final healthService = HealthConnectService();
      final historyStore = TelemetryHistoryStore();

      // 1. Fetch latest CareLink (with automatic OAuth2 token refresh) or xDrip+
      var telemetry = await careLinkService.fetchLatestTelemetry();

      // 2. Also read local Notification / Accessibility data stored natively in HomeWidgetPreferences
      final localState =
          await NotificationService.readLocalBridgeStateFromHomeWidget();
      telemetry = NotificationService.mergeLocalBridgeState(
        telemetry,
        localState,
      );

      // 3. Persist up to 14 days of history cleanly across restarts
      final mergedHistory =
          await historyStore.mergeAndSaveSgHistory(telemetry.sgHistory);
      final mergedMeals =
          await historyStore.mergeAndSaveMeals(telemetry.mealMarkers);
      telemetry = telemetry.copyWith(
        sgHistory: mergedHistory,
        mealMarkers: mergedMeals,
      );
      await careLinkService.cacheTelemetry(telemetry);

      final range = await historyStore.loadTargetRange();
      final manualSession = await historyStore.loadManualWorkout();

      // 4. Read Fitbit Health Connect metrics if already authorized in background
      final fitbitMetrics = await healthService.fetchFitbitMetrics24h(
        requestPermissionIfMissing: false,
      );

      final sportEval = SportPredictionService.evaluate(
        telemetry: telemetry,
        fitbitMetrics: fitbitMetrics,
        manualSession: manualSession,
      );
      final tir24h = TimeInRangeService.computeWindowMetrics(
        readings: telemetry.sgHistory,
        period: TirPeriod.h24,
        range: range,
      );
      final pred30m = GlucosePredictionService.predict(
        telemetry: telemetry,
        isExerciseActiveOrRecovery: sportEval.isExerciseActiveOrRecovery,
      );

      // 5. Write pending & new SG/meal readings to Google Health Connect
      final hcSummary = await healthService.syncTelemetryToHealthConnect(
        telemetry,
        requestPermissionIfMissing: false,
      );

      // 6. Refresh HomeWidget & persistent notification
      final sessionStatus = await careLinkService.getSessionStatus();
      await WidgetService.syncWidgetWithTelemetry(
        telemetry,
        tir24h: tir24h,
        prediction30m: pred30m,
        sportEvaluation: sportEval,
        range: range,
        careLinkReauthRequired:
            sessionStatus == CareLinkSessionStatus.reauthRequired,
      );

      await healthService.recordBackgroundSyncAttempt(
        '${hcSummary.status.labelPt} (${hcSummary.sgWrittenCount} SG, ${hcSummary.pendingCount} pendentes)',
      );

      return true;
    } catch (e) {
      debugPrint('Background Workmanager sync error ($taskName): ${e.runtimeType}');
      return false;
    }
  });
}

class BackgroundSyncService {
  static Future<void> initializeAndSchedule() async {
    try {
      await Workmanager().initialize(callbackDispatcher);
      await Workmanager().registerPeriodicTask(
        kPeriodicSyncUniqueName,
        kPeriodicSyncTaskName,
        frequency: const Duration(minutes: 15),
        initialDelay: const Duration(minutes: 15),
        existingWorkPolicy: ExistingPeriodicWorkPolicy.update,
        constraints: Constraints(
          networkType: NetworkType.notRequired,
        ),
      );
    } catch (e) {
      debugPrint('BackgroundSyncService.initializeAndSchedule error: ${e.runtimeType}');
    }
  }
}
