// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
package com.familyhelper

import android.app.AlertDialog
import android.app.KeyguardManager
import android.content.*
import android.graphics.Color
import android.graphics.Point
import android.media.AudioManager
import android.media.ToneGenerator
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.os.SystemClock
import android.provider.Settings
import android.speech.tts.TextToSpeech
import android.view.WindowManager
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView
import android.widget.ScrollView
import androidx.core.content.ContextCompat
import com.familyhelper.common.BaseFamilyActivity
import com.familyhelper.common.NativeEvents
import com.familyhelper.health.HealthBridge
import com.familyhelper.widget.WidgetActions
import com.familyhelper.battery.BatteryRunner
import com.familyhelper.battery.BatteryScheduler
import com.familyhelper.battery.BatteryStore
import com.familyhelper.battery.BatterySync
import com.familyhelper.care.CareActions
import com.familyhelper.care.CareKickJob
import com.familyhelper.care.CareRunner
import com.familyhelper.care.CareStore
import com.familyhelper.care.CareNotifier
import com.familyhelper.care.ScreenTimeMonitor
import com.familyhelper.care.TaiwanMarket
import com.familyhelper.reminders.AndroidReminderStore
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.Locale
import java.util.concurrent.Executors

class MainActivity : BaseFamilyActivity() {
    private val health = HealthBridge(this)
    private var consentDialog: AlertDialog? = null
    private var consentDialogSessionId: String? = null
    private var messageDialog: AlertDialog? = null
    private var previewTts: TextToSpeech? = null
    private var previewTtsReady = false
    private val batteryWorker = Executors.newSingleThreadExecutor()
    private var batteryDialog: AlertDialog? = null
    private var batteryApprovalUntilMs = 0L
    private var reminderDialog: AlertDialog? = null
    private var reminderApprovalUntilMs = 0L
    private var placeApprovalUntilMs = 0L
    private var placeDialog: AlertDialog? = null
    private var sharingDialog: AlertDialog? = null
    private val sharingApprovalUntil = HashMap<String, Long>()
    private val careWorker = Executors.newSingleThreadExecutor()
    private val stopReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action == Intent.ACTION_SCREEN_OFF ||
                (intent?.action == "com.familyhelper.CAPTURE_STOPPED" && ConsentGate.isActive())) NativeEvents.stop()
            if (intent?.action == Intent.ACTION_POWER_CONNECTED ||
                intent?.action == Intent.ACTION_POWER_DISCONNECTED) sampleBatteryAsync()
        }
    }
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val filter = IntentFilter().apply {
            addAction(Intent.ACTION_SCREEN_ON)
            addAction(Intent.ACTION_SCREEN_OFF)
            addAction("com.familyhelper.CAPTURE_STOPPED")
            addAction(Intent.ACTION_POWER_CONNECTED)
            addAction(Intent.ACTION_POWER_DISCONNECTED)
        }
        ContextCompat.registerReceiver(this, stopReceiver, filter, ContextCompat.RECEIVER_NOT_EXPORTED)
        BatteryScheduler.ensure(this)
        // Preview speech is local to the host phone. No push payload or background audio is read aloud here.
        previewTts = TextToSpeech(applicationContext) { status ->
            Handler(Looper.getMainLooper()).post {
                if (status == TextToSpeech.SUCCESS) {
                    val language = previewTts?.setLanguage(Locale.TAIWAN)
                    previewTtsReady = language != null &&
                        language != TextToSpeech.LANG_MISSING_DATA &&
                        language != TextToSpeech.LANG_NOT_SUPPORTED
                }
            }
        }
    }
    override fun onResume() {
        super.onResume()
        BatteryScheduler.ensure(this)
        sampleBatteryAsync()
        ScreenTimeMonitor.start(this)
        try { com.familyhelper.care.PlaceAlerts.register(this) } catch (_: Exception) {}
        // Flutter triggers careRunNow after Firebase (or a debug Emulator) is configured.
        if (NativeEvents.channel != null && WidgetActions.hasAction()) bridge.invokeMethod("widgetReady", null)
    }
    override fun stopNative() {
        ConsentGate.clear()
        consentDialog?.dismiss(); consentDialog = null
        consentDialogSessionId = null
        messageDialog?.dismiss(); messageDialog = null
        batteryDialog?.dismiss(); batteryDialog = null
        batteryApprovalUntilMs = 0L
        reminderDialog?.dismiss(); reminderDialog = null
        reminderApprovalUntilMs = 0L
        stopService(Intent(this, MediaCaptureService::class.java))
        super.stopNative()
    }
    @Suppress("DEPRECATION")
    override fun handleRoleMethod(call: MethodCall, result: MethodChannel.Result): Boolean {
        when (call.method) {
            "requestConsent" -> showConsent(call.argument<String>("sessionId") ?: "", call.argument<String>("name") ?: "家人", result)
            "cancelConsent" -> {
                val id = call.argument<String>("sessionId") ?: ""
                if (id.isNotBlank()) {
                    ConsentGate.cancelApproval(id)
                    if (consentDialogSessionId == id) consentDialog?.dismiss()
                }
                result.success(null)
            }
            "startCaptureService" -> {
                val id = call.argument<String>("sessionId") ?: ""
                if (!foregroundActivity || !ConsentGate.activate(id)) { result.error("CONSENT_REQUIRED", "請重新取得長輩同意", null); return true }
                MediaCaptureService.ready = { e -> if (e == null) result.success(null) else result.error("CAPTURE_SERVICE", e.message, null) }
                try { ContextCompat.startForegroundService(this, Intent(this, MediaCaptureService::class.java)) }
                catch (e: Exception) { MediaCaptureService.ready = null; ConsentGate.clear(); throw e }
            }
            // Grandma pressed 呼叫/SOS herself in the open app: that press is the
            // local consent for this one family-answered session.
            "hostCallConsent" -> {
                val id = call.argument<String>("sessionId").orEmpty()
                if (!foregroundActivity || id.isBlank() || ConsentGate.isActive() ||
                    getSystemService(KeyguardManager::class.java).isKeyguardLocked) result.success(false)
                else { ConsentGate.approve(id); result.success(true) }
            }
            "activateCall" -> result.success(foregroundActivity && ConsentGate.activate(call.argument<String>("sessionId").orEmpty()))
            "keepAlive" -> result.success(ConsentGate.keepAlive(call.argument<String>("sessionId") ?: ""))
            "geometry" -> {
                val display = (getSystemService(WINDOW_SERVICE) as WindowManager).defaultDisplay
                val size = Point(); display.getRealSize(size)
                result.success(mapOf("width" to size.x, "height" to size.y, "rotation" to display.rotation,
                    "accessibility" to (HostAccessibilityService.instance != null)))
            }
            "gesture" -> result.success(HostAccessibilityService.instance?.perform(call.arguments as? Map<*, *> ?: emptyMap<Any, Any>()) ?: false)
            "accessibilityEnabled" -> result.success(HostAccessibilityService.instance != null)
            "accessibilitySettings" -> { startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)); result.success(null) }
            "batterySettings" -> { startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)); result.success(null) }
            "startStandby" -> { if (foregroundActivity) ContextCompat.startForegroundService(this, Intent(this, ForegroundHelperService::class.java)); result.success(null) }
            "stopStandby" -> { stopService(Intent(this, ForegroundHelperService::class.java)); result.success(null) }
            "consumeWidgetAction" -> result.success(WidgetActions.consume())
            "showLargeMessage" -> {
                val value = (call.argument<String>("text") ?: "").take(140)
                if (ConsentGate.isActive()) {
                    if (foregroundActivity) {
                        messageDialog?.dismiss()
                        val view = TextView(this).apply { text = value; textSize = 32f; setPadding(dp(24), dp(24), dp(24), dp(24)) }
                        messageDialog = AlertDialog.Builder(this).setTitle("家人說").setView(view).setPositiveButton("知道了", null).show()
                    } else {
                        val manager = getSystemService(android.app.NotificationManager::class.java)
                        val open = android.app.PendingIntent.getActivity(this, 91, packageManager.getLaunchIntentForPackage(packageName)!!,
                            android.app.PendingIntent.FLAG_UPDATE_CURRENT or android.app.PendingIntent.FLAG_IMMUTABLE)
                        manager.notify(204, android.app.Notification.Builder(this, "family_alerts").setSmallIcon(R.drawable.ic_stat_family)
                            .setContentTitle("家人說").setContentText(value).setStyle(android.app.Notification.BigTextStyle().bigText(value))
                            .setContentIntent(open).setAutoCancel(true).build())
                    }
                }
                result.success(null)
            }
            "previewSpeak" -> {
                val text = call.argument<String>("text")?.trim().orEmpty()
                when {
                    !foregroundActivity -> result.error("FOREGROUND_REQUIRED", "請開啟 App 再朗讀", null)
                    text.isBlank() || text.length > 240 -> result.error("INVALID_TEXT", "朗讀文字無效", null)
                    !previewTtsReady -> result.error("TTS_UNAVAILABLE", "請確認已安裝中文語音服務", null)
                    previewTts?.speak(text, TextToSpeech.QUEUE_FLUSH, null, "fh-preview-${System.currentTimeMillis()}") == TextToSpeech.SUCCESS -> result.success(true)
                    else -> result.error("TTS_FAILED", "朗讀未能開始", null)
                }
            }
            "previewAlertTone" -> {
                if (!foregroundActivity) {
                    result.error("FOREGROUND_REQUIRED", "請開啟 App 再試聽", null)
                } else {
                    try {
                        val tone = ToneGenerator(AudioManager.STREAM_NOTIFICATION, 75)
                        tone.startTone(ToneGenerator.TONE_PROP_BEEP, 250)
                        Handler(Looper.getMainLooper()).postDelayed({ tone.release() }, 350)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("TONE_UNAVAILABLE", "提示聲無法播放", null)
                    }
                }
            }
            "batterySnapshot" -> result.success(BatteryStore(this).snapshot())
            "screenOnDuration" -> result.success(ScreenTimeMonitor.continuousMs())
            "batterySampleNow" -> {
                batteryWorker.execute {
                    try {
                        BatteryRunner.sampleAndSync(applicationContext)
                        val snapshot = BatteryStore(applicationContext).snapshot()
                        Handler(Looper.getMainLooper()).post { result.success(snapshot); bridge.invokeMethod("batteryChanged", snapshot) }
                    } catch (e: Exception) {
                        Handler(Looper.getMainLooper()).post { result.error("BATTERY_SAMPLE", "電量檢查失敗，請稍後重試", null) }
                    }
                }
            }
            "batteryPrepareConsent" -> prepareBatteryConsent(result)
            "batteryShareConsent" -> {
                val uid = call.argument<String>("hostUid").orEmpty()
                val version = call.argument<Int>("version") ?: 0
                val disclosureVersion = call.argument<Int>("disclosureVersion") ?: 0
                if (!foregroundActivity || ConsentGate.isActive() ||
                    SystemClock.elapsedRealtime() > batteryApprovalUntilMs ||
                    getSystemService(KeyguardManager::class.java).isKeyguardLocked ||
                    disclosureVersion != BatteryStore.DISCLOSURE_VERSION) {
                    result.error("LOCAL_CONSENT_REQUIRED", "請長輩在本機解鎖後操作", null)
                } else {
                    batteryApprovalUntilMs = 0L
                    BatteryStore(this).setShareConsent(uid, version, true, disclosureVersion)
                    sampleBatteryAsync()
                    result.success(BatteryStore(this).snapshot())
                }
            }
            "batteryStopSharing" -> {
                batteryApprovalUntilMs = 0L
                BatteryStore(this).stopSharingLocally()
                result.success(BatteryStore(this).snapshot())
            }
            "batteryConsentSynced" -> {
                BatteryStore(this).markConsentSynced(call.argument<Int>("version") ?: 0)
                result.success(null)
            }
            "batteryVoiceEnabled" -> {
                if (!foregroundActivity || ConsentGate.isActive()) {
                    result.error("LOCAL_CONTROL_REQUIRED", "請長輩在本機設定朗讀", null)
                } else {
                    BatteryStore(this).setVoiceEnabled(call.argument<Boolean>("enabled") ?: false)
                    result.success(BatteryStore(this).snapshot())
                }
            }
            "batteryToneEnabled" -> {
                if (!foregroundActivity || ConsentGate.isActive()) {
                    result.error("LOCAL_CONTROL_REQUIRED", "請長輩在本機設定提示聲", null)
                } else {
                    BatteryStore(this).setToneEnabled(call.argument<Boolean>("enabled") ?: false)
                    result.success(BatteryStore(this).snapshot())
                }
            }
            "batteryAcknowledgeLocal" -> {
                BatteryStore(this).acknowledgeLocal()
                result.success(BatteryStore(this).snapshot())
            }
            "batteryRetrySync" -> batteryWorker.execute {
                try {
                    val okay = BatterySync.retry(applicationContext)
                    val snapshot = BatteryStore(applicationContext).snapshot()
                    Handler(Looper.getMainLooper()).post {
                        result.success(mapOf("synced" to okay, "snapshot" to snapshot))
                        bridge.invokeMethod("batteryChanged", snapshot)
                    }
                } catch (_: Exception) {
                    Handler(Looper.getMainLooper()).post {
                        result.error("BATTERY_SYNC", "電量同步暫時失敗，請稍後重試", null)
                    }
                }
            }
            "batteryConfigureEmulator" -> {
                try {
                    BatterySync.configureDebugEmulator(
                        call.argument<String>("host") ?: "10.0.2.2",
                        call.argument<Int>("authPort") ?: 9099,
                        call.argument<Int>("functionsPort") ?: 5001)
                    result.success(true)
                } catch (_: Exception) { result.error("EMULATOR_DISABLED", "目前不能使用測試服務", null) }
            }
            "careSnapshot" -> {
                val store = AndroidReminderStore(this)
                val today = TaiwanMarket.day(System.currentTimeMillis()).toString()
                val sound = CareRunner.currentSound(this)
                result.success(CareStore(this).snapshot(today) + store.snapshot() + mapOf(
                    "today" to today, "notificationsAllowed" to CareNotifier.notificationsAllowed(this),
                    "sound" to mapOf("ringer" to sound.ringer, "dnd" to sound.dnd, "mediaZero" to sound.mediaZero,
                        "problems" to sound.problems()),
                    "delivered" to store.acceptedKeys().toList(),
                    "plan" to (store.cachedSettings()?.items?.map { mapOf("type" to it.type, "time" to it.time,
                        "text" to it.text, "id" to it.id, "repeat" to it.repeat, "date" to it.date,
                        "voiceId" to it.voiceId, "author" to it.author,
                        "days" to it.days, "pausedUntil" to it.pausedUntil) } ?: emptyList<Any>())))
            }
            "reminderPrepareConsent" -> prepareReminderConsent(result)
            "reminderEnable" -> {
                val uid = call.argument<String>("hostUid").orEmpty()
                if (!foregroundActivity || ConsentGate.isActive() || SystemClock.elapsedRealtime() > reminderApprovalUntilMs ||
                    getSystemService(KeyguardManager::class.java).isKeyguardLocked || uid.isBlank()) {
                    result.error("LOCAL_CONSENT_REQUIRED", "請長輩在本機解鎖後操作", null)
                } else {
                    reminderApprovalUntilMs = 0L
                    AndroidReminderStore(this).enableLocally(uid, 2)
                    careWorker.execute { try { CareRunner.run(applicationContext) } catch (_: Exception) {} }
                    result.success(true)
                }
            }
            "reminderDisable" -> {
                reminderApprovalUntilMs = 0L
                AndroidReminderStore(this).stopLocally()
                CareStore(this).clearWeather()
                result.success(true)
            }
            "careReplay" -> {
                val key = call.argument<String>("key").orEmpty()
                careWorker.execute {
                    val item = AndroidReminderStore(applicationContext).cachedSettings()?.items
                        ?.firstOrNull { key.endsWith(":" + (if (it.id.isNotEmpty()) it.id else "${it.type}:${it.time}")) }
                    val outcome = item?.let { CareNotifier.playReminder(applicationContext, it, CareStore(applicationContext)) } ?: "failed"
                    Handler(Looper.getMainLooper()).post { result.success(outcome) }
                }
            }
            "careSaveConfig" -> {
                val store = CareStore(this)
                store.saveDatabaseUrl(call.argument<String>("databaseUrl").orEmpty())
                store.saveHostUid(call.argument<String>("hostUid").orEmpty())
                result.success(true)
            }
            "careSaveReminderPlan" -> {
                // The open app passes the plan it just read with the host's own
                // identity; the same strict parser and version rule apply.
                val store = AndroidReminderStore(this)
                val uid = call.argument<String>("hostUid").orEmpty()
                val plan = com.familyhelper.reminders.ReminderSettingsParser.parse(call.argument<Map<String, Any?>>("plan"))
                val saved = store.isEnabled() && uid == store.hostUid() && plan != null &&
                    plan.version >= (store.cachedSettings()?.version ?: 0)
                if (saved) store.saveSettings(plan!!)
                result.success(saved)
            }
            "careSaveVoiceProfiles" -> {
                CareStore(this).saveVoiceProfiles(call.argument<Map<String, Any?>>("profiles"))
                CareKickJob.schedule(this, 0)
                result.success(true)
            }
            "careSaveQuotes" -> {
                @Suppress("UNCHECKED_CAST")
                val quotes = (call.argument<Map<String, String>>("quotes") ?: emptyMap())
                CareStore(this).saveQuotes(quotes); result.success(true)
            }
            "careSaveWeather" -> {
                val store = CareStore(this)
                val city = call.argument<String>("city")
                if (city == null) { store.clearWeather() } else {
                    store.saveWeather(city, call.argument<Double>("latitude") ?: 999.0, call.argument<Double>("longitude") ?: 999.0,
                        call.argument<String>("morningTime").orEmpty(), call.argument<Int>("version") ?: 0)
                }
                result.success(true)
            }
            "careRespond" -> {
                if (!foregroundActivity || ConsentGate.isActive()) {
                    result.error("LOCAL_CONTROL_REQUIRED", "請長輩在本機回覆", null)
                } else {
                    val key = call.argument<String>("key").orEmpty()
                    val type = call.argument<String>("type").orEmpty()
                    val time = call.argument<String>("time").orEmpty()
                    val response = call.argument<String>("response").orEmpty()
                    val date = call.argument<String>("date").orEmpty()
                    CareNotifier.cancel(this, CareNotifier.reminderId(key))
                    careWorker.execute {
                        CareActions.respond(applicationContext, CareStore(applicationContext), date, key, type, time,
                            call.argument<String>("text").orEmpty(), response, System.currentTimeMillis())
                    }
                    result.success(true)
                }
            }
            "careSetRest" -> {
                if (!foregroundActivity || ConsentGate.isActive()) {
                    result.error("LOCAL_CONTROL_REQUIRED", "請長輩在本機設定", null)
                } else {
                    CareStore(this).setRestEnabled(call.argument<Boolean>("enabled") ?: false)
                    ScreenTimeMonitor.reschedule(this); result.success(true)
                }
            }
            "careSetCompanion" -> {
                val items = (call.argument<Map<String, Boolean>>("items") ?: emptyMap())
                CareStore(this).setCompanionConsent(call.argument<String>("hostUid").orEmpty(), call.argument<Int>("version") ?: 0, items)
                CareKickJob.schedule(this, 0); result.success(true)
            }
            "careStopCompanion" -> { CareStore(this).stopCompanionLocally(); result.success(true) }
            "careRunNow" -> careWorker.execute {
                try { CareRunner.run(applicationContext) } catch (_: Exception) {}
                Handler(Looper.getMainLooper()).post { result.success(true) }
            }
            "placeSnapshot" -> result.success(com.familyhelper.care.PlaceAlerts.snapshot(this))
            "placePrepareConsent" -> preparePlaceConsent(result)
            "placeSetHere" -> careWorker.execute {
                val ok = try { com.familyhelper.care.PlaceAlerts.captureHere(applicationContext, call.argument<String>("kind").orEmpty()) } catch (_: Exception) { false }
                Handler(Looper.getMainLooper()).post { result.success(ok) }
            }
            "placeEnable" -> {
                if (!foregroundActivity || SystemClock.elapsedRealtime() > placeApprovalUntilMs) {
                    result.error("LOCAL_CONSENT_REQUIRED", "請在長輩手機上同意", null)
                } else {
                    com.familyhelper.care.PlaceAlerts.enable(this, call.argument<String>("hostUid").orEmpty(), call.argument<Int>("version") ?: 0)
                    result.success(com.familyhelper.care.PlaceAlerts.snapshot(this))
                }
            }
            "placeDisable" -> {
                placeApprovalUntilMs = 0L
                com.familyhelper.care.PlaceAlerts.disable(this, call.argument<Boolean>("forget") == true)
                result.success(com.familyhelper.care.PlaceAlerts.snapshot(this))
            }
            "placeSetWorkName" -> {
                com.familyhelper.care.PlaceAlerts.setWorkName(this, call.argument<String>("name").orEmpty())
                result.success(com.familyhelper.care.PlaceAlerts.snapshot(this))
            }
            "placeRegister" -> { com.familyhelper.care.PlaceAlerts.register(this); result.success(true) }
            "locationSnapshot" -> result.success(com.familyhelper.care.LocationShare.snapshot(this))
            "usageSnapshot" -> careWorker.execute {
                val snap = try { com.familyhelper.care.AppUsage.snapshot(applicationContext) } catch (_: Exception) { emptyMap<String, Any?>() }
                Handler(Looper.getMainLooper()).post { result.success(snap) }
            }
            "sharingPrepareConsent" -> prepareSharingConsent(call.argument<String>("kind").orEmpty(), result)
            "locationEnable", "usageEnable" -> {
                val kind = if (call.method == "locationEnable") "location" else "usage"
                if (!foregroundActivity || SystemClock.elapsedRealtime() > (sharingApprovalUntil[kind] ?: 0L)) {
                    result.error("LOCAL_CONSENT_REQUIRED", "請在長輩手機上同意", null)
                } else {
                    sharingApprovalUntil.remove(kind)
                    val uid = call.argument<String>("hostUid").orEmpty()
                    val version = call.argument<Int>("version") ?: 0
                    if (kind == "location") com.familyhelper.care.LocationShare.enable(this, uid, version)
                    else com.familyhelper.care.AppUsage.enable(this, uid, version)
                    result.success(true)
                }
            }
            "locationDisable" -> { com.familyhelper.care.LocationShare.disable(this); result.success(true) }
            "usageDisable" -> { com.familyhelper.care.AppUsage.disable(this); result.success(true) }
            "locationRefresh" -> { com.familyhelper.care.StatusJob.runNow(this, location = true, usage = true); result.success(true) }
            "openUsageAccessSettings" -> {
                try { startActivity(Intent(Settings.ACTION_USAGE_ACCESS_SETTINGS)) } catch (_: Exception) {
                    startActivity(Intent(Settings.ACTION_SETTINGS))
                }
                result.success(null)
            }
            "openSoundSettings" -> { startActivity(Intent(Settings.ACTION_SOUND_SETTINGS)); result.success(null) }
            "openNotificationSettings" -> {
                startActivity(Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(Settings.EXTRA_APP_PACKAGE, packageName))
                result.success(null)
            }
            "healthStatus" -> health.status(result)
            "healthPermission" -> health.requestPermission(result)
            "readHealth" -> health.read(result)
            else -> return false
        }
        return true
    }
    private fun dp(n: Int) = (n * resources.displayMetrics.density).toInt()
    private fun sampleBatteryAsync() {
        batteryWorker.execute {
            try {
                BatteryRunner.sampleAndSync(applicationContext)
                val snapshot = BatteryStore(applicationContext).snapshot()
                Handler(Looper.getMainLooper()).post { bridge.invokeMethod("batteryChanged", snapshot) }
            } catch (_: Exception) { BatteryStore(applicationContext).markSyncError("電量檢查暫時失敗，請稍後重試") }
        }
    }

    private fun prepareBatteryConsent(result: MethodChannel.Result) {
        if (!foregroundActivity || ConsentGate.isActive() || batteryDialog != null ||
            getSystemService(KeyguardManager::class.java).isKeyguardLocked) {
            result.success(false); return
        }
        val message = TextView(this).apply {
            text = "同意後，這支手機會分享：\n\n1. 電量百分比與充電狀態。\n2. 取樣與同步時間。\n3. 低電量事件及判斷持續時間所需的事件編號、取樣計時資訊。\n4. 低電量時通知已配對家人；家人可確認收到。\n\n不分享其他手機的電量或 App 名稱。只有你能在本機開啟，也能隨時暫停或撤銷。"
            textSize = 26f; setTextColor(Color.BLACK)
            setPadding(dp(24), dp(24), dp(24), dp(24))
        }
        var answered = false
        val dialog = AlertDialog.Builder(this).setTitle("同意分享手機電量")
            .setView(ScrollView(this).apply { addView(message) })
            .setPositiveButton("同意分享") { _, _ ->
                answered = true
                batteryApprovalUntilMs = SystemClock.elapsedRealtime() + 60_000L
                result.success(true)
            }
            .setNegativeButton("先不要") { _, _ -> answered = true; result.success(false) }
            .create()
        batteryDialog = dialog
        dialog.setOnDismissListener {
            batteryDialog = null
            if (!answered) result.success(false)
        }
        dialog.show()
        dialog.window?.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        dialog.getButton(AlertDialog.BUTTON_POSITIVE)?.apply { textSize = 26f; minHeight = dp(96) }
        dialog.getButton(AlertDialog.BUTTON_NEGATIVE)?.apply { textSize = 26f; minHeight = dp(96) }
    }
    /** Grandma reads and agrees on her own unlocked phone; the approval is
     * only valid for two minutes and only for the item she agreed to.
     */
    private fun prepareSharingConsent(kind: String, result: MethodChannel.Result) {
        val (title, body) = when (kind) {
            "location" -> "分享我的位置" to "開啟後：\n\n1. 已配對的家人可以在 App 的「定位」看到你手機現在大約在哪裡（地圖上的位置與時間）。\n2. 手機約每 15 分鐘更新一次；家人按「重新定位」時也會更新。手機會在背景使用定位，系統可能顯示定位圖示。\n3. 家人可以按「讓手機響」，你的手機會用鬧鐘音量響 10 秒，方便找手機；通知上可以按「停止」。\n\n你可以隨時在「家人設定 → 分享位置」關閉，關閉後家人就看不到位置。"
            "usage" -> "分享手機使用時間" to "開啟後：\n\n1. 已配對的家人可以看到你今天和最近 7 天，每個 App 用了多久（例如 LINE 30 分鐘）。\n2. 只會傳 App 名稱和分鐘數，不會看到你在 App 裡看了什麼、和誰聊天。\n3. 接著要在系統設定裡，自己打開 FamilyHelper 長輩的「使用情形存取權」。\n\n你可以隨時在「家人設定 → 分享手機使用時間」關閉，關閉後家人就看不到。"
            else -> { result.success(false); return }
        }
        if (!foregroundActivity || sharingDialog != null || ConsentGate.isActive() ||
            getSystemService(KeyguardManager::class.java).isKeyguardLocked) { result.success(false); return }
        val message = TextView(this).apply {
            text = body
            textSize = 26f; setTextColor(Color.BLACK)
            setPadding(dp(24), dp(24), dp(24), dp(24))
        }
        var answered = false
        val dialog = AlertDialog.Builder(this).setTitle(title)
            .setView(ScrollView(this).apply { addView(message) })
            .setPositiveButton("同意") { _, _ ->
                answered = true
                sharingApprovalUntil[kind] = SystemClock.elapsedRealtime() + 120_000L
                result.success(true)
            }
            .setNegativeButton("先不要") { _, _ -> answered = true; result.success(false) }
            .create()
        sharingDialog = dialog
        dialog.setOnDismissListener { sharingDialog = null; if (!answered) result.success(false) }
        dialog.show()
        dialog.getButton(AlertDialog.BUTTON_POSITIVE)?.apply { textSize = 26f; minHeight = dp(96) }
        dialog.getButton(AlertDialog.BUTTON_NEGATIVE)?.apply { textSize = 26f; minHeight = dp(96) }
    }
    private fun preparePlaceConsent(result: MethodChannel.Result) {
        if (!foregroundActivity || placeDialog != null ||
            getSystemService(KeyguardManager::class.java).isKeyguardLocked) { result.success(false); return }
        val message = TextView(this).apply {
            text = "開啟後：\n\n1. 你離開或回到「家」、到達或離開「工作地點」時，已配對的家人會收到通知，例如「長輩到家了 18:05」。\n2. 只傳「哪個地方、到達或離開、時間」，不會傳你的位置座標或走過的路線。\n3. 手機會在背景使用定位，系統可能顯示定位圖示。\n\n你可以隨時在「家人設定 → 出門到家通知」暫停或關閉。"
            textSize = 26f; setTextColor(Color.BLACK)
            setPadding(dp(24), dp(24), dp(24), dp(24))
        }
        var answered = false
        val dialog = AlertDialog.Builder(this).setTitle("出門到家通知")
            .setView(ScrollView(this).apply { addView(message) })
            .setPositiveButton("同意") { _, _ ->
                answered = true
                placeApprovalUntilMs = SystemClock.elapsedRealtime() + 120_000L
                result.success(true)
            }
            .setNegativeButton("先不要") { _, _ -> answered = true; result.success(false) }
            .create()
        placeDialog = dialog
        dialog.setOnDismissListener { placeDialog = null; if (!answered) result.success(false) }
        dialog.show()
        dialog.getButton(AlertDialog.BUTTON_POSITIVE)?.apply { textSize = 26f; minHeight = dp(96) }
        dialog.getButton(AlertDialog.BUTTON_NEGATIVE)?.apply { textSize = 26f; minHeight = dp(96) }
    }
    private fun prepareReminderConsent(result: MethodChannel.Result) {
        if (!foregroundActivity || ConsentGate.isActive() || reminderDialog != null ||
            getSystemService(KeyguardManager::class.java).isKeyguardLocked) {
            result.success(false); return
        }
        val message = TextView(this).apply {
            text = "開啟後，這支手機會：\n\n1. 依家人設定的時間，跳出吃藥、喝水、休息、拍照提醒。\n2. 在家人設定的早安時間，顯示天氣與每日一句。\n3. 手機有聲音時，用中文朗讀提醒內容；靜音或勿擾時只顯示通知。\n\n提醒在這支手機上執行，可能晚幾分鐘，不保證準點。家人會看到提醒有沒有在這支手機播出（只代表手機播了，不代表你聽到或做了）。隨時可以關閉。"
            textSize = 26f; setTextColor(Color.BLACK)
            setPadding(dp(24), dp(24), dp(24), dp(24))
        }
        var answered = false
        val dialog = AlertDialog.Builder(this).setTitle("開啟提醒與朗讀")
            .setView(ScrollView(this).apply { addView(message) })
            .setPositiveButton("開啟") { _, _ ->
                answered = true
                reminderApprovalUntilMs = SystemClock.elapsedRealtime() + 60_000L
                result.success(true)
            }
            .setNegativeButton("先不要") { _, _ -> answered = true; result.success(false) }
            .create()
        reminderDialog = dialog
        dialog.setOnDismissListener {
            reminderDialog = null
            if (!answered) result.success(false)
        }
        dialog.show()
        dialog.window?.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        dialog.getButton(AlertDialog.BUTTON_POSITIVE)?.apply { textSize = 26f; minHeight = dp(96) }
        dialog.getButton(AlertDialog.BUTTON_NEGATIVE)?.apply { textSize = 26f; minHeight = dp(96) }
    }
    private fun showConsent(id: String, name: String, result: MethodChannel.Result) {
        if (!foregroundActivity || isFinishing || getSystemService(KeyguardManager::class.java).isKeyguardLocked ||
            ConsentGate.isActive() || consentDialog != null || id.isBlank()) { result.success(false); return }
        var resolved = false
        var dialog: AlertDialog? = null
        val layout = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setPadding(dp(24), dp(20), dp(24), dp(20)) }
        layout.addView(TextView(this).apply { text = "${name.take(24)}想幫忙\n\n同意後，家人可以看畫面、使用相機與麥克風，並協助操作。"; textSize = 28f; setTextColor(Color.BLACK) })
        fun finish(allowed: Boolean) {
            if (resolved) return
            resolved = true
            if (allowed) ConsentGate.approve(id)
            dialog?.dismiss()
            if (consentDialog === dialog) {
                consentDialog = null
                consentDialogSessionId = null
            }
            // Close the secure consent window before Flutter can start capture.
            result.success(allowed)
        }
        fun button(label: String, color: Int, action: () -> Unit): Button = Button(this).apply {
            text = label; textSize = 32f; setTextColor(Color.WHITE); setBackgroundColor(color)
            minHeight = dp(120); layoutParams = LinearLayout.LayoutParams(-1, dp(120)).apply { topMargin = dp(16) }
            setOnClickListener { action() }
        }
        layout.addView(button("同意", Color.rgb(18, 92, 73)) { finish(true) })
        layout.addView(button("拒絕", Color.rgb(166, 31, 42)) { finish(false) })
        dialog = AlertDialog.Builder(this).setView(ScrollView(this).apply { addView(layout) }).setCancelable(false).create().also {
            consentDialog = it
            consentDialogSessionId = id
            it.setOnDismissListener { if (!resolved) finish(false) }
            it.show()
            // Consent dialog is never included in screenshots / remote capture.
            it.window?.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        }
    }
    override fun onDestroy() {
        batteryDialog?.dismiss()
        batteryApprovalUntilMs = 0L
        batteryWorker.shutdownNow()
        careWorker.shutdownNow()
        reminderDialog?.dismiss()
        previewTts?.stop()
        previewTts?.shutdown()
        previewTts = null
        unregisterReceiver(stopReceiver)
        super.onDestroy()
    }
}
