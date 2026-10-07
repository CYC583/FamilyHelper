# FamilyHelper

[English](README.md) | **繁體中文**

**讓家人在長輩同意下，遠端幫忙操作 Android 手機。**

長輩手機只有兩顆大按鈕：「呼叫家人」和「SOS 緊急求助」。家人可以從自己的手機看到長輩的畫面、幫忙點擊、視訊聊天；**每一次協助都必須長輩在自己手機上親自按「同意」**，隨時可以停止。

> 目前只支援 Android。每個家庭使用自己的 Firebase 後端，資料不會和其他家庭共用。

<p align="center"><img src="docs/images/demo.gif" alt="FamilyHelper 示範" width="560"></p>

<p align="center"><em>示範：配對 → 長輩親自同意 → Android 確認螢幕分享。為了安全，同意畫面禁止截圖，第 4 格為示意圖。</em></p>

| 長輩版首頁 | 長輩版設定 | 家人版首頁 | 家人配對 |
| --- | --- | --- | --- |
| ![長輩版首頁](docs/images/host-home.png) | ![長輩版設定](docs/images/host-settings.png) | ![家人版首頁](docs/images/client-home.png) | ![家人配對](docs/images/client-pair.png) |

---

## 為什麼做這個 App

我的外婆一個人住。她的手機收到通知時，只會響起系統提示音——她不知道是哪個 App，也不知道是誰傳來的。除非有人直接打電話給她，否則她很少能即時回覆訊息，也常常錯過重要的通知。

獨居的長輩最缺的，其實是陪伴。所以我做了 FamilyHelper：

- 家人傳來的文字和語音，會直接**朗讀、播放出來**，比冷冰冰的提示音更有溫度、更有親和力。
- 畫面簡單到外婆自己就能**拍照分享**，家人即使不在身邊，每天也能看到她的狀況。
- 外婆需要幫忙時，按一顆大按鈕就能找到家人；經過她同意後，家人就能遠端協助。

做了這個 App 之後，我們家的凝聚力也變得更好了。

這是我利用晚餐時間 vibe coding 做出來的，所以有些地方還有點簡陋 😂 不過系統功能的設計倒是實際磨合了一整天，邊用邊修正了很多次。

### 告訴我你家長輩的需求

**你家的長輩有什麼需求，是程式可以幫上忙的嗎？** 歡迎開一個 [💡 分享長輩需求](../../issues/new?template=elder_need.yml) Issue，或到 [Discussions](../../discussions) 留言。您有想法，我有實作力——當然，之後就不會只是 vibe coding 了 😄

也歡迎地球村的大家給我任何意見！

---

## 功能

| 長輩版（裝在長輩手機） | 家人版（裝在家人手機，最多 6 台） |
| --- | --- |
| 兩顆巨型按鈕：呼叫家人、SOS（附位置） | 收到呼叫／SOS 推播，一鍵接聽 |
| 每次協助都要本機同意，可隨時停止 | 看長輩畫面、遠端點擊與滑動、視訊對話 |
| 大字留言、家人語音、每日一句 | 長輩狀態：電量、最後上線、通知紀錄 |
| 一鍵拍照分享給家人 | 照片牆，可存到手機相簿 |
| 提醒朗讀（吃藥、喝水…）、久看休息 | 幫長輩設定提醒、天氣朗讀時間 |
| 低電量朗讀提醒 | 低電量通知、顯示哪位家人正在處理 |
| 選用：位置、使用時間、出門到家、健康資料 | 地圖查看、讓長輩手機響鈴 |
| 桌面小工具：呼叫／SOS | — |

所有「分享給家人」的項目都**預設關閉**，要由長輩在自己手機上開啟，也可以隨時暫停。

## 隱私與安全

- **逐次同意**：家人每次要協助，都要長輩在本機按同意，再由 Android 系統詢問螢幕分享。拒絕、鎖屏、停止分享、斷線都會立刻停止控制。
- **系統畫面不能被遠端點擊**：系統設定、權限視窗、安裝程式、本 App 本身都會擋下遠端手勢。
- **畫面不錄影、不上傳**：畫面與聲音以 WebRTC 點對點傳送，不存進資料庫。
- **沒有帳號密碼**：只用六位數配對碼與匿名身分。所有綁定、授權、鎖定都由後端驗證。
- **資料在你自己的 Firebase**：每個家庭各自建立專案。注意：Firebase 專案的管理者（也就是你）看得到資料庫內容。

