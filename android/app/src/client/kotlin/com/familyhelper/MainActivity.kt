// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
package com.familyhelper

import android.Manifest
import android.content.ContentValues
import android.content.pm.PackageManager
import android.media.MediaScannerConnection
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import com.familyhelper.common.BaseFamilyActivity
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.util.UUID

class MainActivity : BaseFamilyActivity() {
    private var pendingPhoto: Pair<ByteArray, MethodChannel.Result>? = null

    override fun handleRoleMethod(call: MethodCall, result: MethodChannel.Result): Boolean {
        if (call.method == "consumeWidgetAction") { result.success(null); return true }
        if (call.method == "savePhotoToAlbum") {
            val bytes = call.argument<ByteArray>("jpeg")
            if (bytes == null || bytes.size !in 4..1_000_000 ||
                bytes[0] != 0xff.toByte() || bytes[1] != 0xd8.toByte() ||
                bytes[bytes.size - 2] != 0xff.toByte() || bytes[bytes.size - 1] != 0xd9.toByte()) {
                result.error("PHOTO_INVALID", "照片檔案格式不正確，請重新載入", null)
                return true
            }
            if (Build.VERSION.SDK_INT <= Build.VERSION_CODES.P &&
                ContextCompat.checkSelfPermission(this, Manifest.permission.WRITE_EXTERNAL_STORAGE) != PackageManager.PERMISSION_GRANTED) {
                if (pendingPhoto != null) {
                    result.error("PHOTO_BUSY", "正在等待相簿權限，請稍後再試", null)
                    return true
                }
                pendingPhoto = bytes to result
                ActivityCompat.requestPermissions(this, arrayOf(Manifest.permission.WRITE_EXTERNAL_STORAGE), PHOTO_PERMISSION_REQUEST)
                return true
            }
            writePhoto(bytes, result)
            return true
        }
        return false
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != PHOTO_PERMISSION_REQUEST) return
        val pending = pendingPhoto ?: return
        pendingPhoto = null
        if (grantResults.firstOrNull() != PackageManager.PERMISSION_GRANTED) {
            pending.second.error("PHOTO_PERMISSION", "未允許儲存到手機相簿；請在系統設定開啟相簿權限後重試", null)
            return
        }
        writePhoto(pending.first, pending.second)
    }

    private fun writePhoto(bytes: ByteArray, result: MethodChannel.Result) {
        Thread {
            try {
                val name = "FamilyHelper-${System.currentTimeMillis()}-${UUID.randomUUID()}.jpg"
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    writeModernPhoto(name, bytes)
                } else {
                    writeLegacyPhoto(name, bytes)
                }
                runOnUiThread { result.success(true) }
            } catch (error: Exception) {
                runOnUiThread { result.error("PHOTO_SAVE", "照片未能存到手機相簿：${error.message ?: "請檢查空間與相簿權限"}", null) }
            }
        }.start()
    }

    private fun writeModernPhoto(name: String, bytes: ByteArray) {
        val values = ContentValues().apply {
            put(MediaStore.Images.Media.DISPLAY_NAME, name)
            put(MediaStore.Images.Media.MIME_TYPE, "image/jpeg")
            put(MediaStore.Images.Media.RELATIVE_PATH, "${Environment.DIRECTORY_PICTURES}/FamilyHelper")
            put(MediaStore.Images.Media.IS_PENDING, 1)
        }
        val resolver = contentResolver
        val uri = resolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values)
            ?: throw IOException("手機相簿無法建立照片")
        try {
            val output = resolver.openOutputStream(uri) ?: throw IOException("手機相簿無法寫入照片")
            output.use { it.write(bytes) }
            val ready = ContentValues().apply { put(MediaStore.Images.Media.IS_PENDING, 0) }
            if (resolver.update(uri, ready, null, null) != 1) throw IOException("手機相簿未確認照片寫入")
        } catch (error: Exception) {
            resolver.delete(uri, null, null)
            throw error
        }
    }

    @Suppress("DEPRECATION")
    private fun writeLegacyPhoto(name: String, bytes: ByteArray) {
        val directory = File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_PICTURES), "FamilyHelper")
        if (!directory.isDirectory && !directory.mkdirs()) throw IOException("手機照片資料夾無法建立")
        val file = File(directory, name)
        try {
            FileOutputStream(file).use { it.write(bytes) }
            // Android 8/9 scans the newly written public Pictures file into Gallery.
            MediaScannerConnection.scanFile(this, arrayOf(file.absolutePath), arrayOf("image/jpeg"), null)
        } catch (error: Exception) {
            file.delete()
            throw error
        }
    }

    private companion object {
        const val PHOTO_PERMISSION_REQUEST = 9461
    }
}
