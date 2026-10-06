// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
package com.familyhelper.common

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import java.io.File
import java.util.Locale

/** Traditional Chinese speech for the open app, rendered to a file and played
 * through LoudAudio so it can be louder than maximum volume. Queued in order.
 */
object Speaker {
    private var tts: TextToSpeech? = null
    private var ready = false
    private val queue = ArrayDeque<String>()
    private var busy = false
    private lateinit var app: Context

    @Synchronized fun say(context: Context, text: String) {
        app = context.applicationContext
        queue.addLast(text)
        if (tts == null) {
            tts = TextToSpeech(app) { status ->
                synchronized(this) {
                    ready = status == TextToSpeech.SUCCESS
                    if (ready) {
                        tts?.setLanguage(Locale.TAIWAN)
                        tts?.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
                            override fun onStart(id: String?) {}
                            override fun onDone(id: String?) {
                                val f = File(app.cacheDir, "$id.wav")
                                Handler(Looper.getMainLooper()).post {
                                    LoudAudio.playAsync(app, f) { f.delete(); next() }
                                }
                            }
                            @Deprecated("Deprecated in Java") override fun onError(id: String?) { next() }
                        })
                        pump()
                    } else queue.clear()
                }
            }
        } else if (ready) pump()
    }

    @Synchronized private fun next() { busy = false; pump() }

    @Synchronized private fun pump() {
        if (busy || !ready) return
        val text = queue.removeFirstOrNull() ?: return
        busy = true
        val id = "fh-say-${System.nanoTime()}"
        val result = tts?.synthesizeToFile(text, null, File(app.cacheDir, "$id.wav"), id)
        if (result != TextToSpeech.SUCCESS) busy = false
    }
}
