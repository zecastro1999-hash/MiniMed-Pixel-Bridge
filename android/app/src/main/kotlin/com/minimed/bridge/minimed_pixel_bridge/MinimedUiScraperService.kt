package com.minimed.bridge.minimed_pixel_bridge

import android.accessibilityservice.AccessibilityService
import android.util.Log
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import es.antonborri.home_widget.HomeWidgetPlugin
import org.json.JSONArray
import org.json.JSONObject
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

class MinimedUiScraperService : AccessibilityService() {

    private var lastScrapeAtMs: Long = 0L

    companion object {
        private const val TAG = "MinimedUiScraper"
        private const val MINIMED_EU_PKG = "com.medtronic.diabetes.minimedmobile.eu"
        private const val MINIMED_US_PKG = "com.medtronic.diabetes.minimedmobile.us"

        private val AXIS_VALUES = setOf(50, 70, 180, 250, 300, 350, 400)

        private val SG_WITH_UNIT_REGEX = Regex(
            """\b([4-9]\d|[1-3]\d{2}|400)\s*mg/d[lL]\b""",
            RegexOption.IGNORE_CASE
        )
        private val PURE_INT_REGEX = Regex("""^\s*([4-9]\d|[1-3]\d{2}|400)\s*$""")
        private val UNITS_REGEX = Regex("""(\d+[.,]\d+|\d+)\s*U\b""", RegexOption.IGNORE_CASE)
        private val CARBS_REGEX = Regex(
            """(\d+(?:[.,]\d+)?)\s*(?:gramas|grama|g\b)""",
            RegexOption.IGNORE_CASE
        )
        private val TIME_REGEX = Regex("""\b([01]?\d|2[0-3]):([0-5]\d)\b""")
        private val PERCENT_REGEX = Regex("""(\d{1,3})\s*%""")
        private val DAYS_REGEX = Regex("""(\d+\s*dias?|\d+\s*days?)""", RegexOption.IGNORE_CASE)
    }

    override fun onServiceConnected() {
        super.onServiceConnected()
        Log.i(TAG, "MinimedUiScraperService connected")
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        val root = rootInActiveWindow ?: return
        val pkg = event?.packageName?.toString() ?: root.packageName?.toString() ?: return
        if (pkg != MINIMED_EU_PKG && pkg != MINIMED_US_PKG) {
            return
        }

        val nowMs = System.currentTimeMillis()
        if (nowMs - lastScrapeAtMs < 350L) {
            return
        }
        lastScrapeAtMs = nowMs

        val nodes = mutableListOf<String>()
        collectNodeTexts(root, nodes)
        if (nodes.isEmpty()) return

        parseAndPersistNodes(nodes, pkg, nowMs)
    }

    override fun onInterrupt() {
        Log.w(TAG, "MinimedUiScraperService interrupted")
    }

    private fun collectNodeTexts(node: AccessibilityNodeInfo?, out: MutableList<String>) {
        if (node == null) return
        val text = node.text?.toString()?.trim()
        if (!text.isNullOrEmpty()) {
            out.add(text)
        }
        val desc = node.contentDescription?.toString()?.trim()
        if (!desc.isNullOrEmpty() && desc != text) {
            out.add(desc)
        }
        for (i in 0 until node.childCount) {
            val child = node.getChild(i)
            if (child != null) {
                collectNodeTexts(child, out)
                child.recycle()
            }
        }
    }

