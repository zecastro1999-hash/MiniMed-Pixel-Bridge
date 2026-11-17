package com.minimed.bridge.minimed_pixel_bridge

import android.app.Notification
import android.os.Handler
import android.os.Looper
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.util.Log
import es.antonborri.home_widget.HomeWidgetPlugin
import org.json.JSONArray
import org.json.JSONObject
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

class MinimedNotificationListenerService : NotificationListenerService() {

    companion object {
        private const val TAG = "MinimedNotifService"
        const val MINIMED_EU_PACKAGE = "com.medtronic.diabetes.minimedmobile.eu"
        const val MINIMED_US_PACKAGE = "com.medtronic.diabetes.minimedmobile.us"

        @Volatile
        var instance: MinimedNotificationListenerService? = null

        private val EXPLICIT_SG_REGEX = Regex(
            """\b([4-9]\d|[1-3]\d{2}|400)\s*(?:mg/dL|mg/dl)\b""",
            RegexOption.IGNORE_CASE
        )
        private val FALLBACK_SG_REGEX = Regex(
            """(?:SG|Glucose|Glicemia|Sensor|BG)[:\s]*([4-9]\d|[1-3]\d{2}|400)\b""",
            RegexOption.IGNORE_CASE
        )
        private val IOB_REGEX = Regex(
            """(?:Insulina\s+ativa|Active\s+Insulin|IOB)[:\s]*(\d+[.,]\d+|\d+)\s*U\b""",
            RegexOption.IGNORE_CASE
        )

        fun parseSgValue(rawText: String): Int? {
            val explicitMatch = EXPLICIT_SG_REGEX.find(rawText)
            if (explicitMatch != null) {
                return explicitMatch.groupValues[1].toIntOrNull()
            }
            val fallbackMatch = FALLBACK_SG_REGEX.find(rawText)
            if (fallbackMatch != null) {
                return fallbackMatch.groupValues[1].toIntOrNull()
            }
            return null
        }

        fun parseIobValue(rawText: String): Double? {
            val match = IOB_REGEX.find(rawText) ?: return null
            return match.groupValues[1].replace(',', '.').toDoubleOrNull()
        }

        fun parseTrend(rawText: String): Pair<String, String> {
            return when {
                rawText.contains("↑↑") || rawText.contains("⇈") ||
                    rawText.contains("UP_DOUBLE", ignoreCase = true) ||
                    rawText.contains("rising rapidly", ignoreCase = true) -> Pair("UP_DOUBLE", "↑↑")
                rawText.contains("↓↓") || rawText.contains("⇊") ||
                    rawText.contains("DOWN_DOUBLE", ignoreCase = true) ||
                    rawText.contains("falling rapidly", ignoreCase = true) -> Pair("DOWN_DOUBLE", "↓↓")
                rawText.contains("↑") || rawText.contains("↗") ||
                    rawText.contains("UP", ignoreCase = true) ||
                    rawText.contains("rising", ignoreCase = true) -> Pair("UP", "↑")
                rawText.contains("↓") || rawText.contains("↘") ||
                    rawText.contains("DOWN", ignoreCase = true) ||
                    rawText.contains("falling", ignoreCase = true) -> Pair("DOWN", "↓")
                else -> Pair("NONE", "→")
            }
        }
    }

    override fun onListenerConnected() {
        super.onListenerConnected()
        instance = this
        Log.i(TAG, "NotificationListenerService connected")
        scanActiveNotifications()
    }

    override fun onListenerDisconnected() {
        instance = null
        super.onListenerDisconnected()
    }

    fun scanActiveNotifications(): Map<String, Any>? {
        return try {
            val active = activeNotifications ?: return null
            var latestPayload: Map<String, Any>? = null
            for (sbn in active) {
                val pkg = sbn?.packageName ?: continue
                if (pkg == MINIMED_EU_PACKAGE || pkg == MINIMED_US_PACKAGE) {
                    val result = processStatusBarNotification(sbn)
                    if (result != null) {
                        latestPayload = result
                    }
                }
            }
            latestPayload
        } catch (e: Exception) {
            Log.w(TAG, "scanActiveNotifications warning")
            null
        }
    }

    override fun onNotificationPosted(sbn: StatusBarNotification?) {
        if (sbn == null) return
        val pkg = sbn.packageName ?: return
        if (pkg != MINIMED_EU_PACKAGE && pkg != MINIMED_US_PACKAGE) {
            return
        }
        processStatusBarNotification(sbn)
    }

