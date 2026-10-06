# 參與貢獻

歡迎回報問題與提出改進！開始之前請先閱讀：

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)：程式結構與安全設計
- [docs/TESTING.md](docs/TESTING.md)：測試方式

## 不可改變的產品原則

這些是 FamilyHelper 的核心，PR 若違反會被要求修改：

1. **每次協助都要長輩在本機同意**，並重新取得 Android 螢幕分享授權。拒絕、撤銷、鎖屏、停止分享、逾時或斷線必須停止控制。
2. **遠端不得代按** App 同意框、系統權限、安全設定或解鎖畫面。
3. **長輩首頁只有兩個主要按鈕**（呼叫家人、SOS），至少 120dp 高、文字至少 24sp、高對比。
4. **分享給家人的資料預設關閉**，由長輩在本機開啟。
5. **授權與鎖定由後端驗證**。App 不直接寫入綁定、同意或會話鎖；資料庫規則維持預設拒絕。
6. 不把金鑰、密碼、service account、TURN secret 放進 App 或 Git。

## 開發流程

```bash
flutter pub get
flutter analyze            # 必須 0 issue
flutter test
npm ci --prefix backend/functions && npm test --prefix backend/functions
python3 -m unittest discover -s tool/tests -p 'test_*.py'
```

後端規則或授權有改動時，另外跑 Emulator 測試（從 `backend/` 執行；Firebase Emulator 需要 **JDK 21**，Android 建置則用 JDK 17）：

```bash
npx --yes firebase-tools@15.26.0 emulators:exec --only database --project demo-familyhelper "cd functions && npm run test:rules"
```

## 程式風格

- UI 顏色、間距、圓角用 `lib/app/common/ui/fh_tokens.dart`，不要寫死 `Color(0x…)`
- 載入、空狀態、錯誤、提示用 `fh_widgets.dart` 的 `FhLoadingView`、`FhEmptyState`、`FhErrorView`、`FhStatusBanner`
- 長輩端的文字與按鈕要在 320dp 寬、200% 系統字級下不爆版
- 修 bug 先寫會失敗的測試，再修正
- 使用者看得到的文字一律用繁體中文

## Pull Request

- 一個 PR 只處理一件事，說明「改了什麼、為什麼、怎麼驗證」
- 涉及畫面請附上截圖（含大字級）
- 涉及權限、配對、會話、資料庫規則的改動，請說明拒絕與失效情境的測試

## 授權

提交 PR 即表示你同意：

1. 你的貢獻以本專案的 [LICENSE](LICENSE) 授權釋出；
2. 你擁有提交內容的權利；
3. 原作者 cyc 可以將你的貢獻納入本專案，並以其他條款（包括商業授權）重新授權。
