// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
package com.familyhelper.care

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.AudioManager
import android.os.Build
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import androidx.core.content.ContextCompat
import com.familyhelper.R
import com.familyhelper.reminders.DueReminder
import java.util.Locale
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

/** Visible reminder first, speech second. "Accepted" means Android took the
 * notification request; a queued utterance is never reported as heard.
 */
object CareNotifier {
    const val CHANNEL = "care_reminders"
    const val ACTION_REMINDER = "com.familyhelper.care.REMINDER"
    const val ACTION_REST = "com.familyhelper.care.REST"
    private const val REST_ID = 4410
    private const val MORNING_ID = 4411

    fun notificationsAllowed(context: Context): Boolean {
        val manager = context.getSystemService(NotificationManager::class.java)
        return manager.areNotificationsEnabled() && (Build.VERSION.SDK_INT < 33 ||
            ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED)
    }

    private fun channel(context: Context): NotificationManager {
        val manager = context.getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(NotificationChannel(CHANNEL, "每日提醒與早安", NotificationManager.IMPORTANCE_HIGH))
        return manager
    }

    fun reminderId(key: String) = 5000 + (key.hashCode() and 0x0fff)

    /** Each button needs its own PendingIntent; equal codes would overwrite extras. */
    fun actionRequestCode(id: Int, response: String) = id * 4 + when (response) {
        "done" -> 1; "later" -> 2; "skip" -> 3; else -> 0
    }

