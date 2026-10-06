// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
package com.familyhelper.health

import android.app.Activity
import android.os.Bundle
import android.widget.TextView

class PrivacyActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(TextView(this).apply {
            textSize = 24f; setPadding(32, 48, 32, 32)
            text = "FamilyHelper 健康資料說明\n\n僅在您啟用後，讀取 Samsung Health 寫入 Health Connect 的心率、血氧及睡眠區間。\n\n最新資料及時間會傳到您設定的 Firebase，僅此手機及已配對家人可以讀取。\n\n不寫入 Health Connect，不用於廣告或診斷。此版本只有 App 在前景時更新，不保證即時告警。\n\n可在 App 設定停用並清除雲端最新資料，亦可在系統 Health Connect 撤銷讀取權限。"
        })
    }
}
