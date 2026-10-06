// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
import 'package:flutter/material.dart';
import '../common/firebase_service.dart';
import '../common/native_bridge.dart';
import 'client_photo_page.dart';
import 'pairing_client_page.dart';
import 'remote_view_page.dart';
import 'client_companion_page.dart';
import 'client_settings_page.dart';
import 'incoming_alert_page.dart';
import 'client_status_view.dart';
import 'client_location_page.dart';
import 'handling_bar.dart';
import '../common/family_messages_panel.dart';
import '../common/unread.dart';
import 'dart:async';
import '../common/ui/fh_tokens.dart';
import '../common/ui/fh_format.dart';
import '../common/ui/fh_widgets.dart';

class ClientHomePage extends StatefulWidget {
  final FirebaseService api;
  const ClientHomePage({super.key, required this.api});
  @override
  State<ClientHomePage> createState() => _ClientHomePageState();
}

class _ClientHomePageState extends State<ClientHomePage> {
  late Stream<Map<String, dynamic>> _linkStream;
  final _familyStreams = <String, Stream<Map<String, dynamic>>>{};

  /// Internal tab ids: 0 status, 1 chat, 2 photos, 3 settings, 4 location.
  /// [_navOrder] is the order shown in the bottom bar.
  int _tab = 0;
  static const _navOrder = [0, 4, 1, 2, 3];
  bool busy = false;
  final _shownAlerts = <String>{};
  final DateTime _openedAt = DateTime.now();
  Map<String, dynamic> _chat = const {};
  int _chatSeenAt = 0;
  String? _chatHost;
  StreamSubscription<Map<String, dynamic>>? _chatSub;

  void _ensureChat(String host) {
    if (_chatHost == host) return;
    _chatHost = host;
    _chatSub?.cancel();
    unawaited(
      loadChatSeen().then((v) {
        if (mounted) setState(() => _chatSeenAt = v);
      }),
    );
    try {
      _chatSub = widget.api.watch('care/$host/messages/items').listen((v) {
        if (!mounted) return;
        setState(() => _chat = v);
        if (_tab == 1) _markChatSeen();
      }, onError: (_) {});
    } catch (_) {}
  }

  void _markChatSeen() {
    final newest = newestMessageAt(_chat);
    if (newest <= _chatSeenAt) return;
    setState(() => _chatSeenAt = newest);
    unawaited(saveChatSeen(newest));
  }

  @override
  void dispose() {
    _chatSub?.cancel();
    super.dispose();
  }

