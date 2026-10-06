// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import '../common/constants.dart';
import '../common/firebase_service.dart';
import '../common/native_bridge.dart';
import '../common/care_reminder_rules.dart';
import '../common/rtc_session.dart';
import '../common/unread.dart';
import '../client/remote_view_page.dart' show CallControls;
import 'pairing_page.dart';
import 'sos_service.dart';
import 'health_connect_service.dart';
import 'host_photo_page.dart';
import 'photo_camera_service.dart';
import 'battery_consent_page.dart';
import 'host_today_page.dart';
import 'host_family_page.dart';
import '../common/ui/fh_tokens.dart';
import '../common/ui/fh_widgets.dart';
import 'host_tab_bar.dart';

class HostHomePage extends StatefulWidget {
  final FirebaseService api;
  final PhotoCameraPort? photoCameraPort;
  final String? initialNotice;
  const HostHomePage({
    super.key,
    required this.api,
    this.photoCameraPort,
    this.initialNotice,
  });
  @override
  State<HostHomePage> createState() => _HostHomePageState();
}

/// Stays outside the scrollable remote-assistance content so the host can
/// always end the current session without searching for an off-screen button.
class HostEndAssistanceBar extends StatelessWidget {
  final VoidCallback onEnd;
  const HostEndAssistanceBar({super.key, required this.onEnd});

  @override
  Widget build(BuildContext context) => SafeArea(
    top: false,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
      child: SizedBox(
        height: 120,
        child: FilledButton(
          onPressed: onEnd,
          style: FilledButton.styleFrom(
            backgroundColor: FhColors.danger,
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(24),
            ),
          ),
          child: const Text(
            '結束協助',
            style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
          ),
        ),
      ),
    ),
  );
}

