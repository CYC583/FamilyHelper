# 架構與安全設計

給想了解或修改 FamilyHelper 的開發者。以下參數是設計值，以原始碼為準；技術依據列在文末。

## 整體架構

```text
長輩手機（host APK）                家人手機（client APK，最多 6 台）
  Flutter UI                          Flutter UI
  Kotlin：無障礙、螢幕分享、Widget      
        │  WebRTC：畫面／視訊／聲音／點擊（點對點，必要時經 TURN）│
        └──────────────────────────────────────────────────────┘
        │                                      │
        └──── Firebase（每個家庭自己的專案）────┘
              匿名 Auth · Realtime Database（信令、狀態）
              Cloud Functions（配對、授權、鎖定、推播）
              Cloud Storage（照片、語音，選用）· FCM 推播
```

程式位置：

| 範圍 | 位置 |
| --- | --- |
| 兩端入口 | `lib/main_host.dart`、`lib/main_client.dart` |
| 長輩端／家人端畫面 | `lib/app/host/`、`lib/app/client/` |
| 共用：連線、Firebase、設計系統 | `lib/app/common/`（設計系統在 `common/ui/`） |
| Android 原生 | `android/app/src/{main,host,client}/kotlin/` |
| 後端 Functions | `backend/functions/src/`（純狀態邏輯在 `*_state.js`，有單元測試） |
| 資料庫與 Storage 規則 | `backend/database.rules.json`、`backend/storage.rules` |
| 設定、打包工具 | `tool/` |

## 資料分工

| 資料 | 路徑／傳送方式 | 讀寫權限 |
| --- | --- | --- |
| 匿名裝置角色、名稱 | `/core/devices/{uid}` | Functions 寫；本裝置讀 |
| client → host 綁定 | `/core/links/{clientUid}` | Functions 寫；該 client 讀 |
| 配對碼的 HMAC | `/core/pairCodes/{hmac}` | 只有 Functions |
| 成員、通知、健康最新資料 | `/core/families/{hostUid}` | Functions 寫；host 與目前綁定成員讀 |
| 連線狀態 | `/core/sessions/{sessionId}` | Functions 寫；host 與當次仍綁定的 client 讀 |
| SDP／ICE | `/signals/{sessionId}` | 僅被接受且未逾時的當次雙方；offer/answer/ICE 各自限寫 |
| FCM token | `/pushTokens/{uid}` | 只有 Functions；不讓家人直接讀他人 token |
| 螢幕、相機、聲音 | WebRTC | 當次雙方；無直連時經 TURN |
| 點擊與大字訊息 | WebRTC DataChannel | 當次雙方；host 再做 native 驗證 |

不會把螢幕或影音錄影存入 Firebase。Firebase 管理員仍能存取資料庫中的信令、位置、健康與事件；本系統不是對 Firebase 管理員隱藏這些資料的零知識系統。

後端以 `/core` 的一個 RTDB transaction 更新配對、成員和鎖定，避免在兩個無法原子同步的節點各寫一半。這適合「一個家庭一個 Firebase 專案」的小規模用量；不適合把多個家庭放在同一個專案當公眾服務，因為共用根 transaction 與定期清理成本會隨資料量成長。

## 配對與身分

- Firebase Anonymous Auth UID 代表安裝實例，不是假造的 deviceId。沒有登入表單。
- 已註冊角色不可改變。每台 client 綁定一個 host；一個 host 最多 6 台 client（`MAX_FAMILY_CLIENTS`），第七台拒絕。每個 Firebase 專案只允許一個 host 身分，整體註冊裝置上限 16 個（含重裝）；新裝置同來源 IP 雜湊每日最多 10 次註冊。這些是費用／濫用緩解，不是可抵禦分散式攻擊的硬成本上限。
- 配對碼由 Node `crypto.randomInt` 產生，保留前導零。有效期 5 分鐘，成功一次即刪除。
- 每台 client 在 10 分鐘內最多 5 次輸入；同來源 IP 雜湊另有限流。失敗猜碼也會消耗次數。
- 配對碼以伺服器密鑰 HMAC 儲存，不以可離線窮舉的裸 SHA-256 儲存。
- 每位家人配對都需 host 重新產生新碼。滿 6 台後必須先解除舊裝置。
- 解除配對會取消當次連線與權限；退出 client App 或重開手機不會解除。
- 清除 App 資料／解除安裝會失去匿名身分，client 需重新配對。host 清除資料後不能自行建立第二個家庭主機，須由該 Firebase 專案的管理者在主控台處理舊身分；勿直接清空整個資料庫。
- 沒有啟用 App Check 強制驗證，避免把側載 App 綁死於未配置的驗證供應商。仍有應用層授權與限流；若改成對公眾提供，需另設適合發佈模式的驗證與濫用防護。

