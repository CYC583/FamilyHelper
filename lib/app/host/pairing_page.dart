// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../common/constants.dart';
import '../common/firebase_service.dart';
import '../common/native_bridge.dart';
import 'health_connect_service.dart';
import 'battery_consent_page.dart';
import 'host_care_settings_page.dart';
import 'host_place_alerts_page.dart';
import 'host_contacts_page.dart';
import 'host_check_page.dart';
import 'host_sharing_page.dart';
import '../common/profile_page.dart';
import '../common/about_page.dart';
import '../common/ui/fh_tokens.dart';
import '../common/ui/fh_widgets.dart';

class PairingPage extends StatefulWidget {
  final FirebaseService api;
  const PairingPage({super.key, required this.api});
  @override
  State<PairingPage> createState() => _PairingPageState();
}

class _PairingPageState extends State<PairingPage> {
  String code = '', message = '';
  DateTime? expiry;
  Set<String>? codeMemberIds;
  bool busy = false, healthEnabled = false;
  late final Stream<Map<String, dynamic>> familyStream;
  final low = TextEditingController(),
      high = TextEditingController(),
      oxygen = TextEditingController();
  late final health = HealthConnectService(widget.api);
  @override
  void initState() {
    super.initState();
    familyStream = widget.api.family(widget.api.uid);
    load();
  }