    private fun openApp(context: Context, code: Int): PendingIntent? =
        context.packageManager.getLaunchIntentForPackage(context.packageName)?.let {
            PendingIntent.getActivity(context, code, it, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        }

    private fun action(context: Context, label: String, intent: Intent, code: Int): Notification.Action =
        Notification.Action.Builder(null, label, PendingIntent.getBroadcast(context, code,
            // Explicit, non-exported receiver: other apps cannot fake a reply.
            intent.setClass(context, CareActionReceiver::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)).build()

    fun reminderTitle(type: String) = when (type) {
        "medicine" -> "吃藥時間到了"
        "water" -> "喝點水吧"
        "rest" -> "起來動一動、休息一下"
        "photo" -> "記得拍一張照片給家人"
        else -> "家人的提醒"
    }

    /** What grandma hears: "小明提醒你：吃血壓藥", or a gentle default. */
    fun spokenLine(type: String, text: String, author: String): String {
        val who = author.trim().ifEmpty { "家人" }
        val words = text.trim()
        return when {
            words.isNotEmpty() -> "長輩，${who}提醒你：$words"
            type == "medicine" -> "長輩，${who}提醒你，吃藥時間到了。"
            type == "water" -> "長輩，${who}提醒你，喝點水吧。"
            type == "rest" -> "長輩，${who}提醒你，起來動一動，休息一下。"
            type == "photo" -> "長輩，${who}提醒你，今天記得拍一張照片給家人。"
            else -> "長輩，${who}有話要跟你說。"
        }
    }

    /** Spoken reminder; no buttons to press. Lock screen shows a generic line. */
    fun presentReminder(context: Context, due: DueReminder, store: CareStore): Boolean {
        if (!notificationsAllowed(context)) {
            store.noteEvent("reminder", "通知權限未開啟，${reminderTitle(due.item.type)} 未能顯示")
            return false
        }
        val manager = channel(context)
        val id = reminderId(due.key)
        val intro = store.introFor(due.item.authorUid)
        // With the family member's own intro clip, read only the content after it.
        val line = if (intro != null && ReminderVoices.file(context, intro).exists())
            (due.item.text.trim().ifEmpty { spokenLine(due.item.type, "", "").substringAfter("提醒你，").ifEmpty { "有話要跟你說。" } })
        else spokenLine(due.item.type, due.item.text, due.item.author)
        val body = due.item.text.ifBlank { if (due.item.voiceId != null) "${due.item.author.ifBlank { "家人" }}錄了一段話給你" else "${due.item.time} 的提醒" }
        val publicVersion = Notification.Builder(context, CHANNEL).setSmallIcon(R.drawable.ic_stat_family)
            .setContentTitle("FamilyHelper 有一則提醒").setContentText("解鎖後查看").build()
        val note = Notification.Builder(context, CHANNEL).setSmallIcon(R.drawable.ic_stat_family)
            .setContentTitle(if (due.item.type == "custom") "${due.item.author.ifBlank { "家人" }}的提醒" else reminderTitle(due.item.type))
            .setContentText(body).setStyle(Notification.BigTextStyle().bigText(body))
            .setCategory(Notification.CATEGORY_REMINDER).setVisibility(Notification.VISIBILITY_PRIVATE)
            .setPublicVersion(publicVersion).setContentIntent(openApp(context, id)).setAutoCancel(true).build()
        return try {
            manager.notify(id, note)
            store.noteEvent("reminder", "已顯示「${reminderTitle(due.item.type)}」")
            val outcome = playReminder(context, due.item, store)
            store.recordDelivery(due.key, outcome, System.currentTimeMillis())
            // A real playback failure is retried on the next run (within the hour).
            outcome != "failed"
        } catch (_: SecurityException) {
            store.noteEvent("reminder", "Android 拒絕顯示提醒通知")
            store.recordDelivery(due.key, "failed", System.currentTimeMillis())
            false
        }
    }

    /** Speak (and play the family voice). Returns played / text_fallback / silent / failed. */
    fun playReminder(context: Context, item: com.familyhelper.reminders.ReminderItem, store: CareStore): String {
        if (quietReason(context) != null) return "silent"
        val intro = store.introFor(item.authorUid)?.takeIf { ReminderVoices.file(context, it).exists() }
        val line = if (intro != null)
            (item.text.trim().ifEmpty { spokenLine(item.type, "", "").substringAfter("提醒你，") })
        else spokenLine(item.type, item.text, item.author)
        if (intro != null) ReminderVoices.play(context, intro)
        val voice = item.voiceId
        var voiceMissing = false
        if (voice != null) {
            store.appHostUid()?.let { ReminderVoices.fetch(context, it, voice) }
            voiceMissing = !ReminderVoices.file(context, voice).exists()
        }
        val blocked = speak(context, if (voiceMissing && item.text.isBlank())
            "$line（錄音還沒下載好）" else line, store, "reminder")
        if (blocked != null) return "failed"
        if (voice != null && !voiceMissing) ReminderVoices.play(context, voice)
        return if (voiceMissing) "text_fallback" else "played"
    }

    fun cancel(context: Context, id: Int) = context.getSystemService(NotificationManager::class.java).cancel(id)

    fun presentRest(context: Context, store: CareStore): Boolean {
        if (!notificationsAllowed(context)) { store.noteEvent("rest", "通知權限未開啟，休息提醒未顯示"); return false }
        val manager = channel(context)
        val note = Notification.Builder(context, CHANNEL).setSmallIcon(R.drawable.ic_stat_family)
            .setContentTitle("看手機很久了，休息一下吧").setContentText("讓眼睛看看遠方，起來走一走。")
            .setCategory(Notification.CATEGORY_REMINDER).setContentIntent(openApp(context, REST_ID))
            .addAction(action(context, "我休息一下", Intent(ACTION_REST).putExtra("response", "done"), REST_ID * 2))
            .addAction(action(context, "稍後", Intent(ACTION_REST).putExtra("response", "later"), REST_ID * 2 + 1))
            .setAutoCancel(true).build()
        return try {
            manager.notify(REST_ID, note)
            store.noteEvent("rest", "已顯示休息提醒")
            speak(context, "長輩，看手機很久了，休息一下，讓眼睛看看遠方。", store, "rest")
            true
        } catch (_: SecurityException) { store.noteEvent("rest", "Android 拒絕顯示休息提醒"); false }
    }
    fun cancelRest(context: Context) = cancel(context, REST_ID)

    fun presentMorning(context: Context, script: String, store: CareStore, introVoiceId: String? = null): String {
        if (!notificationsAllowed(context)) return "通知權限未開啟，早安播報未顯示"
        val manager = channel(context)
        val note = Notification.Builder(context, CHANNEL).setSmallIcon(R.drawable.ic_stat_family)
            .setContentTitle("早安").setContentText(script).setStyle(Notification.BigTextStyle().bigText(script))
            .setContentIntent(openApp(context, MORNING_ID)).setAutoCancel(true).build()
        return try {
            manager.notify(MORNING_ID, note)
            if (introVoiceId != null && quietReason(context) == null) ReminderVoices.play(context, introVoiceId)
            speak(context, script, store, "morning") ?: "已顯示早安卡並朗讀"
        } catch (_: SecurityException) { "Android 拒絕顯示早安通知" }
    }

    /** Why the phone should stay silent (silent/vibrate, DND, media at zero), or null. */
    fun quietReason(context: Context): String? {
        val audio = context.getSystemService(AudioManager::class.java)
        val manager = context.getSystemService(NotificationManager::class.java)
        return when {
            audio.ringerMode != AudioManager.RINGER_MODE_NORMAL -> "手機是靜音或震動，只顯示通知不朗讀"
            manager.currentInterruptionFilter > NotificationManager.INTERRUPTION_FILTER_ALL -> "勿擾模式中，只顯示通知不朗讀"
            audio.getStreamVolume(AudioManager.STREAM_MUSIC) == 0 -> "媒體音量為零，只顯示通知不朗讀"
            else -> null
        }
    }

    /** Returns null when speech actually started, or the reason it did not. */
    fun speak(context: Context, words: String, store: CareStore, tag: String): String? {
        val reason = quietReason(context)
        if (reason != null) { store.noteEvent("${tag}Voice", reason); return reason }
        val ready = CountDownLatch(1)
        val status = AtomicInteger(TextToSpeech.ERROR)
        val tts = TextToSpeech(context.applicationContext) { status.set(it); ready.countDown() }
        try {
            if (!ready.await(5, TimeUnit.SECONDS) || status.get() != TextToSpeech.SUCCESS) return "中文朗讀服務無法啟動".also { store.noteEvent("${tag}Voice", it) }
            val language = tts.setLanguage(Locale.TAIWAN)
            if (language == TextToSpeech.LANG_MISSING_DATA || language == TextToSpeech.LANG_NOT_SUPPORTED) {
                return "手機沒有可用的繁體中文語音".also { store.noteEvent("${tag}Voice", it) }
            }
            val finished = CountDownLatch(1)
            val ok = AtomicInteger(0)
            val out = java.io.File(context.cacheDir, "care-$tag-${System.nanoTime()}.wav")
            tts.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
                override fun onStart(utteranceId: String?) {}
                override fun onDone(utteranceId: String?) { ok.set(1); finished.countDown() }
                @Deprecated("Deprecated in Java") override fun onError(utteranceId: String?) { finished.countDown() }
            })
            if (tts.synthesizeToFile(words.take(400), null, out, "familyhelper-$tag") != TextToSpeech.SUCCESS) {
                return "朗讀未能排入語音服務".also { store.noteEvent("${tag}Voice", it) }
            }
            finished.await(30, TimeUnit.SECONDS)
            if (ok.get() != 1) return "朗讀沒有開始".also { store.noteEvent("${tag}Voice", it) }
            // Played through LoudnessEnhancer so it can exceed maximum volume.
            com.familyhelper.common.LoudAudio.playBlocking(context, out)
            out.delete()
            return null.also { store.noteEvent("${tag}Voice", "已朗讀") }
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt(); return "朗讀被系統中斷"
        } finally { tts.stop(); tts.shutdown() }
    }
}