## 一次連線的狀態

`pending → accepted → ended`；或 `pending → rejected / expired`。

1. 已配對 client 呼叫 `requestHelp`，transaction 檢查目前是否有有效 pending／accepted。
2. 請求先占用唯一位置，避免兩個同意框同時出現。等待上限 90 秒。
3. host 在前景顯示原生大字確認框；僅本機按鈕能建立記憶體中的 ConsentGate。
4. 同意後，後端記錄 accepted；host 每次另呼叫 `requestCapturePermission(fullScreenOnly: true)`。
5. 得到 Android 新授權後，啟動 mediaProjection 前台服務，再以同一份 token 擷取。
6. 雙方取得相機與麥克風權限，啟動 camera/microphone 前台服務，交換 offer/answer/ICE。
7. 相機與聲音先加入 PeerConnection；螢幕使用獨立的 send-only track 和 stream ID。
8. WebRTC DataChannel 建立後，才開始遠端輸入。没有新的本機同意，不自動重新連線。

後端雙方各 10 秒送一次心跳，連線租約取較舊一方心跳加 45 秒；任一方不能單獨永遠續約。每次同意最多 30 分鐘。native 控制另由約 2 秒的 DataChannel 心跳維持，斷訊約 9 秒即停用；尚未建立通道的起始寬限為 60 秒。

只要 SDK 回報中斷、使用者結束、鎖屏或系統撤銷螢幕分享，就直接清除 native 控制權；後端結束通知失敗時仍保留租約過期作為兜底。Timer 在系統負載或排程暫停時不是精確計時保證。

## 遠端輸入協定

```json
{
  "type": "swipe",
  "sessionId": "當次連線的隨機 ID",
  "seq": 12,
  "x": 0.5,
  "y": 0.8,
  "x2": 0.5,
  "y2": 0.2,
  "width": 1080,
  "height": 2400,
  "rotation": 0
}
```

上例的解析度、序號與座標僅是協定示例。client 使用 `contain` 顯示畫面，先扣除黑邊，再換算 0～1 座標。native 重新確認當前尺寸與方向、座標是否有限數、session ID、遞增序號、當前本機同意、心跳、鎖屏及前景套件；不接受任意 Accessibility action 或任意鍵碼。

Accessibility 只以視窗狀態及最上層視窗的套件名稱判定前景 App。為讀取最上層套件身分，Android 服務宣告 `canRetrieveWindowContent=true`；這是較強的系統能力，長輩須在系統設定親自開啟，App 內已清楚揭露。實作不讀取 UI 文字、不抓取節點樹、不讀取密碼。每次遠端協助仍須長輩本機同意並授予 Android 當次螢幕分享；長輩可隨時停止分享。App 自己、系統設定、System UI、權限控制器與安裝程式拒絕遠端手勢。App 清單為保守的套件名稱防護，不應宣稱能識別所有 OEM／第三方敏感畫面；銀行或其他 App 的受保護畫面可能無法分享，這是預期限制。

## Android 原生模組

| 檔案 | 職責 |
| --- | --- |
| `ConsentGate.kt` | 記憶體內一次性同意、session、心跳、序號檢查 |
| `HostAccessibilityService.kt` | 原生 tap／longPress／swipe；禁止敏感系統畫面 |
| `MediaCaptureService.kt` | 分享中的前台通知與 native 斷訊 watchdog |
| `ForegroundCallService.kt` | 兩種 flavor 通話中的相機／麥克風前台服務 |
| `ForegroundHelperService.kt` | host 自願開啟的待命通知；不錄音、不定位、不分享 |
| `MainActivity.kt` | 本機大按鈕確認、MethodChannel、螢幕停止及鎖屏事件 |
| `WidgetActionActivity.kt` | 不對其他 App 開放的 Widget 入口 |
| `HealthBridge.kt` | 可選 Health Connect 權限與前景讀取 |

Widget 使用 immutable PendingIntent 進入 `exported=false` Activity，再交給 App 處理。對外開放的 launcher 不接受任意 `widget_action` 來冒發 SOS，也不接受任何通知 payload 自動開啟控制。

## flutter_webrtc 最小修補

固定套件 `1.6.2+hotfix.3` 的 Android `GetUserMediaImpl.java` 在 MediaProjection `onStop` 尚未將停止事件告知此 App。專案保存相同版本完整原檔及 MIT 授權，僅加入 package-scoped 的 `CAPTURE_STOPPED` 廣播與擷取世代檢查。