    private fun parseAndPersistNodes(nodes: List<String>, pkg: String, nowMs: Long) {
        val joined = nodes.joinToString(" | ")

        val sgValue = extractSg(nodes)
        val iobValue = extractIob(nodes)
        val (carbsGrams, carbsTime) = extractMealCarbs(nodes)
        val reservoirUnits = extractReservoir(nodes)
        val (pumpBatteryLabel, pumpBatteryPercent) = extractPumpBattery(nodes)
        val sensorBattery = extractSensorBattery(nodes)
        val sensorDaysLeft = extractSensorDaysLeft(nodes)

        val widgetPrefs = HomeWidgetPlugin.getData(applicationContext)
        val editor = widgetPrefs.edit()
        val timeFormatted = SimpleDateFormat("HH:mm", Locale.getDefault()).format(Date(nowMs))

        if (sgValue != null) {
            editor.putString("sg_value", sgValue.toString())
            editor.putString("last_updated", "UI $timeFormatted")
            editor.putString("last_timestamp_ms", nowMs.toString())
            editor.putString("source_badge", "780G Screen")
            appendSgToLocalHistory(widgetPrefs, editor, sgValue, nowMs)
        }

        if (iobValue != null) {
            val formattedIob = String.format(Locale.US, "%.2f U", iobValue)
            editor.putString("active_insulin", formattedIob)
            editor.putString("active_insulin_num", iobValue.toString())
        }

        if (carbsGrams != null) {
            val carbsDisplay = "${carbsGrams.toInt()}g"
            editor.putString("last_carbs", carbsDisplay)
            editor.putString("last_carbs_grams", carbsGrams.toString())
            if (carbsTime != null) {
                editor.putString("last_carbs_time", carbsTime)
            }
        }

        if (reservoirUnits != null) {
            val resFormatted = String.format(Locale.US, "%.1f U", reservoirUnits)
            editor.putString("reservoir", resFormatted)
            editor.putString("reservoir_num", reservoirUnits.toString())
        }

        if (pumpBatteryLabel != null) {
            editor.putString("pump_battery", pumpBatteryLabel)
            if (pumpBatteryPercent == null) {
                editor.remove("pump_battery_percent")
            }
        }
        if (pumpBatteryPercent != null) {
            editor.putInt("pump_battery_percent", pumpBatteryPercent)
        }

        if (sensorBattery != null) {
            editor.putString("sensor_battery", sensorBattery)
        }
        if (sensorDaysLeft != null) {
            editor.putString("sensor_days_left", sensorDaysLeft)
        }

        editor.putLong("raw_accessibility_ts", nowMs)
        editor.apply()

        MinimedWidgetProvider.updateAllWidgets(applicationContext)

        val payload = HashMap<String, Any?>()
        payload["eventType"] = "accessibility"
        payload["packageName"] = pkg
        payload["timestampMs"] = nowMs
        if (sgValue != null) payload["sg"] = sgValue
        if (iobValue != null) payload["activeInsulin"] = iobValue
        if (carbsGrams != null) payload["carbsGrams"] = carbsGrams
        if (carbsTime != null) payload["carbsTime"] = carbsTime
        if (reservoirUnits != null) payload["reservoirUnits"] = reservoirUnits
        if (pumpBatteryLabel != null) payload["pumpBatteryLabel"] = pumpBatteryLabel
        if (pumpBatteryPercent != null) payload["pumpBatteryPercent"] = pumpBatteryPercent
        if (sensorBattery != null) payload["sensorBattery"] = sensorBattery
        if (sensorDaysLeft != null) payload["sensorDaysLeft"] = sensorDaysLeft
        // Avoid transmitting full screen dump unless needed locally
        if (joined.length < 300) {
            payload["rawAccessibility"] = joined
        }

        NotificationBridge.emitNotification(payload.filterValues { it != null }.mapValues { it.value!! })
    }

    private fun extractSg(nodes: List<String>): Int? {
        for (node in nodes) {
            val m = SG_WITH_UNIT_REGEX.find(node)
            if (m != null) {
                val valInt = m.groupValues[1].toIntOrNull()
                if (valInt != null && valInt in 40..400) {
                    return valInt
                }
            }
        }
        for (i in nodes.indices) {
            val current = nodes[i]
            if (current.contains("mg/dl", ignoreCase = true)) {
                val prev = nodes.getOrNull(i - 1)
                val next = nodes.getOrNull(i + 1)
                val prevVal = prev?.let { PURE_INT_REGEX.find(it)?.groupValues?.get(1)?.toIntOrNull() }
                if (prevVal != null && prevVal in 40..400) return prevVal
                val nextVal = next?.let { PURE_INT_REGEX.find(it)?.groupValues?.get(1)?.toIntOrNull() }
                if (nextVal != null && nextVal in 40..400) return nextVal
            }
        }
        val mgdlIndices = nodes.indices.filter { nodes[it].contains("mg/dl", ignoreCase = true) }
        for (idx in mgdlIndices) {
            val start = maxOf(0, idx - 3)
            val end = minOf(nodes.lastIndex, idx + 3)
            for (j in start..end) {
                val candidate = PURE_INT_REGEX.find(nodes[j])?.groupValues?.get(1)?.toIntOrNull()
                if (candidate != null && candidate in 40..400 && candidate !in AXIS_VALUES) {
                    return candidate
                }
            }
        }
        return null
    }

