// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../host/host_home_page.dart';
import '../client/client_home_page.dart';
import 'constants.dart';
import 'firebase_service.dart';
import 'native_bridge.dart';
import 'fcm_service.dart';
import 'onboarding_page.dart';
import 'ui/fh_theme.dart';
import 'ui/fh_tokens.dart';
import 'ui/fh_widgets.dart';

Future<FirebaseApp> ensureFirebaseInitialized() async {
  if (Firebase.apps.isNotEmpty) return Firebase.app();
  // Android's google-services.json creates the native default app. Passing a
  // second set of options here can fail with core/duplicate-app on cold start.
  return Firebase.initializeApp();
}

Future<void> boot(AppRole role) async {
  WidgetsFlutterBinding.ensureInitialized();
  NativeBridge.initialize();
  runApp(FamilyApp(role: role));
}

const bool batteryEmulatorRequested = bool.fromEnvironment('FH_USE_EMULATOR');

Future<void> configureLocalEmulators(AppRole role) async {
  if (!batteryEmulatorRequested) return;
  if (!kDebugMode) {
    throw StateError('正式版本不得連接測試用 Firebase Emulator');
  }
  const host = '10.0.2.2';
  await FirebaseAuth.instance.useAuthEmulator(host, 9099);
  FirebaseFunctions.instanceFor(
    region: AppConfig.region,
  ).useFunctionsEmulator(host, 5001);
  FirebaseDatabase.instanceFor(
    app: Firebase.app(),
    databaseURL: AppConfig.databaseUrl,
  ).useDatabaseEmulator(host, 9000);
  if (role == AppRole.host) {
    // The native RTDB instance is shared with FlutterFire; configuring it here
    // would race FlutterFire. The open app hands the plan to native instead.
    await NativeBridge.batteryConfigureEmulator(host: host);
  }
}

class FamilyApp extends StatelessWidget {
  final AppRole role;
  const FamilyApp({super.key, required this.role});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'FamilyHelper',
    debugShowCheckedModeBanner: false,
    theme: buildFhTheme(role),
    home: StartupPage(role: role),
  );
}

class StartupPage extends StatefulWidget {
  final AppRole role;
  const StartupPage({super.key, required this.role});
  @override
  State<StartupPage> createState() => _StartupPageState();
}

class _StartupPageState extends State<StartupPage> {
  final api = FirebaseService();
  FcmService? fcm;
  String? error;
  bool ready = false;
  bool? showOnboarding;
  bool notConfigured = false;
  String? startupNotice;
  @override
  void initState() {
    super.initState();
    loadOnboarding();
  }

  String get onboardingKey => widget.role == AppRole.host
      ? 'onboarding_host_v1'
      : 'onboarding_client_v1';

  Future<void> loadOnboarding() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;
      final show = prefs.getBool(onboardingKey) != true;
      setState(() => showOnboarding = show);
      if (!show) await initialize();
    } catch (e) {
      if (mounted) {
        setState(() {
          showOnboarding = false;
          error = '無法讀取首次使用設定：${errorMessage(e)}';
        });
      }
    }
  }

  Future<void> finishOnboarding() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(onboardingKey, true);
    if (!mounted) return;
    setState(() => showOnboarding = false);
    await initialize();
  }

  Future<void> initialize() async {
    setState(() {
      error = null;
      ready = false;
    });
    try {
      if (!AppConfig.ready) {
        setState(() => notConfigured = true);
        return;
      }
      await ensureFirebaseInitialized();
      await configureLocalEmulators(widget.role);
      final prefs = await SharedPreferences.getInstance();
      await api.start(
        widget.role,
        prefs.getString('deviceName') ??
            (widget.role == AppRole.host ? '長輩' : '家人手機'),
      );
      fcm ??= FcmService(api);
      String? notice;
      if (batteryEmulatorRequested) {
        notice = '模擬器測試模式：不會向正式推播服務註冊。';
      } else {
        try {
          await fcm!.start();
        } catch (_) {
          notice = '推播尚未啟用，請檢查通知權限及 Firebase 設定。';
        }
      }
      if (!mounted) return;
      setState(() {
        ready = true;
        startupNotice = widget.role == AppRole.host ? notice : null;
      });
      if (notice != null && widget.role != AppRole.host) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text(notice!)));
          }
        });
      }
    } catch (e) {
      if (e is FirebaseException) {
        debugPrint(
          'FamilyHelper startup Firebase error: ${e.plugin}/${e.code}',
        );
      }
      if (mounted) setState(() => error = errorMessage(e));
    }
  }

  @override
  void dispose() {
    fcm?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (showOnboarding == true) {
      return OnboardingPage(role: widget.role, onDone: finishOnboarding);
    }
    if (ready) {
      return widget.role == AppRole.host
          ? HostHomePage(api: api, initialNotice: startupNotice)
          : ClientHomePage(api: api);
    }
    return Scaffold(
      body: SafeArea(
        child: notConfigured
            ? const FhErrorView(
                key: Key('startup-not-configured'),
                title: '這個 App 還沒設定完成',
                message: '安裝檔沒有包含 Firebase 設定，所以無法連線。',
                extra: FhStatusBanner(
                  tone: FhTone.info,
                  announce: false,
                  title: '給負責安裝的家人',
                  message:
                      '請在電腦上執行專案裡的設定精靈：\n'
                      'python3 tool/setup.py（Windows：python tool/setup.py）\n'
                      '完成後重新打包、重新安裝這個 App。',
                ),
              )
            : error == null
            ? const FhLoadingView(label: '正在連線…')
            : FhErrorView(
                title: '暫時無法連線',
                message: '$error\n\n請確認手機有網路，再按「重試」。',
                onRetry: loadOnboarding,
              ),
      ),
    );
  }
}