Gradle 在 flutter_webrtc 子專案的 source set 排除上游該檔，再加入 `android/webrtc_patch/GetUserMediaImpl.java`。不改動全域 Pub cache。host 的 receiver 不對其他 App 開放；舊擷取的停止回呼不可關掉新的擷取。

升級 flutter_webrtc 時務必重新比較上游原檔並重作此小修補，不可只改 pubspec 版本。原始來源與 SHA-256 見該目錄的 `README.md`。

## TURN 與網路

- 使用可信任的自有 TURN／相同 REST 認證的服務；secret 只留在 Functions Secret Manager。
- coturn 要啟用 `use-auth-secret`、相同 `static-auth-secret`、正確 realm／外網地址／relay port 防火牆規則。
- 如需 `turns:`，配置可驗證的 TLS 憑證與 TCP/TLS listener；不要把無效憑證錯誤當成一般網路問題。
- `TURN_URL` 可填像 `turn:你的主機:3478?transport=udp,turns:你的主機:5349?transport=tcp`；這是格式示例，不是可用服務。
- 正式使用前要以不同網路、行動網路與 Wi-Fi 實測；必要時於測試版暫設 `iceTransportPolicy: relay` 確認真的使用 TURN，再恢復正常選路。
- 不把長期 TURN 使用者密碼打包進 client；後端只向當次已接受的參與者發出限時憑證。

## 通知、健康與保留

FCM「接受發送」與「家人按確認收到」是不同狀態。App 被強制停止、通知權限被關閉、Google Play services 不可用、網路離線、OEM 省電都可能影響收到通知。待命服務與關閉電池最佳化不能保證永遠在線。

位置只在 SOS 前景操作中取得，若超過等待時間或未授權，不阻擋通知。FCM 通知標題、內文與 data 不含位置；有權限的目前配對成員開啟 App 後才從 RTDB 查看。推播前會重新讀取成員，縮小解除配對競爭窗口，但無法撤回已交給 FCM 的通知；若競爭發生，通知仍只有通用訊息。

健康同步預設關閉；只讀取 `com.sec.android.app.shealth` 的最近記錄。健康資料可能延遲；來源無資料時保留空值。心率與血氧提醒只檢查 15 分鐘以內的新記錄；相同樣本及 15 分鐘內重複提醒會被抑制。這些是避免舊資料與通知洗版的設計值，不是醫療標準。

定期清理：每 6 小時檢查一次，無過期 core 資料時跳過交易；pair codes 和限流記錄過期即清；結束／過期連線信令於排程清理；session 記錄保留約一天；SOS／呼叫／健康通知保留約七天。健康最新值保留到下次更新或使用者停用清除。裝置與綁定記錄不自動刪除，達 16 台須由管理者處理。排程間隔與失敗會影響實際刪除時間；連線授權由規則與租約即時判斷，不依賴排程準時執行。

## 已知限制

- 只支援 Android。iOS 不允許第三方 App 操作其他 App，長輩端的遠端點擊無法在 iPhone 實作。
- 每日提醒排程（`careDaily`）與後端 Functions 區域固定為台灣時區 `Asia/Taipei`／`asia-east1`。其他地區要同時修改 `backend/functions/src/index.js` 與 `lib/app/common/constants.dart`。
- 健康資料只讀 Samsung Health 經 Health Connect 的記錄，且只在 App 開啟時同步。
- 沒有 TURN 時，跨網路（例如 Wi‑Fi 對行動網路）的畫面分享可能失敗。

## 官方來源

查閱於 2026-09-30；程式碼與設計值以此專案檔案為準。

- [Android MediaProjection](https://developer.android.com/media/grow/media-projection)
- [Android 前台服務類型](https://developer.android.com/develop/background-work/services/fgs/service-types)
- [Android AccessibilityService](https://developer.android.com/reference/android/accessibilityservice/AccessibilityService)
- [Firebase callable functions](https://firebase.google.com/docs/functions/callable)
- [Firebase RTDB 安全規則](https://firebase.google.com/docs/database/security)
- [Firebase Functions 部署條件](https://firebase.google.com/docs/functions/get-started)
- [WebRTC TURN](https://webrtc.org/getting-started/turn-server)
- [flutter_webrtc changelog](https://pub.dev/packages/flutter_webrtc/changelog)
- [Health Connect](https://developer.android.com/health-and-fitness/health-connect/get-started)
- [AGP 8.10／Gradle／JDK 相容性](https://developer.android.com/build/releases/agp-8-10-0-release-notes)