    private fun processStatusBarNotification(sbn: StatusBarNotification): Map<String, Any>? {
        val pkg = sbn.packageName ?: return null
        val notification = sbn.notification ?: return null
        val extras = notification.extras ?: return null

        val title = extras.getCharSequence(Notification.EXTRA_TITLE)?.toString()?.trim() ?: ""
        val text = extras.getCharSequence(Notification.EXTRA_TEXT)?.toString()?.trim() ?: ""
        val subText = extras.getCharSequence(Notification.EXTRA_SUB_TEXT)?.toString()?.trim() ?: ""
        val bigText = extras.getCharSequence(Notification.EXTRA_BIG_TEXT)?.toString()?.trim() ?: ""

        val combined = listOf(title, text, bigText, subText)
            .filter { it.isNotEmpty() }
            .joinToString(" | ")

        val sgValue = parseSgValue(title) ?: parseSgValue(combined)
        val iobValue = parseIobValue(text) ?: parseIobValue(combined)
        val (trendCode, trendArrow) = parseTrend(combined)

        val rawWhen = notification.`when`
        val rawPost = sbn.postTime
        val eventTimeMs = when {
            rawWhen > 0L -> rawWhen
            rawPost > 0L -> rawPost
            else -> System.currentTimeMillis()
        }
        val timeFormatted = SimpleDateFormat("HH:mm", Locale.getDefault()).format(Date(eventTimeMs))

        val widgetPrefs = HomeWidgetPlugin.getData(applicationContext)
        val editor = widgetPrefs.edit()

        if (sgValue != null) {
            editor.putString("sg_value", sgValue.toString())
            editor.putString("sg_trend", trendCode)
            editor.putString("sg_trend_arrow", trendArrow)
            editor.putString("last_updated", "Live $timeFormatted")
            editor.putString("last_timestamp_ms", eventTimeMs.toString())
            editor.putString("source_badge", "780G Notif")
            appendSgToLocalHistory(widgetPrefs, editor, sgValue, eventTimeMs)
        }

        if (iobValue != null) {
            val formattedIob = String.format(Locale.US, "%.2f U", iobValue)
            editor.putString("active_insulin", formattedIob)
            editor.putString("active_insulin_num", iobValue.toString())
        }

        editor.putLong("raw_notif_ts", eventTimeMs)
        editor.apply()

        MinimedWidgetProvider.updateAllWidgets(applicationContext)

        val payload = HashMap<String, Any>()
        payload["eventType"] = "notification"
        payload["packageName"] = pkg
        payload["timestampMs"] = eventTimeMs
        payload["rawCombined"] = combined
        payload["trend"] = trendCode
        payload["trendArrow"] = trendArrow
        if (sgValue != null) payload["sg"] = sgValue
        if (iobValue != null) payload["activeInsulin"] = iobValue

        NotificationBridge.emitNotification(payload)
        return payload
    }

    private fun appendSgToLocalHistory(
        prefs: android.content.SharedPreferences,
        editor: android.content.SharedPreferences.Editor,
        sg: Int,
        eventTimeMs: Long
    ) {
        try {
            val raw = prefs.getString("local_sg_history_json", "[]") ?: "[]"
            val arr = JSONArray(raw)
            if (arr.length() > 0) {
                val lastObj = arr.getJSONObject(arr.length() - 1)
                val lastTs = lastObj.optLong("ts", 0L)
                val lastSg = lastObj.optInt("sg", -1)
                if (kotlin.math.abs(eventTimeMs - lastTs) < 60_000L && lastSg == sg) {
                    return
                }
            }
            val entry = JSONObject().apply {
                put("sg", sg)
                put("ts", eventTimeMs)
                put("src", "notification")
            }
            arr.put(entry)
            val trimmed = JSONArray()
            val startIdx = maxOf(0, arr.length() - 288)
            for (k in startIdx until arr.length()) {
                trimmed.put(arr.get(k))
            }
            editor.putString("local_sg_history_json", trimmed.toString())
        } catch (e: Exception) {
            Log.w(TAG, "Failed updating local notification history")
        }
    }
}

object NotificationBridge {
    var eventSink: io.flutter.plugin.common.EventChannel.EventSink? = null
    @Volatile
    var lastInterceptedPayload: Map<String, Any>? = null

    fun emitNotification(payload: Map<String, Any>) {
        lastInterceptedPayload = payload
        Handler(Looper.getMainLooper()).post {
            eventSink?.success(payload)
        }
    }
}
