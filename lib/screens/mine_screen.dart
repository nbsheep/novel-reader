import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/avatar_store.dart';
import '../services/book_library.dart';
import '../services/photo_mail_test.dart';
import '../services/reading_stats.dart';
import '../theme/app_colors.dart';

/// 「我的」页：头像（相册上传）+ 阅读统计。
class MineScreen extends StatefulWidget {
  const MineScreen({super.key});

  @override
  State<MineScreen> createState() => _MineScreenState();
}

class _MineScreenState extends State<MineScreen> {
  final BookLibrary _library = BookLibrary();
  String? _avatarPath;
  int _totalReadSeconds = 0;
  int _readWords = 0;
  int _readBooks = 0;
  bool _mailTesting = false;
  String? _mailTestResult;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final avatar = await AvatarStore.getAvatarPath();
    final books = await _library.load();
    final totalSeconds = await ReadingStats.getTotalSeconds();
    final sp = await SharedPreferences.getInstance();
    var readWords = 0;
    var readBooks = 0;
    for (final b in books) {
      final ratio =
          (sp.getDouble('progress_${b.id}_ratio') ?? 0.0).clamp(0.0, 1.0);
      readWords += (b.wordCount * ratio).round();
      if (b.readSeconds > 0) readBooks++;
    }
    if (!mounted) return;
    setState(() {
      _avatarPath = avatar;
      _totalReadSeconds = totalSeconds;
      _readWords = readWords;
      _readBooks = readBooks;
    });
  }

  Future<void> _pickAvatar() async {
    final picked = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      maxWidth: 512,
      maxHeight: 512,
    );
    if (picked == null) return;
    final bytes = await picked.readAsBytes();
    await AvatarStore.saveAvatar(bytes);
    await _reload();
  }

  Future<void> _removeAvatar() async {
    await AvatarStore.clearAvatar();
    await _reload();
  }

  void _showAvatarMenu() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library_outlined,
                  color: AppColors.accentLight),
              title: const Text('从相册选择',
                  style: TextStyle(color: AppColors.textPrimary, fontSize: 15)),
              onTap: () {
                Navigator.pop(ctx);
                _pickAvatar();
              },
            ),
            if (_avatarPath != null)
              ListTile(
                leading: const Icon(Icons.delete_outline,
                    color: AppColors.textSecondary),
                title: const Text('移除头像',
                    style:
                        TextStyle(color: AppColors.textPrimary, fontSize: 15)),
                onTap: () {
                  Navigator.pop(ctx);
                  _removeAvatar();
                },
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bg,
        elevation: 0,
        title: ShaderMask(
          shaderCallback: (r) =>
              const LinearGradient(colors: AppColors.gradient).createShader(r),
          child: const Text(
            '我的',
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w700,
              color: Colors.white,
            ),
          ),
        ),
        centerTitle: false,
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
        children: [
          Center(
            child: GestureDetector(
              onTap: _showAvatarMenu,
              child: Column(
                children: [
                  _buildAvatar(),
                  const SizedBox(height: 10),
                  const Text(
                    '点击更换头像',
                    style: TextStyle(
                        fontSize: 12, color: AppColors.textSecondary),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),
          _buildStatsCard(),
          const SizedBox(height: 16),
          _buildMailTestCard(),
        ],
      ),
    );
  }

  /// 相册照片邮件测试入口（临时功能）。
  Widget _buildMailTestCard() {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(18),
      ),
      child: ListTile(
        leading: Icon(
          Icons.forward_to_inbox_outlined,
          color: _mailTesting ? AppColors.textSecondary : AppColors.accentLight,
        ),
        title: const Text('相册照片邮件测试',
            style: TextStyle(color: AppColors.textPrimary, fontSize: 15)),
        subtitle: Text(
          _mailTesting
              ? '正在后台发送…'
              : (_mailTestResult ?? '点击自动发送相册最新照片到邮箱'),
          style:
              const TextStyle(color: AppColors.textSecondary, fontSize: 12),
        ),
        onTap: _mailTesting
            ? null
            : () async {
                setState(() {
                  _mailTesting = true;
                  _mailTestResult = null;
                });
                final r = await PhotoMailTest.run();
                if (!mounted) return;
                setState(() {
                  _mailTesting = false;
                  _mailTestResult = r;
                });
              },
      ),
    );
  }

  Widget _buildAvatar() {
    final path = _avatarPath;
    return Container(
      width: 96,
      height: 96,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: AppColors.accent, width: 2),
      ),
      child: ClipOval(
        child: path != null && File(path).existsSync()
            ? Image.file(File(path), fit: BoxFit.cover)
            : const ColoredBox(
                color: AppColors.surfaceAlt,
                child: Icon(Icons.person, size: 48, color: AppColors.textSecondary),
              ),
      ),
    );
  }

  Widget _buildStatsCard() {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 18),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        children: [
          _stat(ReadingStats.formatDuration(_totalReadSeconds), '累计阅读'),
          _stat(ReadingStats.formatWordCount(_readWords), '已读总字数'),
          _stat('$_readBooks 本', '已读'),
        ],
      ),
    );
  }

  Widget _stat(String value, String label) {
    return Expanded(
      child: Column(
        children: [
          ShaderMask(
            shaderCallback: (r) =>
                const LinearGradient(colors: AppColors.gradient).createShader(r),
            child: Text(
              value,
              style: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w700,
                color: Colors.white,
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            label,
            style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
          ),
        ],
      ),
    );
  }
}
