# 安裝教學

這份說明寫給「家裡負責弄手機的人」。不需要會寫程式，但會用到電腦的「終端機」（Mac 的「終端機」App、Windows 的「PowerShell」），只要複製貼上指令即可。

整個流程：

```text
1. 在電腦安裝工具（只要做一次）
2. 執行設定精靈：建立你家的 Firebase、打包 App
3. 把 App 裝到長輩和家人的手機
4. 配對
5. （選用）開啟遠端點擊與其他分享
```

---

## 1. 安裝工具

| 工具 | 用途 | 下載 |
| --- | --- | --- |
| Flutter 3.35.7 | 打包 App | <https://docs.flutter.dev/get-started/install> |
| Android Studio | 提供 Android SDK | <https://developer.android.com/studio> |
| JDK 17 | 編譯 Android | <https://adoptium.net/temurin/releases/?version=17> |
| Node.js 22 | 部署後端 | <https://nodejs.org/> |
| Python 3 | 執行設定精靈 | Mac／Linux 已內建；Windows：<https://www.python.org/downloads/> |
| Git（選用） | 下載專案 | <https://git-scm.com/downloads>，或在 GitHub 頁面按「Code → Download ZIP」 |

安裝完成後，在終端機執行：

```bash
flutter doctor
flutter doctor --android-licenses
```

`flutter doctor` 的 Android 那一行打勾就可以了（iOS、Chrome、Xcode 那幾行不用理會）。

> **Windows 使用者**：以下的 `python3` 請改成 `python`。

## 2. 執行設定精靈

```bash
cd FamilyHelper           # 進入下載的專案資料夾
python3 tool/setup.py --check   # 先檢查工具是否都裝好
python3 tool/setup.py
```

精靈共 9 步，每一步都會說明要做什麼。下面是幾個要在**網頁上手動操作**的地方：

### 2-1. 登入 Google 與建立專案

瀏覽器會打開 Google 登入頁，用你的 Google 帳號登入即可。接著精靈會問專案 ID，例如 `familyhelper-chen`（全球不能重複，只能用小寫英文、數字和減號）。

### 2-2. 升級 Blaze 方案

Cloud Functions 需要 Blaze（用量計費）方案。精靈會打開 Firebase 主控台的方案頁面：