完整設計請看 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)。

## 開始使用

需要一台電腦（Mac、Windows 或 Linux）來建立後端和打包 App。**不需要會寫程式**，照著設定精靈回答問題就好，大約 30–60 分鐘。

1. **安裝工具**：Flutter、JDK 17、Node.js 22、Python 3（[安裝教學](docs/SETUP.md#1-安裝工具)）
2. **下載專案並執行設定精靈**

   ```bash
   git clone https://github.com/CYC583/FamilyHelper.git
   cd FamilyHelper
   python3 tool/setup.py
   ```

   Windows 的 PowerShell 請改用 `python tool/setup.py`。

   精靈會帶你：登入 Google → 建立 Firebase 專案 → 開啟需要的服務 → 部署後端 → 產生簽章金鑰 → 打包兩個 APK。中途中斷的話，重新執行會從上次的步驟繼續。

3. **安裝到手機**：`dist/familyhelper-host.apk` 裝在長輩手機，`dist/familyhelper-client.apk` 裝在家人手機，再用配對碼連結。

圖文詳解與常見問題：**[docs/SETUP.md](docs/SETUP.md)**

## 費用

Firebase 的 Cloud Functions 需要 **Blaze（用量計費）方案**，要綁定付款方式。一個家庭的用量通常很小，但實際費用依 Google 的計價與你的用量而定，**本專案不保證免費**。建議在 Google Cloud 設定預算提醒。

跨網路連線可以另外設定 Cloudflare TURN（選用），費用依 Cloudflare 計價。

## 限制

- **只支援 Android 8 以上**。iOS 不允許第三方 App 操作其他 App，所以長輩端的遠端點擊無法在 iPhone 上實現。
- **App 是手動安裝的 APK**，沒有上架商店。
- 沒有設定 TURN 時，長輩和家人在不同網路（例如 Wi‑Fi 對行動網路）可能無法分享畫面。
- SOS 只會通知家人，**沒有串接 119 或任何緊急救護機構**。手機關機、沒網路、通知被關閉時，家人可能收不到。
- 健康資料只是同步記錄，**不是醫療監測**。
- 每日提醒排程與後端區域固定為台灣時區，其他地區請見 [ARCHITECTURE 的已知限制](docs/ARCHITECTURE.md#已知限制)。

## 給開發者

```bash
flutter pub get
flutter analyze
flutter test
npm ci --prefix backend/functions && npm test --prefix backend/functions
python3 -m unittest discover -s tool/tests -p 'test_*.py'

# 需要 config/*.json（由 tool/setup.py 產生）才能連到後端
flutter run --flavor host   -t lib/main_host.dart   --dart-define-from-file=config/host.json
flutter run --flavor client -t lib/main_client.dart --dart-define-from-file=config/client.json
```

- 工具版本：Flutter 3.35.7、JDK 17（Firebase Emulator 需 JDK 21）、Node.js 22、Android SDK 36
- 程式結構與安全設計：[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
- 測試方式：[docs/TESTING.md](docs/TESTING.md)
- 參與貢獻：[CONTRIBUTING.md](CONTRIBUTING.md)
- 回報安全問題：[SECURITY.md](SECURITY.md)

## 授權

**© 2026 cyc（原作者）**

本專案以 [PolyForm Noncommercial 1.0.0](https://polyformproject.org/licenses/noncommercial/1.0.0) 加上附加條款授權，詳見 [LICENSE](LICENSE)：

- ✅ 自行下載、建置，安裝給自己的家人使用
- ✅ 改成自己喜歡的介面、新增功能，並以非商業方式分享（須保留原作者標示）
- ❌ **未經作者書面同意，不得上架任何應用程式商店**（Google Play、各品牌商店、第三方 APK 站等）
- ❌ 任何商業用途、商業改編或販售

這是「原始碼公開」授權，不是 OSI 定義的開放原始碼授權。第三方元件依各自的授權，見 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。


**有意合作上架或商業合作？** 歡迎寫信到 **ychen9086@gmail.com**，我們可以長談後續合作與相關事務。
