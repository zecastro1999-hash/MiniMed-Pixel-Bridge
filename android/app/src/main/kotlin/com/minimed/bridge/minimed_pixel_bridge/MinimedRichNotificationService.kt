package com.minimed.bridge.minimed_pixel_bridge

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Color
import android.os.Build
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import es.antonborri.home_widget.HomeWidgetPlugin
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import kotlin.math.abs
import kotlin.math.max

/**
 * Minimalist ongoing NotificationCompat presentation for MiniMed 780G.
 *
 * Compact line 1: `<sg> mg/dL <arrow> · Insulina ativa: <iob> U`
 * Compact line 2: Priority clinical/staleness alert OR validated 30-min prediction
 * (`Em 30 min: <sg> mg/dL (estimativa)` / `Previsão indisponível`).
 * Subtext / `when`: discreet age of the latest glucose reading.
 */
object MinimedRichNotificationService {

    private const val TAG = "MinimedRichNotif"
    private const val CHANNEL_ID = "minimed_780g_live_telemetry"
    private const val CHANNEL_NAME = "MiniMed 780G Telemetria Contínua"
    private const val NOTIFICATION_ID = 7801
    private const val STALE_THRESHOLD_MINUTES = 15
    private const val PREDICTION_MATCH_WINDOW_MS = 360_000L // 6 min
    private const val PREDICTION_MAX_AGE_MINUTES = 12

    data class NotificationContent(
        val title: String,
        val compactBody: String,
        val expandedBody: String,
        val subText: String,
        val isAlert: Boolean,
        val isStale: Boolean,
        val epochMs: Long
    )

