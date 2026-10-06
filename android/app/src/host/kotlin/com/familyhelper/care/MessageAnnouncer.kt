// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
package com.familyhelper.care

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.media.MediaPlayer
import android.util.Base64
import com.familyhelper.R
import com.google.android.gms.tasks.Tasks
import com.google.firebase.database.FirebaseDatabase
import com.google.firebase.functions.FirebaseFunctions
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** Reads new family messages aloud on grandma's phone (only after she turned
 * on 提醒與朗讀). Text: "小明說：…". Voice: "小明傳來語音" then the recording.
 * Silent/DND phones get the visible notification only.
 */
object MessageAnnouncer {
    private const val CHANNEL = "care_messages"
    private const val NOTE_ID = 4430

    fun run(context: Context, uid: String, db: FirebaseDatabase, care: CareStore) {
        val names = (Tasks.await(db.getReference("core/families/$uid/members").get(), 10, TimeUnit.SECONDS).value as? Map<*, *>)
            ?.mapNotNull { (k, v) -> (k as? String)?.let { it to (((v as? Map<*, *>)?.get("name") as? String) ?: "家人") } }?.toMap() ?: emptyMap()
        val items = Tasks.await(db.getReference("care/$uid/messages/items").get(), 10, TimeUnit.SECONDS).value as? Map<*, *> ?: return
        val last = care.lastAnnouncedAt()
        val now = System.currentTimeMillis()
        if (last == 0L) { care.markAnnounced(now); return } // never replay history on first run
        val fresh = items.mapNotNull { (k, v) -> (v as? Map<*, *>)?.let { (k as String) to it } }
            .filter { (_, m) -> m["authorId"] != uid && (m["authorId"] as? String) in names.keys &&
                ((m["createdAt"] as? Number)?.toLong() ?: 0) > last && ((m["expiresAt"] as? Number)?.toLong() ?: 0) > now }
            .sortedBy { (_, m) -> (m["createdAt"] as Number).toLong() }
            .take(5)
        for ((id, m) in fresh) {
            val who = names[m["authorId"]] ?: "家人"
            val voice = m["kind"] == "voice"
            if (voice && m["status"] != "ready") continue
            val intro = care.introFor(m["authorId"] as? String)?.takeIf { ReminderVoices.file(context, it).exists() }
            val line = when {
                voice -> "${who}傳來一段語音"
                intro != null -> (m["text"] as? String).orEmpty()
                else -> "${who}說：${(m["text"] as? String).orEmpty()}"
            }
            if (!voice && intro != null && CareNotifier.quietReason(context) == null) ReminderVoices.play(context, intro)
            show(context, who, if (voice) "傳來一段語音，打開 App 的「家人」可以再聽" else (m["text"] as? String).orEmpty())
            val blocked = CareNotifier.speak(context, line, care, "message")
            if (voice && blocked == null) playVoice(context, uid, id)
            care.markAnnounced((m["createdAt"] as Number).toLong())
        }
    }

    private fun show(context: Context, who: String, text: String) {
        val manager = context.getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(NotificationChannel(CHANNEL, "家人留言", NotificationManager.IMPORTANCE_HIGH))
        val open = context.packageManager.getLaunchIntentForPackage(context.packageName)?.let {
            PendingIntent.getActivity(context, NOTE_ID, it, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        }
        try {
            manager.notify(NOTE_ID, Notification.Builder(context, CHANNEL).setSmallIcon(R.drawable.ic_stat_family)
                .setContentTitle("$who 的留言").setContentText(text).setStyle(Notification.BigTextStyle().bigText(text))
                .setContentIntent(open).setAutoCancel(true).build())
        } catch (_: SecurityException) {}
    }

    private fun playVoice(context: Context, host: String, id: String) {
        try {
            val result = Tasks.await(FirebaseFunctions.getInstance("asia-east1").getHttpsCallable("getVoiceMessage")
                .call(mapOf("hostId" to host, "id" to id)), 20, TimeUnit.SECONDS).getData() as? Map<*, *> ?: return
            val bytes = Base64.decode(result["audioBase64"] as? String ?: return, Base64.DEFAULT)
            val file = File(context.cacheDir, "announce.m4a").apply { writeBytes(bytes) }
            com.familyhelper.common.LoudAudio.playBlocking(context, file)
            file.delete()
        } catch (_: Exception) {}
    }
}

/** FCM data message for grandma's phone: wake the care run right away. */
class HostPushReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val type = intent.getStringExtra("type") ?: return
        when (type) {
            "message", "photo" -> CareKickJob.schedule(context, 0)
            "locate" -> StatusJob.runNow(context, location = true, usage = AppUsage.enabled(context))
            "usage" -> StatusJob.runNow(context, location = false, usage = true)
            "ring" -> RingJob.schedule(context, intent.getStringExtra("by") ?: "家人",
                intent.getStringExtra("seconds")?.toIntOrNull() ?: 10)
        }
    }
}
