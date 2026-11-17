import 'dart:async';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:health/health.dart';
import 'package:intl/intl.dart';
import '../main.dart';
import '../models/pump_telemetry.dart';
import '../services/carelink_service.dart';
import '../services/glucose_prediction_service.dart';
import '../services/health_connect_service.dart';
import '../services/notification_service.dart';
import '../services/sport_prediction_service.dart';
import '../services/telemetry_history_store.dart';
import '../services/time_in_range_service.dart';
import '../services/widget_service.dart';
import '../widgets/settings_modals.dart';
import '../widgets/tir_ring_painter.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen>
    with WidgetsBindingObserver {
  late final CareLinkService _careLinkService;
  final HealthConnectService _healthConnectService = HealthConnectService();
  final NotificationService _notificationService = NotificationService();
  final TelemetryHistoryStore _historyStore = TelemetryHistoryStore();

  int _selectedTabIndex = 0;
  int _chartHours = 6;
  TirPeriod _selectedTirPeriod = TirPeriod.h24;
  HealthWorkoutActivityType _selectedManualSport =
      HealthWorkoutActivityType.RUNNING;

  PumpTelemetry _telemetry = PumpTelemetry.empty();
  FitbitHealthMetrics _fitbitMetrics = const FitbitHealthMetrics();
  TargetRangeConfig _targetRange = TargetRangeConfig.defaultRange;
  ManualWorkoutSession? _manualWorkout;
  CareLinkSessionStatus _careLinkStatus = CareLinkSessionStatus.unconfigured;
  CareLinkRefreshDiagnostics? _refreshDiag;
  SyncDiagnosticsSnapshot _diagSnapshot = const SyncDiagnosticsSnapshot();
  HealthSyncResult? _lastTestSyncResult;

  bool _isLoading = true;
  bool _isSyncing = false;
  bool _isTestingSync = false;
  bool _isRefreshingLocal = false;
  bool _isRequestingHealthAuth = false;
  bool _notifAccessGranted = false;
  bool _postNotifGranted = false;
  bool _accessibilityAccessGranted = false;
  bool _healthPermissionsGranted = false;
  bool _batteryOptIgnored = false;
  bool _showAdvancedStats = false;

  StreamSubscription<InterceptedSgNotification>? _notifSub;
  Timer? _clockTimer;

  @override
  void initState() {
    super.initState();
    _careLinkService = CareLinkService(
      onStatusChanged: (status) {
        if (mounted && _careLinkStatus != status) {
          setState(() => _careLinkStatus = status);
        }
      },
    );
    WidgetsBinding.instance.addObserver(this);
    _clockTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
    _initializeBridge();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _clockTimer?.cancel();
    _notifSub?.cancel();
    _notificationService.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !_isRequestingHealthAuth) {
      _refreshLocalStateAndPermissions();
    }
  }

  Future<void> _initializeBridge() async {
    setState(() => _isLoading = true);

    _targetRange = await _historyStore.loadTargetRange();
    _manualWorkout = await _historyStore.loadManualWorkout();
    final persistedHistory = await _historyStore.loadSgHistory();

    final cachedFitbit = await _healthConnectService.loadCachedFitbitMetrics();
    if (cachedFitbit != null && mounted) {
      setState(() {
        _fitbitMetrics = cachedFitbit;
        if (cachedFitbit.authorized) {
          _healthPermissionsGranted = true;
        }
      });
    }

    _notificationService.startListening();
    _notifSub = _notificationService.onSgIntercepted.listen((event) async {
      await _handleIncomingNativeEvent(event);
    });

    await _checkSystemPermissions();
    await _notificationService.scanActiveNotifications();
    final localState = await _notificationService.getLocalBridgeState();

    var latest = await _careLinkService.fetchLatestTelemetry();
    latest = NotificationService.mergeLocalBridgeState(latest, localState);

    final mergedHistory = await _historyStore.mergeAndSaveSgHistory([
      ...persistedHistory,
      ...latest.sgHistory,
    ]);
    final mergedMeals =
        await _historyStore.mergeAndSaveMeals(latest.mealMarkers);
    latest = latest.copyWith(
      sgHistory: mergedHistory,
      mealMarkers: mergedMeals,
    );

    if (latest.sgValue == null && mergedHistory.isNotEmpty) {
      final last = mergedHistory.last;
      latest = latest.copyWith(
        sgValue: last.sg,
        sgDateTime: last.timestamp,
        sgOrigin: last.origin,
      );
    }

    await _careLinkService.cacheTelemetry(latest);

    final fitbit = await _healthConnectService.fetchFitbitMetrics24h(
      requestPermissionIfMissing: false,
    );
    await _healthConnectService.syncTelemetryToHealthConnect(
      latest,
      requestPermissionIfMissing: false,
    );

    final status = await _careLinkService.getSessionStatus();
    final refreshDiag = await _careLinkService.inspectStoredRefresh();
    final diag = await _healthConnectService.loadDiagnosticsSnapshot();

    await _pushWidgetAndNotification(
      telemetry: latest,
      fitbit: fitbit,
      careLinkReauthRequired: status == CareLinkSessionStatus.reauthRequired,
    );

    if (mounted) {
      setState(() {
        _telemetry = latest;
        _fitbitMetrics = fitbit;
        if (fitbit.authorized) _healthPermissionsGranted = true;
        _careLinkStatus = status;
        _refreshDiag = refreshDiag;
        _diagSnapshot = diag;
        _isLoading = false;
      });
    }
  }

  Future<void> _handleIncomingNativeEvent(InterceptedSgNotification event) async {
    final now = DateTime.now();
    var incomingHistory = List<SgReading>.from(_telemetry.sgHistory);
    final origin = event.eventType == 'accessibility'
        ? TelemetryOrigin.accessibility
        : TelemetryOrigin.notification;

    if (event.sgValue != null) {
      final candidate = SgReading(
        sg: event.sgValue!,
        timestamp: event.timestamp,
        origin: origin,
      );
      if (candidate.isValidAt(now)) {
        incomingHistory = await _historyStore.mergeAndSaveSgHistory([
          ...incomingHistory,
          candidate,
        ]);
      }
    }

    var updatedMeals = List<MealMarker>.from(_telemetry.mealMarkers);
    if (event.carbsGrams != null && event.carbsGrams! > 0) {
      final meal = MealMarker(
        carbsGrams: event.carbsGrams!,
        timestamp: event.timestamp,
        displayTime: event.carbsTime,
        origin: origin,
      );
      if (meal.isValidAt(now)) {
        updatedMeals = await _historyStore.mergeAndSaveMeals([
          ...updatedMeals,
          meal,
        ]);
      }
    }

    final sourceLabel =
        event.eventType == 'accessibility' ? 'MiniMed Ecrã' : 'MiniMed Notif.';

    final updated = _telemetry.copyWith(
      sgValue: event.sgValue ?? _telemetry.sgValue,
      sgDateTime:
          event.sgValue != null ? event.timestamp : _telemetry.sgDateTime,
      sgTrend: event.sgValue != null ? event.trend : _telemetry.sgTrend,
      sgOrigin: event.sgValue != null ? origin : _telemetry.sgOrigin,
      activeInsulin: event.activeInsulin ?? _telemetry.activeInsulin,
      reservoirRemaining:
          event.reservoirRemaining ?? _telemetry.reservoirRemaining,
      pumpBatteryPercent: event.pumpBatteryPercent,
      clearPumpBatteryPercent: event.pumpBatteryPercent == null &&
          event.pumpBatteryLabel != null,
      pumpBatteryLabel: event.pumpBatteryLabel ?? _telemetry.pumpBatteryLabel,
      sensorBatteryLabel:
          event.sensorBatteryLabel ?? _telemetry.sensorBatteryLabel,
      sensorDaysRemaining:
          event.sensorDaysRemaining ?? _telemetry.sensorDaysRemaining,
      sgHistory: incomingHistory,
      mealMarkers: updatedMeals,
      dataSource: sourceLabel,
    );

    if (mounted) {
      setState(() {
        _telemetry = updated;
      });
    }

    await _careLinkService.cacheTelemetry(updated);
    await _healthConnectService.syncTelemetryToHealthConnect(
      updated,
      requestPermissionIfMissing: false,
    );
    await _pushWidgetAndNotification(
      telemetry: updated,
      fitbit: _fitbitMetrics,
    );

    final diag = await _healthConnectService.loadDiagnosticsSnapshot();
    if (mounted) {
      setState(() => _diagSnapshot = diag);
    }
  }

  Future<void> _pushWidgetAndNotification({
    required PumpTelemetry telemetry,
    required FitbitHealthMetrics fitbit,
    bool? careLinkReauthRequired,
  }) async {
    final tir24 = TimeInRangeService.computeWindowMetrics(
      readings: telemetry.sgHistory,
      period: TirPeriod.h24,
      range: _targetRange,
    );
    final sportEval = SportPredictionService.evaluate(
      telemetry: telemetry,
      fitbitMetrics: fitbit,
      manualSession: _manualWorkout,
    );
    final pred30 = GlucosePredictionService.predict(
      telemetry: telemetry,
      isExerciseActiveOrRecovery: sportEval.isExerciseActiveOrRecovery,
    );

    await WidgetService.syncWidgetWithTelemetry(
      telemetry,
      tir24h: tir24,
      prediction30m: pred30,
      sportEvaluation: sportEval,
      range: _targetRange,
      careLinkReauthRequired: careLinkReauthRequired ??
          (_careLinkStatus == CareLinkSessionStatus.reauthRequired),
    );
  }

  Future<void> _refreshLocalStateAndPermissions() async {
    if (_isRefreshingLocal || _isRequestingHealthAuth) return;
    _isRefreshingLocal = true;
    try {
      await _checkSystemPermissions();
      await _notificationService.scanActiveNotifications();
      final localState = await _notificationService.getLocalBridgeState();
      var merged =
          NotificationService.mergeLocalBridgeState(_telemetry, localState);

      final persistedHistory =
          await _historyStore.mergeAndSaveSgHistory(merged.sgHistory);
      merged = merged.copyWith(sgHistory: persistedHistory);

      final fitbit = await _healthConnectService.fetchFitbitMetrics24h(
        requestPermissionIfMissing: false,
      );
      final diag = await _healthConnectService.loadDiagnosticsSnapshot();
      final status = await _careLinkService.getSessionStatus();

      if (mounted) {
        setState(() {
          _telemetry = merged;
          _fitbitMetrics = fitbit;
          _diagSnapshot = diag;
          _careLinkStatus = status;
          if (fitbit.authorized) _healthPermissionsGranted = true;
        });
      }

      await _pushWidgetAndNotification(
        telemetry: merged,
        fitbit: fitbit,
      );
    } finally {
      _isRefreshingLocal = false;
    }
  }

  Future<void> _authorizeHealthConnect() async {
    if (_isRequestingHealthAuth) return;
    setState(() => _isRequestingHealthAuth = true);
    try {
      await _healthConnectService.requestPermissions();
      await _checkSystemPermissions();
      final metrics = await _healthConnectService.fetchFitbitMetrics24h(
        requestPermissionIfMissing: false,
      );
      final diag = await _healthConnectService.loadDiagnosticsSnapshot();
      if (!mounted) return;
      setState(() {
        _fitbitMetrics = metrics;
        _diagSnapshot = diag;
        if (metrics.authorized || diag.glucoseWriteGranted) {
          _healthPermissionsGranted = true;
        }
      });
      await _pushWidgetAndNotification(
        telemetry: _telemetry,
        fitbit: metrics,
      );
    } finally {
      if (mounted) {
        setState(() => _isRequestingHealthAuth = false);
      } else {
        _isRequestingHealthAuth = false;
      }
    }
  }

  Future<void> _checkSystemPermissions() async {
    final notifOk = await _notificationService.isNotificationAccessGranted();
    final postOk = await _notificationService.isPostNotificationsGranted();
    final accessOk = await _notificationService.isAccessibilityAccessGranted();
    final battOk = await _notificationService.isIgnoringBatteryOptimizations();
    final glucoseWrite =
        await _healthConnectService.hasGlucoseWritePermission();
    final grantedFitbit = await _healthConnectService.getGrantedFitbitTypes();
    final cachedFitbitAuth =
        await _healthConnectService.getCachedFitbitAuthorized();
    final diag = await _healthConnectService.loadDiagnosticsSnapshot();

    final hcOk =
        grantedFitbit.isNotEmpty || glucoseWrite || cachedFitbitAuth;
    if (mounted) {
      setState(() {
        _notifAccessGranted = notifOk;
        _postNotifGranted = postOk;
        _accessibilityAccessGranted = accessOk;
        _batteryOptIgnored = battOk;
        _healthPermissionsGranted = hcOk;
        _diagSnapshot = diag;
      });
    }
  }

  Future<void> _forceSyncAll() async {
    if (_isSyncing) return;
    setState(() => _isSyncing = true);

    try {
      await _notificationService.scanActiveNotifications();
      final localState = await _notificationService.getLocalBridgeState();

      var telemetry = await _careLinkService.fetchLatestTelemetry();
      telemetry =
          NotificationService.mergeLocalBridgeState(telemetry, localState);

      final mergedHistory =
          await _historyStore.mergeAndSaveSgHistory(telemetry.sgHistory);
      final mergedMeals =
          await _historyStore.mergeAndSaveMeals(telemetry.mealMarkers);
      telemetry = telemetry.copyWith(
        sgHistory: mergedHistory,
        mealMarkers: mergedMeals,
      );
      await _careLinkService.cacheTelemetry(telemetry);

      await _healthConnectService.syncTelemetryToHealthConnect(
        telemetry,
        requestPermissionIfMissing: false,
      );
      final fitbit = await _healthConnectService.fetchFitbitMetrics24h(
        requestPermissionIfMissing: false,
      );

      await _checkSystemPermissions();
      final status = await _careLinkService.getSessionStatus();
      final refreshDiag = await _careLinkService.inspectStoredRefresh();
      final diag = await _healthConnectService.loadDiagnosticsSnapshot();

      await _pushWidgetAndNotification(
        telemetry: telemetry,
        fitbit: fitbit,
        careLinkReauthRequired: status == CareLinkSessionStatus.reauthRequired,
      );

      if (mounted) {
        setState(() {
          _telemetry = telemetry;
          _fitbitMetrics = fitbit;
          _careLinkStatus = status;
          _refreshDiag = refreshDiag;
          _diagSnapshot = diag;
          _isSyncing = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isSyncing = false);
      }
    }
  }

  Future<void> _runTestSyncDiagnostic() async {
    if (_isTestingSync) return;
    setState(() => _isTestingSync = true);
    try {
      final result = await _healthConnectService.testSynchronization(
        currentTelemetry: _telemetry,
      );
      final diag = await _healthConnectService.loadDiagnosticsSnapshot();
      if (!mounted) return;
      setState(() {
        _lastTestSyncResult = result;
        _diagSnapshot = diag;
        _isTestingSync = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${result.status.labelPt}: ${result.message}')),
      );
    } catch (e) {
      if (mounted) {
        setState(() => _isTestingSync = false);
      }
    }
  }

  Future<void> _startManualWorkout() async {
    final session = ManualWorkoutSession(
      activityTypeName: _selectedManualSport.name,
      startTime: DateTime.now().toUtc(),
    );
    await _historyStore.saveManualWorkout(session);
    if (mounted) {
      setState(() => _manualWorkout = session);
    }
    await _pushWidgetAndNotification(
      telemetry: _telemetry,
      fitbit: _fitbitMetrics,
    );
  }

  Future<void> _stopManualWorkout() async {
    final current = _manualWorkout;
    if (current == null || !current.isOngoing) return;
    final ended = ManualWorkoutSession(
      activityTypeName: current.activityTypeName,
      startTime: current.startTime,
      endTime: DateTime.now().toUtc(),
    );
    await _historyStore.saveManualWorkout(ended);
    if (mounted) {
      setState(() => _manualWorkout = ended);
    }
    await _pushWidgetAndNotification(
      telemetry: _telemetry,
      fitbit: _fitbitMetrics,
    );
  }

  String _formatPtNumber(double value, int decimals) {
    return value.toStringAsFixed(decimals).replaceAll('.', ',');
  }

  SportEvaluationResult get _currentSportEval => SportPredictionService.evaluate(
        telemetry: _telemetry,
        fitbitMetrics: _fitbitMetrics,
        manualSession: _manualWorkout,
      );

  GlucosePredictionResult get _currentPrediction30m =>
      GlucosePredictionService.predict(
        telemetry: _telemetry,
        isExerciseActiveOrRecovery: _currentSportEval.isExerciseActiveOrRecovery,
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: EspressoPalette.background,
      appBar: AppBar(
        backgroundColor: EspressoPalette.background,
        surfaceTintColor: Colors.transparent,
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: EspressoPalette.cardBrown,
                borderRadius: BorderRadius.circular(14),
              ),
              child: const Icon(
                Icons.water_drop_rounded,
                color: EspressoPalette.peachAccent,
                size: 20,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'MiniMed 780G',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: EspressoPalette.creamText,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    _careLinkStatus.labelPt,
                    style: TextStyle(
                      fontSize: 11.5,
                      color:
                          _careLinkStatus == CareLinkSessionStatus.reauthRequired
                              ? const Color(0xFFFFB4AB)
                              : EspressoPalette.sandAccent,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Sincronizar agora',
            onPressed: _isSyncing ? null : _forceSyncAll,
            icon: _isSyncing
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: EspressoPalette.peachAccent,
                    ),
                  )
                : const Icon(
                    Icons.sync_rounded,
                    color: EspressoPalette.creamText,
                  ),
          ),
        ],
      ),
      body: _isLoading
          ? const Center(
              child: CircularProgressIndicator(
                color: EspressoPalette.peachAccent,
              ),
            )
          : IndexedStack(
              index: _selectedTabIndex,
              children: [
                _buildLiveTab(),
                _buildSportTab(),
                _buildMetricsTab(),
                _buildConfigTab(),
              ],
            ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedTabIndex,
        backgroundColor: EspressoPalette.cardEspresso,
        indicatorColor: EspressoPalette.cardBrown,
        surfaceTintColor: Colors.transparent,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        onDestinationSelected: (index) =>
            setState(() => _selectedTabIndex = index),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.sensors_outlined, color: EspressoPalette.sandAccent),
            selectedIcon:
                Icon(Icons.sensors_rounded, color: EspressoPalette.peachAccent),
            label: 'Live',
          ),
          NavigationDestination(
            icon: Icon(Icons.fitness_center_outlined,
                color: EspressoPalette.sandAccent),
            selectedIcon: Icon(Icons.fitness_center_rounded,
                color: EspressoPalette.peachAccent),
            label: 'Desporto',
          ),
          NavigationDestination(
            icon: Icon(Icons.analytics_outlined,
                color: EspressoPalette.sandAccent),
            selectedIcon: Icon(Icons.analytics_rounded,
                color: EspressoPalette.peachAccent),
            label: 'Métricas',
          ),
          NavigationDestination(
            icon: Icon(Icons.tune_outlined, color: EspressoPalette.sandAccent),
            selectedIcon:
                Icon(Icons.tune_rounded, color: EspressoPalette.peachAccent),
            label: 'Config',
          ),
        ],
      ),
    );
  }

  // =========================================================================
  // TAB 1: LIVE (Minimalist 5-step hierarchy)
  // =========================================================================

  Widget _buildLiveTab() {
    final now = DateTime.now();
    final tir24 = TimeInRangeService.computeWindowMetrics(
      readings: _telemetry.sgHistory,
      period: TirPeriod.h24,
      range: _targetRange,
      asOf: now,
    );
    final streak = TimeInRangeService.computeInRangeStreak(
      readings: _telemetry.sgHistory,
      range: _targetRange,
      asOf: now,
    );
    final sportEval = _currentSportEval;
    final pred30 = _currentPrediction30m;

    return RefreshIndicator(
      color: EspressoPalette.peachAccent,
      backgroundColor: EspressoPalette.cardBrown,
      onRefresh: _forceSyncAll,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
        children: [
          if (_careLinkStatus == CareLinkSessionStatus.reauthRequired) ...[
            _buildActionableAlertBanner(
              text: 'Sessão CareLink expirada — necessária nova autenticação.',
              actionLabel: 'Renovar',
              onTap: () => showCareLinkSourceSheet(
                context: context,
                careLinkService: _careLinkService,
                notificationService: _notificationService,
                onUpdated: _forceSyncAll,
              ),
            ),
            const SizedBox(height: 12),
          ],

          // 1. Glicose Atual
          _buildCurrentGlucoseHeroCard(now),
          const SizedBox(height: 14),

          // 2. Gráfico
          _buildGlucoseChartCard(now),
          const SizedBox(height: 14),

          // 3. Previsão a 30 minutos
          _buildPredictionCard(pred30),
          const SizedBox(height: 14),

          // 4. Tempo no Alvo + Cronómetro contínuo
          _buildLiveTirCard(tir24, streak),
          const SizedBox(height: 14),

          // Optional contextual sport pill ONLY when active or recovery
          if (sportEval.isExerciseActiveOrRecovery) ...[
            _buildActiveSportBanner(sportEval),
            const SizedBox(height: 14),
          ],

          // 5. Informações adicionais simplificadas
          _buildAdditionalInfoCard(now),
        ],
      ),
    );
  }

  Widget _buildActionableAlertBanner({
    required String text,
    required String actionLabel,
    required VoidCallback onTap,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF3E1E19),
        borderRadius: BorderRadius.circular(22),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.lock_reset_rounded,
            color: Color(0xFFFFB4AB),
            size: 20,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                color: Color(0xFFFFDAD6),
                fontSize: 12.5,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          TextButton(
            onPressed: onTap,
            child: Text(
              actionLabel,
              style: const TextStyle(
                color: EspressoPalette.peachAccent,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCurrentGlucoseHeroCard(DateTime now) {
    final hasSg = _telemetry.sgValue != null;
    final stale = _telemetry.isReadingStaleAt(now);
    final ageLabel = _telemetry.timeSinceReadingLabelAt(now);
    final sgColor = !hasSg
        ? EspressoPalette.sandAccent
        : (stale
            ? EspressoPalette.sandAccent
            : (_telemetry.sgValue! < _targetRange.lowMgDl
                ? const Color(0xFFFFB4AB)
                : (_telemetry.sgValue! > _targetRange.highMgDl
                    ? EspressoPalette.peachAccent
                    : Colors.white)));

    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: EspressoPalette.cardBrown,
        borderRadius: BorderRadius.circular(28),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  hasSg ? _telemetry.glycemicStatePt(_targetRange) : 'Sem leitura',
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                    color: stale && hasSg
                        ? const Color(0xFFFFB4AB)
                        : EspressoPalette.peachAccent,
                  ),
                ),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: stale && hasSg
                      ? const Color(0xFF3E1E19)
                      : EspressoPalette.cardEspresso.withValues(alpha: 0.65),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Text(
                  hasSg
                      ? (stale ? '$ageLabel · antiga' : ageLabel)
                      : _telemetry.dataSource,
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: stale && hasSg
                        ? const Color(0xFFFFDAD6)
                        : EspressoPalette.sandAccent,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Flexible(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Text(
                        hasSg ? '${_telemetry.sgValue}' : '--',
                        style: TextStyle(
                          fontSize: 56,
                          height: 1.0,
                          fontWeight: FontWeight.w800,
                          color: sgColor,
                          letterSpacing: -1.5,
                        ),
                      ),
                      const SizedBox(width: 8),
                      const Text(
                        'mg/dL',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w500,
                          color: EspressoPalette.creamText,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Text(
                        hasSg ? _telemetry.trendArrow : '',
                        style: const TextStyle(
                          fontSize: 30,
                          fontWeight: FontWeight.w700,
                          color: EspressoPalette.peachAccent,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            hasSg
                ? '${_telemetry.trendDescriptionPt()} • ${_telemetry.dataSource}'
                : 'A aguardar leitura real via CareLink ou MiniMed Mobile',
            style: const TextStyle(
              fontSize: 13,
              color: EspressoPalette.sandAccent,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGlucoseChartCard(DateTime now) {
    final cutoff = now.subtract(Duration(hours: _chartHours));
    final readings = _telemetry.sgHistory
        .where((r) => !r.timestamp.isBefore(cutoff) && !r.timestamp.isAfter(now))
        .toList()
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));

    final double maxX = _chartHours.toDouble();
    final spots = readings.map((r) {
      final hoursFromStart =
          r.timestamp.difference(cutoff).inSeconds / 3600.0;
      return FlSpot(
        hoursFromStart.clamp(0.0, maxX),
        r.sg.toDouble().clamp(40.0, 320.0),
      );
    }).toList();

    final mealVerticalLines = _telemetry.mealMarkers
        .where((m) => !m.timestamp.isBefore(cutoff) && !m.timestamp.isAfter(now))
        .map((m) {
      final x =
          (m.timestamp.difference(cutoff).inSeconds / 3600.0).clamp(0.0, maxX);
      return VerticalLine(
        x: x,
        color: EspressoPalette.peachAccent.withValues(alpha: 0.55),
        strokeWidth: 1.2,
        dashArray: [4, 4],
        label: VerticalLineLabel(
          show: true,
          alignment: Alignment.topRight,
          style: const TextStyle(
            color: EspressoPalette.peachAccent,
            fontSize: 10,
            fontWeight: FontWeight.w600,
          ),
          labelResolver: (_) => '${m.carbsGrams.round()}g',
        ),
      );
    }).toList();

    return Container(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
      decoration: BoxDecoration(
        color: EspressoPalette.cardEspresso,
        borderRadius: BorderRadius.circular(28),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Curva de glicose',
                  style: TextStyle(
                    fontSize: 14.5,
                    fontWeight: FontWeight.w700,
                    color: EspressoPalette.creamText,
                  ),
                ),
              ),
              Wrap(
                spacing: 6,
                children: [6, 12, 24].map((h) {
                  final active = _chartHours == h;
                  return ChoiceChip(
                    label: Text('${h}h'),
                    selected: active,
                    visualDensity: VisualDensity.compact,
                    labelStyle: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                      color: active
                          ? EspressoPalette.darkPillText
                          : EspressoPalette.sandAccent,
                    ),
                    selectedColor: EspressoPalette.peachAccent,
                    backgroundColor: EspressoPalette.background,
                    side: BorderSide.none,
                    onSelected: (_) => setState(() => _chartHours = h),
                  );
                }).toList(),
              ),
            ],
          ),
          const SizedBox(height: 14),
          SizedBox(
            height: 170,
            child: spots.isEmpty
                ? const Center(
                    child: Text(
                      'Sem leituras neste período.',
                      style: TextStyle(
                        color: EspressoPalette.sandAccent,
                        fontSize: 12.5,
                      ),
                    ),
                  )
                : LineChart(
                    LineChartData(
                      minX: 0,
                      maxX: maxX,
                      minY: 40,
                      maxY: 280,
                      clipData: const FlClipData.all(),
                      gridData: const FlGridData(show: false),
                      borderData: FlBorderData(show: false),
                      rangeAnnotations: RangeAnnotations(
                        horizontalRangeAnnotations: [
                          HorizontalRangeAnnotation(
                            y1: _targetRange.lowMgDl.toDouble(),
                            y2: _targetRange.highMgDl.toDouble(),
                            color: EspressoPalette.batteryFill
                                .withValues(alpha: 0.22),
                          ),
                        ],
                      ),
                      extraLinesData: ExtraLinesData(
                        horizontalLines: [
                          HorizontalLine(
                            y: _targetRange.highMgDl.toDouble(),
                            color: EspressoPalette.sandAccent
                                .withValues(alpha: 0.4),
                            strokeWidth: 1,
                            dashArray: [5, 5],
                          ),
                          HorizontalLine(
                            y: _targetRange.lowMgDl.toDouble(),
                            color: EspressoPalette.peachAccent
                                .withValues(alpha: 0.45),
                            strokeWidth: 1,
                            dashArray: [5, 5],
                          ),
                        ],
                        verticalLines: mealVerticalLines,
                      ),
                      titlesData: FlTitlesData(
                        topTitles: const AxisTitles(
                          sideTitles: SideTitles(showTitles: false),
                        ),
                        rightTitles: const AxisTitles(
                          sideTitles: SideTitles(showTitles: false),
                        ),
                        leftTitles: AxisTitles(
                          sideTitles: SideTitles(
                            showTitles: true,
                            reservedSize: 32,
                            interval: 60,
                            getTitlesWidget: (val, _) => Text(
                              val.toInt().toString(),
                              style: const TextStyle(
                                color: EspressoPalette.sandAccent,
                                fontSize: 10,
                              ),
                            ),
                          ),
                        ),
                        bottomTitles: AxisTitles(
                          sideTitles: SideTitles(
                            showTitles: true,
                            interval: (_chartHours / 4).clamp(1.0, 6.0),
                            getTitlesWidget: (val, _) {
                              final t = cutoff.add(
                                Duration(minutes: (val * 60).round()),
                              );
                              return Padding(
                                padding: const EdgeInsets.only(top: 6),
                                child: Text(
                                  DateFormat('HH:mm').format(t),
                                  style: const TextStyle(
                                    color: EspressoPalette.sandAccent,
                                    fontSize: 10,
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                      ),
                      lineBarsData: [
                        LineChartBarData(
                          spots: spots,
                          isCurved: spots.length > 2,
                          curveSmoothness: 0.22,
                          preventCurveOverShooting: true,
                          color: EspressoPalette.chartLine,
                          barWidth: 2.6,
                          dotData: FlDotData(show: spots.length < 15),
                          belowBarData: BarAreaData(
                            show: true,
                            gradient: const LinearGradient(
                              colors: [
                                EspressoPalette.chartFillTop,
                                EspressoPalette.chartFillBottom,
                              ],
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildPredictionCard(GlucosePredictionResult pred) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: EspressoPalette.cardEspresso,
        borderRadius: BorderRadius.circular(28),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Daqui a 30 minutos',
                  style: TextStyle(
                    fontSize: 14.5,
                    fontWeight: FontWeight.w700,
                    color: EspressoPalette.peachAccent,
                  ),
                ),
              ),
              if (pred.confidence != null)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: EspressoPalette.cardBrown,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Text(
                    pred.confidence!.labelPt,
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: EspressoPalette.creamText,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            pred.trendHeadlinePt,
            style: const TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w700,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            pred.numericRangeLabelPt,
            style: const TextStyle(
              fontSize: 13,
              color: EspressoPalette.sandAccent,
            ),
          ),
          if (pred.contextFactors.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: pred.contextFactors
                  .map(
                    (f) => Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: EspressoPalette.background,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        f,
                        style: const TextStyle(
                          fontSize: 11,
                          color: EspressoPalette.creamText,
                        ),
                      ),
                    ),
                  )
                  .toList(),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildLiveTirCard(
    TimeInRangeSummary tir24,
    InRangeStreakResult streak,
  ) {
    final pct = tir24.inRangePercent;
    return Material(
      color: EspressoPalette.cardEspresso,
      borderRadius: BorderRadius.circular(28),
      child: InkWell(
        borderRadius: BorderRadius.circular(28),
        onTap: () => setState(() => _selectedTabIndex = 2),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Row(
            children: [
              TirRingWidget(
                inRangePercent: pct,
                belowPercent: tir24.belowRangePercent,
                abovePercent: tir24.aboveRangePercent,
                size: 86,
                strokeWidth: 9,
              ),
              const SizedBox(width: 18),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      pct != null
                          ? 'Tempo no alvo: ${pct.round()}%'
                          : 'Tempo no alvo: --%',
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      streak.displayLabelPt,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: EspressoPalette.peachAccent,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      tir24.hasSufficientData
                          ? 'Últimas 24h • Cobertura ${tir24.coveragePercent.round()}%'
                          : 'Dados insuficientes nas últimas 24h',
                      style: const TextStyle(
                        fontSize: 11.5,
                        color: EspressoPalette.sandAccent,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(
                Icons.chevron_right_rounded,
                color: EspressoPalette.sandAccent,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildActiveSportBanner(SportEvaluationResult eval) {
    final workout = eval.activeOrRecoveryWorkout;
    return Material(
      color: EspressoPalette.cardBrown.withValues(alpha: 0.78),
      borderRadius: BorderRadius.circular(26),
      child: InkWell(
        borderRadius: BorderRadius.circular(26),
        onTap: () => setState(() => _selectedTabIndex = 1),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: EspressoPalette.cardEspresso,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: const Icon(
                  Icons.directions_run_rounded,
                  color: EspressoPalette.peachAccent,
                  size: 20,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${eval.state.labelPt} • ${workout?.displayActivityName ?? "Exercício"}',
                      style: const TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w700,
                        color: EspressoPalette.creamText,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      eval.riskLevel.labelPt,
                      style: const TextStyle(
                        fontSize: 12,
                        color: EspressoPalette.peachAccent,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(
                Icons.chevron_right_rounded,
                color: EspressoPalette.sandAccent,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAdditionalInfoCard(DateTime now) {
    final iobStr = _telemetry.activeInsulin != null
        ? '${_formatPtNumber(_telemetry.activeInsulin!, 2)} U'
        : '--';
    final resStr = _telemetry.reservoirRemaining != null
        ? '${_formatPtNumber(_telemetry.reservoirRemaining!, 1)} U'
        : '--';
    final batteryStr = _telemetry.pumpBatteryDisplay;
    final sensorStr = _telemetry.sensorRemainingDisplay;

    final remCarbs = _telemetry.estimatedRemainingCarbsAt(now);
    final showCarbs = remCarbs != null && remCarbs >= 1.0;

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: EspressoPalette.cardEspresso,
        borderRadius: BorderRadius.circular(28),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Informações adicionais',
            style: TextStyle(
              fontSize: 14.5,
              fontWeight: FontWeight.w700,
              color: EspressoPalette.creamText,
            ),
          ),
          const SizedBox(height: 14),
          _buildInfoLine('Insulina ativa', iobStr, highlight: true),
          if (showCarbs) ...[
            const SizedBox(height: 10),
            _buildInfoLine(
              'Hidratos em absorção (estimativa)',
              '~${remCarbs.round()} g',
            ),
          ],
          const SizedBox(height: 10),
          _buildInfoLine('Reservatório', resStr),
          const SizedBox(height: 10),
          _buildInfoLine('Estado da bateria', batteryStr),
          const SizedBox(height: 10),
          _buildInfoLine('Estado do sensor', sensorStr),
        ],
      ),
    );
  }

  Widget _buildInfoLine(String label, String value, {bool highlight = false}) {
    return Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: const TextStyle(
              fontSize: 13.5,
              color: EspressoPalette.sandAccent,
            ),
          ),
        ),
        Text(
          value,
          style: TextStyle(
            fontSize: 14.5,
            fontWeight: FontWeight.w700,
            color: highlight
                ? EspressoPalette.peachAccent
                : EspressoPalette.creamText,
          ),
        ),
      ],
    );
  }

  // =========================================================================
  // TAB 2: DESPORTO (Smart Sport Mode + Fitbit Health Connect)
  // =========================================================================

  Widget _buildSportTab() {
    final eval = _currentSportEval;
    final fitbit = _fitbitMetrics;
    final workout = eval.activeOrRecoveryWorkout;
    final bool showAuthPrompt =
        !fitbit.authorized && !fitbit.hasAnyData && !_healthPermissionsGranted;

    return RefreshIndicator(
      color: EspressoPalette.peachAccent,
      backgroundColor: EspressoPalette.cardBrown,
      onRefresh: _forceSyncAll,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
        children: [
          // Sport State & Prudent Assessment Card
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: EspressoPalette.cardBrown,
              borderRadius: BorderRadius.circular(28),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 5,
                      ),
                      decoration: BoxDecoration(
                        color: eval.state == SportActivityState.active
                            ? EspressoPalette.peachAccent
                            : (eval.state == SportActivityState.recovery
                                ? EspressoPalette.lightCreamPill
                                : EspressoPalette.cardEspresso),
                        borderRadius: BorderRadius.circular(18),
                      ),
                      child: Text(
                        eval.state.labelPt,
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w700,
                          color: eval.state == SportActivityState.none
                              ? EspressoPalette.sandAccent
                              : EspressoPalette.darkPillText,
                        ),
                      ),
                    ),
                    const Spacer(),
                    if (eval.isExerciseActiveOrRecovery &&
                        workout != null)
                      Text(
                        workout.displayActivityName,
                        style: const TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w700,
                          color: EspressoPalette.creamText,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 16),
                Text(
                  eval.riskLevel.labelPt,
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                    color: eval.riskLevel == SportRiskLevel.falling
                        ? const Color(0xFFFFB4AB)
                        : (eval.riskLevel == SportRiskLevel.elevatedDropRisk
                            ? EspressoPalette.peachAccent
                            : Colors.white),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  eval.summaryTextPt,
                  style: const TextStyle(
                    fontSize: 13,
                    color: EspressoPalette.creamText,
                  ),
                ),
                if (eval.state == SportActivityState.active &&
                    workout != null) ...[
                  const SizedBox(height: 14),
                  _buildMetricGrid([
                    _MetricTileData(
                      label: 'Duração decorrida',
                      value: '${eval.activeElapsed?.inMinutes ?? workout.durationMinutes} min',
                      highlight: true,
                    ),
                    _MetricTileData(
                      label: 'Freq. cardíaca',
                      value: eval.availableHeartRateBpm != null
                          ? '${eval.availableHeartRateBpm} bpm'
                          : 'Indisponível',
                    ),
                  ]),
                ] else if (eval.state == SportActivityState.recovery &&
                    workout != null) ...[
                  const SizedBox(height: 14),
                  _buildMetricGrid([
                    _MetricTileData(
                      label: 'Último treino',
                      value: workout.displayActivityName,
                    ),
                    _MetricTileData(
                      label: 'Terminou há',
                      value: TimeInRangeSummary.formatDurationPt(
                        eval.timeSinceWorkoutEnded ?? Duration.zero,
                      ),
                    ),
                  ]),
                ],
                if (eval.contributingFactors.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  ...eval.contributingFactors.map(
                    (f) => Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text(
                        '• $f',
                        style: const TextStyle(
                          fontSize: 12,
                          color: EspressoPalette.sandAccent,
                        ),
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                Text(
                  eval.experimentalDisclaimer,
                  style: const TextStyle(
                    fontSize: 11,
                    color: EspressoPalette.sandAccent,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),

          // Manual Workout Controls (handles delayed watch/Fitbit Health Connect sync)
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: EspressoPalette.cardEspresso,
              borderRadius: BorderRadius.circular(28),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Controlo manual de treino',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: EspressoPalette.creamText,
                  ),
                ),
                const SizedBox(height: 4),
                const Text(
                  'Útil quando a sincronização Health Connect do relógio apenas chega após terminar a atividade.',
                  style: TextStyle(
                    fontSize: 12,
                    color: EspressoPalette.sandAccent,
                  ),
                ),
                const SizedBox(height: 12),
                if (_manualWorkout != null && _manualWorkout!.isOngoing) ...[
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFFFFB4AB),
                        foregroundColor: EspressoPalette.darkPillText,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                      onPressed: _stopManualWorkout,
                      icon: const Icon(Icons.stop_circle_outlined),
                      label: const Text('Terminar treino em curso'),
                    ),
                  ),
                ] else ...[
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: SportPredictionService.supportedManualTypes
                        .map((type) {
                      final selected = _selectedManualSport == type;
                      return ChoiceChip(
                        label: Text(
                          FitbitWorkoutSummary.workoutDisplayNamePt(type),
                        ),
                        selected: selected,
                        labelStyle: TextStyle(
                          fontSize: 12,
                          color: selected
                              ? EspressoPalette.darkPillText
                              : EspressoPalette.creamText,
                        ),
                        selectedColor: EspressoPalette.peachAccent,
                        backgroundColor: EspressoPalette.background,
                        side: BorderSide.none,
                        onSelected: (_) =>
                            setState(() => _selectedManualSport = type),
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 14),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: EspressoPalette.peachAccent,
                        foregroundColor: EspressoPalette.darkPillText,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                      onPressed: _startManualWorkout,
                      icon: const Icon(Icons.play_arrow_rounded),
                      label: Text(
                        'Iniciar ${FitbitWorkoutSummary.workoutDisplayNamePt(_selectedManualSport)}',
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 14),

          // Health Connect / Fitbit Overview
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: EspressoPalette.cardEspresso,
              borderRadius: BorderRadius.circular(28),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'Atividade Fitbit · 24h (Health Connect)',
                        style: TextStyle(
                          fontSize: 14.5,
                          fontWeight: FontWeight.w700,
                          color: EspressoPalette.creamText,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Atualizar Health Connect',
                      onPressed: _isRequestingHealthAuth
                          ? null
                          : () async {
                              final metrics = await _healthConnectService
                                  .fetchFitbitMetrics24h(
                                requestPermissionIfMissing: false,
                              );
                              if (!mounted) return;
                              setState(() {
                                _fitbitMetrics = metrics;
                                if (metrics.authorized) {
                                  _healthPermissionsGranted = true;
                                }
                              });
                            },
                      icon: const Icon(
                        Icons.refresh_rounded,
                        color: EspressoPalette.peachAccent,
                      ),
                    ),
                  ],
                ),
                if (showAuthPrompt) ...[
                  Text(
                    fitbit.errorMessage ??
                        'Autoriza leituras de exercício, frequência cardíaca, calorias, passos e sono no Health Connect.',
                    style: const TextStyle(
                      fontSize: 12.5,
                      color: EspressoPalette.sandAccent,
                    ),
                  ),
                  const SizedBox(height: 12),
                  FilledButton.tonalIcon(
                    style: FilledButton.styleFrom(
                      backgroundColor: EspressoPalette.peachAccent,
                      foregroundColor: EspressoPalette.darkPillText,
                    ),
                    onPressed: _isRequestingHealthAuth
                        ? null
                        : _authorizeHealthConnect,
                    icon: const Icon(Icons.favorite_rounded, size: 18),
                    label: Text(
                      _isRequestingHealthAuth
                          ? 'A verificar permissões...'
                          : 'Autorizar leituras Fitbit',
                    ),
                  ),
                ] else ...[
                  const SizedBox(height: 10),
                  _buildMetricGrid([
                    _MetricTileData(
                      label: 'Passos (24h)',
                      value: fitbit.steps24h != null
                          ? '${fitbit.steps24h}'
                          : '--',
                    ),
                    _MetricTileData(
                      label: 'Calorias ativas',
                      value: fitbit.activeCalories24h != null
                          ? '${fitbit.activeCalories24h!.round()} kcal'
                          : '--',
                    ),
                    _MetricTileData(
                      label: 'FC atual / repouso',
                      value:
                          '${fitbit.latestHeartRate ?? "--"} / ${fitbit.restingHeartRate ?? "--"} bpm',
                    ),
                    _MetricTileData(
                      label: 'Sono (24h)',
                      value: fitbit.sleepFormatted,
                    ),
                  ]),
                ],
              ],
            ),
          ),

          if (fitbit.workouts24h.isNotEmpty) ...[
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: EspressoPalette.cardEspresso,
                borderRadius: BorderRadius.circular(28),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Treinos registados nas últimas 24h',
                    style: TextStyle(
                      fontSize: 14.5,
                      fontWeight: FontWeight.w700,
                      color: EspressoPalette.creamText,
                    ),
                  ),
                  const SizedBox(height: 8),
                  ...fitbit.workouts24h.take(4).map((w) {
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '${w.displayActivityName} · ${w.durationMinutes} min',
                                  style: const TextStyle(
                                    color: EspressoPalette.creamText,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                Text(
                                  '${DateFormat('HH:mm').format(w.startTime)}–${DateFormat('HH:mm').format(w.endTime)} • ${w.activeKcal.round()} kcal${w.avgHr > 0 ? " • ${w.avgHr.round()} bpm" : ""}',
                                  style: const TextStyle(
                                    color: EspressoPalette.sandAccent,
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    );
                  }),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  // =========================================================================
  // TAB 3: MÉTRICAS (Time-weighted TIR + Coverage + Simplified Terminology)
  // =========================================================================

  Widget _buildMetricsTab() {
    final now = DateTime.now();
    final summary = TimeInRangeService.computeWindowMetrics(
      readings: _telemetry.sgHistory,
      period: _selectedTirPeriod,
      range: _targetRange,
      asOf: now,
    );
    final streak = TimeInRangeService.computeInRangeStreak(
      readings: _telemetry.sgHistory,
      range: _targetRange,
      asOf: now,
    );
    final periodMean = _telemetry.meanGlucoseInWindow(
      _selectedTirPeriod.duration,
      now: now,
    );
    final estimatedA1c = periodMean != null
        ? (3.31 + (0.02392 * periodMean))
        : null;

    final tirPct = summary.inRangePercent;
    final tbrPct = summary.belowRangePercent;
    final tarPct = summary.aboveRangePercent;

    return RefreshIndicator(
      color: EspressoPalette.peachAccent,
      backgroundColor: EspressoPalette.cardBrown,
      onRefresh: _forceSyncAll,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
        children: [
          // Period switcher: 24h | 7d | 14d
          SegmentedButton<TirPeriod>(
            segments: TirPeriod.values
                .map(
                  (p) => ButtonSegment<TirPeriod>(
                    value: p,
                    label: Text(p.shortLabel),
                  ),
                )
                .toList(),
            selected: {_selectedTirPeriod},
            onSelectionChanged: (set) {
              setState(() => _selectedTirPeriod = set.first);
            },
            style: SegmentedButton.styleFrom(
              backgroundColor: EspressoPalette.cardEspresso,
              selectedBackgroundColor: EspressoPalette.peachAccent,
              selectedForegroundColor: EspressoPalette.darkPillText,
              foregroundColor: EspressoPalette.creamText,
            ),
          ),
          const SizedBox(height: 14),

          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: EspressoPalette.cardBrown,
              borderRadius: BorderRadius.circular(28),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    TirRingWidget(
                      inRangePercent: tirPct,
                      belowPercent: tbrPct,
                      abovePercent: tarPct,
                      size: 112,
                      strokeWidth: 12,
                    ),
                    const SizedBox(width: 18),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            tirPct != null
                                ? 'Tempo no alvo: ${tirPct.round()}%'
                                : 'Tempo no alvo: --%',
                            style: const TextStyle(
                              fontSize: 19,
                              fontWeight: FontWeight.w800,
                              color: Colors.white,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Alvo ${_targetRange.lowMgDl}–${_targetRange.highMgDl} mg/dL • ${_selectedTirPeriod.fullLabel}',
                            style: const TextStyle(
                              fontSize: 12,
                              color: EspressoPalette.sandAccent,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            streak.displayLabelPt,
                            style: const TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                              color: EspressoPalette.peachAccent,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                _buildTirRangeBar(tbr: tbrPct, tir: tirPct, tar: tarPct),
                const SizedBox(height: 16),
                _buildInfoLine(
                  'No alvo (${_targetRange.lowMgDl}–${_targetRange.highMgDl})',
                  summary.hasSufficientData
                      ? '${TimeInRangeSummary.formatDurationPt(summary.inRangeDuration)} (${_formatPtNumber(tirPct ?? 0, 1)}%)'
                      : '--',
                  highlight: true,
                ),
                const SizedBox(height: 8),
                _buildInfoLine(
                  'Abaixo (<${_targetRange.lowMgDl})',
                  summary.hasSufficientData
                      ? '${TimeInRangeSummary.formatDurationPt(summary.belowRangeDuration)} (${_formatPtNumber(tbrPct ?? 0, 1)}%)'
                      : '--',
                ),
                const SizedBox(height: 8),
                _buildInfoLine(
                  'Acima (>${_targetRange.highMgDl})',
                  summary.hasSufficientData
                      ? '${TimeInRangeSummary.formatDurationPt(summary.aboveRangeDuration)} (${_formatPtNumber(tarPct ?? 0, 1)}%)'
                      : '--',
                ),
                const SizedBox(height: 12),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: EspressoPalette.cardEspresso.withValues(alpha: 0.75),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        summary.isPartialCoverage
                            ? Icons.warning_amber_rounded
                            : Icons.timeline_rounded,
                        size: 16,
                        color: summary.isPartialCoverage
                            ? EspressoPalette.peachAccent
                            : EspressoPalette.sandAccent,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          summary.hasSufficientData
                              ? 'Cobertura dos dados: ${summary.coveragePercent.round()}% (${TimeInRangeSummary.formatDurationPt(summary.coveredDuration)})${summary.isPartialCoverage ? " • dados parciais" : ""}'
                              : 'Dados insuficientes para calcular o período selecionado.',
                          style: const TextStyle(
                            fontSize: 11.5,
                            color: EspressoPalette.creamText,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),

          _buildMetricGrid([
            _MetricTileData(
              label: 'Glicemia média',
              value: periodMean != null ? '${periodMean.round()} mg/dL' : '--',
            ),
            _MetricTileData(
              label: 'HbA1c estimada',
              value: estimatedA1c != null
                  ? '${_formatPtNumber(estimatedA1c, 1)}%'
                  : '--',
              highlight: true,
            ),
          ]),
          const SizedBox(height: 14),

          // Collapsible Advanced Details (SD, CV%, Tight TIR, Markers)
          Container(
            decoration: BoxDecoration(
              color: EspressoPalette.cardEspresso,
              borderRadius: BorderRadius.circular(24),
            ),
            child: Theme(
              data: Theme.of(context).copyWith(
                dividerColor: Colors.transparent,
              ),
              child: ExpansionTile(
                initiallyExpanded: _showAdvancedStats,
                onExpansionChanged: (v) =>
                    setState(() => _showAdvancedStats = v),
                title: const Text(
                  'Detalhes avançados e registos',
                  style: TextStyle(
                    fontSize: 14.5,
                    fontWeight: FontWeight.w700,
                    color: EspressoPalette.creamText,
                  ),
                ),
                iconColor: EspressoPalette.peachAccent,
                collapsedIconColor: EspressoPalette.sandAccent,
                childrenPadding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
                children: [
                  _buildInfoLine(
                    'Desvio-padrão',
                    _telemetry.standardDeviation != null
                        ? '${_formatPtNumber(_telemetry.standardDeviation!, 1)} mg/dL'
                        : '--',
                  ),
                  const SizedBox(height: 8),
                  _buildInfoLine(
                    'Coeficiente de variação',
                    _telemetry.cvPercent != null
                        ? '${_formatPtNumber(_telemetry.cvPercent!, 1)}%'
                        : '--',
                  ),
                  const SizedBox(height: 8),
                  _buildInfoLine(
                    'Bólus recentes (24h)',
                    _telemetry.bolusMarkers.isEmpty
                        ? '--'
                        : '${_formatPtNumber(_telemetry.totalBolusUnits, 2)} U (${_telemetry.bolusMarkers.length})',
                  ),
                  const SizedBox(height: 8),
                  _buildInfoLine(
                    'Auto-Basal SmartGuard',
                    _telemetry.autoBasalMarkers.isEmpty
                        ? '--'
                        : '${_formatPtNumber(_telemetry.totalAutoBasalUnits, 2)} U (${_telemetry.autoBasalMarkers.length})',
                  ),
                  if (_telemetry.mealMarkers.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    const Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        'Refeições registadas:',
                        style: TextStyle(
                          fontSize: 12,
                          color: EspressoPalette.peachAccent,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(height: 6),
                    ..._telemetry.mealMarkers.reversed.take(4).map(
                          (m) => Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              '• ${m.carbsGrams.round()} g hidratos (${m.displayTime ?? DateFormat('HH:mm').format(m.timestamp)})',
                              style: const TextStyle(
                                fontSize: 12,
                                color: EspressoPalette.sandAccent,
                              ),
                            ),
                          ),
                        ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTirRangeBar({
    required double? tbr,
    required double? tir,
    required double? tar,
  }) {
    if (tbr == null || tir == null || tar == null) {
      return Container(
        height: 16,
        decoration: BoxDecoration(
          color: EspressoPalette.batteryTrack,
          borderRadius: BorderRadius.circular(12),
        ),
      );
    }

    final tbrFlex = (tbr * 10).round().clamp(0, 1000);
    final tirFlex = (tir * 10).round().clamp(0, 1000);
    final tarFlex = (tar * 10).round().clamp(0, 1000);

    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: SizedBox(
        height: 16,
        child: Row(
          children: [
            if (tbrFlex > 0)
              Expanded(
                flex: tbrFlex,
                child: Container(color: const Color(0xFFFFB4AB)),
              ),
            if (tirFlex > 0)
              Expanded(
                flex: tirFlex,
                child: Container(color: EspressoPalette.batteryFill),
              ),
            if (tarFlex > 0)
              Expanded(
                flex: tarFlex,
                child: Container(color: EspressoPalette.peachAccent),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildMetricGrid(List<_MetricTileData> items) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final double tileWidth = ((constraints.maxWidth - 10) / 2).clamp(
          110.0,
          double.infinity,
        );
        return Wrap(
          spacing: 10,
          runSpacing: 10,
          children: items.map((item) {
            return SizedBox(
              width: tileWidth,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                decoration: BoxDecoration(
                  color: item.highlight
                      ? EspressoPalette.cardBrown
                      : EspressoPalette.cardEspresso,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.label,
                      style: const TextStyle(
                        fontSize: 11.5,
                        color: EspressoPalette.sandAccent,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      item.value,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 16.5,
                        fontWeight: FontWeight.w700,
                        color: item.highlight
                            ? EspressoPalette.peachAccent
                            : EspressoPalette.creamText,
                      ),
                    ),
                  ],
                ),
              ),
            );
          }).toList(),
        );
      },
    );
  }

  // =========================================================================
  // TAB 4: CONFIGURAÇÕES (Diagnostics, Sync Health, CareLink, Permissions)
  // =========================================================================

  Widget _buildConfigTab() {
    final bool miniMedLocalActive =
        _accessibilityAccessGranted || _notifAccessGranted;

    return RefreshIndicator(
      color: EspressoPalette.peachAccent,
      backgroundColor: EspressoPalette.cardBrown,
      onRefresh: _forceSyncAll,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
        children: [
          // 1. Estado da sincronização (Mandatory Diagnostics Card)
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: EspressoPalette.cardBrown,
              borderRadius: BorderRadius.circular(28),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Estado da sincronização',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: EspressoPalette.peachAccent,
                  ),
                ),
                const SizedBox(height: 12),
                _buildDiagRow(
                  'MiniMed (listeners locais)',
                  miniMedLocalActive ? 'Ligada' : 'Desligada',
                  ok: miniMedLocalActive,
                ),
                _buildDiagRow(
                  'CareLink',
                  _careLinkStatus.labelPt,
                  ok: _careLinkStatus == CareLinkSessionStatus.connected ||
                      _careLinkStatus == CareLinkSessionStatus.refreshing,
                ),
                _buildDiagRow(
                  'Renovação automática OAuth2',
                  _refreshDiag?.summaryPt ?? '--',
                  ok: _refreshDiag?.isVerified ?? false,
                  isWarning: _refreshDiag != null &&
                      (_refreshDiag!.readiness ==
                              CareLinkRefreshReadiness.incomplete ||
                          _refreshDiag!.readiness ==
                              CareLinkRefreshReadiness.failed),
                ),
                _buildDiagRow(
                  'Health Connect',
                  _diagSnapshot.healthConnectAvailable
                      ? (_diagSnapshot.glucoseWriteGranted ||
                              _diagSnapshot.fitbitReadGranted
                          ? 'Autorizado'
                          : 'Não autorizado')
                      : 'Indisponível',
                  ok: _diagSnapshot.healthConnectAvailable &&
                      (_diagSnapshot.glucoseWriteGranted ||
                          _diagSnapshot.fitbitReadGranted),
                ),
                _buildDiagRow(
                  'Permissão para escrever glicose',
                  _diagSnapshot.glucoseWriteGranted ? 'Sim' : 'Não',
                  ok: _diagSnapshot.glucoseWriteGranted,
                ),
                _buildDiagRow(
                  'Permissão para escrever refeições',
                  _diagSnapshot.nutritionWriteGranted ? 'Sim' : 'Não (opcional)',
                  ok: _diagSnapshot.nutritionWriteGranted,
                ),
                _buildDiagRow(
                  'Última glicemia recebida',
                  _diagSnapshot.lastReceivedSg != null
                      ? '${_diagSnapshot.lastReceivedSg} mg/dL (${_formatTimestamp(_diagSnapshot.lastReceivedSgAt)})'
                      : '--',
                ),
                _buildDiagRow(
                  'Última glicemia enviada com sucesso',
                  _diagSnapshot.lastSyncedSg != null
                      ? '${_diagSnapshot.lastSyncedSg} mg/dL (${_formatTimestamp(_diagSnapshot.lastSyncedSgAt)})'
                      : '--',
                ),
                _buildDiagRow(
                  'Registos pendentes',
                  '${_diagSnapshot.pendingCount}',
                ),
                _buildDiagRow(
                  'Último erro de sincronização',
                  _diagSnapshot.lastError ?? 'Nenhum',
                  isWarning: _diagSnapshot.lastError != null,
                ),
                const SizedBox(height: 12),
                const Text(
                  'Nota: a tarefa em segundo plano (~15 min) depende da gestão de bateria do Android e não garante entrega instantânea.',
                  style: TextStyle(
                    fontSize: 11.5,
                    color: EspressoPalette.sandAccent,
                  ),
                ),
                const SizedBox(height: 14),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: EspressoPalette.peachAccent,
                      foregroundColor: EspressoPalette.darkPillText,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    onPressed: _isTestingSync ? null : _runTestSyncDiagnostic,
                    icon: _isTestingSync
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: EspressoPalette.darkPillText,
                            ),
                          )
                        : const Icon(Icons.play_circle_outline_rounded),
                    label: Text(
                      _isTestingSync
                          ? 'A testar sincronização...'
                          : 'Testar sincronização',
                    ),
                  ),
                ),
                if (_lastTestSyncResult != null) ...[
                  const SizedBox(height: 10),
                  Text(
                    'Resultado: ${_lastTestSyncResult!.status.labelPt} — ${_lastTestSyncResult!.message}',
                    style: const TextStyle(
                      fontSize: 12,
                      color: EspressoPalette.creamText,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 14),

          // 2. Quick Settings & Permissions Grid
          Row(
            children: [
              Expanded(
                child: _buildHomeActionTile(
                  icon: Icons.cloud_sync_rounded,
                  title: 'CareLink / xDrip+',
                  subtitle: _careLinkStatus.labelPt,
                  active: _careLinkStatus == CareLinkSessionStatus.connected,
                  onTap: () => showCareLinkSourceSheet(
                    context: context,
                    careLinkService: _careLinkService,
                    notificationService: _notificationService,
                    onUpdated: _forceSyncAll,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _buildHomeActionTile(
                  icon: Icons.track_changes_rounded,
                  title: 'Intervalo-alvo',
                  subtitle:
                      '${_targetRange.lowMgDl}–${_targetRange.highMgDl} mg/dL',
                  active: true,
                  onTap: () => showTargetRangeSheet(
                    context: context,
                    currentRange: _targetRange,
                    onSaved: (newRange) async {
                      await _historyStore.saveTargetRange(newRange);
                      setState(() => _targetRange = newRange);
                      await _pushWidgetAndNotification(
                        telemetry: _telemetry,
                        fitbit: _fitbitMetrics,
                      );
                    },
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _buildHomeActionTile(
                  icon: Icons.favorite_rounded,
                  title: 'Health Connect',
                  subtitle: _diagSnapshot.glucoseWriteGranted
                      ? 'Escrita ativa'
                      : 'Autorizar',
                  active: _healthPermissionsGranted,
                  onTap: _authorizeHealthConnect,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _buildHomeActionTile(
                  icon: Icons.notifications_active_rounded,
                  title: 'Notif. contínua',
                  subtitle: _postNotifGranted ? 'Ativa' : 'Autorizar',
                  active: _postNotifGranted,
                  onTap: () async {
                    await _notificationService
                        .requestPostNotificationsPermission();
                    await _checkSystemPermissions();
                    await _notificationService.refreshRichNotification();
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _buildHomeActionTile(
                  icon: Icons.accessibility_new_rounded,
                  title: 'Leitor ecrã 780G',
                  subtitle: _accessibilityAccessGranted ? 'Ativo' : 'Ativar',
                  active: _accessibilityAccessGranted,
                  onTap: _notificationService.openAccessibilitySettings,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _buildHomeActionTile(
                  icon: Icons.notifications_none_rounded,
                  title: 'Listener notif.',
                  subtitle: _notifAccessGranted ? 'Ativo' : 'Opcional',
                  active: _notifAccessGranted,
                  onTap: _notificationService.openNotificationAccessSettings,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _buildHomeActionTile(
                  icon: Icons.battery_saver_rounded,
                  title: 'Bateria Pixel',
                  subtitle: _batteryOptIgnored
                      ? 'Sem restrições'
                      : 'Otimizada (rever)',
                  active: _batteryOptIgnored,
                  onTap: _notificationService.openBatteryOptimizationSettings,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _buildHomeActionTile(
                  icon: Icons.widgets_rounded,
                  title: 'Widget Pixel',
                  subtitle: 'Fixar no ecrã',
                  active: true,
                  onTap: WidgetService.requestPinToHomeScreen,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),

          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              foregroundColor: EspressoPalette.sandAccent,
              side: BorderSide(
                color: EspressoPalette.sandAccent.withValues(alpha: 0.4),
              ),
              padding: const EdgeInsets.symmetric(vertical: 12),
            ),
            onPressed: () async {
              await _notificationService.clearBridgeState();
              await _historyStore.clearAllHistory();
              await _careLinkService.cacheTelemetry(PumpTelemetry.empty());
              if (!mounted) return;
              setState(() {
                _telemetry = PumpTelemetry.empty();
                _manualWorkout = null;
              });
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Histórico e cache locais limpos.')),
              );
            },
            icon: const Icon(Icons.delete_outline_rounded, size: 18),
            label: const Text('Limpar histórico e cache locais'),
          ),
        ],
      ),
    );
  }

  Widget _buildDiagRow(
    String label,
    String value, {
    bool? ok,
    bool isWarning = false,
  }) {
    final Color valueColor = isWarning
        ? const Color(0xFFFFB4AB)
        : (ok == null
            ? EspressoPalette.creamText
            : (ok ? EspressoPalette.peachAccent : const Color(0xFFFFB4AB)));

    return Padding(
      padding: const EdgeInsets.only(bottom: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 5,
            child: Text(
              label,
              style: const TextStyle(
                fontSize: 12.5,
                color: EspressoPalette.sandAccent,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 5,
            child: Text(
              value,
              textAlign: TextAlign.end,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: valueColor,
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _formatTimestamp(DateTime? dt) {
    if (dt == null) return '--';
    return DateFormat('HH:mm').format(dt.toLocal());
  }

  Widget _buildHomeActionTile({
    required IconData icon,
    required String title,
    required String subtitle,
    required bool active,
    required VoidCallback onTap,
  }) {
    return Material(
      color: active ? EspressoPalette.cardBrown : EspressoPalette.cardEspresso,
      borderRadius: BorderRadius.circular(24),
      child: InkWell(
        borderRadius: BorderRadius.circular(24),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(9),
                decoration: BoxDecoration(
                  color: active
                      ? EspressoPalette.peachAccent.withValues(alpha: 0.16)
                      : EspressoPalette.background,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(
                  icon,
                  color: active
                      ? EspressoPalette.peachAccent
                      : EspressoPalette.sandAccent,
                  size: 19,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: EspressoPalette.creamText,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: const TextStyle(
                        fontSize: 11.5,
                        color: EspressoPalette.sandAccent,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MetricTileData {
  final String label;
  final String value;
  final bool highlight;

  const _MetricTileData({
    required this.label,
    required this.value,
    this.highlight = false,
  });
}
