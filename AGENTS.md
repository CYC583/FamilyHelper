# FamilyHelper — AI 程式助理專案指引

給 Codex、Claude Code 等 AI 助理與貢獻者。用繁體中文回覆與撰寫使用者可見文字。

## 先讀

- `README.md`：產品說明；`docs/SETUP.md`：安裝流程；`docs/ARCHITECTURE.md`：架構與安全設計；`docs/TESTING.md`：測試
- `CONTRIBUTING.md`：**不可改變的產品原則**（逐次同意、系統畫面不能被遠端點擊、長輩首頁兩顆大按鈕、分享預設關閉、後端驗證授權）
- 若根目錄有 `CODEX_TODO.md`，那是目前的工作清單（不進 Git）

## 專案事實

- Flutter Android；`host`／`client` 兩個 Gradle flavor，入口 `lib/main_host.dart`、`lib/main_client.dart`
- 每個家庭自建 Firebase：匿名 Auth、Realtime Database、Cloud Functions（`asia-east1`）、選用 Storage、FCM
- 最多 6 位家人（`MAX_FAMILY_CLIENTS`，前後端常數需一致）
- 設計系統：`lib/app/common/ui/`（`fh_tokens.dart`、`fh_theme.dart`、`fh_widgets.dart`、`fh_format.dart`）
- 授權：PolyForm Noncommercial 1.0.0＋禁止上架附加條款，原作者 cyc。**不得移除** `LICENSE`、檔頭版權行、`AboutPage` 的作者標示

## 工具版本

Flutter 3.35.7／Dart 3.9.2、JDK 17（Android 建置）、JDK 21（Firebase Emulator）、Node.js 22、Python 3、firebase-tools 15.26.0。保留 `pubspec.lock`、`package-lock.json`，非必要不升級依賴。

## 驗證命令（從專案根目錄）

```bash
python3 tool/check_sources.py
python3 -m unittest discover -s tool/tests -p 'test_*.py'
npm ci --prefix backend/functions && npm test --prefix backend/functions
flutter pub get && flutter analyze && flutter test
flutter build apk --debug --flavor host -t lib/main_host.dart
flutter build apk --debug --flavor client -t lib/main_client.dart
```

規則／授權改動另跑（從 `backend/`，需 JDK 21）：

```bash
npx --yes firebase-tools@15.26.0 emulators:exec --only database --project demo-familyhelper "cd functions && npm run test:rules"
npx --yes firebase-tools@15.26.0 emulators:exec --only auth,functions,database --project demo-familyhelper "cd functions && npm run test:callables"
```

模擬器實測時用 `--dart-define=FH_USE_EMULATOR=true` 讓 App 連本機 Emulator，不要連正式 Firebase。

## 工作規則

- 以實際命令結果判定完成；分清「原始碼已改」「測試通過」「模擬器實測」「實機驗證」
- 修 bug 先寫會失敗的測試；UI 改動要在 320dp 寬與 200% 字級下截圖確認
- UI 不寫死 `Color(0x…)`；狀態用 `FhStatusBanner`／`FhEmptyState`／`FhLoadingView`／`FhErrorView`
- 改 UI 文字時，同步更新依賴該文字的測試
- **不要 commit、push、部署 Firebase、發送推播**，除非使用者明確要求
- 不提交 keystore、`key.properties`、`google-services.json`、`config/*.json`、`.env*`、`.secret*`、`.setup/`
- 修改 WebRTC 版本時一併處理 `android/webrtc_patch/`，並實測 Android「停止分享」