  void clearStaleCodeAfterFrame(String staleCode) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || code != staleCode) return;
      setState(() {
        code = '';
        expiry = null;
        codeMemberIds = null;
      });
    });
  }

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    low.text = prefs.getDouble('heartLow')?.toString() ?? '';
    high.text = prefs.getDouble('heartHigh')?.toString() ?? '';
    oxygen.text = prefs.getDouble('oxygenLow')?.toString() ?? '';
    if (mounted) {
      setState(() => healthEnabled = prefs.getBool('healthEnabled') ?? false);
    }
  }

  Future<void> run(Future<void> Function() action) async {
    if (busy) return;
    setState(() {
      busy = true;
      message = '';
    });
    try {
      await action();
    } catch (e) {
      if (mounted) setState(() => message = errorMessage(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> generate(Set<String> memberIds) => run(() async {
    final data = await widget.api.call('createPairCode');
    if (mounted) {
      setState(() {
        code = data['code'] as String;
        expiry = DateTime.fromMillisecondsSinceEpoch(data['expiresAt'] as int);
        codeMemberIds = memberIds;
      });
    }
  });
  Future<void> unpair(String id, String name) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('解除 $name？'),
        content: const Text('此裝置需要重新配對才能再協助。'),
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
    if (yes == true) {
      await run(() async {
        await widget.api.call('unpairDevice', {
          'hostId': widget.api.uid,
          'clientId': id,
        });
      });
    }
  }

  Future<void> explainRemoteTapPermission() async {
    final proceed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true,
        title: const Text('遠端點擊權限'),
        content: const Text(
          'Android 的無障礙服務會授予「查看視窗內容」的系統能力。FamilyHelper 只用它辨識目前是哪個 App，避免家人遠端按到系統設定或授權畫面；不讀取畫面文字或密碼。\n\n'
          '這項權限必須由長輩在手機設定中手動開啟。不開啟仍可配對與求助，但家人不能遠端點擊。每次協助仍須長輩親自同意並允許螢幕分享，也可以隨時停止。',
          style: TextStyle(fontSize: 20),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('暫不開啟'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('前往手機設定'),
          ),
        ],
      ),
    );
    if (proceed == true && mounted) {
      await run(NativeBridge.accessibilitySettings);
    }
  }

  Future<void> thresholds() => run(() async {
    final values = {
      'heartLow': low.text,
      'heartHigh': high.text,
      'oxygenLow': oxygen.text,
    };
    final parsed = <String, double>{};
    for (final e in values.entries) {
      if (e.value.trim().isEmpty) continue;
      final n = double.tryParse(e.value);
      if (n == null ||
          !n.isFinite ||
          n <= 0 ||
          (e.key == 'oxygenLow' && n > 100)) {
        throw Exception('請輸入有效數值；血氧百分比不可超過 100');
      }
      parsed[e.key] = n;
    }
    if (parsed.containsKey('heartLow') &&
        parsed.containsKey('heartHigh') &&
        parsed['heartLow']! >= parsed['heartHigh']!) {
      throw Exception('心率下限必須小於上限');
    }
    final prefs = await SharedPreferences.getInstance();
    for (final key in values.keys) {
      if (parsed[key] == null) {
        await prefs.remove(key);
      } else {
        await prefs.setDouble(key, parsed[key]!);
      }
    }
    if (mounted) setState(() => message = '已儲存自訂提醒範圍');
  });
  @override
  void dispose() {
    low.dispose();
    high.dispose();
    oxygen.dispose();
    super.dispose();
  }

  Widget _navTile({
    Key? key,
    required IconData icon,
    required String title,
    required String subtitle,
    VoidCallback? onTap,
    IconData trailing = Icons.chevron_right,
  }) => ListTile(
    key: key,
    leading: Icon(icon, size: 30),
    title: Text(title),
    subtitle: Text(subtitle),
    trailing: Icon(trailing),
    onTap: onTap,
  );

  void _push(Widget page) =>
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));

  Widget _group(List<Widget> tiles) => FhCard(
    padding: EdgeInsets.zero,
    child: Column(
      children: [
        for (final (i, tile) in tiles.indexed) ...[
          if (i > 0) const Divider(indent: FhSpace.lg, endIndent: FhSpace.lg),
          tile,
        ],
      ],
    ),
  );

  Widget _pairingSection() => StreamBuilder<Map<String, dynamic>>(
    stream: familyStream,
    builder: (context, snapshot) {
      final text = Theme.of(context).textTheme;
      final members = asMap(snapshot.data?['members']);
      final full = snapshot.hasData && members.length >= maxFamilyClients;
      final staleCode =
          code.isNotEmpty &&
          (snapshot.hasError ||
              (snapshot.hasData &&
                  (codeMemberIds == null ||
                      codeMemberIds!.length != members.length ||
                      !codeMemberIds!.containsAll(members.keys))));
      if (staleCode) clearStaleCodeAfterFrame(code);
      final showCode = !full && !staleCode && code.isNotEmpty;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FhCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    const Icon(
                      Icons.group_add_outlined,
                      size: 32,
                      color: FhColors.brand,
                    ),
                    const SizedBox(width: FhSpace.md),
                    Expanded(
                      child: Text(
                        snapshot.hasData
                            ? '已連結 ${members.length}／$maxFamilyClients 位家人'
                            : '連結家人',
                        style: text.titleLarge,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: FhSpace.sm),
                const Text('把配對碼交給要綁定的家人。'),
                Text('每位家人都需重新產生一組配對碼。', style: text.bodySmall),
                const SizedBox(height: FhSpace.lg),
                if (snapshot.hasError)
                  FhStatusBanner(
                    tone: FhTone.danger,
                    message: '無法載入家人清單：${errorMessage(snapshot.error!)}',
                  ),
                if (!snapshot.hasData && !snapshot.hasError)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: FhSpace.md),
                    child: Text('正在讀取家人清單…', textAlign: TextAlign.center),
                  ),
                if (full)
                  const FhStatusBanner(
                    tone: FhTone.warning,
                    message: '已額滿，請先解除一位家人。',
                  ),
                if (showCode)
                  Container(
                    key: const Key('pair-code-box'),
                    padding: const EdgeInsets.symmetric(
                      vertical: FhSpace.lg,
                      horizontal: FhSpace.sm,
                    ),
                    decoration: BoxDecoration(
                      color: FhColors.brandTint,
                      borderRadius: BorderRadius.circular(FhRadius.md),
                      border: Border.all(color: FhColors.brand, width: 2),
                    ),
                    child: Column(
                      children: [
                        FittedBox(
                          fit: BoxFit.scaleDown,
                          child: SelectableText(
                            code,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              fontSize: 52,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 10,
                              color: FhColors.brandDark,
                              fontFeatures: [FontFeature.tabularFigures()],
                            ),
                          ),
                        ),
                        if (expiry != null)
                          Text(
                            '有效至 ${expiry!.hour.toString().padLeft(2, '0')}:${expiry!.minute.toString().padLeft(2, '0')}；用過即失效',
                            textAlign: TextAlign.center,
                            style: text.bodySmall,
                          ),
                      ],
                    ),
                  ),
                const SizedBox(height: FhSpace.lg),
                FilledButton(
                  onPressed: busy || !snapshot.hasData || full
                      ? null
                      : () => generate(members.keys.toSet()),
                  child: Text(showCode ? '重新產生配對碼' : '產生配對碼'),
                ),
              ],
            ),
          ),
          if (members.isNotEmpty) ...[
            const FhSectionHeader(title: '已連結的家人'),
            _group([
              for (final e in members.entries)
                ListTile(
                  leading: const CircleAvatar(
                    backgroundColor: FhColors.brandTint,
                    foregroundColor: FhColors.brand,
                    child: Icon(Icons.person),
                  ),
                  title: Text(asMap(e.value)['name'] as String? ?? '家人'),
                  trailing: TextButton(
                    style: TextButton.styleFrom(
                      foregroundColor: FhColors.danger,
                    ),
                    onPressed: busy
                        ? null
                        : () => unpair(
                            e.key,
                            asMap(e.value)['name'] as String? ?? '家人',
                          ),
                    child: const Text('解除'),
                  ),
                ),
            ]),
          ],
        ],
      );
    },
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('家人設定'),
      bottom: busy
          ? const PreferredSize(
              preferredSize: Size.fromHeight(4),
              child: LinearProgressIndicator(),
            )
          : null,
    ),
    body: ListView(
      padding: const EdgeInsets.fromLTRB(
        FhSpace.lg,
        FhSpace.sm,
        FhSpace.lg,
        FhSpace.xxl,
      ),
      children: [
        // Results appear at the top, where the elder is already looking,
        // instead of at the end of a long list.
        if (message.isNotEmpty) ...[
          FhStatusBanner(key: const Key('settings-message'), message: message),
          const SizedBox(height: FhSpace.md),
        ],
        _pairingSection(),
        const FhSectionHeader(title: '我和家人分享什麼', subtitle: '每一項都可以隨時關閉'),
        _group([
          _navTile(
            key: const Key('open-profile'),
            icon: Icons.account_circle_outlined,
            title: '我的名字與頭貼',
            subtitle: '家人看到的稱呼和照片',
            onTap: () async {
              final family = await widget.api.read(
                'core/families/${widget.api.uid}',
              );
              if (!mounted) return;
              _push(
                ProfilePage(
                  api: widget.api,
                  hostId: widget.api.uid,
                  currentName: family['name'] as String? ?? '長輩',
                  large: true,
                ),
              );
            },
          ),
          _navTile(
            key: const Key('open-location-sharing'),
            icon: Icons.location_on_outlined,
            title: '分享我的位置',
            subtitle: '家人可以在地圖上看到手機在哪裡，也能讓手機響 10 秒',
            onTap: () =>
                _push(HostSharingPage(api: widget.api, kind: 'location')),
          ),
          _navTile(
            key: const Key('open-usage-sharing'),
            icon: Icons.hourglass_bottom,
            title: '分享手機使用時間',
            subtitle: '家人可以看到每個 App 用了多久（只有名稱和分鐘）',
            onTap: () => _push(HostSharingPage(api: widget.api, kind: 'usage')),
          ),
          _navTile(
            icon: Icons.battery_alert_outlined,
            title: '長輩手機電量守護',
            subtitle: '低電量中文朗讀、提示聲、家人分享與暫停',
            onTap: () => _push(BatteryConsentPage(api: widget.api)),
          ),
          _navTile(
            key: const Key('open-check'),
            icon: Icons.fact_check_outlined,
            title: '手機檢查與分享',
            subtitle: '檢查通知、聲音、權限；看看正在分享什麼給家人',
            onTap: () => _push(HostCheckPage(api: widget.api)),
          ),
        ]),
        const FhSectionHeader(title: '提醒與求助'),
        _group([
          _navTile(
            icon: Icons.record_voice_over_outlined,
            title: '提醒、朗讀與陪伴分享',
            subtitle: '家人設定的提醒、久看休息、檢查聲音、分享給家人',
            onTap: () => _push(HostCareSettingsPage(api: widget.api)),
          ),
          _navTile(
            icon: Icons.phone_outlined,
            title: '家人電話',
            subtitle: '確認家人的電話，求助沒人接時可一鍵撥打',
            onTap: () => _push(HostContactsPage(api: widget.api)),
          ),
          _navTile(
            icon: Icons.home_outlined,
            title: '出門到家通知',
            subtitle: '離開或到達家、工作地點時通知家人（不傳位置）',
            onTap: () => _push(HostPlaceAlertsPage(api: widget.api)),
          ),
        ]),
        const FhSectionHeader(title: '手機權限', subtitle: '這些都要在長輩自己的手機上操作'),
        _group([
          _navTile(
            icon: Icons.touch_app_outlined,
            title: '允許遠端點擊',
            subtitle:
                '須由長輩在系統協助工具中手動開啟。Android 會授予查看視窗內容的能力；本 App 只檢查目前 App 名稱來阻擋系統設定與授權畫面的遠端點擊，不讀取文字或密碼。每次協助仍須長輩親自同意並允許螢幕分享，可隨時停止。',
            trailing: Icons.open_in_new,
            onTap: busy ? null : explainRemoteTapPermission,
          ),
          _navTile(
            icon: Icons.my_location,
            title: 'SOS 位置權限',
            subtitle: '只在按下 SOS 時嘗試取得位置',
            trailing: Icons.open_in_new,
            onTap: () => run(() async {
              final value = await Geolocator.requestPermission();
              if (mounted) {
                setState(
                  () => message =
                      value == LocationPermission.whileInUse ||
                          value == LocationPermission.always
                      ? '已允許位置'
                      : '未允許位置；SOS 仍可發送',
                );
              }
            }),
          ),
          _navTile(
            icon: Icons.battery_saver_outlined,
            title: '電池設定',
            subtitle: '請手動將 FamilyHelper 設為無限制',
            trailing: Icons.open_in_new,
            onTap: () => run(NativeBridge.batterySettings),
          ),
          Padding(
            padding: const EdgeInsets.all(FhSpace.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('待命通知', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: FhSpace.xs),
                Text(
                  '待命仍可能被系統停止；不會自動開始分享畫面。',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: FhSpace.md),
                Wrap(
                  spacing: FhSpace.md,
                  runSpacing: FhSpace.sm,
                  children: [
                    OutlinedButton(
                      onPressed: () => run(
                        () => NativeBridge.channel.invokeMethod<void>(
                          'startStandby',
                        ),
                      ),
                      child: const Text('開啟待命通知'),
                    ),
                    OutlinedButton(
                      onPressed: () => run(
                        () => NativeBridge.channel.invokeMethod<void>(
                          'stopStandby',
                        ),
                      ),
                      child: const Text('關閉待命通知'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ]),
        const FhSectionHeader(title: '健康資料（選用）', subtitle: '預設關閉；不是醫療監測'),
        FhCard(
          padding: EdgeInsets.zero,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SwitchListTile(
                title: const Text('健康資料（選用）'),
                subtitle: const Text(
                  '需先在 Samsung Health 允許同步至 Health Connect。本版只在 App 開啟時更新；不是即時醫療監測。',
                ),
                value: healthEnabled,
                onChanged: busy
                    ? null
                    : (value) => run(() async {
                        if (value) {
                          await health.enable();
                        } else {
                          await health.disable();
                        }
                        if (mounted) setState(() => healthEnabled = value);
                      }),
              ),
              if (healthEnabled)
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    FhSpace.lg,
                    0,
                    FhSpace.lg,
                    FhSpace.lg,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      OutlinedButton(
                        onPressed: busy
                            ? null
                            : () => run(() async {
                                await health.sync();
                                if (mounted) {
                                  setState(() => message = '已更新；沒有資料的項目會留白');
                                }
                              }),
                        child: const Text('立即同步健康資料'),
                      ),
                      const SizedBox(height: FhSpace.lg),
                      const Text('自訂提醒範圍（留空不提醒；請依醫療人員建議設定）'),
                      const SizedBox(height: FhSpace.md),
                      TextField(
                        controller: low,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        decoration: const InputDecoration(
                          labelText: '心率下限（次／分）',
                        ),
                      ),
                      const SizedBox(height: FhSpace.md),
                      TextField(
                        controller: high,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        decoration: const InputDecoration(
                          labelText: '心率上限（次／分）',
                        ),
                      ),
                      const SizedBox(height: FhSpace.md),
                      TextField(
                        controller: oxygen,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        decoration: const InputDecoration(labelText: '血氧下限（%）'),
                      ),
                      const SizedBox(height: FhSpace.md),
                      OutlinedButton(
                        onPressed: busy ? null : thresholds,
                        child: const Text('儲存提醒範圍'),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        const FhSectionHeader(title: '其他'),
        _group([
          _navTile(
            key: const Key('open-about'),
            icon: Icons.info_outline,
            title: '關於 FamilyHelper',
            subtitle: '作者、版權與授權',
            onTap: () => _push(const AboutPage(role: AppRole.host)),
          ),
        ]),
      ],
    ),
  );
}
