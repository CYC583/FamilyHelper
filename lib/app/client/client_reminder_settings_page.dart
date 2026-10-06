// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
import 'dart:async';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';

import '../common/care_companion.dart';
import '../common/family_messages_panel.dart';
import '../common/firebase_service.dart';
import '../common/ui/fh_tokens.dart';
import '../common/ui/fh_widgets.dart';

const reminderLabels = <String, String>{
  'medicine': '吃藥',
  'water': '喝水',
  'rest': '休息',
  'photo': '拍照',
  'custom': '自訂',
};

String _two(int v) => v.toString().padLeft(2, '0');
const _weekdays = ['一', '二', '三', '四', '五', '六', '日'];
String _dateKey(DateTime d) => '${d.year}-${_two(d.month)}-${_two(d.day)}';

/// "每天" / "每週一、三" / "10月5日".
String repeatLabel(Map<String, dynamic> item) {
  if (item['repeat'] == 'once') return _dateLabel('${item['date']}');
  if (item['repeat'] == 'weekly' && item['days'] is List) {
    final days = [
      for (final d in item['days'] as List)
        if (d is num && d >= 1 && d <= 7) _weekdays[d.toInt() - 1],
    ];
    return '每週${days.join('、')}';
  }
  return '每天';
}

String _dateLabel(String date) {
  final p = date.split('-');
  return p.length == 3 ? '${int.parse(p[1])}月${int.parse(p[2])}日' : date;
}

/// Family-managed reminders read aloud on grandma's phone. Each one is daily
/// or one-off, with text and/or a family voice recording. Every change is
/// saved immediately; the server keeps another member's edit from being lost.
class ClientReminderSettingsPage extends StatefulWidget {
  final FirebaseService api;
  final String hostId;
  final VoicePort voice;
  final DateTime Function() clock;
  const ClientReminderSettingsPage({
    super.key,
    required this.api,
    required this.hostId,
    this.voice = const NativeVoicePort(),
    this.clock = DateTime.now,
  });

  @override
  State<ClientReminderSettingsPage> createState() =>
      _ClientReminderSettingsPageState();
}