class _HostHomePageState extends State<HostHomePage>
    with WidgetsBindingObserver {
  StreamSubscription<Map<String, dynamic>>? familySub, sessionSub;
  StreamSubscription<String>? nativeSub;
  Timer? healthTimer, pendingTimer, restTimer;
  DateTime? restSnoozedUntil, lastRestRemindedAt;
  bool restDialogOpen = false;
  RtcSession? rtc;
  String? pendingId, watchingId, askingId, processingConsentId, lastAlertId;
  Map<String, dynamic> pending = {};
  bool dialogOpen = false,
      batteryDialogOpen = false,
      sending = false,
      foreground = true,
      settingsOpen = false,
      syncing = false;
  String status = '';
  Map<String, dynamic> battery = {};
  int selectedTab = 0;
  Map<String, dynamic> chat = const {};
  int chatSeenAt = 0;
  StreamSubscription<Map<String, dynamic>>? chatSub;
  late final health = HealthConnectService(widget.api);
  void _watchChat() {
    unawaited(
      loadChatSeen().then((v) {
        if (mounted) setState(() => chatSeenAt = v);
      }),
    );
    try {
      chatSub = widget.api
          .watch('care/${widget.api.uid}/messages/items')
          .listen((v) {
            if (!mounted) return;
            setState(() => chat = v);
            if (selectedTab == 3) _markChatSeen();
          }, onError: (_) {});
    } catch (_) {}
  }

  void _markChatSeen() {
    final newest = newestMessageAt(chat);
    if (newest <= chatSeenAt) return;
    setState(() => chatSeenAt = newest);
    unawaited(saveChatSeen(newest));
  }

  void _selectTab(int index) {
    setState(() => selectedTab = index);
    if (index == 3) _markChatSeen();
  }

  @override
  void initState() {
    super.initState();
    status = widget.initialNotice ?? '';
    WidgetsBinding.instance.addObserver(this);
    _watchChat();
    try {
      if (AppConfig.databaseUrl.isNotEmpty) {
        unawaited(
          NativeBridge.careSaveConfig(
            AppConfig.databaseUrl,
            widget.api.uid,
          ).catchError((_) {}),
        );
      }
    } catch (_) {}
    _listenContacts();
    nativeSub = NativeBridge.events.stream.listen((event) {
      if (event == 'widget') consumeWidget();
      if (event == 'battery') refreshBattery();
    });
    familySub = widget.api
        .family(widget.api.uid)
        .listen(
          (family) {
            if (lastAlertId != null) {
              final last = asMap(asMap(family['alerts'])[lastAlertId]);
              if (asMap(last['receipts']).isNotEmpty && mounted) {
                setState(() => status = '家人已確認收到');
              }
            }
            final id = family['activeSessionId'] as String?;
            if (id == watchingId) return;
            watchingId = id;
            if (processingConsentId != id) processingConsentId = null;
            final previousAsk = askingId;
            if (previousAsk != null && previousAsk != id) {
              unawaited(cancelConsent(previousAsk));
            }
            sessionSub?.cancel();
            pendingTimer?.cancel();
            pendingId = null;
            pending = {};
            if (id == null) return;
            sessionSub = widget.api
                .session(id)
                .listen(
                  (session) {
                    if (watchingId != id) return;
                    if (session['status'] == 'pending') {
                      pendingId = id;
                      pending = session;
                      pendingTimer?.cancel();
                      final remaining =
                          (session['expiresAt'] as num? ?? 0).toInt() -
                          DateTime.now().millisecondsSinceEpoch;
                      if (remaining <= 0) {
                        pendingId = null;
                        pending = {};
                        if (askingId == id) unawaited(cancelConsent(id));
                        return;
                      }
                      pendingTimer = Timer(
                        Duration(milliseconds: remaining),
                        () {
                          if (pendingId != id) return;
                          pendingId = null;
                          pending = {};
                          if (askingId == id) unawaited(cancelConsent(id));
                        },
                      );
                      maybeAsk();
                    } else {
                      pendingTimer?.cancel();
                      pendingId = null;
                      pending = {};
                      if (processingConsentId == id) processingConsentId = null;
                      if (session['status'] != 'accepted' && askingId == id) {
                        unawaited(cancelConsent(id));
                      }
                    }
                  },
                  onError: (Object e) {
                    if (watchingId != id) return;
                    if (askingId == id) unawaited(cancelConsent(id));
                    if (mounted) setState(() => status = errorMessage(e));
                  },
                );
          },
          onError: (Object e) {
            if (mounted) setState(() => status = errorMessage(e));
          },
        );
    healthTimer = Timer.periodic(
      const Duration(minutes: 1),
      (_) => syncHealth(),
    );
    // This checks only the nonurgent rest reminder. Medication, call and SOS
    // never enter the market-hours deferral policy.
    restTimer = Timer.periodic(
      const Duration(minutes: 1),
      (_) => checkRestReminder(),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      consumeWidget();
      syncHealth();
      refreshBattery();
      checkRestReminder();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    foreground = state == AppLifecycleState.resumed;
    if (foreground) {
      maybeAsk();
      consumeWidget();
      syncHealth();
      refreshBattery(sample: true);
      checkRestReminder();
    }
    if (state == AppLifecycleState.detached) rtc?.close();
  }

  Future<void> syncHealth() async {
    if (!foreground || syncing || settingsOpen) return;
    syncing = true;
    try {
      await health.sync();
    } catch (_) {
      /* Settings offers explicit status/error. */
    } finally {
      syncing = false;
    }
  }

  Future<void> checkRestReminder() async {
    if (!mounted ||
        !foreground ||
        settingsOpen ||
        dialogOpen ||
        batteryDialogOpen ||
        restDialogOpen ||
        selectedTab == 2 ||
        (rtc != null && !rtc!.closed)) {
      return;
    }
    try {
      final duration = await NativeBridge.screenOnDuration();
      if (!mounted ||
          !foreground ||
          restDialogOpen ||
          (rtc != null && !rtc!.closed)) {
        return;
      }
      final now = DateTime.now();
      final decision = decideRestReminder(
        now: now,
        continuousScreenOn: duration,
        snoozedUntil: restSnoozedUntil,
        lastRemindedAt: lastRestRemindedAt,
      );
      if (decision.action != RestReminderAction.remindNow) return;
      restDialogOpen = true;
      lastRestRemindedAt = now;
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('眼睛休息一下', style: TextStyle(fontSize: 30)),
          content: const Text(
            '螢幕已亮一段時間，看看遠方、喝口水也很好。',
            style: TextStyle(fontSize: 24),
          ),
          actions: [
            TextButton(
              onPressed: () {
                restSnoozedUntil = DateTime.now().add(
                  const Duration(minutes: 15),
                );
                lastRestRemindedAt = null;
                Navigator.pop(dialogContext);
              },
              child: const Text('稍後提醒', style: TextStyle(fontSize: 22)),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('好，我休息', style: TextStyle(fontSize: 22)),
            ),
          ],
        ),
      );
      restDialogOpen = false;
    } catch (_) {
      // A missing platform bridge must never block the two help buttons.
      restDialogOpen = false;
    }
  }

  Future<void> refreshBattery({bool sample = false}) async {
    try {
      final latest = sample
          ? await NativeBridge.batterySampleNow()
          : await NativeBridge.batterySnapshot();
      if (!mounted) return;
      setState(() => battery = latest);
      final percent = latest['batteryPercent'];
      final episode = latest['episodeId'];
      if (foreground &&
          selectedTab == 0 &&
          !dialogOpen &&
          !batteryDialogOpen &&
          percent is num &&
          percent <= 30 &&
          latest['charging'] != true &&
          episode is String &&
          latest['acknowledgedEpisodeId'] != episode) {
        batteryDialogOpen = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) showLowBattery(episode, percent.toInt());
        });
      }
    } catch (_) {
      // Lack of a native bridge in a design preview must not hide SOS.
    }
  }

  Future<void> showLowBattery(String episode, int percent) async {
    if (!mounted || !foreground || selectedTab != 0) {
      batteryDialogOpen = false;
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('手機快沒電了', style: TextStyle(fontSize: 30)),
        content: Text(
          '目前電量 $percent%，請幫手機充電。',
          style: const TextStyle(fontSize: 24),
        ),
        actions: [
          FilledButton(
            onPressed: () async {
              try {
                await NativeBridge.batteryAcknowledgeLocal();
                if (dialogContext.mounted) Navigator.pop(dialogContext);
                if (mounted) {
                  setState(() => status = '知道了，記得充電喔');
                }
              } catch (e) {
                if (mounted) setState(() => status = errorMessage(e));
              }
            },
            child: const Text('知道了', style: TextStyle(fontSize: 24)),
          ),
        ],
      ),
    );
    batteryDialogOpen = false;
    if (mounted) refreshBattery();
  }

  Future<void> openBattery() async {
    settingsOpen = true;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => BatteryConsentPage(api: widget.api),
      ),
    );
    settingsOpen = false;
    refreshBattery();
    maybeAsk();
  }

  Future<void> consumeWidget() async {
    if (!foreground || !mounted) return;
    final action = await NativeBridge.widgetAction();
    if (action != null && mounted) await alert(action);
  }

  Future<void> cancelConsent(String id) async {
    try {
      await NativeBridge.cancelConsent(id);
    } catch (e) {
      if (mounted) setState(() => status = '無法關閉已失效的同意請求：${errorMessage(e)}');
    }
  }

  void releaseConsentPrompt(String id) {
    if (askingId != id) return;
    askingId = null;
    dialogOpen = false;
    if (pendingId != null && pendingId != id) unawaited(maybeAsk());
  }

  Future<void> maybeAsk() async {
    final id = pendingId;
    if (!mounted ||
        !foreground ||
        settingsOpen ||
        dialogOpen ||
        id == null ||
        processingConsentId == id ||
        (rtc != null && !rtc!.closed)) {
      return;
    }
    if ((pending['expiresAt'] as num? ?? 0) <=
        DateTime.now().millisecondsSinceEpoch) {
      return;
    }
    dialogOpen = true;
    askingId = id;
    try {
      final allowed = await NativeBridge.consent(
        id,
        pending['clientName'] as String? ?? '家人',
      );
      // A lifecycle resume can occur before acceptHelp returns. Do not reopen
      // the consent dialog for the same request while the answer is processing.
      processingConsentId = id;
      releaseConsentPrompt(id);
      if (!mounted ||
          watchingId != id ||
          pendingId != id ||
          (pending['expiresAt'] as num? ?? 0) <=
              DateTime.now().millisecondsSinceEpoch) {
        await NativeBridge.cancelConsent(id);
        return;
      }
      if (!allowed) {
        await widget.api.end(id, reject: true);
        return;
      }
      await widget.api.call('acceptHelp', {'sessionId': id});
      if (!mounted || watchingId != id) {
        await NativeBridge.cancelConsent(id);
        await widget.api.end(id);
        return;
      }
      final old = rtc;
      if (old != null) {
        old.removeListener(updateRtc);
        await old.releaseRenderers();
      }
      final next = RtcSession(api: widget.api, id: id, isHost: true);
      rtc = next;
      next.addListener(updateRtc);
      await next.initialize();
      if (mounted) setState(() {});
    } catch (e) {
      processingConsentId = id;
      await cancelConsent(id);
      if (watchingId == id) {
        await NativeBridge.stop();
        try {
          await widget.api.end(id);
        } catch (_) {}
        if (mounted) setState(() => status = errorMessage(e));
      }
    } finally {
      releaseConsentPrompt(id);
    }
  }

  void updateRtc() {
    if (mounted) setState(() {});
  }

  StreamSubscription<Map<String, dynamic>>? ringSub, contactsSub;

  /// idle · contacting · answered · noAnswer · notified · failed
  String help = 'idle';
  String? helpType, ringId, answeredBy;
  Map<String, dynamic> contacts = const {};
  Timer? ringTimeout;

  List<MapEntry<String, Map<String, dynamic>>> get confirmedContacts => [
    for (final e in contacts.entries)
      if (asMap(e.value)['confirmed'] == true &&
          asMap(e.value)['phone'] is String)
        MapEntry(e.key, asMap(e.value)),
  ];

  void _listenContacts() {
    try {
      contactsSub = widget.api
          .watch('care/${widget.api.uid}/contacts')
          .listen((v) => setState(() => contacts = v), onError: (_) {});
    } catch (_) {}
  }

  void say(String text) {
    unawaited(NativeBridge.speakText(text).catchError((_) {}));
  }

  Future<void> alert(String type) async {
    if (sending) return;
    final sos = type == 'sos';
    // Say only what is true now; the result is announced when it is known.
    say('正在聯絡家人。');
    setState(() {
      sending = true;
      help = 'contacting';
      helpType = type;
      ringId = null;
      answeredBy = null;
      status = '';
    });
    try {
      final value = await SosService(widget.api).send(type);
      if (!mounted) return;
      lastAlertId = value['alertId'] as String?;
      final accepted = value['accepted'] as int? ?? 0;
      final sessionId = value['sessionId'] as String?;
      if (sessionId != null) {
        setState(() => ringId = sessionId);
        waitForAnswer(sessionId, shareScreen: !sos);
      } else if (accepted > 0) {
        say('已通知家人，等家人回覆。');
        setState(() => help = 'notified');
      } else {
        say('沒有聯絡上家人，可以按打電話，或再試一次。');
        setState(() => help = 'failed');
      }
    } catch (e) {
      say('沒有送出，可以按打電話，或再試一次。');
      if (mounted) setState(() => help = 'failed');
    } finally {
      if (mounted) setState(() => sending = false);
    }
  }

  Future<void> cancelHelp() async {
    final id = ringId;
    ringSub?.cancel();
    ringSub = null;
    ringTimeout?.cancel();
    setState(() => help = 'idle');
    say('已取消這次呼叫。');
    if (id != null) {
      try {
        await widget.api.call('cancelHostCall', {'sessionId': id});
      } catch (_) {}
    }
  }

  void _noAnswer() {
    ringSub?.cancel();
    ringSub = null;
    ringTimeout?.cancel();
    say('家人現在沒有接，可以按打電話，或再試一次。');
    if (mounted) setState(() => help = 'noAnswer');
  }

  /// Grandma pressed the button herself, so a family answer starts the call
  /// without another in-app consent; Android still asks once to share screen.
  void waitForAnswer(String id, {required bool shareScreen}) {
    ringSub?.cancel();
    ringTimeout?.cancel();
    ringSub = widget.api.session(id).listen((session) async {
      final state = session['status'];
      if (state == 'accepted') {
        await ringSub?.cancel();
        ringSub = null;
        ringTimeout?.cancel();
        final name = session['clientName'] as String? ?? '家人';
        if (!await NativeBridge.hostCallConsent(id)) {
          if (mounted) setState(() => help = 'failed');
          return;
        }
        say(
          shareScreen
              ? '$name接起來了。請按「立即開始」，$name就能看到你的手機畫面。'
              : '$name接起來了，正在接通。',
        );
        if (mounted) {
          setState(() {
            help = 'answered';
            answeredBy = name;
          });
        }
        if (shareScreen) {
          var canTap = true;
          try {
            canTap = await NativeBridge.accessibilityEnabled();
          } catch (_) {}
          if (!canTap) {
            say('如果要讓家人幫你操作手機，之後請到家人設定，打開允許遠端點擊。');
          }
        }
        final old = rtc;
        if (old != null) {
          old.removeListener(updateRtc);
          await old.releaseRenderers();
        }
        final next = RtcSession(
          api: widget.api,
          id: id,
          isHost: true,
          shareScreen: shareScreen,
        );
        rtc = next;
        next.addListener(updateRtc);
        await next.initialize();
        if (mounted) setState(() => help = 'idle');
      } else if (['expired', 'ended', 'rejected'].contains(state) ||
          session.isEmpty) {
        if (help == 'contacting') _noAnswer();
      }
    });
    ringTimeout = Timer(const Duration(seconds: 95), () {
      if (ringSub != null && mounted && help == 'contacting') _noAnswer();
    });
  }

  Widget helpPanel() {
    final sos = helpType == 'sos';
    final big = const TextStyle(fontSize: 28, fontWeight: FontWeight.bold);
    final (String title, Color color) = switch (help) {
      'contacting' => ('正在聯絡家人…', FhColors.brand),
      'answered' => ('${answeredBy ?? '家人'}接起來了，正在接通', FhColors.brand),
      'notified' => ('已通知家人，等家人回覆', FhColors.brand),
      'noAnswer' => ('家人現在沒有接', FhColors.danger),
      _ => ('沒有送出', FhColors.danger),
    };
    final stuck = help == 'noAnswer' || help == 'failed' || help == 'notified';
    Widget action(
      String label,
      IconData icon,
      VoidCallback onTap, {
      Key? key,
    }) => Padding(
      padding: const EdgeInsets.only(top: 10),
      child: SizedBox(
        width: double.infinity,
        height: 72,
        child: FilledButton.icon(
          key: key,
          style: FilledButton.styleFrom(
            backgroundColor: Colors.white,
            foregroundColor: color,
          ),
          onPressed: onTap,
          icon: Icon(icon, size: 32),
          label: Text(label, style: const TextStyle(fontSize: 24)),
        ),
      ),
    );
    return Container(
      key: const Key('help-panel'),
      width: double.infinity,
      margin: const EdgeInsets.only(top: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        children: [
          Semantics(
            liveRegion: true,
            child: Text(
              title,
              textAlign: TextAlign.center,
              style: big.copyWith(color: Colors.white),
            ),
          ),
          if (help == 'contacting')
            action(
              '取消這次呼叫',
              Icons.close,
              cancelHelp,
              key: const Key('help-cancel'),
            ),
          if (stuck) ...[
            for (final c in confirmedContacts)
              action(
                '打電話給${c.value['name'] ?? '家人'}',
                Icons.phone,
                () => NativeBridge.dialNumber(c.value['phone'] as String),
                key: Key('help-dial-${c.key}'),
              ),
            if (help != 'notified')
              action(
                '再試一次',
                Icons.refresh,
                () => alert(sos ? 'sos' : 'call'),
                key: const Key('help-retry'),
              ),
            TextButton(
              onPressed: () => setState(() => help = 'idle'),
              child: const Text(
                '關閉',
                style: TextStyle(color: Colors.white, fontSize: 22),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> settings() async {
    settingsOpen = true;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => PairingPage(api: widget.api)),
    );
    settingsOpen = false;
    maybeAsk();
    syncHealth();
  }

  @override
  void dispose() {
    final activeAsk = askingId;
    if (activeAsk != null) unawaited(cancelConsent(activeAsk));
    WidgetsBinding.instance.removeObserver(this);
    familySub?.cancel();
    ringSub?.cancel();
    contactsSub?.cancel();
    ringTimeout?.cancel();
    sessionSub?.cancel();
    nativeSub?.cancel();
    chatSub?.cancel();
    healthTimer?.cancel();
    restTimer?.cancel();
    pendingTimer?.cancel();
    rtc?.removeListener(updateRtc);
    rtc?.releaseRenderers();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final call = rtc;
    final active = call != null && !call.closed;
    return Scaffold(
      backgroundColor: FhColors.background,
      appBar: AppBar(
        title: Text(
          selectedTab == 0 || active
              ? '需要幫忙嗎？'
              : selectedTab == 1
              ? '今天'
              : selectedTab == 3
              ? '家人'
              : '照片',
          style: const TextStyle(fontSize: 24),
        ),
        actions: [
          if (!active &&
              battery['batteryPercent'] is num &&
              (battery['batteryPercent'] as num) <= 30 &&
              battery['charging'] != true)
            TextButton(
              key: const Key('host-low-battery'),
              onPressed: openBattery,
              child: Text(
                '${(battery['batteryPercent'] as num).toInt()}% 電量低',
                style: const TextStyle(color: FhColors.danger, fontSize: 16),
              ),
            ),
          IconButton(
            tooltip: '家人設定',
            onPressed: active ? null : settings,
            icon: const Icon(Icons.settings),
          ),
        ],
      ),
      bottomNavigationBar: active
          ? HostEndAssistanceBar(onEnd: () async => call.close())
          : HostTabBar(
              selected: selectedTab,
              chatUnread: unreadCount(chat, widget.api.uid, chatSeenAt),
              onSelect: _selectTab,
            ),
      body: !active && selectedTab == 2
          ? HostPhotoPage(api: widget.api, cameraPort: widget.photoCameraPort)
          : !active && selectedTab == 3
          ? HostFamilyPage(api: widget.api)
          : !active && selectedTab == 1
          ? HostTodayPage(
              hostUid: widget.api.uid,
              api: widget.api,
              showWeatherAndQuote: false,
            )
          : SafeArea(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final landscape =
                      constraints.maxWidth > constraints.maxHeight;
                  final largeText =
                      MediaQuery.textScalerOf(context).scale(1) >= 1.7;
                  final gap = largeText ? 12.0 : 24.0;
                  final fillHome =
                      !active &&
                      status.isEmpty &&
                      help == 'idle' &&
                      call?.error == null;
                  final buttonHeight = landscape
                      ? (constraints.maxHeight - 40).clamp(
                          120.0,
                          double.infinity,
                        )
                      : ((constraints.maxHeight - 40 - gap) / 2).clamp(
                          120.0,
                          double.infinity,
                        );
                  Widget callButton() => huge(
                    '呼叫家人',
                    FhColors.brand,
                    sending ? null : () => alert('call'),
                    Icons.video_call,
                    height: fillHome ? buttonHeight : null,
                    compact: landscape,
                  );
                  Widget sosButton() => huge(
                    'SOS\n緊急求助',
                    FhColors.danger,
                    sending ? null : () => alert('sos'),
                    Icons.emergency_outlined,
                    height: fillHome ? buttonHeight : null,
                    compact: landscape,
                  );
                  return SingleChildScrollView(
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        minHeight: constraints.maxHeight,
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(20),
                        child: Column(
                          children: [
                            if (active) ...[
                              Text(
                                call.status,
                                style: const TextStyle(
                                  fontSize: 28,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              CallControls(session: call, large: true),
                              if (call.renderersReady)
                                SizedBox(
                                  height: call.shareScreen ? 220 : 360,
                                  child: RTCVideoView(
                                    call.remoteCamera,
                                    objectFit: RTCVideoViewObjectFit
                                        .RTCVideoViewObjectFitContain,
                                  ),
                                ),
                              const Text(
                                '需要操作其他 App 時，請按手機首頁鍵。',
                                style: TextStyle(fontSize: 24),
                              ),
                            ] else ...[
                              if (landscape)
                                Row(
                                  children: [
                                    Expanded(child: callButton()),
                                    const SizedBox(width: 12),
                                    Expanded(child: sosButton()),
                                  ],
                                )
                              else ...[
                                callButton(),
                                SizedBox(height: gap),
                                sosButton(),
                              ],
                            ],
                            if (!active && help != 'idle') helpPanel(),
                            if (status.isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(top: FhSpace.xl),
                                child: FhStatusBanner(
                                  key: const Key('host-status'),
                                  message: status,
                                ),
                              ),
                            if (call?.closed == true && call?.error != null)
                              Padding(
                                padding: const EdgeInsets.only(top: FhSpace.md),
                                child: FhStatusBanner(
                                  tone: FhTone.danger,
                                  message: call!.error!,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
    );
  }

  Widget huge(
    String label,
    Color color,
    VoidCallback? action,
    IconData icon, {
    double? height,
    bool compact = false,
  }) {
    final largeText =
        compact || MediaQuery.textScalerOf(context).scale(1) >= 1.7;
    return SizedBox(
      width: double.infinity,
      height: height,
      child: FilledButton(
        onPressed: action,
        style: FilledButton.styleFrom(
          backgroundColor: color,
          foregroundColor: Colors.white,
          minimumSize: Size(120, height ?? (largeText ? 176 : 180)),
          padding: EdgeInsets.all(largeText ? 12 : 20),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!largeText) ...[
              Icon(icon, size: 48),
              const SizedBox(height: 8),
            ],
            Text(
              label,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: largeText ? 24 : 36,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
