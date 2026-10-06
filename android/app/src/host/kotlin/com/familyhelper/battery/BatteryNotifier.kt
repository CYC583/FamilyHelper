// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
package com.familyhelper.battery

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioManager
import android.media.RingtoneManager
import android.os.Build
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import androidx.core.content.ContextCompat
import com.familyhelper.R
import java.util.Locale
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

/** One stable visible alert. Sound/TTS are attempted only when Android allows
 * them; a queued TTS utterance is never reported as actually spoken.
 */
object BatteryNotifier {
    private const val NOTIFICATION_ID = 4301
    private const val SOUND_CHANNEL = "care_battery_host_sound"
    private const val SILENT_CHANNEL = "care_battery_host_silent"
    @Volatile private var activeVoice: TextToSpeech? = null

    fun present(context: Context, decision: BatteryDecision, store: BatteryStore) {
        if (decision.reminder == "resolved") {
            activeVoice?.stop()
            activeVoice = null
            context.getSystemService(NotificationManager::class.java).cancel(NOTIFICATION_ID)
            return
        }
        if (decision.reminder == null) return
        val manager = context.getSystemService(NotificationManager::class.java)
        val allowed = manager.areNotificationsEnabled() &&
            (Build.VERSION.SDK_INT < 33 || ContextCompat.checkSelfPermission(context,
                Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED)
        if (!allowed) {
            store.notificationResult(null, "Android 通知權限未開啟；App 首頁仍會顯示提醒")
            store.voiceResult(null, "通知權限未開啟，未自動朗讀")
            return
        }
        val silent = NotificationChannel(SILENT_CHANNEL, "電量守護（無聲）", NotificationManager.IMPORTANCE_DEFAULT)
            .apply { setSound(null, null); enableVibration(false) }
        val sound = NotificationChannel(SOUND_CHANNEL, "電量守護（提示聲）", NotificationManager.IMPORTANCE_HIGH)
            .apply { setSound(RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION), null) }
        manager.createNotificationChannel(silent)
        manager.createNotificationChannel(sound)
        val critical = decision.reminder == "critical"
        val title = if (critical) "手機電量很低，請現在充電" else "手機快沒電了，請幫手機充電"
        val body = if (critical) "已提醒長輩充電；請接上充電器。" else "請接上充電器，充電後提醒會自動解除。"
        val launch = context.packageManager.getLaunchIntentForPackage(context.packageName)
        val pending = launch?.let { PendingIntent.getActivity(context, NOTIFICATION_ID, it,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE) }
        val channel = if (store.toneEnabled()) SOUND_CHANNEL else SILENT_CHANNEL
        val note = Notification.Builder(context, channel)
            .setSmallIcon(R.drawable.ic_stat_family)
            .setContentTitle(title).setContentText(body)
            .setStyle(Notification.BigTextStyle().bigText(body))
            .setCategory(Notification.CATEGORY_REMINDER)
            .setContentIntent(pending).setOngoing(true).build()
        try {
            manager.notify(NOTIFICATION_ID, note)
            store.notificationResult(System.currentTimeMillis(), null)
        } catch (_: SecurityException) {
            store.notificationResult(null, "Android 拒絕顯示通知")
            store.voiceResult(null, "通知未能顯示，未自動朗讀")
            return
        }
        speakIfAllowed(context, store, if (critical)
            "長輩，手機電量很低，請現在充電" else "長輩，手機快沒電了，請幫手機充電")
    }

    private fun speakIfAllowed(context: Context, store: BatteryStore, words: String) {
        if (!store.voiceEnabled()) { store.voiceResult(null, "長輩已關閉自動朗讀"); return }
        val audio = context.getSystemService(AudioManager::class.java)
        val manager = context.getSystemService(NotificationManager::class.java)
        if (audio.ringerMode != AudioManager.RINGER_MODE_NORMAL ||
            audio.getStreamVolume(AudioManager.STREAM_MUSIC) == 0 ||
            manager.currentInterruptionFilter != NotificationManager.INTERRUPTION_FILTER_ALL) {
            store.voiceResult(null, "手機靜音、媒體音量為零或勿擾中，未自動朗讀")
            return
        }
        val initialized = CountDownLatch(1)
        val status = AtomicInteger(TextToSpeech.ERROR)
        val tts = TextToSpeech(context.applicationContext) { result ->
            status.set(result); initialized.countDown()
        }
        activeVoice = tts
        try {
            if (!initialized.await(5, TimeUnit.SECONDS) || status.get() != TextToSpeech.SUCCESS) {
                store.voiceResult(null, "中文朗讀服務無法啟動")
                return
            }
            val language = tts.setLanguage(Locale.TAIWAN)
            if (language == TextToSpeech.LANG_MISSING_DATA ||
                language == TextToSpeech.LANG_NOT_SUPPORTED) {
                store.voiceResult(null, "手機沒有可用的繁體中文語音")
                return
            }
            val finished = CountDownLatch(1)
            tts.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
                override fun onStart(utteranceId: String?) {
                    store.voiceResult(System.currentTimeMillis(), null)
                }
                override fun onDone(utteranceId: String?) { finished.countDown() }
                override fun onError(utteranceId: String?) {
                    store.voiceResult(null, "朗讀失敗，請檢查語音服務")
                    finished.countDown()
                }
            })
            if (tts.speak(words, TextToSpeech.QUEUE_FLUSH, null, "familyhelper-battery") != TextToSpeech.SUCCESS) {
                store.voiceResult(null, "朗讀未能排入語音服務")
                return
            }
            if (!finished.await(15, TimeUnit.SECONDS)) {
                store.voiceResult(null, "朗讀逾時，請檢查語音服務")
            }
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
            store.voiceResult(null, "朗讀被系統中斷")
        } finally {
            if (activeVoice === tts) activeVoice = null
            tts.stop(); tts.shutdown()
        }
    }
}