class _ClientReminderSettingsPageState
    extends State<ClientReminderSettingsPage> {
  Map<String, dynamic> v2 = const {}, v1 = const {};
  Map<String, dynamic> sync = const {}, todayStatus = const {};
  final subs = <StreamSubscription<Map<String, dynamic>>>[];
  bool saving = false;
  String? status, error, playing;

  @override
  void initState() {
    super.initState();
    final today = taipeiDateKey(widget.clock());
    for (final (path, setter) in [
      ('settings/reminderPlan', (Map<String, dynamic> v) => v2 = v),
      ('settings/reminders', (Map<String, dynamic> v) => v1 = v),
      ('reminderStatus/sync', (Map<String, dynamic> v) => sync = v),
      (
        'reminderStatus/days/$today',
        (Map<String, dynamic> v) => todayStatus = v,
      ),
    ]) {
      try {
        subs.add(
          widget.api
              .watch('care/${widget.hostId}/$path')
              .listen(
                (v) => setState(() => setter(v)),
                onError: (Object e) => setState(() => error = errorMessage(e)),
              ),
        );
      } catch (e) {
        error = errorMessage(e);
      }
    }
  }

  @override
  void dispose() {
    for (final s in subs) {
      s.cancel();
    }
    super.dispose();
  }

  /// Current rows; the old daily list is carried over until the first save.
  List<Map<String, dynamic>> get items {
    final source = v2.isNotEmpty ? v2['items'] : v1['items'];
    if (source is! List) return [];
    return [
      for (final raw in source.whereType<Map>())
        if (reminderLabels.containsKey(raw['type']) && raw['time'] is String)
          asMap(raw),
    ];
  }

  int get version => (v2['version'] as num?)?.toInt() ?? 0;

  Map<String, dynamic> _wire(Map<String, dynamic> item) => {
    if (item['id'] is String && v2.isNotEmpty) 'id': item['id'],
    'type': item['type'],
    'repeat': const {'once', 'weekly'}.contains(item['repeat'])
        ? item['repeat']
        : 'daily',
    if (item['repeat'] == 'once') 'date': item['date'],
    if (item['repeat'] == 'weekly') 'days': item['days'],
    if (item['pausedUntil'] is String) 'pausedUntil': item['pausedUntil'],
    'time': item['time'],
    'text': item['text'] ?? '',
    if (item['voiceId'] is String) 'voiceId': item['voiceId'],
  };

  /// Applies [change] to the latest list. When another family member saved
  /// first, the change is re-applied once to their newer list instead of
  /// throwing away what this person just edited.
  Future<void> _save(
    List<Map<String, dynamic>> Function(List<Map<String, dynamic>>) change,
    String ok,
  ) async {
    setState(() {
      saving = true;
      error = null;
      status = '正在儲存…';
    });
    try {
      for (var attempt = 0; ; attempt++) {
        final base = version;
        try {
          await widget.api.call('setReminderPlan', {
            'hostId': widget.hostId,
            'expectedVersion': base,
            'items': change(items).map(_wire).toList(),
          });
          break;
        } on FirebaseFunctionsException catch (e) {
          if (e.code != 'aborted' || attempt > 0) rethrow;
          if (mounted) setState(() => status = '其他家人剛改過，正在合併你的修改…');
          for (var i = 0; i < 30 && version == base && mounted; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 100));
          }
        }
      }
      if (mounted) setState(() => status = ok);
    } catch (e) {
      if (mounted) {
        setState(() {
          status = null;
          error = '沒有儲存：${errorMessage(e)}';
        });
      }
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  Future<void> _edit([int? index]) async {
    final current = items;
    final result = await Navigator.of(context).push<Map<String, dynamic>>(
      MaterialPageRoute(
        builder: (_) => ReminderEditPage(
          api: widget.api,
          hostId: widget.hostId,
          voice: widget.voice,
          clock: widget.clock,
          initial: index == null ? null : current[index],
        ),
      ),
    );
    if (result == null || !mounted) return;
    if (index == null) {
      await _save((list) => [...list, result], '已新增提醒');
      return;
    }
    final old = current[index];
    await _save(
      (list) => _replace(list, old, {
        ...result,
        if (old['id'] != null) 'id': old['id'],
        if (old['pausedUntil'] is String) 'pausedUntil': old['pausedUntil'],
      }),
      '已修改提醒',
    );
  }

  /// Finds the row by id (index only for the old id-less list); a row another
  /// member deleted meanwhile is added back as this person's edit.
  List<Map<String, dynamic>> _replace(
    List<Map<String, dynamic>> list,
    Map<String, dynamic> old,
    Map<String, dynamic>? next,
  ) {
    final i = old['id'] is String
        ? list.indexWhere((r) => r['id'] == old['id'])
        : list.indexWhere(
            (r) => r['type'] == old['type'] && r['time'] == old['time'],
          );
    final out = [...list];
    if (i < 0) {
      if (next != null) out.add(next);
    } else if (next == null) {
      out.removeAt(i);
    } else {
      out[i] = next;
    }
    return out;
  }

  Future<void> _more(int index, String action) async {
    final row = items[index];
    final today = taipeiDateKey(widget.clock());
    switch (action) {
      case 'pause-today':
        await _save(
          (l) => _replace(l, row, {...row, 'pausedUntil': today}),
          '今天先不提醒，明天照常',
        );
      case 'pause-until':
        final start = DateTime.parse(today);
        final picked = await showDatePicker(
          context: context,
          helpText: '暫停到哪一天（含當天）',
          initialDate: start.add(const Duration(days: 1)),
          firstDate: start,
          lastDate: start.add(const Duration(days: 365)),
        );
        if (picked == null || !mounted) return;
        await _save(
          (l) => _replace(l, row, {...row, 'pausedUntil': _dateKey(picked)}),
          '已暫停到${picked.month}月${picked.day}日',
        );
      case 'resume':
        await _save(
          (l) => _replace(l, row, {...row}..remove('pausedUntil')),
          '已恢復提醒',
        );
      case 'copy':
        final copy = {...row}
          ..remove('id')
          ..remove('pausedUntil');
        await _save((l) => [...l, copy], '已複製一個提醒，可以再修改時間');
    }
  }

  Future<void> _delete(int index) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('刪除這個提醒？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('刪除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final row = items[index];
    await _save((l) => _replace(l, row, null), '已刪除提醒');
  }

  Future<void> _preview(String voiceId) async {
    if (playing == voiceId) {
      await widget.voice.stopPlay().catchError((_) {});
      setState(() => playing = null);
      return;
    }
    setState(() => playing = voiceId);
    try {
      final r = await widget.api.call('getReminderVoice', {
        'hostId': widget.hostId,
        'voiceId': voiceId,
      });
      await widget.voice.play(r['audioBase64'] as String);
    } catch (e) {
      if (mounted) {
        setState(() {
          playing = null;
          error = '語音無法播放：${errorMessage(e)}';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final rows = items;
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('reminder-add'),
        onPressed: saving ? null : () => _edit(),
        icon: const Icon(Icons.add),
        label: const Text('新增提醒'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
        children: [
          Text(
            '時間到時，長輩手機會唸出「你的名字提醒你：…」，有錄音就接著播放你的聲音。長輩不用按任何按鈕。「已播放」只代表手機播了，不代表長輩聽到或做了。',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 8),
          if (status != null)
            FhStatusBanner(tone: FhTone.success, message: status!),
          if (error != null)
            FhStatusBanner(tone: FhTone.danger, message: error!),
          if (rows.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: FhEmptyState(
                icon: Icons.alarm_add,
                title: '還沒有提醒，按右下角「新增提醒」',
              ),
            ),
          for (var i = 0; i < rows.length; i++)
            Card(
              key: Key('reminder-row-$i'),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${rows[i]['time']}　${repeatLabel(rows[i])}　${reminderLabels[rows[i]['type']]}',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          if ('${rows[i]['text'] ?? ''}'.isNotEmpty)
                            Text(
                              '${rows[i]['text']}',
                              style: Theme.of(context).textTheme.bodyMedium,
                            ),
                          if (rows[i]['type'] is String &&
                              rows[i]['time'] is String)
                            Text(
                              familyReminderStatus(
                                item: CareReminder.parsePlan([rows[i]]).first,
                                today: taipeiDateKey(widget.clock()),
                                now: widget.clock(),
                                planVersion: version,
                                syncedVersion: (sync['version'] as num?)
                                    ?.toInt(),
                                delivery:
                                    asMap(
                                      todayStatus[(rows[i]['id'] as String? ??
                                              '${rows[i]['type']}_${rows[i]['time']}')
                                          .replaceAll(':', '_')],
                                    ).isEmpty
                                    ? null
                                    : asMap(
                                        todayStatus[(rows[i]['id'] as String? ??
                                                '${rows[i]['type']}_${rows[i]['time']}')
                                            .replaceAll(':', '_')],
                                      ),
                              ),
                              key: Key('reminder-status-$i'),
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(color: FhColors.brand),
                            ),
                          if (rows[i]['author'] is String)
                            Text(
                              rows[i]['editedBy'] is String &&
                                      rows[i]['editedBy'] != rows[i]['author']
                                  ? '${rows[i]['author']} 設定・最後由 ${rows[i]['editedBy']} 修改'
                                  : '${rows[i]['author']} 設定',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          if (rows[i]['voiceId'] is String)
                            TextButton.icon(
                              onPressed: () =>
                                  _preview(rows[i]['voiceId'] as String),
                              icon: Icon(
                                playing == rows[i]['voiceId']
                                    ? Icons.stop
                                    : Icons.play_arrow,
                              ),
                              label: const Text('聽錄音'),
                            ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: '修改',
                      onPressed: saving ? null : () => _edit(i),
                      icon: const Icon(Icons.edit),
                    ),
                    IconButton(
                      tooltip: '刪除',
                      onPressed: saving ? null : () => _delete(i),
                      icon: const Icon(Icons.delete_outline),
                    ),
                    PopupMenuButton<String>(
                      key: Key('reminder-more-$i'),
                      tooltip: '更多',
                      enabled: !saving,
                      onSelected: (a) => _more(i, a),
                      itemBuilder: (_) => [
                        if (rows[i]['pausedUntil'] is String &&
                            '${rows[i]['pausedUntil']}'.compareTo(
                                  taipeiDateKey(widget.clock()),
                                ) >=
                                0)
                          const PopupMenuItem(
                            value: 'resume',
                            child: Text('取消暫停'),
                          )
                        else ...[
                          const PopupMenuItem(
                            value: 'pause-today',
                            child: Text('今天先暫停'),
                          ),
                          const PopupMenuItem(
                            value: 'pause-until',
                            child: Text('暫停到某一天…'),
                          ),
                        ],
                        const PopupMenuItem(value: 'copy', child: Text('複製一個')),
                      ],
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Add or edit one reminder. Returns the reminder map, or null when cancelled.
class ReminderEditPage extends StatefulWidget {
  final FirebaseService api;
  final String hostId;
  final VoicePort voice;
  final DateTime Function() clock;
  final Map<String, dynamic>? initial;
  const ReminderEditPage({
    super.key,
    required this.api,
    required this.hostId,
    required this.voice,
    required this.clock,
    this.initial,
  });

  @override
  State<ReminderEditPage> createState() => _ReminderEditPageState();
}

class _ReminderEditPageState extends State<ReminderEditPage> {
  late String type = widget.initial?['type'] as String? ?? 'custom';
  late String repeat =
      const {'once', 'weekly'}.contains(widget.initial?['repeat'])
      ? widget.initial!['repeat'] as String
      : 'daily';
  late final Set<int> days = {
    for (final d in (widget.initial?['days'] as List? ?? const []))
      if (d is num) d.toInt(),
  };
  bool get once => repeat == 'once';
  late DateTime date = _initialDate();
  late TimeOfDay time = _initialTime();
  late final text = TextEditingController(
    text: widget.initial?['text'] as String? ?? '',
  );
  late String? voiceId = widget.initial?['voiceId'] as String?;
  bool recording = false, uploading = false;
  String? status;
  DateTime? started;

  DateTime _initialDate() {
    final raw = widget.initial?['date'];
    final parsed = raw is String ? DateTime.tryParse(raw) : null;
    final wall = widget.clock().toUtc().add(const Duration(hours: 8));
    return parsed ?? DateTime(wall.year, wall.month, wall.day);
  }

  TimeOfDay _initialTime() {
    final raw = widget.initial?['time'];
    if (raw is String && raw.length == 5) {
      return TimeOfDay(
        hour: int.parse(raw.substring(0, 2)),
        minute: int.parse(raw.substring(3)),
      );
    }
    return const TimeOfDay(hour: 9, minute: 0);
  }

  @override
  void dispose() {
    text.dispose();
    if (recording) unawaited(widget.voice.cancel().catchError((_) {}));
    super.dispose();
  }

  Future<void> _startRecord() async {
    if (recording || uploading) return;
    if (!await widget.voice.ensurePermission()) {
      setState(() => status = '需要允許使用麥克風才能錄音');
      return;
    }
    try {
      await widget.voice.start();
      started = widget.clock();
      setState(() {
        recording = true;
        status = '錄音中…說完放開（最多 30 秒）';
      });
    } catch (e) {
      setState(() => status = '無法錄音：${errorMessage(e)}');
    }
  }

  Future<void> _stopRecord() async {
    if (!recording) return;
    setState(() => recording = false);
    try {
      final note = await widget.voice.stop();
      final audio = note['audioBase64'], ms = note['durationMs'];
      if (audio is! String || ms is! num) {
        setState(() => status = '太短了，請按住久一點再說');
        return;
      }
      setState(() {
        uploading = true;
        status = '正在上傳錄音…';
      });
      final r = await widget.api.call('uploadReminderVoice', {
        'hostId': widget.hostId,
        'audioBase64': audio,
        'durationMs': ms.toInt(),
      });
      setState(() {
        voiceId = r['voiceId'] as String?;
        status = '錄音完成，可以先試聽';
      });
    } catch (e) {
      setState(() => status = '錄音沒有上傳：${errorMessage(e)}');
    } finally {
      if (mounted) setState(() => uploading = false);
    }
  }

  Future<void> _listen() async {
    final id = voiceId;
    if (id == null) return;
    try {
      final r = await widget.api.call('getReminderVoice', {
        'hostId': widget.hostId,
        'voiceId': id,
      });
      await widget.voice.play(r['audioBase64'] as String);
    } catch (e) {
      setState(() => status = '無法播放：${errorMessage(e)}');
    }
  }

  void _done() {
    final words = text.text.trim();
    if (words.isEmpty && voiceId == null && type == 'custom') {
      setState(() => status = '請輸入一句話，或錄一段語音');
      return;
    }
    if (words.length > 80 || words.contains(RegExp(r'[\x00-\x1f<>]'))) {
      setState(() => status = '文字請在 80 字內，不要換行或輸入 < >');
      return;
    }
    if (repeat == 'weekly' && days.isEmpty) {
      setState(() => status = '請選擇星期幾');
      return;
    }
    Navigator.of(context).pop({
      'type': type,
      'repeat': repeat,
      if (once) 'date': _dateKey(date),
      if (repeat == 'weekly') 'days': (days.toList()..sort()),
      'time': '${_two(time.hour)}:${_two(time.minute)}',
      'text': words,
      if (voiceId != null) 'voiceId': voiceId,
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(widget.initial == null ? '新增提醒' : '修改提醒'),
      actions: [
        TextButton(
          key: const Key('reminder-done'),
          onPressed: uploading || recording ? null : _done,
          child: Text('完成', style: Theme.of(context).textTheme.labelLarge),
        ),
      ],
    ),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('種類', style: Theme.of(context).textTheme.titleMedium),
        Wrap(
          spacing: 8,
          children: [
            for (final e in reminderLabels.entries)
              ChoiceChip(
                label: Text(e.value),
                selected: type == e.key,
                onSelected: (_) => setState(() => type = e.key),
              ),
          ],
        ),
        const SizedBox(height: 16),
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(value: 'daily', label: Text('每天固定')),
            ButtonSegment(value: 'weekly', label: Text('每週幾天')),
            ButtonSegment(value: 'once', label: Text('只提醒一次')),
          ],
          selected: {repeat},
          onSelectionChanged: (v) => setState(() => repeat = v.first),
        ),
        const SizedBox(height: 8),
        if (repeat == 'weekly')
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (var d = 1; d <= 7; d++)
                FilterChip(
                  key: Key('weekday-$d'),
                  label: Text('週${_weekdays[d - 1]}'),
                  selected: days.contains(d),
                  onSelected: (on) =>
                      setState(() => on ? days.add(d) : days.remove(d)),
                ),
            ],
          ),
        if (once)
          ListTile(
            leading: const Icon(Icons.event),
            title: Text('日期：${date.month}月${date.day}日'),
            trailing: const Icon(Icons.edit_calendar),
            onTap: () async {
              final today = _initialDate();
              final picked = await showDatePicker(
                context: context,
                initialDate: date.isBefore(today) ? today : date,
                firstDate: today,
                lastDate: today.add(const Duration(days: 365)),
              );
              if (picked != null) setState(() => date = picked);
            },
          ),
        ListTile(
          key: const Key('reminder-time'),
          leading: const Icon(Icons.schedule),
          title: Text('時間：${_two(time.hour)}:${_two(time.minute)}'),
          trailing: const Icon(Icons.edit),
          onTap: () async {
            final picked = await showTimePicker(
              context: context,
              initialTime: time,
            );
            if (picked != null) setState(() => time = picked);
          },
        ),
        const SizedBox(height: 8),
        TextField(
          key: const Key('reminder-text'),
          controller: text,
          maxLength: 80,
          decoration: const InputDecoration(
            labelText: '要唸給長輩聽的話（可不填，改用錄音）',
            hintText: '例如：記得吃血壓藥喔',
          ),
        ),
        const SizedBox(height: 8),
        Text('或錄一段你的聲音', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        GestureDetector(
          key: const Key('reminder-record'),
          onLongPressStart: (_) => _startRecord(),
          onLongPressEnd: (_) => _stopRecord(),
          onLongPressCancel: () {
            if (recording) {
              setState(() => recording = false);
              unawaited(widget.voice.cancel().catchError((_) {}));
            }
          },
          child: Container(
            height: 64,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: recording ? FhColors.dangerSoft : FhColors.brand,
              borderRadius: BorderRadius.circular(32),
            ),
            child: Text(
              recording ? '錄音中…放開完成' : (voiceId == null ? '按住錄音' : '按住重錄'),
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: recording ? FhColors.danger : Colors.white,
              ),
            ),
          ),
        ),
        if (voiceId != null)
          Row(
            children: [
              TextButton.icon(
                onPressed: _listen,
                icon: const Icon(Icons.play_arrow),
                label: const Text('試聽'),
              ),
              TextButton.icon(
                onPressed: () => setState(() => voiceId = null),
                icon: const Icon(Icons.delete_outline),
                label: const Text('不要錄音'),
              ),
            ],
          ),
        if (status != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: FhStatusBanner(message: status!),
          ),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: uploading || recording ? null : _done,
          child: const Text('完成'),
        ),
      ],
    ),
  );
}