    private fun extractIob(nodes: List<String>): Double? {
        for (i in nodes.indices) {
            val node = nodes[i]
            val lower = node.lowercase(Locale.getDefault())
            if (lower.contains("insulina ativa") || lower.contains("active insulin") || lower.contains("iob")) {
                UNITS_REGEX.find(node)?.let { m ->
                    return m.groupValues[1].replace(',', '.').toDoubleOrNull()
                }
                val start = maxOf(0, i - 2)
                val end = minOf(nodes.lastIndex, i + 3)
                for (j in start..end) {
                    if (j == i) continue
                    val match = UNITS_REGEX.find(nodes[j])
                    if (match != null) {
                        val parsed = match.groupValues[1].replace(',', '.').toDoubleOrNull()
                        if (parsed != null && parsed <= 50.0) {
                            return parsed
                        }
                    }
                }
            }
        }
        return null
    }

    private fun extractMealCarbs(nodes: List<String>): Pair<Double?, String?> {
        for (i in nodes.indices) {
            val lower = nodes[i].lowercase(Locale.getDefault())
            if (lower.contains("refeição") || lower.contains("refeicao") ||
                lower.contains("meal") || lower.contains("hidratos") || lower.contains("carbs")
            ) {
                var foundCarbs: Double? = null
                var foundTime: String? = null
                val start = maxOf(0, i - 2)
                val end = minOf(nodes.lastIndex, i + 4)
                for (j in start..end) {
                    val candidate = nodes[j]
                    if (foundCarbs == null) {
                        CARBS_REGEX.find(candidate)?.let { m ->
                            foundCarbs = m.groupValues[1].replace(',', '.').toDoubleOrNull()
                        }
                    }
                    if (foundTime == null) {
                        TIME_REGEX.find(candidate)?.let { m ->
                            foundTime = m.value
                        }
                    }
                }
                if (foundCarbs != null) {
                    return Pair(foundCarbs, foundTime)
                }
            }
        }
        return Pair(null, null)
    }

    private fun extractReservoir(nodes: List<String>): Double? {
        for (i in nodes.indices) {
            val lower = nodes[i].lowercase(Locale.getDefault())
            if (lower.contains("reservatório") || lower.contains("reservatorio") ||
                lower.contains("reservoir") || lower.contains("restante") || lower.contains("cartucho")
            ) {
                val start = maxOf(0, i - 2)
                val end = minOf(nodes.lastIndex, i + 3)
                for (j in start..end) {
                    val m = UNITS_REGEX.find(nodes[j])
                    if (m != null) {
                        val parsed = m.groupValues[1].replace(',', '.').toDoubleOrNull()
                        if (parsed != null && parsed in 0.0..300.0) {
                            return parsed
                        }
                    }
                }
            }
        }
        val hasStatusKeywords = nodes.any {
            val l = it.lowercase(Locale.getDefault())
            l.contains("estado") || l.contains("bomba") || l.contains("status") || l.contains("pump")
        }
        if (hasStatusKeywords) {
            for (i in nodes.indices) {
                val node = nodes[i]
                val lower = node.lowercase(Locale.getDefault())
                if (lower.contains("insulina ativa") || lower.contains("active insulin") ||
                    lower.contains("bólus") || lower.contains("bolus") ||
                    lower.contains("basal") || lower.contains("u/h") || lower.contains("total")
                ) {
                    continue
                }
                val prevLower = nodes.getOrNull(i - 1)?.lowercase(Locale.getDefault()) ?: ""
                if (prevLower.contains("insulina ativa") || prevLower.contains("bólus") || prevLower.contains("basal")) {
                    continue
                }
                val m = UNITS_REGEX.find(node)
                if (m != null) {
                    val parsed = m.groupValues[1].replace(',', '.').toDoubleOrNull()
                    if (parsed != null && parsed in 0.0..300.0) {
                        return parsed
                    }
                }
            }
        }
        return null
    }

