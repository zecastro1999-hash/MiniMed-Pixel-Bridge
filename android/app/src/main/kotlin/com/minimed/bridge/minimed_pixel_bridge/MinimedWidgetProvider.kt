package com.minimed.bridge.minimed_pixel_bridge

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.graphics.Color
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetPlugin
import es.antonborri.home_widget.HomeWidgetProvider
import kotlin.math.abs

class MinimedWidgetProvider : HomeWidgetProvider() {

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == AppWidgetManager.ACTION_APPWIDGET_UPDATE) {
            MinimedRichNotificationService.showOrUpdate(context)
        }
        super.onReceive(context, intent)
    }

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
        widgetData: SharedPreferences
    ) {
        MinimedRichNotificationService.showOrUpdate(context)

        for (widgetId in appWidgetIds) {
            val views = RemoteViews(context.packageName, R.layout.minimed_widget)

            val sgValueStr = widgetData.getString("sg_value", null)
            val trendCode = widgetData.getString("sg_trend", "NONE") ?: "NONE"
            val trendArrow = widgetData.getString("sg_trend_arrow", "→") ?: "→"
            val pred30Label = widgetData.getString("predicted_30m_label", "indisponível") ?: "indisponível"
            val tirPercent = widgetData.getString("tir_percent", "--%") ?: "--%"
            val rawIob = widgetData.getString("active_insulin", null)
            val fallbackUpdated = widgetData.getString("last_updated", "--") ?: "--"
            val timestampStr = widgetData.getString("last_timestamp_ms", null)

            val (ageLabel, isStale) = computeAgeStatus(timestampStr, fallbackUpdated)
            val sgInt = sgValueStr?.toIntOrNull()
            val sgDisplay = if (sgInt != null && sgInt > 0) "$sgInt mg/dL" else "-- mg/dL"

            val trendDesc = widgetData.getString("sg_trend_text_pt", null) ?: trendDescriptionPt(trendCode)
            val effectivePredLabel = if (isStale) "indisponível (leitura antiga)" else pred30Label
            val iobDisplay = formatPortugueseDecimal(rawIob) ?: "-- U"

            views.setTextViewText(R.id.widget_title, "MiniMed 780G")
            views.setTextViewText(R.id.widget_updated, ageLabel)
            views.setTextViewText(R.id.widget_sg_value, sgDisplay)
            views.setTextViewText(R.id.widget_sg_trend, if (sgInt != null && sgInt > 0) trendArrow else "")
            views.setTextViewText(
                R.id.widget_trend_label,
                if (sgInt == null || sgInt <= 0) "Sem leitura disponível" else if (isStale) "$trendDesc · antiga" else trendDesc
            )
            views.setTextViewText(R.id.widget_prediction_line, "Previsão 30 min: $effectivePredLabel")
            views.setTextViewText(R.id.widget_tir_pill, "No alvo: $tirPercent · 24h")
            views.setTextViewText(R.id.widget_iob_pill, iobDisplay)

            if (isStale) {
                views.setTextColor(R.id.widget_updated, Color.parseColor("#FFFFB4AB"))
                views.setTextColor(R.id.widget_sg_value, Color.parseColor("#FFD5B195"))
            } else if (sgInt != null && sgInt > 0) {
                views.setTextColor(R.id.widget_updated, Color.parseColor("#FFD5B195"))
                when {
                    sgInt < 70 -> views.setTextColor(R.id.widget_sg_value, Color.parseColor("#FFFFB4AB"))
                    sgInt > 250 -> views.setTextColor(R.id.widget_sg_value, Color.parseColor("#FFFFCCA7"))
                    else -> views.setTextColor(R.id.widget_sg_value, Color.parseColor("#FFFFFFFF"))
                }
            } else {
                views.setTextColor(R.id.widget_updated, Color.parseColor("#FFD5B195"))
                views.setTextColor(R.id.widget_sg_value, Color.parseColor("#FFD5B195"))
            }

            val launchIntent = Intent(context, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
            }
            val pendingIntent = PendingIntent.getActivity(
                context,
                widgetId,
                launchIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
            views.setOnClickPendingIntent(R.id.widget_root, pendingIntent)

            appWidgetManager.updateAppWidget(widgetId, views)
        }
    }

    private fun trendDescriptionPt(code: String): String {
        return when (code.uppercase()) {
            "UP" -> "Glicose a subir"
            "UP_DOUBLE", "DOUBLE_UP" -> "Glicose a subir rapidamente"
            "DOWN" -> "Glicose a descer"
            "DOWN_DOUBLE", "DOUBLE_DOWN" -> "Glicose a descer rapidamente"
            else -> "Glicose estável"
        }
    }

    private fun formatPortugueseDecimal(raw: String?): String? {
        if (raw.isNullOrBlank()) return null
        return raw.replace('.', ',')
    }

    private fun computeAgeStatus(timestampStr: String?, fallback: String): Pair<String, Boolean> {
        val epochMs = timestampStr?.toLongOrNull() ?: return Pair(fallback, false)
        if (epochMs <= 0L) return Pair(fallback, false)
        val diffMs = abs(System.currentTimeMillis() - epochMs)
        val mins = (diffMs / 60000L).toInt()
        val stale = mins > 15
        val label = when {
            mins < 1 -> "agora"
            mins < 60 -> "há ${mins} min"
            else -> {
                val hrs = mins / 60
                val remMins = mins % 60
                if (remMins == 0) "há ${hrs}h" else "há ${hrs}h ${remMins}m"
            }
        }
        return Pair(if (stale) "$label · antiga" else label, stale)
    }

    companion object {
        fun updateAllWidgets(context: Context) {
            MinimedRichNotificationService.showOrUpdate(context)

            val appWidgetManager = AppWidgetManager.getInstance(context)
            val componentName = ComponentName(context, MinimedWidgetProvider::class.java)
            val widgetIds = appWidgetManager.getAppWidgetIds(componentName)
            if (widgetIds.isNotEmpty()) {
                val prefs = HomeWidgetPlugin.getData(context)
                MinimedWidgetProvider().onUpdate(context, appWidgetManager, widgetIds, prefs)
            }
        }
    }
}