  /// Grandma's SOS / 呼叫 pops a full-screen page once per alert, if it is
  /// recent and this phone has not acknowledged it yet.
  void _maybeShowIncoming(String host, Map<String, dynamic> family) {
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final entry in asMap(family['alerts']).entries) {
      final alert = asMap(entry.value);
      final created = (alert['createdAt'] as num?)?.toInt() ?? 0;
      if (!const {'sos', 'call'}.contains(alert['type']) ||
          now - created > 3 * 60_000 ||
          asMap(alert['receipts']).containsKey(widget.api.uid) ||
          asMap(alert['answeredBy']).isNotEmpty ||
          alert['cancelledAt'] is num ||
          !_shownAlerts.add(entry.key)) {
        continue;
      }
      // Older alerts already pending at app start still show (within 3 min).
      if (created < _openedAt.millisecondsSinceEpoch - 3 * 60_000) continue;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            fullscreenDialog: true,
            builder: (_) => IncomingAlertPage(
              api: widget.api,
              hostId: host,
              alertId: entry.key,
              alert: alert,
            ),
          ),
        );
      });
      break;
    }
  }

  String? error;

  @override
  void initState() {
    super.initState();
    _linkStream = widget.api.watch('core/links/${widget.api.uid}');
  }

  @override
  void didUpdateWidget(covariant ClientHomePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.api != widget.api) {
      _linkStream = widget.api.watch('core/links/${widget.api.uid}');
      _familyStreams.clear();
    }
  }

  Future<void> request(String host) async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final response = await widget.api.call('requestHelp', {'hostId': host});
      if (!mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (_) => RemoteViewPage(
            api: widget.api,
            id: response['sessionId'] as String,
          ),
        ),
      );
    } catch (e) {
      if (mounted) setState(() => error = errorMessage(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> unlink(String host) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('解除與長輩的配對？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('解除'),
          ),
        ],
      ),
    );
    if (yes != true) return;
    try {
      await widget.api.call('unpairDevice', {
        'hostId': host,
        'clientId': widget.api.uid,
      });
    } catch (e) {
      if (mounted) setState(() => error = errorMessage(e));
    }
  }

  @override
  Widget build(BuildContext context) => StreamBuilder<Map<String, dynamic>>(
    stream: _linkStream,
    builder: (context, link) {
      if (link.hasError) {
        return Scaffold(body: Center(child: Text(errorMessage(link.error!))));
      }
      if (!link.hasData) {
        return const Scaffold(body: Center(child: CircularProgressIndicator()));
      }
      final host = link.data!['hostId'] as String?;
      if (host == null) return PairingClientPage(api: widget.api);
      _ensureChat(host);
      final unread = unreadCount(_chat, widget.api.uid, _chatSeenAt);
      return Scaffold(
        appBar: AppBar(
          title: Text(switch (_tab) {
            1 => '聊天',
            2 => '照片',
            3 => '設定',
            4 => '定位',
            _ => '長輩狀態',
          }),
        ),
        body: StreamBuilder<Map<String, dynamic>>(
          stream: _familyStreams.putIfAbsent(
            host,
            () => widget.api.family(host),
          ),
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return Center(child: Text(errorMessage(snapshot.error!)));
            }
            if (!snapshot.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            final family = snapshot.data ?? {};
            _maybeShowIncoming(host, family);
            final names = {
              for (final e in asMap(family['members']).entries)
                e.key: (asMap(e.value)['name'] as String?) ?? '家人',
            };
            final hostName = family['name'] as String? ?? '長輩';
            if (_tab == 4) {
              return ClientLocationPage(
                api: widget.api,
                hostId: host,
                hostName: hostName,
              );
            }
            if (_tab == 1) {
              return Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 0),
                child: FamilyMessagesPanel(
                  api: widget.api,
                  hostId: host,
                  selfUid: widget.api.uid,
                  isHost: false,
                  names: names,
                  hostName: hostName,
                  fillHeight: true,
                ),
              );
            }
            if (_tab == 3) {
              return ClientSettingsPage(
                api: widget.api,
                hostId: host,
                onUnlink: () => unlink(host),
              );
            }
            if (_tab == 2) {
              return ClientPhotoPage(
                api: widget.api,
                hostId: host,
                sharingEnabled:
                    asMap(family['photoConsent'])['enabled'] == true,
                consent: asMap(family['photoConsent']),
                names: names,
              );
            }
            final alerts = asMap(family['alerts']).entries.toList()
              ..sort(
                (a, b) => ((asMap(b.value)['createdAt'] as num?) ?? 0)
                    .compareTo((asMap(a.value)['createdAt'] as num?) ?? 0),
              );
            return ListView(
              padding: const EdgeInsets.all(20),
              children: [
                if (error != null) ...[
                  FhStatusBanner(tone: FhTone.danger, message: error!),
                  const SizedBox(height: FhSpace.md),
                ],
                for (final entry in alerts.take(3))
                  if (const {
                        'sos',
                        'call',
                      }.contains(asMap(entry.value)['type']) &&
                      !asMap(
                        asMap(entry.value)['receipts'],
                      ).containsKey(widget.api.uid))
                    Card(
                      color: asMap(entry.value)['type'] == 'sos'
                          ? FhColors.danger
                          : FhColors.brand,
                      child: ListTile(
                        minVerticalPadding: 18,
                        leading: Icon(
                          asMap(entry.value)['type'] == 'sos'
                              ? Icons.emergency
                              : Icons.video_call,
                          color: Colors.white,
                          size: 40,
                        ),
                        title: Text(
                          asMap(entry.value)['type'] == 'sos'
                              ? '長輩按了緊急求助'
                              : '長輩找你',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 24,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        subtitle: Text(
                          asMap(asMap(entry.value)['answeredBy']).isNotEmpty
                              ? '${time(asMap(entry.value)['createdAt'])}・${asMap(asMap(entry.value)['answeredBy'])['name'] ?? '家人'} 已接聽'
                              : '${time(asMap(entry.value)['createdAt'])}・點這裡查看',
                          style: const TextStyle(color: Colors.white),
                        ),
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            fullscreenDialog: true,
                            builder: (_) => IncomingAlertPage(
                              api: widget.api,
                              hostId: host,
                              alertId: entry.key,
                              alert: asMap(entry.value),
                            ),
                          ),
                        ),
                      ),
                    ),
                FilledButton.icon(
                  key: const Key('assist-phone'),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(56),
                  ),
                  onPressed: busy ? null : () => request(host),
                  icon: const Icon(Icons.touch_app),
                  label: Text(busy ? '連線處理中…' : '協助操作長輩的手機（需長輩同意）'),
                ),
                const SizedBox(height: 16),
                ClientStatusSummary(
                  api: widget.api,
                  hostId: host,
                  family: family,
                ),
                const FhSectionHeader(title: '更多'),
                Card(
                  margin: EdgeInsets.zero,
                  clipBehavior: Clip.antiAlias,
                  child: Column(
                    children: [
                      for (final (key, icon, label, page) in [
                        (
                          'week',
                          Icons.calendar_view_week,
                          '本週摘要',
                          () => ListView(
                            padding: const EdgeInsets.all(20),
                            children: [
                              ClientCompanionPage(
                                api: widget.api,
                                hostId: host,
                                family: family,
                                embedded: true,
                              ),
                            ],
                          ),
                        ),
                        (
                          'health',
                          Icons.favorite_outline,
                          '健康資料',
                          () => ListView(
                            padding: const EdgeInsets.all(20),
                            children: [healthPanel(asMap(family['health']))],
                          ),
                        ),
                        (
                          'history',
                          Icons.notifications_none,
                          '通知紀錄',
                          () => StreamBuilder<Map<String, dynamic>>(
                            stream: widget.api.family(host),
                            initialData: family,
                            builder: (context, snap) => ListView(
                              padding: const EdgeInsets.all(20),
                              children: alertHistory(
                                context,
                                host,
                                snap.data ?? family,
                              ),
                            ),
                          ),
                        ),
                      ])
                        ListTile(
                          key: Key('entry-$key'),
                          leading: Icon(icon),
                          title: Text(label),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => Scaffold(
                                appBar: AppBar(title: Text(label)),
                                body: page(),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _navOrder.indexOf(_tab),
          onDestinationSelected: (index) {
            setState(() => _tab = _navOrder[index]);
            if (_tab == 1) _markChatSeen();
          },
          destinations: [
            NavigationDestination(
              key: Key('client-tab-守護'),
              icon: Icon(Icons.shield_outlined),
              selectedIcon: Icon(Icons.shield),
              label: MediaQuery.textScalerOf(context).scale(1) > 1.5
                  ? '狀態'
                  : '長輩狀態',
              tooltip: '長輩狀態',
            ),
            const NavigationDestination(
              key: Key('client-tab-定位'),
              icon: Icon(Icons.location_on_outlined),
              selectedIcon: Icon(Icons.location_on),
              label: '定位',
            ),
            NavigationDestination(
              key: const Key('client-tab-陪伴'),
              icon: Badge(
                key: const Key('client-chat-badge'),
                isLabelVisible: unread > 0,
                label: Text(unread > 9 ? '9+' : '$unread'),
                child: const Icon(Icons.forum_outlined),
              ),
              selectedIcon: const Icon(Icons.forum),
              label: '聊天',
              tooltip: unread > 0 ? '聊天，$unread 則新留言' : '聊天',
            ),
            NavigationDestination(
              key: Key('client-tab-照片'),
              icon: Icon(Icons.photo_outlined),
              selectedIcon: Icon(Icons.photo),
              label: '照片',
            ),
            NavigationDestination(
              key: Key('client-tab-協助'),
              icon: Icon(Icons.settings_outlined),
              selectedIcon: Icon(Icons.settings),
              label: '設定',
            ),
          ],
        ),
      );
    },
  );

  List<Widget> alertHistory(
    BuildContext context,
    String host,
    Map<String, dynamic> family,
  ) {
    final alerts = asMap(family['alerts']).entries.toList()
      ..sort(
        (a, b) => ((asMap(b.value)['createdAt'] as num?) ?? 0).compareTo(
          (asMap(a.value)['createdAt'] as num?) ?? 0,
        ),
      );
    return [
      if (error != null) FhStatusBanner(tone: FhTone.danger, message: error!),
      if (alerts.isEmpty)
        const FhEmptyState(
          icon: Icons.notifications_none,
          title: '目前沒有通知',
          message: '長輩按「呼叫家人」或 SOS 時，會出現在這裡。',
        ),
      ...alerts.take(20).map((entry) {
        final value = asMap(entry.value),
            loc = asMap(asMap(entry.value)['location']);
        final seen = asMap(value['receipts']).containsKey(widget.api.uid);
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  value['type'] == 'sos'
                      ? 'SOS 緊急求助'
                      : value['type'] == 'health'
                      ? '健康數值提醒'
                      : '長輩呼叫你',
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 24,
                  ),
                ),
                Text(time(value['createdAt'])),
                if (value['type'] == 'sos' &&
                    loc['lat'] is num &&
                    loc['lng'] is num) ...[
                  Text(
                    '位置取得時間 ${time(loc['time'])}・誤差約 ${(loc['accuracy'] as num?)?.round() ?? '?'} 公尺',
                  ),
                  OutlinedButton.icon(
                    onPressed: () => NativeBridge.openMap(
                      (loc['lat'] as num).toDouble(),
                      (loc['lng'] as num).toDouble(),
                    ),
                    icon: const Icon(Icons.map),
                    label: const Text('開啟地圖'),
                  ),
                ] else if (value['type'] == 'sos')
                  const Text('這次沒有取得位置'),
                if (value['type'] == 'sos' || value['type'] == 'call')
                  HandlingBar(
                    api: widget.api,
                    hostId: host,
                    eventKey: 'alert-${entry.key}',
                  ),
                TextButton(
                  onPressed: seen
                      ? null
                      : () async {
                          try {
                            await widget.api.call('acknowledgeAlert', {
                              'hostId': host,
                              'alertId': entry.key,
                            });
                          } catch (e) {
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    '沒有送出，請再按一次：${errorMessage(e)}',
                                  ),
                                ),
                              );
                            }
                          }
                        },
                  child: Text(seen ? '你已確認收到' : '確認收到'),
                ),
              ],
            ),
          ),
        );
      }),
    ];
  }

  Widget healthPanel(Map<String, dynamic> data) {
    if (data.isEmpty) {
      return const FhEmptyState(
        icon: Icons.favorite_outline,
        title: '尚未啟用或尚未同步。',
        message: '健康資料是選用功能，要由長輩在自己的手機「家人設定」中開啟。',
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final (key, name, unit) in [
          ('heart', '心率', '次／分'),
          ('oxygen', '血氧', '%'),
          ('sleep', '最近睡眠區間', '小時'),
        ])
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Builder(
              builder: (_) {
                final item = asMap(data[key]);
                return Text(
                  item.isEmpty
                      ? '$name：沒有資料'
                      : '$name：${item['value']} $unit\n記錄於 ${time(item['time'])}',
                );
              },
            ),
          ),
        const Text(
          '這是同步記錄，不是即時監測；睡眠區間含區間內可能清醒的時間。',
          style: TextStyle(fontSize: 16),
        ),
      ],
    );
  }

  String time(dynamic value) => friendlyTime(value);
}