    /**
     * Preserves qualitative battery labels ("Alta", "Média", "Baixa") WITHOUT
     * inventing exact numerical percentages.
     */
    private fun extractPumpBattery(nodes: List<String>): Pair<String?, Int?> {
        for (i in nodes.indices) {
            val lower = nodes[i].lowercase(Locale.getDefault())
            if ((lower.contains("bomba") || lower.contains("pump") || lower.contains("bateria") || lower.contains("battery")) &&
                !lower.contains("sensor") && !lower.contains("transmissor")
            ) {
                val start = maxOf(0, i - 1)
                val end = minOf(nodes.lastIndex, i + 3)
                for (j in start..end) {
                    val candidate = nodes[j]
                    val cLower = candidate.lowercase(Locale.getDefault())
                    when {
                        cLower == "alta" || cLower.contains("alta") || cLower == "high" ->
                            return Pair("Alta", null)
                        cLower == "média" || cLower == "media" || cLower.contains("média") || cLower == "medium" ->
                            return Pair("Média", null)
                        cLower == "baixa" || cLower.contains("baixa") || cLower == "low" ->
                            return Pair("Baixa", null)
                    }
                    PERCENT_REGEX.find(candidate)?.let { m ->
                        val pct = m.groupValues[1].toIntOrNull()
                        if (pct != null && pct in 0..100) {
                            return Pair("$pct%", pct)
                        }
                    }
                }
            }
        }
        for (node in nodes) {
            val trimmed = node.trim().lowercase(Locale.getDefault())
            when (trimmed) {
                "alta" -> return Pair("Alta", null)
                "média", "media" -> return Pair("Média", null)
                "baixa" -> return Pair("Baixa", null)
            }
        }
        return Pair(null, null)
    }

    private fun extractSensorBattery(nodes: List<String>): String? {
        for (i in nodes.indices) {
            val lower = nodes[i].lowercase(Locale.getDefault())
            if (lower.contains("sensor") || lower.contains("transmissor") || lower.contains("transmitter")) {
                val start = maxOf(0, i - 1)
                val end = minOf(nodes.lastIndex, i + 4)
                for (j in start..end) {
                    PERCENT_REGEX.find(nodes[j])?.let { m ->
                        val pct = m.groupValues[1].toIntOrNull()
                        if (pct != null && pct in 0..100) {
                            return "$pct%"
                        }
                    }
                }
            }
        }
        return null
    }

    private fun extractSensorDaysLeft(nodes: List<String>): String? {
        for (node in nodes) {
            DAYS_REGEX.find(node)?.let { m ->
                return m.groupValues[1].trim()
            }
        }
        return null
    }

    private fun appendSgToLocalHistory(
        prefs: android.content.SharedPreferences,
        editor: android.content.SharedPreferences.Editor,
        sg: Int,
        nowMs: Long
    ) {
        try {
            val raw = prefs.getString("local_sg_history_json", "[]") ?: "[]"
            val arr = JSONArray(raw)
            if (arr.length() > 0) {
                val lastObj = arr.getJSONObject(arr.length() - 1)
                val lastTs = lastObj.optLong("ts", 0L)
                val lastSg = lastObj.optInt("sg", -1)
                if (nowMs - lastTs < 240_000L && lastSg == sg) {
                    return
                }
            }
            val entry = JSONObject().apply {
                put("sg", sg)
                put("ts", nowMs)
                put("src", "accessibility")
            }
            arr.put(entry)
            val trimmed = JSONArray()
            val startIdx = maxOf(0, arr.length() - 288)
            for (k in startIdx until arr.length()) {
                trimmed.put(arr.get(k))
            }
            editor.putString("local_sg_history_json", trimmed.toString())
        } catch (e: Exception) {
            Log.w(TAG, "Failed updating local history cache")
        }
    }
}
