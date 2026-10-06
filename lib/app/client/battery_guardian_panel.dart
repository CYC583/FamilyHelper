// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import '../common/firebase_service.dart';
import 'handling_bar.dart';
import '../common/host_liveness.dart';
import '../common/ui/fh_tokens.dart';
import '../common/ui/fh_format.dart';
import '../common/ui/fh_widgets.dart';

class BatteryGuardianPanel extends StatefulWidget {
  final FirebaseService api;
  final String hostId;
  final Future<bool> Function()? notificationStatus;
  final Future<bool> Function()? requestNotification;
  final DateTime Function()? clock;
  const BatteryGuardianPanel({
    super.key,
    required this.api,
    required this.hostId,
    this.notificationStatus,
    this.requestNotification,
    this.clock,
  });

  @override
  State<BatteryGuardianPanel> createState() => _BatteryGuardianPanelState();
}

class _BatteryGuardianPanelState extends State<BatteryGuardianPanel>
    with WidgetsBindingObserver {
  late Stream<Map<String, dynamic>> consentStream;
  Stream<Map<String, dynamic>>? latestStream, eventStream, preferenceStream;
  String? error;
  bool busy = false;
  bool? osNotificationsAllowed;
  Timer? livenessTimer;

  DateTime get now => widget.clock?.call() ?? DateTime.now();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    bind();
    refreshNotificationStatus();
    livenessTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    livenessTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) setState(() {});
  }

  DateTime? serverTime(Object? millis) => millis is num
      ? DateTime.fromMillisecondsSinceEpoch(millis.toInt(), isUtc: true)
      : null;

  Future<void> refreshNotificationStatus() async {
    try {
      final allowed =
          await (widget.notificationStatus?.call() ??
              Permission.notification.status.then(
                (status) => status.isGranted,
              ));
      if (mounted) setState(() => osNotificationsAllowed = allowed);
    } catch (_) {
      // Unknown is not the same as granted; the server preference still loads.
      if (mounted) setState(() => osNotificationsAllowed = null);
    }
  }

  Future<void> askForNotifications() => act(() async {
    bool allowed;
    if (widget.requestNotification != null) {
      allowed = await widget.requestNotification!();
    } else {
      final status = await Permission.notification.request();
      if (status.isPermanentlyDenied) await openAppSettings();
      allowed = status.isGranted;
    }
    if (mounted) {
      setState(() {
        osNotificationsAllowed = allowed;
        if (!allowed) error = 'Android 通知仍未開啟；請在手機設定允許後重開 App。';
      });
    }
  });

  @override
  void didUpdateWidget(covariant BatteryGuardianPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.api != widget.api || oldWidget.hostId != widget.hostId) {
      bind();
    }
  }

  void bind() {
    final path = 'care/${widget.hostId}/battery';
    consentStream = widget.api.watch('$path/consent');
    latestStream = null;
    eventStream = null;
    preferenceStream = null;
  }

  Future<void> act(Future<void> Function() action) async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await action();
    } catch (e) {
      if (mounted) setState(() => error = errorMessage(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  String time(Object? millis) {
    return friendlyTime(millis, now: now);
  }

  @override
  Widget build(BuildContext context) => StreamBuilder<Map<String, dynamic>>(
    stream: consentStream,
    builder: (context, consent) {
      if (consent.hasError) {
        return FhStatusBanner(
          tone: FhTone.danger,
          message: '電量守護無法讀取：${errorMessage(consent.error!)}',
        );
      }
      if (!consent.hasData) return const FhStatusBanner(message: '正在確認電量分享狀態…');
      final allowed =
          consent.data?['enabled'] == true &&
          consent.data?['status'] == 'enabled' &&
          consent.data?['disclosureVersion'] == 2;
      if (!allowed) {
        latestStream = null;
        eventStream = null;
        preferenceStream = null;
        if (consent.data?['enabled'] == true) {
          return const FhStatusBanner(
            tone: FhTone.warning,
            message: '需要長輩在本機重新確認新版電量分享說明。',
          );
        }
        return const FhEmptyState(
          icon: Icons.battery_unknown,
          title: '尚無電量資料',
          message: '長輩尚未同意分享電量，或目前已暫停。',
        );
      }
      final path = 'care/${widget.hostId}/battery';
      latestStream ??= widget.api.watch('$path/latest');
      eventStream ??= widget.api.batteryEvents(widget.hostId);
      preferenceStream ??= widget.api.watch(
        '$path/preferences/${widget.api.uid}',
      );
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          StreamBuilder<Map<String, dynamic>>(
            stream: latestStream,
            builder: (context, latest) {
              if (latest.hasError) {
                return FhStatusBanner(
                  tone: FhTone.danger,
                  message: '電量資料讀取失敗：${errorMessage(latest.error!)}',
                );
              }
              if (!latest.hasData) {
                return const FhStatusBanner(message: '正在讀取長輩手機最近回報…');
              }
              final data = latest.data!;
              final receivedAt = data['receivedAt'];
              final consentAt = serverTime(consent.data?['updatedAt']);
              final reportAt = serverTime(receivedAt);
              final liveness = assessHostLiveness(
                now: now,
                consentStatus: consent.data?['status'] as String?,
                consentUpdatedAt: consentAt,
                lastReportAt: reportAt,
              );
              if (reportAt != null &&
                  consentAt != null &&
                  reportAt.isBefore(consentAt)) {
                return FhEmptyState(
                  icon: Icons.battery_unknown,
                  title: '尚無本次分享的電量',
                  message: liveness.state == HostLiveness.suspectedOffline
                      ? '疑似離線：重新同意後超過三小時仍未收到新回報；之前分享的電量不再顯示。'
                      : '尚無本次分享的回報；之前分享的電量不再顯示。',
                );
              }
              if (data.isEmpty) {
                return FhEmptyState(
                  icon: Icons.battery_unknown,
                  title: '尚無同步資料',
                  message: liveness.state == HostLiveness.suspectedOffline
                      ? '疑似離線：長輩重新同意後超過三小時，仍沒有收到第一筆資料。可能是沒網路、省電或 App 未執行。'
                      : '已同意分享，尚無同步資料。',
                );
              }
              final percent = data['batteryPercent'];
              final stale =
                  receivedAt is! num ||
                  now.millisecondsSinceEpoch - receivedAt.toInt() >
                      60 * 60 * 1000;
              return Semantics(
                label: stale ? '長輩手機電量資料過期' : '長輩手機電量',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (liveness.state == HostLiveness.suspectedOffline) ...[
                      Text(
                        '疑似離線，尚未收到長輩手機的新資料',
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(color: FhColors.warning),
                      ),
                      Text(
                        '最後回報：${time(receivedAt)}。可能是沒網路、省電或 App 未執行，不能據此判定手機已關機。',
                      ),
                    ],
                    Text(
                      stale
                          ? '資料已超過一小時'
                          : data['charging'] == true
                          ? '正在充電'
                          : '長輩手機電量',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    Text(
                      percent is num ? '${percent.toInt()}%' : '百分比未知',
                      style: Theme.of(context).textTheme.headlineMedium,
                    ),
                    Text(
                      '手機取樣：${time(data['observedAt'])}；伺服器收到：${time(receivedAt)}',
                    ),
                    const Text('這是最近一次同步，不是即時監測；推播服務接受不代表裝置已收到。'),
                  ],
                ),
              );
            },
          ),
          const SizedBox(height: 12),
          if (osNotificationsAllowed == false) ...[
            const Text(
              'Android 通知尚未開啟；即使下方偏好已開，也不會收到手機提醒。',
              style: TextStyle(color: FhColors.warning),
            ),
            OutlinedButton(
              onPressed: busy ? null : askForNotifications,
              child: const Text('開啟 Android 通知'),
            ),
          ],
          StreamBuilder<Map<String, dynamic>>(
            stream: eventStream,
            builder: (context, events) {
              if (events.hasError) {
                return FhStatusBanner(
                  tone: FhTone.danger,
                  message: '提醒紀錄無法讀取：${errorMessage(events.error!)}',
                );
              }
              if (!events.hasData) {
                return const FhStatusBanner(message: '正在讀取提醒紀錄…');
              }
              final entries = events.data!.entries.toList()
                ..sort(
                  (a, b) => ((asMap(b.value)['createdAt'] as num?) ?? 0)
                      .compareTo((asMap(a.value)['createdAt'] as num?) ?? 0),
                );
              if (entries.isEmpty) {
                return const FhEmptyState(
                  icon: Icons.notifications_none,
                  title: '目前沒有持續低電量提醒。',
                );
              }
              return Column(
                children: [
                  for (final entry in entries.take(3))
                    Builder(
                      builder: (_) {
                        final item = asMap(entry.value);
                        final acknowledged = asMap(
                          item['acknowledgedAt'],
                        ).containsKey(widget.api.uid);
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            ListTile(
                              contentPadding: EdgeInsets.zero,
                              leading: const Icon(
                                Icons.battery_alert,
                                color: FhColors.warning,
                              ),
                              title: Text(
                                item['resolvedAt'] is num
                                    ? '系統偵測：電量已恢復'
                                    : item['severity'] == 'critical'
                                    ? '長輩手機電量非常低'
                                    : '長輩手機持續低電量',
                              ),
                              subtitle: Text(
                                '建立於 ${time(item['createdAt'])}；${acknowledged ? '你已確認' : '尚未確認'}',
                              ),
                              trailing: TextButton(
                                onPressed: busy || acknowledged
                                    ? null
                                    : () => act(() async {
                                        await widget.api
                                            .call('ackBatteryEvent', {
                                              'hostId': widget.hostId,
                                              'eventId': entry.key,
                                            });
                                      }),
                                child: Text(acknowledged ? '已知道' : '我知道了'),
                              ),
                            ),
                            // People's handling is separate from the system fact
                            // "電量已恢復" shown in the title above.
                            HandlingBar(
                              api: widget.api,
                              hostId: widget.hostId,
                              eventKey: 'battery-${entry.key}',
                            ),
                          ],
                        );
                      },
                    ),
                ],
              );
            },
          ),
          const Divider(height: 20),
          StreamBuilder<Map<String, dynamic>>(
            stream: preferenceStream,
            builder: (context, prefs) {
              if (prefs.hasError) {
                return FhStatusBanner(
                  tone: FhTone.danger,
                  message: '通知設定無法讀取：${errorMessage(prefs.error!)}',
                );
              }
              if (!prefs.hasData) {
                return const FhStatusBanner(message: '正在讀取我的通知設定…');
              }
              final current = prefs.data!;
              final enabled = current['enabled'] != false;
              final sound = current['soundEnabled'] == true;
              Future<void> save({
                required bool notify,
                required bool alertSound,
              }) => act(() async {
                await widget.api.call('setBatteryNotificationPreference', {
                  'hostId': widget.hostId,
                  'enabled': notify,
                  'soundEnabled': alertSound,
                });
              });
              return Column(
                children: [
                  SwitchListTile(
                    title: const Text('通知我長輩手機低電量'),
                    subtitle: const Text('只影響我的手機；不改長輩的設定'),
                    value: enabled,
                    onChanged: busy
                        ? null
                        : (value) => save(notify: value, alertSound: sound),
                  ),
                  SwitchListTile(
                    title: const Text('我的手機播放警報聲'),
                    subtitle: const Text('預設關閉；仍受手機通知權限與勿擾限制'),
                    value: sound,
                    onChanged: busy || !enabled
                        ? null
                        : (value) => save(notify: enabled, alertSound: value),
                  ),
                ],
              );
            },
          ),
          if (error != null)
            FhStatusBanner(tone: FhTone.danger, message: error!),
        ],
      );
    },
  );
}
