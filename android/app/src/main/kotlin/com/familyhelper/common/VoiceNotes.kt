// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
package com.familyhelper.common

import android.content.Context
import android.media.MediaPlayer
import android.media.MediaRecorder
import android.os.Build
import android.os.SystemClock
import android.util.Base64
import java.io.File

/** Short voice notes for family messages: AAC in MP4, mono, at most 30 seconds.
 * Recording only starts from an explicit button press in the open app.
 */
class VoiceNotes(private val context: Context) {
    companion object { const val MAX_MS = 30_000 }
    private var recorder: MediaRecorder? = null
    private var player: MediaPlayer? = null
    private var stopper: (() -> Unit)? = null
    private var file: File? = null
    private var startedAt = 0L

    fun start() {
        stopPlayback()
        cancel()
        val out = File(context.cacheDir, "voice-note.m4a").also { it.delete() }
        @Suppress("DEPRECATION")
        val next = if (Build.VERSION.SDK_INT >= 31) MediaRecorder(context) else MediaRecorder()
        try {
            next.setAudioSource(MediaRecorder.AudioSource.MIC)
            next.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
            next.setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
            next.setAudioChannels(1)
            next.setAudioSamplingRate(16_000)
            next.setAudioEncodingBitRate(32_000)
            next.setMaxDuration(MAX_MS)
            next.setOutputFile(out.absolutePath)
            next.prepare()
            next.start()
        } catch (e: Exception) { next.release(); out.delete(); throw e }
        recorder = next; file = out; startedAt = SystemClock.elapsedRealtime()
    }

    /** Returns base64 audio and its duration, or null if nothing usable was recorded. */
    fun stop(): Map<String, Any>? {
        val active = recorder ?: return null
        val duration = (SystemClock.elapsedRealtime() - startedAt).coerceAtMost(MAX_MS.toLong())
        recorder = null
        try { active.stop() } catch (_: Exception) { active.release(); file?.delete(); return null }
        active.release()
        val out = file ?: return null
        file = null
        val bytes = out.readBytes().also { out.delete() }
        if (duration < 500 || bytes.size < 64 || bytes.size > 400_000) return null
        return mapOf("audioBase64" to Base64.encodeToString(bytes, Base64.NO_WRAP), "durationMs" to duration.toInt())
    }

    /** 0..1 loudness since the last call, for a live waveform; 0 when idle. */
    fun level(): Double = try { ((recorder?.maxAmplitude ?: 0) / 32767.0).coerceIn(0.0, 1.0) } catch (_: Exception) { 0.0 }
    fun elapsedMs(): Long = if (recorder == null) 0 else SystemClock.elapsedRealtime() - startedAt

    fun cancel() {
        recorder?.let { try { it.stop() } catch (_: Exception) {}; it.release() }
        recorder = null
        file?.delete(); file = null
    }

    fun play(base64: String, onDone: () -> Unit) {
        stopPlayback()
        val bytes = Base64.decode(base64, Base64.DEFAULT)
        require(bytes.size in 64..400_000) { "語音檔無效" }
        val out = File(context.cacheDir, "voice-play.m4a").apply { writeBytes(bytes) }
        stopper = LoudAudio.playAsync(context, out) { stopper = null; onDone() }
    }

    fun stopPlayback() {
        stopper?.invoke(); stopper = null
        player?.let { try { it.stop() } catch (_: Exception) {}; it.release() }
        player = null
        File(context.cacheDir, "voice-play.m4a").delete()
    }
}
