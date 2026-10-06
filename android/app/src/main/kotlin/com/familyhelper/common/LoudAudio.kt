// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
package com.familyhelper.common

import android.content.Context
import android.media.AudioAttributes
import android.media.MediaPlayer
import android.media.audiofx.LoudnessEnhancer
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** Plays announcements louder than the phone's maximum media volume using
 * Android's LoudnessEnhancer, at the level grandma chose (off / medium / strong).
 */
object LoudAudio {
    private fun prefs(c: Context) = c.applicationContext.getSharedPreferences("loud_audio_v1", Context.MODE_PRIVATE)

    /** 0 = off, 1 = medium (+8 dB), 2 = strong (+14 dB, default). */
    fun level(c: Context) = prefs(c).getInt("level", 2)
    fun setLevel(c: Context, level: Int) = prefs(c).edit().putInt("level", level.coerceIn(0, 2)).commit()
    private fun gainMb(c: Context) = when (level(c)) { 0 -> 0; 1 -> 800; else -> 1400 }

    private fun prepare(c: Context, file: File, onDone: () -> Unit): Pair<MediaPlayer, LoudnessEnhancer?> {
        val player = MediaPlayer()
        player.setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA)
            .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build())
        player.setDataSource(file.absolutePath)
        player.setOnCompletionListener { onDone() }
        player.setOnErrorListener { _, _, _ -> onDone(); true }
        player.prepare()
        val gain = gainMb(c)
        val enhancer = if (gain > 0) try {
            LoudnessEnhancer(player.audioSessionId).apply { setTargetGain(gain); enabled = true }
        } catch (_: Exception) { null } else null
        return player to enhancer
    }

    /** Blocks until finished (max 40 s). Call on a worker thread. */
    fun playBlocking(c: Context, file: File) {
        if (!file.exists()) return
        val done = CountDownLatch(1)
        var pair: Pair<MediaPlayer, LoudnessEnhancer?>? = null
        try {
            pair = prepare(c, file) { done.countDown() }
            pair.first.start()
            done.await(40, TimeUnit.SECONDS)
        } catch (_: Exception) {
        } finally {
            pair?.second?.release(); pair?.first?.release()
        }
    }

    /** Non-blocking; releases itself when done. Returns a stop function. */
    fun playAsync(c: Context, file: File, onDone: () -> Unit = {}): () -> Unit {
        var pair: Pair<MediaPlayer, LoudnessEnhancer?>? = null
        var released = false
        val release = {
            if (!released) {
                released = true
                pair?.second?.release()
                try { pair?.first?.stop() } catch (_: Exception) {}
                pair?.first?.release()
            }
        }
        try {
            pair = prepare(c, file) { release(); onDone() }
            pair.first.start()
        } catch (_: Exception) { release(); onDone() }
        return release
    }
}