1. 按「修改方案」→ 選「Blaze」
2. 綁定信用卡
3. **建議**：到 [Google Cloud 帳單 → 預算與快訊](https://console.cloud.google.com/billing/budgets) 設定一個小額預算（例如每月 NT$100）並開啟 Email 提醒

一個家庭的使用量通常很小，但費用依實際用量計算，本專案無法保證免費。

### 2-3. 開啟匿名登入

在「Authentication → 登入方式」找到「匿名」，按啟用、儲存。（App 不會出現任何帳號密碼畫面，匿名身分只用來讓後端辨識是哪支手機。）

### 2-4. 建立資料庫

精靈會先嘗試自動建立。如果失敗，在「Realtime Database」按「建立資料庫」、選精靈建議的位置、選「**以鎖定模式啟動**」。之後把頁面上方 `https://…` 的網址貼回精靈。

### 2-5. 建立 Storage（建議）

照片分享和家人語音需要 Storage。按「開始使用」→「以正式版模式啟動」。安全規則會由精靈部署，不需要手動修改。

### 2-6. TURN（選用）

精靈會問要不要設定 Cloudflare TURN。不確定的話先選「n」：同一個 Wi‑Fi 下就能使用。之後若發現長輩在家、你在外面時連不上，再重新執行：

```bash
python3 tool/setup.py --from 6
```

### 2-7. 部署與打包

接下來都是自動的：部署後端（約 5–10 分鐘，中途可能會問要不要啟用 Google API，回答 `Y`）、產生簽章金鑰、打包 App（約 5–15 分鐘）。

完成後，`dist/` 資料夾會有：

- `familyhelper-host.apk`：**長輩版**
- `familyhelper-client.apk`：**家人版**

### ⚠️ 一定要備份的檔案

```text
android/familyhelper-release.jks
android/key.properties
```

這是 App 的簽章金鑰。**遺失後就不能更新已安裝的 App**，只能解除安裝重來，也要全部重新配對。請備份到加密隨身碟或密碼管理器，**不要上傳到 GitHub**（`.gitignore` 已經排除）。

## 3. 安裝到手機

1. 把 APK 傳到手機：LINE「傳檔案」、Google Drive、Email 附件或 USB 都可以
2. 在手機上點開 APK
3. 系統會問「是否允許安裝未知來源的應用程式」→ 允許（只允許你用來開檔案的那個 App 即可）
4. 安裝完成後打開，依畫面指示允許通知、相機、麥克風

| 手機 | 安裝 |
| --- | --- |
| 長輩的手機 | `familyhelper-host.apk`（App 名稱「FamilyHelper 長輩」） |
| 每位家人的手機 | `familyhelper-client.apk`（App 名稱「FamilyHelper 家人」） |

## 4. 配對

1. **長輩手機**：右上角齒輪「家人設定」→「產生配對碼」，畫面上會出現六位數字（5 分鐘內有效、只能用一次）
2. **家人手機**：輸入自己的名字（長輩會看到這個稱呼）和六位數字 →「配對」
3. 每位家人都要重新產生一組新的配對碼。最多 6 位家人

## 5. 長輩手機的建議設定

都在長輩手機「家人設定」裡，**要在長輩手機上親自操作**：

| 設定 | 為什麼 |
| --- | --- |
| **允許遠端點擊** | 開啟後家人才能在畫面上幫忙點。App 會先說明，再帶你到系統的「無障礙」設定，找到 FamilyHelper 並開啟 |
| **電池設定** | 把 FamilyHelper 設為「不受限制」，避免系統把 App 關掉而收不到呼叫 |
| **SOS 位置權限** | 按 SOS 時才能附上位置 |
| 分享位置／使用時間／電量／照片 | 選用，預設都關閉 |

Samsung、OPPO、小米等品牌另外有自己的省電設定，如果發現常常收不到通知，請搜尋「（手機品牌）App 背景執行 不受限制」。

## 6. 之後要更新 App

修改程式或拉取新版本後：

1. 把 `pubspec.yaml` 的 `version:` 最後的數字加 1（例如 `1.6.1+14` → `1.6.2+15`）
2. 重新打包：`python3 tool/build_apks.py`
3. 把新的 APK 裝到手機上（直接覆蓋安裝，資料和配對都會保留）

後端有變更時：`python3 tool/setup.py --from 7`（重新部署＋打包）。

---

## 常見問題

**Q：設定精靈中途失敗或關掉了怎麼辦？**
重新執行 `python3 tool/setup.py`，會從失敗的那一步繼續。要從某一步重來：`python3 tool/setup.py --from 步驟編號`。

**Q：App 打開顯示「這個 App 還沒設定完成」？**
代表打包時沒有 Firebase 設定。請用精靈或 `python3 tool/build_apks.py` 重新打包，不要直接用 `flutter build`。

**Q：按了「呼叫家人」，家人沒收到通知？**
請依序檢查：家人手機的通知權限、兩支手機的省電設定（設為不受限制）、手機是否有網路、手機上是否有 Google Play 服務。

**Q：同意協助後，家人一直看不到畫面？**
如果兩支手機在不同網路，可能需要 TURN，見 [2-6](#2-6-turn選用)。先讓兩支手機連同一個 Wi‑Fi 測試看看。

**Q：家人點畫面沒有反應？**
長輩手機要開啟「允許遠端點擊」（無障礙服務）。另外，系統設定、權限視窗、銀行 App 等敏感畫面本來就會被擋下，這是刻意的保護設計。

**Q：可以用 iPhone 嗎？**
目前不行。iOS 不允許 App 操作其他 App，長輩端的核心功能無法實作。

**Q：長輩換手機或重設手機了？**
每個 Firebase 專案只允許一個長輩身分，新手機會顯示「長輩端已設定，請聯絡管理者」。最簡單的處理方式：到 Firebase 主控台的 Realtime Database，刪除整個 `core` 節點，再讓長輩的新手機和所有家人手機重新開啟 App、重新配對。（照片、提醒等 `care` 資料不受影響，但會對應到舊身分，需要重新設定。）

**Q：我想把 App 分享給朋友的家庭用？**
請讓對方自己執行設定精靈、建立他們自己的 Firebase。不要把你的 APK 給別人，否則他們的資料會進到你的 Firebase，費用也由你支付。

**Q：可以上架到 Google Play 嗎？**
本專案授權禁止未經作者同意上架任何商店，見 [LICENSE](../LICENSE)。
