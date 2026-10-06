// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
import 'package:flutter/material.dart';
import '../common/firebase_service.dart';
import '../common/weather_service.dart';
import 'client_reminder_settings_page.dart';
import '../common/ui/fh_tokens.dart';
import '../common/ui/fh_widgets.dart';

/// Family settings are versioned on the server. Saving a preference does not
/// imply the host has scheduled or played an automatic announcement yet.
class ClientWeatherSettingsPage extends StatefulWidget {
  final FirebaseService api;
  final String hostId;
  final WeatherService weather;
  const ClientWeatherSettingsPage({
    super.key,
    required this.api,
    required this.hostId,
    this.weather = const WeatherService(),
  });

  @override
  State<ClientWeatherSettingsPage> createState() =>
      _ClientWeatherSettingsPageState();
}

class _ClientWeatherSettingsPageState extends State<ClientWeatherSettingsPage> {
  late final Stream<Map<String, dynamic>> settings;
  final query = TextEditingController();
  List<WeatherLocation> choices = const [];
  WeatherLocation? selected;
  TimeOfDay? chosenTime;
  int? editBaseVersion;
  bool searching = false, saving = false;
  String? status, error;

  @override
  void initState() {
    super.initState();
    settings = widget.api.watch('care/${widget.hostId}/settings/weather');
  }

  @override
  void dispose() {
    query.dispose();
    super.dispose();
  }

  Future<void> search() async {
    setState(() {
      searching = true;
      error = null;
      choices = const [];
    });
    try {
      final results = await widget.weather.searchTaiwanCities(query.text);
      if (!mounted) return;
      setState(() {
        choices = results;
        if (results.isEmpty) error = '找不到城市，請試試「台北」「新竹」等縣市名稱。';
      });
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => searching = false);
    }
  }

  TimeOfDay parseTime(Object? value) {
    if (value is String &&
        RegExp(r'^(?:[01][0-9]|2[0-3]):[0-5][0-9]$').hasMatch(value)) {
      return TimeOfDay(
        hour: int.parse(value.substring(0, 2)),
        minute: int.parse(value.substring(3, 5)),
      );
    }
    return const TimeOfDay(hour: 8, minute: 30);
  }

  String encodeTime(TimeOfDay value) =>
      '${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}';

  WeatherLocation? currentCity(Map<String, dynamic> cloud) {
    final city = cloud['city'];
    if (city is! Map ||
        city['name'] is! String ||
        city['latitude'] is! num ||
        city['longitude'] is! num) {
      return null;
    }
    return WeatherLocation(
      city['name'] as String,
      (city['latitude'] as num).toDouble(),
      (city['longitude'] as num).toDouble(),
    );
  }

  Future<void> save(Map<String, dynamic> cloud) async {
    final city = selected ?? currentCity(cloud);
    if (city == null) {
      setState(() => error = '請先搜尋並選擇長輩所在城市。');
      return;
    }
    final time = chosenTime ?? parseTime(cloud['morningTime']);
    setState(() {
      saving = true;
      error = null;
      status = null;
    });
    try {
      final result = await widget.api.call('setWeatherSettings', {
        'hostId': widget.hostId,
        'expectedVersion':
            editBaseVersion ?? (cloud['version'] as num?)?.toInt() ?? 0,
        'city': {
          'name': city.name,
          'latitude': city.latitude,
          'longitude': city.longitude,
        },
        'morningTime': encodeTime(time),
      });
      if (mounted) {
        setState(() {
          editBaseVersion = (result['version'] as num?)?.toInt();
          status = '天氣城市與時間已儲存。長輩要在自己的手機開啟「提醒與朗讀」才會播報，時間可能晚幾分鐘。';
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = errorMessage(e));
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => StreamBuilder<Map<String, dynamic>>(
    stream: settings,
    builder: (context, snapshot) {
      final cloud = snapshot.data ?? {};
      final city = selected ?? currentCity(cloud);
      final time = chosenTime ?? parseTime(cloud['morningTime']);
      return ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text('早安天氣', style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 8),
          const Text('家人選城市，不讀長輩手機位置。天氣是預報，會標示來源與更新時間。'),
          const SizedBox(height: 16),
          TextField(
            controller: query,
            decoration: const InputDecoration(
              labelText: '搜尋台灣縣市',
              hintText: '例如：台北、新竹、花蓮',
            ),
            textInputAction: TextInputAction.search,
            onSubmitted: (_) => search(),
          ),
          OutlinedButton(
            onPressed: searching ? null : search,
            child: Text(searching ? '搜尋中…' : '搜尋城市'),
          ),
          for (final choice in choices)
            ListTile(
              title: Text(choice.name),
              trailing: selected == choice ? const Icon(Icons.check) : null,
              onTap: () => setState(() {
                editBaseVersion ??= (cloud['version'] as num?)?.toInt() ?? 0;
                selected = choice;
                choices = const [];
              }),
            ),
          Text('選擇：${city?.name ?? '尚未選擇'}'),
          const SizedBox(height: 12),
          OutlinedButton(
            onPressed: () async {
              final picked = await showTimePicker(
                context: context,
                initialTime: time,
              );
              if (picked != null && mounted) {
                setState(() {
                  editBaseVersion ??= (cloud['version'] as num?)?.toInt() ?? 0;
                  chosenTime = picked;
                });
              }
            },
            child: Text('早安時間 ${encodeTime(time)}'),
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: saving || !snapshot.hasData || snapshot.hasError
                ? null
                : () => save(cloud),
            child: Text(saving ? '儲存中…' : '儲存城市與時間'),
          ),
          if (snapshot.hasError)
            FhStatusBanner(
              tone: FhTone.danger,
              message: '設定讀取失敗：${errorMessage(snapshot.error!)}',
            ),
          if (error != null)
            FhStatusBanner(tone: FhTone.danger, message: error!),
          if (status != null)
            FhStatusBanner(tone: FhTone.success, message: status!),
          const SizedBox(height: 12),
          const Text(
            '長輩在自己的手機開啟「提醒與朗讀」後，才會在設定時間顯示並朗讀；系統排程可能晚幾分鐘，不保證準點。這裡儲存不代表長輩已經聽到。',
            style: TextStyle(color: FhColors.warning),
          ),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute<void>(
                builder: (_) => ClientReminderSettingsPage(
                  api: widget.api,
                  hostId: widget.hostId,
                ),
              ),
            ),
            icon: const Icon(Icons.notifications_outlined),
            label: const Text('設定每日提醒'),
          ),
        ],
      );
    },
  );
}
