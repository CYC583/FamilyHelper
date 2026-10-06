// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
package com.familyhelper

import android.app.job.JobInfo
import android.app.job.JobParameters
import android.app.job.JobScheduler
import android.app.job.JobService
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.os.PersistableBundle
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import java.util.Locale

/** Family phone: an SOS or 呼叫 push is also read aloud, even when the app is
 * closed. The visible high-priority notification still comes from FCM.
 */
class ClientPushReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val type = intent.getStringExtra("type") ?: return
        if (type != "sos" && type != "call") return
        val extras = PersistableBundle().apply { putString("type", type) }
        context.getSystemService(JobScheduler::class.java).schedule(
            JobInfo.Builder(4501, ComponentName(context, AlertSpeakJob::class.java))
                .setOverrideDeadline(0).setExtras(extras).build())
    }
}

class AlertSpeakJob : JobService() {
    private var tts: TextToSpeech? = null
    override fun onStartJob(params: JobParameters): Boolean {
        val words = if (params.extras.getString("type") == "sos")
            "緊急通知，長輩按了緊急求助，請馬上打開 App 接聽，並打電話給長輩。"
        else "長輩找你，請打開 App 接聽。"
        tts = TextToSpeech(applicationContext) { status ->
            if (status != TextToSpeech.SUCCESS) { jobFinished(params, false); return@TextToSpeech }
            tts?.setLanguage(Locale.TAIWAN)
            tts?.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
                override fun onStart(id: String?) {}
                override fun onDone(id: String?) { finish(params) }
                @Deprecated("Deprecated in Java") override fun onError(id: String?) { finish(params) }
            })
            tts?.speak(words, TextToSpeech.QUEUE_FLUSH, null, "fh-alert")
            tts?.speak(words, TextToSpeech.QUEUE_ADD, null, "fh-alert-2")
        }
        return true
    }
    private fun finish(params: JobParameters) {
        tts?.shutdown(); tts = null; jobFinished(params, false)
    }
    override fun onStopJob(params: JobParameters): Boolean { tts?.shutdown(); return false }
}
