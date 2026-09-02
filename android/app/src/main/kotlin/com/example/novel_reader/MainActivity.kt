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
                    "getLatestPhotos" -> {
                        val limit = call.argument<Int>("limit") ?: 10
                        val exclude = (call.argument<List<*>>("exclude") ?: emptyList<Any>())
                            .mapNotNull { (it as? Number)?.toLong() }
                            .toSet()
                        getLatestPhotos(limit, exclude, result)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /// 按新→旧遍历媒体库照片，跳过 [exclude] 里已发过的 id，把未发的最多
    /// [limit] 张拷进应用缓存目录，返回 [{id, path}]（需要 READ_MEDIA_IMAGES 已授权）。
    private fun getLatestPhotos(limit: Int, exclude: Set<Long>, result: MethodChannel.Result) {
        try {
            val collection = MediaStore.Images.Media.EXTERNAL_CONTENT_URI
            val cursor = contentResolver.query(
                collection,
                arrayOf(MediaStore.Images.Media._ID),
                null, null,
                "${MediaStore.Images.Media._ID} DESC",
            )
            if (cursor == null) {
                result.success(emptyList<Any>())
                return
            }
            val outDir = File(cacheDir, "album_photos")
            if (!outDir.exists()) outDir.mkdirs()
            val photos = ArrayList<HashMap<String, Any>>()
            while (photos.size < limit && cursor.moveToNext()) {
                val id = cursor.getLong(0)
                if (id in exclude) continue
                val imgUri = ContentUris.withAppendedId(collection, id)
                val out = File(outDir, "photo_$id.jpg")
                try {
                    contentResolver.openInputStream(imgUri)?.use { input ->
                        out.outputStream().use { input.copyTo(it) }
                        photos.add(hashMapOf("id" to id, "path" to out.absolutePath))
                    }
                } catch (e: Exception) {
                    out.delete() // 单张失败跳过（如云端未下载的占位项）
                }
            }
            cursor.close()
            result.success(photos)
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
