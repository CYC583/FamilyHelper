// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
package com.familyhelper.care

import android.content.Context
import android.media.MediaPlayer
import android.util.Base64
import com.google.android.gms.tasks.Tasks
import com.google.firebase.functions.FirebaseFunctions
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** Family-recorded reminder voices kept on grandma's phone, so they still play
 * offline and after the cloud copy expires (30 days).
 */
object ReminderVoices {
    private fun dir(context: Context) = File(context.filesDir, "reminder-voices").apply { mkdirs() }
    fun file(context: Context, id: String) = File(dir(context), "$id.m4a")

    /** Download missing voices for the current plan; delete ones no longer used. */
    fun sync(context: Context, host: String, wanted: Set<String>) {
        dir(context).listFiles()?.forEach { f -> if (f.nameWithoutExtension !in wanted) f.delete() }
        for (id in wanted) fetch(context, host, id)
    }

    fun fetch(context: Context, host: String, id: String) {
            val target = file(context, id)
            if (target.exists() && target.length() > 0) return
            try {
                val data = Tasks.await(FirebaseFunctions.getInstance("asia-east1").getHttpsCallable("getReminderVoice")
                    .call(mapOf("hostId" to host, "voiceId" to id)), 20, TimeUnit.SECONDS).getData() as? Map<*, *> ?: return
                val bytes = Base64.decode(data["audioBase64"] as? String ?: return, Base64.DEFAULT)
                if (bytes.size in 64..400_000) {
                    val tmp = File(dir(context), "$id.part").apply { writeBytes(bytes) }
                    tmp.renameTo(target)
                }
            } catch (_: Exception) { /* retried on the next care run */ }
    }

    fun play(context: Context, id: String) {
        com.familyhelper.common.LoudAudio.playBlocking(context, file(context, id))
    }
}
