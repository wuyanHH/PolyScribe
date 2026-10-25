import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../../core/constants/app_colors.dart';
import '../../core/constants/app_constants.dart';
import '../../core/theme/app_theme_provider.dart';
import '../../data/database/app_database.dart';
import '../../engine/model_manager.dart';
import '../../engine/models/model_package_info.dart';
import '../../services/model_download_service.dart';
import '../../services/server/http_server.dart';
import '../models/model_manager_screen.dart';
import 'subpages/about_screen.dart';
import 'subpages/audio_tuning_settings_screen.dart';
import 'subpages/server_settings_screen.dart';
import 'subpages/storage_settings_screen.dart';
import 'subpages/theme_settings_screen.dart';

/// 系统中枢与偏好设置主页面 (规范分组二级菜单架构 / 移动端与桌面端自适应)
class SettingsScreen extends ConsumerStatefulWidget {
  final LocalHttpServer? localHttpServer;
  final VoidCallback? onToggleServer;

  const SettingsScreen({
    super.key,
    this.localHttpServer,
    this.onToggleServer,
  });

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  int _installedModelsCount = 0;
  final int _totalModelsCount = PredefinedModels.all.length;
  String _preferredLanguage = 'zh';
  String _dbSizeText = '计算中...';
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadSettingsData();
  }

  Future<void> _loadSettingsData() async {
    await ModelManager.instance.resolveModels();

    // 检查已就绪模型数
    int readyCount = 0;
    for (final m in PredefinedModels.all) {
      final ok = await ModelDownloadService.instance.checkInstalled(m);
      if (ok) readyCount++;
    }

    final dbDir = await getApplicationDocumentsDirectory();
    final dbFile = File(p.join(dbDir.path, 'polyscribe.db'));

    String sizeStr = '0 KB';
    if (dbFile.existsSync()) {
      final bytes = await dbFile.length();
      sizeStr = bytes > 1024 * 1024
          ? '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB'
          : '${(bytes / 1024).toStringAsFixed(1)} KB';
    }

    final savedLang = await AppDatabase.instance.getSetting('preferred_language') ?? 'zh';

    if (mounted) {
      setState(() {
        _installedModelsCount = readyCount;
        _dbSizeText = sizeStr;
        _preferredLanguage = savedLang;
        _isLoading = false;
      });
    }
  }

  String _getLanguageLabel(String lang) {
    switch (lang) {
      case 'zh':
        return '简体中文 (首选)';
      case 'en':
        return '强制英文';
      case 'auto':
      default:
        return '自动感应 (中/英/粤/日/韩)';
    }
  }

  String _getThemeLabel(ThemeMode mode) {
    switch (mode) {
      case ThemeMode.light:
        return '明亮清新 (浅色)';
      case ThemeMode.dark:
        return '深色沉浸 (夜间)';
      case ThemeMode.system:
        return '跟随设备系统';
    }
  }

  @override
  Widget build(BuildContext context) {
    final currentTheme = ref.watch(themeModeProvider);
    final isCompact = MediaQuery.of(context).size.width < 640;
    final isServerRunning = widget.localHttpServer?.isRunning ?? false;
    final allModelsReady = _installedModelsCount >= _totalModelsCount;

    return Scaffold(
      backgroundColor: context.bg,
      appBar: AppBar(
        backgroundColor: context.surfaceColor,
        elevation: 0,
        title: Row(
          children: [
            const Icon(Icons.tune_rounded, color: AppColors.primary, size: 22),
            const SizedBox(width: 10),
            Text(
              '系统与偏好设置',
              style: TextStyle(fontSize: 16.5, fontWeight: FontWeight.bold, color: context.textMain),
            ),
          ],
        ),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 820),
                child: ListView(
                  padding: EdgeInsets.symmetric(
                    horizontal: isCompact ? 14 : 20,
                    vertical: isCompact ? 14 : 20,
                  ),
                  physics: const BouncingScrollPhysics(),
                  children: [
                    // 分组 1: 外观与个性化
                    _buildSectionHeader('外观与个性化'),
                    _buildGroupCard(
                      children: [
                        _buildNavigationTile(
                          icon: Icons.palette_rounded,
                          iconColor: const Color(0xFF8B5CF6),
                          title: '视觉外观与主题风格',
                          subtitle: _getThemeLabel(currentTheme),
                          onTap: () {
                            Navigator.of(context).push(
                              MaterialPageRoute(builder: (_) => const ThemeSettingsScreen()),
                            ).then((_) => _loadSettingsData());
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 18),

                    // 分组 2: AI 推理与语音引擎
                    _buildSectionHeader('AI 推理与语音引擎'),
                    _buildGroupCard(
                      children: [
                        _buildNavigationTile(
                          icon: Icons.memory_rounded,
                          iconColor: AppColors.primary,
                          title: 'AI 离线模型管理中心',
                          subtitle: allModelsReady
                              ? '全部模型已就绪 ($_installedModelsCount/$_totalModelsCount)'
                              : '存在待部署模型 ($_installedModelsCount/$_totalModelsCount)',
                          trailingBadge: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                            decoration: BoxDecoration(
                              color: (allModelsReady ? AppColors.emerald : AppColors.amber).withValues(alpha: 0.16),
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(
                                color: (allModelsReady ? AppColors.emerald : AppColors.amber).withValues(alpha: 0.4),
                              ),
                            ),
                            child: Text(
                              allModelsReady ? '已就绪' : '待补齐',
                              style: TextStyle(
                                color: allModelsReady ? AppColors.emerald : AppColors.amber,
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                          onTap: () {
                            Navigator.of(context).push(
                              MaterialPageRoute(builder: (_) => const ModelManagerScreen()),
                            ).then((_) => _loadSettingsData());
                          },
                        ),
                        Divider(height: 1, indent: 52, color: context.borderColor),
                        _buildNavigationTile(
                          icon: Icons.tune_rounded,
                          iconColor: AppColors.amber,
                          title: '音频采样与识别调优',
                          subtitle: '${_getLanguageLabel(_preferredLanguage)} · VAD 0.8s 断句 · 抗漂移',
                          onTap: () {
                            Navigator.of(context).push(
                              MaterialPageRoute(builder: (_) => const AudioTuningSettingsScreen()),
                            ).then((_) => _loadSettingsData());
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 18),

                    // 分组 3: 网络与服务互通
                    _buildSectionHeader('网络与服务互通'),
                    _buildGroupCard(
                      children: [
                        _buildNavigationTile(
                          icon: Icons.wifi_tethering_rounded,
                          iconColor: AppColors.cyan,
                          title: '本地 STT API 服务中枢',
                          subtitle: isServerRunning
                              ? '运行中 (监听端口: ${AppConstants.defaultServerPort})'
                              : '已停止待机 · 兼容 OpenAI Whisper 接口',
                          trailingBadge: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                            decoration: BoxDecoration(
                              color: (isServerRunning ? AppColors.emerald : AppColors.textMuted).withValues(alpha: 0.16),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Container(
                                  width: 6,
                                  height: 6,
                                  decoration: BoxDecoration(
                                    color: isServerRunning ? AppColors.emerald : AppColors.textMuted,
                                    shape: BoxShape.circle,
                                  ),
                                ),
                                const SizedBox(width: 5),
                                Text(
                                  isServerRunning ? '在线' : '待机',
                                  style: TextStyle(
                                    color: isServerRunning ? AppColors.emerald : AppColors.textMuted,
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          onTap: () {
                            Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => ServerSettingsScreen(
                                  localHttpServer: widget.localHttpServer,
                                  onToggleServer: widget.onToggleServer,
                                ),
                              ),
                            ).then((_) => setState(() {}));
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 18),

                    // 分组 4: 数据存储与空间维护
                    _buildSectionHeader('数据存储与维护'),
                    _buildGroupCard(
                      children: [
                        _buildNavigationTile(
                          icon: Icons.storage_rounded,
                          iconColor: AppColors.emerald,
                          title: '数据存储与空间维护',
                          subtitle: 'SQLite 数据库占用: $_dbSizeText · 支持紧缩优化',
                          onTap: () {
                            Navigator.of(context).push(
                              MaterialPageRoute(builder: (_) => const StorageSettingsScreen()),
                            ).then((_) => _loadSettingsData());
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 18),

                    // 分组 5: 软件信息与关于
                    _buildSectionHeader('软件信息与支持'),
                    _buildGroupCard(
                      children: [
                        _buildNavigationTile(
                          icon: Icons.info_outline_rounded,
                          iconColor: const Color(0xFFA855F7),
                          title: '关于 ${AppConstants.appFullName} (${AppConstants.appEnglishName})',
                          subtitle: '当前版本 ${AppConstants.appVersion} · 检查更新与发版历史',
                          trailingBadge: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                            decoration: BoxDecoration(
                              color: AppColors.primaryGlow,
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(color: AppColors.primary.withValues(alpha: 0.3)),
                            ),
                            child: const Text(
                              AppConstants.appVersion,
                              style: TextStyle(
                                color: AppColors.primary,
                                fontSize: 11,
                                fontFamily: 'monospace',
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                          onTap: () {
                            Navigator.of(context).push(
                              MaterialPageRoute(builder: (_) => const AboutScreen()),
                            );
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 36),
                  ],
                ),
              ),
            ),
    );
  }

  /// 分组标题
  Widget _buildSectionHeader(String title) {
    return Builder(
      builder: (context) {
        return Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 8),
          child: Text(
            title,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.bold,
              color: context.textGrey,
              letterSpacing: 0.5,
            ),
          ),
        );
      },
    );
  }

  /// 分组外壳卡片
  Widget _buildGroupCard({required List<Widget> children}) {
    return Builder(
      builder: (context) {
        return Container(
          decoration: BoxDecoration(
            color: context.surfaceColor,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: context.borderColor),
          ),
          child: Column(
            children: children,
          ),
        );
      },
    );
  }

  /// 标准二级导航条目 (带有左侧图标、标题、副标题、徽章与右侧箭头)
  Widget _buildNavigationTile({
    required IconData icon,
    required Color iconColor,
    required String title,
    required String subtitle,
    Widget? trailingBadge,
    required VoidCallback onTap,
  }) {
    return Builder(
      builder: (context) {
        return Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: iconColor.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(icon, color: iconColor, size: 20),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                            color: context.textMain,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 3),
                        Text(
                          subtitle,
                          style: TextStyle(
                            fontSize: 11.5,
                            color: context.textGrey,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  if (trailingBadge != null) ...[
                    const SizedBox(width: 8),
                    trailingBadge,
                  ],
                  const SizedBox(width: 6),
                  Icon(Icons.arrow_forward_ios_rounded, size: 14, color: context.textGrey),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
