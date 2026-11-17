package com.minimed.bridge.minimed_pixel_bridge

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class MinimedRichNotificationServiceTest {

    private val nowMs = 1_763_416_800_000L // fixed UTC reference epoch

    @Test
    fun compactNotificationShowsGlucoseArrowIobPredictionAndAge() {
        val freshTs = nowMs - 2 * 60_000L
        val content = MinimedRichNotificationService.buildNotificationContent(
            sgValue = 174,
            trendCode = "DOWN",
            trendArrow = "↓",
            rawIob = "2.00 U",
            predicted30mSg = 155,
            predicted30mValidated = true,
            predicted30mReadingTsMs = freshTs,
            readingTimestampMs = freshTs,
            nowMs = nowMs
        )

        assertEquals("174 mg/dL ↓ · Insulina ativa: 2,00 U", content.title)
        assertEquals("Em 30 min: 155 mg/dL (estimativa)", content.compactBody)
        assertEquals("Última leitura: há 2 min", content.subText)
        assertFalse(content.isAlert)
        assertFalse(content.isStale)
        assertFalse(content.expandedBody.contains("TIR"))
        assertFalse(content.expandedBody.contains("Reservat"))
        assertFalse(content.expandedBody.contains("COB"))
        assertFalse(content.expandedBody.contains("Desporto"))
    }

    @Test
    fun rapidDropReplacesPredictionButKeepsGlucoseArrowAndIobAndRestoresAfterAlert() {
        val ts1 = nowMs - 60_000L
        val alertContent = MinimedRichNotificationService.buildNotificationContent(
            sgValue = 174,
            trendCode = "DOWN_DOUBLE",
            trendArrow = "↓↓",
            rawIob = "2.00 U",
            predicted30mSg = 120,
            predicted30mValidated = true,
            predicted30mReadingTsMs = ts1,
            readingTimestampMs = ts1,
            nowMs = nowMs
        )

        assertEquals("174 mg/dL ↓↓ · Insulina ativa: 2,00 U", alertContent.title)
        assertEquals("⚠️ Atenção: glicose a descer rapidamente", alertContent.compactBody)
        assertTrue(alertContent.isAlert)

        // Alert ends -> trend stabilizes and validated prediction returns automatically
        val ts2 = nowMs - 30_000L
        val recoveredContent = MinimedRichNotificationService.buildNotificationContent(
            sgValue = 165,
            trendCode = "DOWN",
            trendArrow = "↓",
            rawIob = "1.80 U",
            predicted30mSg = 148,
            predicted30mValidated = true,
            predicted30mReadingTsMs = ts2,
            readingTimestampMs = ts2,
            nowMs = nowMs
        )

        assertEquals("165 mg/dL ↓ · Insulina ativa: 1,80 U", recoveredContent.title)
        assertEquals("Em 30 min: 148 mg/dL (estimativa)", recoveredContent.compactBody)
        assertFalse(recoveredContent.isAlert)
    }

    @Test
    fun alertPriorityOrdersMostCriticalFirstAndIgnoresUnvalidatedPredictions() {
        val freshTs = nowMs - 90_000L

        // Unvalidated low prediction MUST NOT trigger a hypo clinical alert
        val unvalidatedLowPred = MinimedRichNotificationService.buildNotificationContent(
            sgValue = 112,
            trendCode = "NONE",
            trendArrow = "→",
            rawIob = "1.10 U",
            predicted30mSg = 58,
            predicted30mValidated = false,
            predicted30mReadingTsMs = freshTs,
            readingTimestampMs = freshTs,
            nowMs = nowMs
        )
        assertEquals("Previsão indisponível", unvalidatedLowPred.compactBody)
        assertFalse(unvalidatedLowPred.isAlert)

        // Low SG + Rapid drop -> Low SG outranks rapid drop; Severe hypo (<54) outranks low
        val lowAndFastDrop = MinimedRichNotificationService.buildNotificationContent(
            sgValue = 64,
            trendCode = "DOWN_DOUBLE",
            trendArrow = "↓↓",
            rawIob = "0.50 U",
            predicted30mSg = 48,
            predicted30mValidated = true,
            predicted30mReadingTsMs = freshTs,
            readingTimestampMs = freshTs,
            nowMs = nowMs
        )
        assertEquals("⚠️ Atenção: glicose baixa", lowAndFastDrop.compactBody)

        val severeLow = MinimedRichNotificationService.buildNotificationContent(
            sgValue = 49,
            trendCode = "DOWN_DOUBLE",
            trendArrow = "↓↓",
            rawIob = "0.50 U",
            predicted30mSg = null,
            predicted30mValidated = false,
            predicted30mReadingTsMs = null,
            readingTimestampMs = freshTs,
            nowMs = nowMs
        )
        assertEquals("⚠️ Alerta crítico: hipoglicemia grave", severeLow.compactBody)
    }

    @Test
    fun staleReadingMarksClearlyAsOutdatedAndHidesOldPrediction() {
        val oldTs = nowMs - 24 * 60_000L
        val staleContent = MinimedRichNotificationService.buildNotificationContent(
            sgValue = 132,
            trendCode = "NONE",
            trendArrow = "→",
            rawIob = "1.25 U",
            predicted30mSg = 130,
            predicted30mValidated = true,
            predicted30mReadingTsMs = oldTs,
            readingTimestampMs = oldTs,
            nowMs = nowMs
        )

        assertTrue(staleContent.isStale)
        assertTrue(staleContent.compactBody.contains("Leitura desatualizada"))
        assertTrue(staleContent.compactBody.contains("24 min"))
        assertTrue(staleContent.subText.contains("desatualizada"))
        assertEquals("132 mg/dL → · Insulina ativa: 1,25 U", staleContent.title)
    }
}
