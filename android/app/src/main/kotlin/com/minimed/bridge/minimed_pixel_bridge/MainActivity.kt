package com.minimed.bridge.minimed_pixel_bridge

import android.Manifest
import android.app.Activity
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import android.text.TextUtils
import androidx.core.app.ActivityCompat
import es.antonborri.home_widget.HomeWidgetPlugin
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugins.GeneratedPluginRegistrant
import io.flutter.plugins.sharedpreferences.SharedPreferencesPlugin
import java.io.BufferedReader
import java.io.File
import java.io.InputStreamReader

class MainActivity : FlutterFragmentActivity() {

    private val methodChannelName = "com.minimed.bridge/notifications"
    private val eventChannelName = "com.minimed.bridge/notification_stream"
    private val pickLoginJsonRequestCode = 9042
    private var pendingFilePickResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        if (!flutterEngine.plugins.has(SharedPreferencesPlugin::class.java)) {
            GeneratedPluginRegistrant.registerWith(flutterEngine)
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, methodChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "isNotificationListenerEnabled" -> {
                        result.success(isNotificationServiceEnabled())
                    }
                    "openNotificationListenerSettings" -> {
                        try {
                            val intent = Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS).apply {
                                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            }
                            startActivity(intent)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("SETTINGS_ERROR", e.message, null)
                        }
                    }
                    "isAccessibilityServiceEnabled" -> {
                        result.success(isAccessibilityServiceEnabled())
                    }
                    "openAccessibilitySettings" -> {
                        try {
                            val intent = Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS).apply {
                                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            }
                            startActivity(intent)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("SETTINGS_ERROR", e.message, null)
                        }
                    }
                    "isIgnoringBatteryOptimizations" -> {
                        val pm = getSystemService(Context.POWER_SERVICE) as? PowerManager
                        result.success(pm?.isIgnoringBatteryOptimizations(packageName) ?: false)
                    }
                    "openBatteryOptimizationSettings" -> {
                        try {
                            val intent = Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS).apply {
                                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            }
                            startActivity(intent)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("SETTINGS_ERROR", e.message, null)
                        }
                    }
                    "scanActiveNotifications" -> {
                        MinimedNotificationListenerService.instance?.scanActiveNotifications()
                        result.success(readLocalBridgeStateMap())
                    }
                    "getLocalBridgeState" -> {
                        result.success(readLocalBridgeStateMap())
                    }
                    "getLastInterceptedNotification" -> {
                        result.success(NotificationBridge.lastInterceptedPayload)
                    }
                    "tryLoadDownloadLoginData" -> {
                        try {
                            val candidatePaths = listOf(
                                "/sdcard/Download/logindata.json",
                                "/storage/emulated/0/Download/logindata.json"
                            )
                            var foundContent: String? = null
                            for (path in candidatePaths) {
                                val f = File(path)
                                if (f.exists() && f.canRead()) {
                                    foundContent = f.readText()
                                    break
                                }
                            }
                            result.success(foundContent)
                        } catch (e: Exception) {
                            result.success(null)
                        }
                    }
                    "pickLoginDataFile" -> {
                        if (pendingFilePickResult != null) {
                            result.error("BUSY", "File picker already open", null)
                            return@setMethodCallHandler
                        }
                        pendingFilePickResult = result
                        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                            addCategory(Intent.CATEGORY_OPENABLE)
                            type = "*/*"
                            putExtra(
                                Intent.EXTRA_MIME_TYPES,
                                arrayOf("application/json", "text/plain")
                            )
                        }
                        @Suppress("DEPRECATION")
                        startActivityForResult(intent, pickLoginJsonRequestCode)
                    }
                    "isPostNotificationsGranted" -> {
                        result.success(MinimedRichNotificationService.hasNotificationPermission(applicationContext))
                    }
                    "requestPostNotificationsPermission" -> {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                            ActivityCompat.requestPermissions(
                                this,
                                arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                                9043
                            )
                            result.success(true)
                        } else {
                            result.success(true)
                        }
                    }
                    "refreshRichNotification" -> {
                        MinimedRichNotificationService.showOrUpdate(applicationContext)
                        result.success(true)
                    }
                    "clearLocalBridgeState" -> {
                        HomeWidgetPlugin.getData(applicationContext).edit().clear().apply()
                        MinimedWidgetProvider.updateAllWidgets(applicationContext)
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, eventChannelName)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    NotificationBridge.eventSink = events
                }

                override fun onCancel(arguments: Any?) {
                    NotificationBridge.eventSink = null
                }
            })
    }

    @Suppress("DEPRECATION")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == pickLoginJsonRequestCode) {
            val callback = pendingFilePickResult
            pendingFilePickResult = null
            if (callback == null) return

            if (resultCode == Activity.RESULT_OK && data?.data != null) {
                try {
                    val uri: Uri = data.data!!
                    val content = contentResolver.openInputStream(uri)?.use { stream ->
                        BufferedReader(InputStreamReader(stream)).readText()
                    }
                    callback.success(content)
                } catch (e: Exception) {
                    callback.error("READ_ERROR", e.message, null)
                }
            } else {
                callback.success(null)
            }
        }
    }

    private fun readLocalBridgeStateMap(): Map<String, Any?> {
        val prefs = HomeWidgetPlugin.getData(applicationContext)
        val sgStr = prefs.getString("sg_value", null)
        val iobNumStr = prefs.getString("active_insulin_num", null)
        val carbsGramsStr = prefs.getString("last_carbs_grams", null)
        val reservoirNumStr = prefs.getString("reservoir_num", null)
        val batteryLabel = prefs.getString("pump_battery", null)
        val isQualitative = batteryLabel?.trim()?.lowercase()?.let {
            it == "alta" || it == "média" || it == "media" || it == "baixa" ||
                it == "high" || it == "medium" || it == "low"
        } ?: false
        val batteryPct = if (!isQualitative && prefs.contains("pump_battery_percent")) {
            prefs.getInt("pump_battery_percent", -1).let { if (it >= 0) it else null }
        } else {
            null
        }
        val tsStr = prefs.getString("last_timestamp_ms", null)

        return mapOf(
            "sgValue" to sgStr?.toIntOrNull(),
            "sgTrend" to prefs.getString("sg_trend", null),
            "sgTrendArrow" to prefs.getString("sg_trend_arrow", null),
            "activeInsulin" to iobNumStr?.toDoubleOrNull(),
            "lastCarbsGrams" to carbsGramsStr?.toDoubleOrNull(),
            "lastCarbsTime" to prefs.getString("last_carbs_time", null),
            "reservoirRemaining" to reservoirNumStr?.toDoubleOrNull(),
            "pumpBatteryLabel" to batteryLabel,
            "pumpBatteryPercent" to batteryPct,
            "sensorBatteryLabel" to prefs.getString("sensor_battery", null),
            "sensorDaysRemaining" to prefs.getString("sensor_days_left", null),
            "lastTimestampMs" to tsStr?.toLongOrNull(),
            "sourceBadge" to prefs.getString("source_badge", null),
            "rawNotifTitle" to prefs.getString("raw_notif_title", null),
            "rawNotifText" to prefs.getString("raw_notif_text", null),
            "rawNotifSubText" to prefs.getString("raw_notif_subtext", null),
            "rawNotifBigText" to prefs.getString("raw_notif_bigtext", null),
            "rawNotifSummary" to prefs.getString("raw_notif_summary", null),
            "rawAccessibilitySummary" to prefs.getString("raw_accessibility_summary", null),
            "localSgHistoryJson" to prefs.getString("local_sg_history_json", null)
        )
    }

    private fun isNotificationServiceEnabled(): Boolean {
        val pkgName = packageName
        val flat = Settings.Secure.getString(contentResolver, "enabled_notification_listeners")
        if (!flat.isNullOrEmpty()) {
            val names = flat.split(":")
            for (name in names) {
                val cn = ComponentName.unflattenFromString(name)
                if (cn != null && cn.packageName == pkgName) {
                    return true
                }
            }
        }
        return false
    }

    private fun isAccessibilityServiceEnabled(): Boolean {
        val expectedComponent = ComponentName(this, MinimedUiScraperService::class.java)
        val enabledServices = Settings.Secure.getString(
            contentResolver,
            Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES
        ) ?: return false

        val splitter = TextUtils.SimpleStringSplitter(':')
        splitter.setString(enabledServices)
        while (splitter.hasNext()) {
            val componentStr = splitter.next()
            val cn = ComponentName.unflattenFromString(componentStr)
            if (cn != null && cn == expectedComponent) {
                return true
            }
        }
        return false
    }
}