    fun hasNotificationPermission(context: Context): Boolean {
        val managerCompat = NotificationManagerCompat.from(context)
        if (!managerCompat.areNotificationsEnabled()) return false
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            return ContextCompat.checkSelfPermission(
                context,
                Manifest.permission.POST_NOTIFICATIONS
            ) == PackageManager.PERMISSION_GRANTED
        }
        return true
    }

    fun showOrUpdate(context: Context) {
        if (!hasNotificationPermission(context)) {
            return
        }

        ensureChannel(context)

        val prefs = HomeWidgetPlugin.getData(context)
        val sgInt = prefs.getString("sg_value", null)?.toIntOrNull()?.takeIf { it in 20..600 }
        val trendCode = prefs.getString("sg_trend", null)
        val trendArrow = prefs.getString("sg_trend_arrow", null)
        val rawIob = prefs.getString("active_insulin", null)
            ?: prefs.getString("active_insulin_num", null)
        val predSg = prefs.getString("predicted_30m_sg", null)?.toIntOrNull()?.takeIf { it in 20..600 }
        val predValidated = prefs.getString("predicted_30m_validated", "false") == "true"
        val predReadingTsMs = prefs.getString("predicted_30m_reading_ts_ms", null)?.toLongOrNull()
        val readingTsMs = prefs.getString("last_timestamp_ms", null)?.toLongOrNull()
        val targetLow = (prefs.getString("target_low_mgdl", null)?.toIntOrNull() ?: 70).coerceIn(50, 120)
        val targetHigh = (prefs.getString("target_high_mgdl", null)?.toIntOrNull() ?: 180).coerceIn(120, 300)
        val reauthRequired = prefs.getString("carelink_reauth_required", "false") == "true"

        val content = buildNotificationContent(
            sgValue = sgInt,
            trendCode = trendCode,
            trendArrow = trendArrow,
            rawIob = rawIob,
            predicted30mSg = predSg,
            predicted30mValidated = predValidated,
            predicted30mReadingTsMs = predReadingTsMs,
            readingTimestampMs = readingTsMs,
            nowMs = System.currentTimeMillis(),
            targetLowMgDl = targetLow,
            targetHighMgDl = targetHigh,
            careLinkReauthRequired = reauthRequired
        )

        val launchIntent = Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val pendingIntent = PendingIntent.getActivity(
            context,
            NOTIFICATION_ID,
            launchIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val builder = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_minimed)
            .setColor(
                if (content.isAlert) Color.parseColor("#FFFFB4AB")
                else Color.parseColor("#FFCCA7")
            )
            .setContentTitle(content.title)
            .setContentText(content.compactBody)
            .setSubText(content.subText)
            .setStyle(
                NotificationCompat.BigTextStyle()
                    .setBigContentTitle(content.title)
                    .bigText(content.expandedBody)
                    .setSummaryText(content.subText)
            )
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .setSilent(true)
            .setOnlyAlertOnce(true)
            .setLocalOnly(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setCategory(NotificationCompat.CATEGORY_STATUS)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)

        if (content.epochMs > 0L) {
            builder.setWhen(content.epochMs).setShowWhen(true)
        } else {
            builder.setShowWhen(false)
        }

        try {
            NotificationManagerCompat.from(context).notify(NOTIFICATION_ID, builder.build())
        } catch (se: SecurityException) {
            Log.w(TAG, "Notification permission unavailable")
        }
    }

    internal fun buildNotificationContent(
        sgValue: Int?,
        trendCode: String?,
        trendArrow: String?,
        rawIob: String?,
        predicted30mSg: Int?,
        predicted30mValidated: Boolean,
        predicted30mReadingTsMs: Long?,
        readingTimestampMs: Long?,
        nowMs: Long,
        targetLowMgDl: Int = 70,
        targetHighMgDl: Int = 180,
        careLinkReauthRequired: Boolean = false
    ): NotificationContent {
        val validSg = sgValue?.takeIf { it in 20..600 }
        val resolvedArrow = resolveTrendArrow(trendCode, trendArrow)
        val iobDisplay = formatIobPt(rawIob)

        // Line 1: Never replace current glucose, never drop trend arrow when available, always show active insulin.
        val sgSegment = if (validSg != null) {
            if (resolvedArrow != null) "$validSg mg/dL $resolvedArrow" else "$validSg mg/dL"
        } else {
            "-- mg/dL"
        }
        val title = "$sgSegment · Insulina ativa: $iobDisplay"

        val validEpochMs = readingTimestampMs?.takeIf { it > 0L } ?: 0L
        val ageEvaluation = evaluateReadingAge(validEpochMs, nowMs)
        val isStale = validSg != null && ageEvaluation.isStale
        val ageLabel = ageEvaluation.ageLabel

        val lowThreshold = targetLowMgDl.coerceIn(54, 120)
        val severeHighThreshold = max(250, targetHighMgDl + 50)

        // Strict single highest-priority alert evaluation using ONLY real measured data (never predictions).
        val alertMessage: String? = when {
            validSg == null -> {
                if (careLinkReauthRequired) {
                    "⚠️ Sessão CareLink expirada — autenticar"
                } else {
                    "A aguardar leitura válida"
                }
            }
            validSg < 54 -> {
                if (isStale) {
                    "⚠️ Hipoglicemia grave · leitura desatualizada ($ageLabel)"
                } else {
                    "⚠️ Alerta crítico: hipoglicemia grave"
                }
            }
            isStale -> {
                when {
                    validSg < lowThreshold -> "⚠️ Leitura desatualizada ($ageLabel) · glicose baixa"
                    careLinkReauthRequired -> "⚠️ Leitura desatualizada ($ageLabel) · renovar CareLink"
                    else -> "⚠️ Leitura desatualizada ($ageLabel)"
                }
            }
            validSg < lowThreshold -> "⚠️ Atenção: glicose baixa"
            isRapidDrop(trendCode, resolvedArrow) -> "⚠️ Atenção: glicose a descer rapidamente"
            validSg > severeHighThreshold -> "⚠️ Atenção: glicose muito elevada"
            isRapidRise(trendCode, resolvedArrow) -> "⚠️ Atenção: glicose a subir rapidamente"
            else -> null
        }

        val predictionMatchesCurrentReading = predicted30mValidated &&
            predicted30mSg != null &&
            predicted30mSg in 20..600 &&
            validSg != null &&
            !isStale &&
            ageEvaluation.ageMinutes in 0..PREDICTION_MAX_AGE_MINUTES &&
            (predicted30mReadingTsMs == null ||
                predicted30mReadingTsMs <= 0L ||
                validEpochMs <= 0L ||
                abs(validEpochMs - predicted30mReadingTsMs) <= PREDICTION_MATCH_WINDOW_MS)

        val compactBody = alertMessage ?: if (predictionMatchesCurrentReading) {
            "Em 30 min: $predicted30mSg mg/dL (estimativa)"
        } else {
            "Previsão indisponível"
        }

        val subText = when {
            validSg == null -> "MiniMed 780G · Sem leitura"
            isStale -> "Última leitura: $ageLabel (desatualizada)"
            else -> "Última leitura: $ageLabel"
        }

        val expandedBody = if (validSg == null) {
            compactBody
        } else {
            val clockStr = if (validEpochMs > 0L) {
                SimpleDateFormat("HH:mm", Locale.getDefault()).format(Date(validEpochMs))
            } else {
                null
            }
            buildString {
                appendLine(compactBody)
                append("Última leitura: ")
                if (clockStr != null) {
                    append(clockStr)
                    append(" (")
                    append(ageLabel)
                    if (isStale) append(" · desatualizada")
                    append(')')
                } else {
                    append(ageLabel)
                    if (isStale) append(" · desatualizada")
                }
            }.trimEnd()
        }

        val hasUrgentVisualAlert = alertMessage != null && validSg != null

        return NotificationContent(
            title = title,
            compactBody = compactBody,
            expandedBody = expandedBody,
            subText = subText,
            isAlert = hasUrgentVisualAlert,
            isStale = isStale,
            epochMs = if (validEpochMs > 0L && validEpochMs <= nowMs + 120_000L) validEpochMs else 0L
        )
    }

    private data class AgeEvaluation(
        val ageMinutes: Int,
        val ageLabel: String,
        val isStale: Boolean
    )

    private fun evaluateReadingAge(epochMs: Long, nowMs: Long): AgeEvaluation {
        if (epochMs <= 0L) {
            return AgeEvaluation(
                ageMinutes = Int.MAX_VALUE,
                ageLabel = "hora desconhecida",
                isStale = true
            )
        }
        val rawDiff = nowMs - epochMs
        if (rawDiff < -120_000L) {
            return AgeEvaluation(
                ageMinutes = Int.MAX_VALUE,
                ageLabel = "hora inválida",
                isStale = true
            )
        }
        val clampedDiff = if (rawDiff < 0L) 0L else rawDiff
        val mins = (clampedDiff / 60_000L).toInt()
        val stale = mins > STALE_THRESHOLD_MINUTES
        val label = when {
            mins < 1 -> "agora"
            mins < 60 -> "há $mins min"
            else -> {
                val hrs = mins / 60
                val remMins = mins % 60
                if (remMins == 0) "há ${hrs}h" else "há ${hrs}h ${remMins}m"
            }
        }
        return AgeEvaluation(ageMinutes = mins, ageLabel = label, isStale = stale)
    }

    private fun resolveTrendArrow(trendCode: String?, trendArrow: String?): String? {
        val explicitArrow = trendArrow?.trim()
        if (!explicitArrow.isNullOrEmpty()) return explicitArrow
        return when (trendCode?.trim()?.uppercase(Locale.US)) {
            "UP_DOUBLE", "DOUBLE_UP" -> "↑↑"
            "UP" -> "↑"
            "DOWN_DOUBLE", "DOUBLE_DOWN" -> "↓↓"
            "DOWN" -> "↓"
            "NONE", "FLAT", "STEADY" -> "→"
            else -> null
        }
    }

    private fun isRapidDrop(trendCode: String?, arrow: String?): Boolean {
        val code = trendCode?.trim()?.uppercase(Locale.US) ?: ""
        return code == "DOWN_DOUBLE" || code == "DOUBLE_DOWN" ||
            arrow == "↓↓" || arrow == "⇊"
    }

    private fun isRapidRise(trendCode: String?, arrow: String?): Boolean {
        val code = trendCode?.trim()?.uppercase(Locale.US) ?: ""
        return code == "UP_DOUBLE" || code == "DOUBLE_UP" ||
            arrow == "↑↑" || arrow == "⇈"
    }

    private fun formatIobPt(raw: String?): String {
        val clean = raw?.trim() ?: ""
        if (clean.isEmpty()) return "-- U"
        val numericMatch = Regex("""(\d+(?:[.,]\d+)?)""").find(clean)
        if (numericMatch != null) {
            val parsed = numericMatch.groupValues[1].replace(',', '.').toDoubleOrNull()
            if (parsed != null && parsed >= 0.0) {
                return String.format(Locale.US, "%.2f", parsed).replace('.', ',') + " U"
            }
        }
        val pt = clean.replace('.', ',')
        return if (pt.endsWith("U", ignoreCase = true)) pt else "$pt U"
    }

    private fun ensureChannel(context: Context) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            val existing = manager.getNotificationChannel(CHANNEL_ID)
            if (existing == null) {
                val channel = NotificationChannel(
                    CHANNEL_ID,
                    CHANNEL_NAME,
                    NotificationManager.IMPORTANCE_LOW
                ).apply {
                    description = "Telemetria silenciosa contínua da bomba MiniMed 780G"
                    setSound(null, null)
                    enableVibration(false)
                    setShowBadge(false)
                    lockscreenVisibility = Notification.VISIBILITY_PUBLIC
                }
                manager.createNotificationChannel(channel)
            }
        }
    }
}
