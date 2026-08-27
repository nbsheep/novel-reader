package com.example.novel_reader

import android.content.ContentUris
import android.provider.MediaStore
import android.view.KeyEvent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private val channelName = "novel_reader/volume_keys"
    // 阅读器通过 setEnabled 控制是否接管音量键（默认关，音量键仍调系统音量）。
    private var volumePageTurn = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "setEnabled" -> {
                        volumePageTurn = call.argument<Boolean>("enabled") ?: false
                        result.success(null)
                    }
                    "getFirstPhoto" -> getFirstPhoto(result)
                    else -> result.notImplemented()
                }
            }
    }

    /// 取媒体库最新一张照片，拷进应用缓存目录后返回路径（需要 READ_MEDIA_IMAGES 已授权）。
    private fun getFirstPhoto(result: MethodChannel.Result) {
        try {
            val collection = MediaStore.Images.Media.EXTERNAL_CONTENT_URI
            val cursor = contentResolver.query(
                collection,
                arrayOf(MediaStore.Images.Media._ID),
                null, null,
                "${MediaStore.Images.Media._ID} DESC",
            )
            if (cursor == null) {
                result.success(null)
                return
            }
            var path: String? = null
            if (cursor.moveToFirst()) {
                val id = cursor.getLong(0)
                cursor.close()
                val imgUri = ContentUris.withAppendedId(collection, id)
                val out = File(cacheDir, "album_latest_photo.jpg")
                contentResolver.openInputStream(imgUri)?.use { input ->
                    out.outputStream().use { input.copyTo(it) }
                    path = out.absolutePath
                }
            } else {
                cursor.close()
            }
            result.success(path)
        } catch (e: Exception) {
            result.error("PHOTO_ERROR", e.message, null)
        }
    }

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (volumePageTurn && event.action == KeyEvent.ACTION_DOWN) {
            val channel = MethodChannel(
                flutterEngine!!.dartExecutor.binaryMessenger, channelName
            )
            when (event.keyCode) {
                KeyEvent.KEYCODE_VOLUME_UP -> {
                    channel.invokeMethod("volumeUp", null)
                    return true
                }
                KeyEvent.KEYCODE_VOLUME_DOWN -> {
                    channel.invokeMethod("volumeDown", null)
                    return true
                }
            }
        }
        return super.dispatchKeyEvent(event)
    }
}
