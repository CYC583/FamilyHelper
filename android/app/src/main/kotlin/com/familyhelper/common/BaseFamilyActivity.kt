// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
package com.familyhelper.common

import android.content.Intent
import android.os.Bundle
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

abstract class BaseFamilyActivity : FlutterFragmentActivity() {
    protected lateinit var bridge: MethodChannel
    protected var foregroundActivity = false
    private val voice by lazy { VoiceNotes(this) }
    override fun onCreate(savedInstanceState: Bundle?) { super.onCreate(savedInstanceState); Notifications.create(this) }
    override fun onResume() { super.onResume(); foregroundActivity = true }
    override fun onPause() { foregroundActivity = false; voice.cancel(); super.onPause() }
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        bridge = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "familyhelper/native")
        NativeEvents.channel = bridge
        NativeEvents.beforeStop = { stopNative() }
        bridge.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "startCallService" -> {
                        if (!foregroundActivity) { result.error("FOREGROUND_REQUIRED", "請開啟 App 再連線", null); return@setMethodCallHandler }
                        ForegroundCallService.ready = { error ->
                            if (error == null) result.success(null) else result.error("CALL_SERVICE", error.message, null)
                        }
                        try { ContextCompat.startForegroundService(this, Intent(this, ForegroundCallService::class.java)) }
                        catch (e: Exception) { ForegroundCallService.ready = null; throw e }
                    }
                    "stopServices" -> { stopNative(); result.success(null) }
                    "voiceStart" -> {
                        if (!foregroundActivity) { result.error("FOREGROUND_REQUIRED", "請開啟 App 再錄音", null); return@setMethodCallHandler }
                        try { voice.start(); result.success(true) }
                        catch (_: Exception) { result.error("RECORD_FAILED", "無法開始錄音，請確認麥克風權限", null) }
                    }
                    "voiceStop" -> result.success(voice.stop())
                    "voiceLevel" -> result.success(mapOf("level" to voice.level(), "elapsedMs" to voice.elapsedMs()))
                    // Opens the dialer with the number filled in; the person presses call.
                    "dialNumber" -> {
                        val number = call.argument<String>("number").orEmpty().filter { it.isDigit() || it == '+' }
                        if (number.length < 6) result.success(false) else {
                            startActivity(Intent(Intent.ACTION_DIAL, android.net.Uri.parse("tel:$number")))
                            result.success(true)
                        }
                    }
                    "openMap" -> {
                        val lat = call.argument<Double>("lat"); val lng = call.argument<Double>("lng")
                        if (lat == null || lng == null) result.success(false) else {
                            val uri = android.net.Uri.parse("https://www.google.com/maps/search/?api=1&query=$lat,$lng")
                            startActivity(Intent(Intent.ACTION_VIEW, uri)); result.success(true)
                        }
                    }
                    "navigateTo" -> {
                        val lat = call.argument<Double>("lat"); val lng = call.argument<Double>("lng")
                        if (lat == null || lng == null) result.success(false) else {
                            val uri = android.net.Uri.parse("https://www.google.com/maps/dir/?api=1&destination=$lat,$lng")
                            startActivity(Intent(Intent.ACTION_VIEW, uri)); result.success(true)
                        }
                    }
                    "loudLevel" -> result.success(LoudAudio.level(this@BaseFamilyActivity))
                    "appInfo" -> {
                        val info = packageManager.getPackageInfo(packageName, 0)
                        val power = getSystemService(android.os.PowerManager::class.java)
                        result.success(mapOf("version" to info.versionName,
                            "batteryUnrestricted" to power.isIgnoringBatteryOptimizations(packageName)))
                    }
                    "setLoudLevel" -> {
                        LoudAudio.setLevel(this@BaseFamilyActivity, call.argument<Int>("level") ?: 2)
                        result.success(true)
                    }
                    "speakText" -> {
                        val words = call.argument<String>("text").orEmpty().trim().take(300)
                        if (words.isEmpty()) result.success(false)
                        else { Speaker.say(applicationContext, words); result.success(true) }
                    }
                    "voiceCancel" -> { voice.cancel(); result.success(null) }
                    "voicePlay" -> {
                        val audio = call.argument<String>("audioBase64").orEmpty()
                        try { voice.play(audio) { bridge.invokeMethod("voicePlaybackDone", null) }; result.success(true) }
                        catch (_: Exception) { result.error("PLAY_FAILED", "語音無法播放", null) }
                    }
                    "voiceStopPlay" -> { voice.stopPlayback(); result.success(null) }
                    else -> if (!handleRoleMethod(call, result)) result.notImplemented()
                }
            } catch (e: Exception) { result.error("NATIVE_ERROR", e.message, null) }
        }
    }
    protected open fun stopNative() { stopService(Intent(this, ForegroundCallService::class.java)) }
    protected abstract fun handleRoleMethod(call: MethodCall, result: MethodChannel.Result): Boolean
    override fun onDestroy() {
        voice.cancel(); voice.stopPlayback()
        if (isFinishing) { NativeEvents.stop(); NativeEvents.channel = null; NativeEvents.beforeStop = null }
        super.onDestroy()
    }
}
