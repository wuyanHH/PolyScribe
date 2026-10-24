import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../../core/constants/app_colors.dart';
import '../../core/constants/app_constants.dart';
import '../../core/theme/app_theme_provider.dart';
import '../../core/utils/app_toast.dart';
import '../../data/database/app_database.dart';
import '../../engine/model_manager.dart';
import '../../services/keep_alive_service.dart';
import '../../services/server/http_server.dart';
import '../models/model_manager_screen.dart';
import '../server/server_console_screen.dart';

/// 系统中枢与偏好设置页面 (深度现代化重构 / 桌面端居中自适应 / 精致微质感卡片)
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
  ModelConfig? _modelConfig;
  double _vadSilenceThreshold = 0.8;
  bool _enableDriftSuppression = true;
  String _preferredLanguage = 'auto';
  bool _autoResumeTranscription = true;
  String _dbSizeText = '计算中...';
  String _dbDirPath = '';
  bool _isVacuuming = false;

  @override
  void initState() {
    super.initState();
    _loadSettingsData();
  }

  Future<void> _loadSettingsData() async {
    final config = await ModelManager.instance.resolveModels();
    final dbDir = await getApplicationDocumentsDirectory();
    _dbDirPath = dbDir.path;
    final dbFile = File(p.join(dbDir.path, 'polyscribe.db'));

    String sizeStr = '0 KB';
    if (dbFile.existsSync()) {
      final bytes = await dbFile.length();
      sizeStr = bytes > 1024 * 1024
          ? '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB'
          : '${(bytes / 1024).toStringAsFixed(1)} KB';
    }

    final savedLang = await AppDatabase.instance.getSetting('preferred_language') ?? 'zh';
    final autoResumeVal = await AppDatabase.instance.getSetting('auto_resume_transcription');
    final autoResume = autoResumeVal == null ? true : (autoResumeVal == 'true');

    if (mounted) {
      setState(() {
        _modelConfig = config;
        _dbSizeText = sizeStr;
        _preferredLanguage = savedLang;
        _autoResumeTranscription = autoResume;
      });
    }
  }

  Future<void> _vacuumDatabase() async {
    if (_isVacuuming) return;
    setState(() => _isVacuuming = true);

    try {
      final db = await AppDatabase.instance.database;
      await db.execute('VACUUM');
      await _loadSettingsData();
      if (mounted) {
        AppToast.success(context, 'SQLite 数据库紧缩与索引碎片清理完成');
      }
    } catch (e) {
      if (mounted) {
        AppToast.error(context, '优化失败: $e');
      }
    } finally {
      if (mounted) {
        setState(() => _isVacuuming = false);
      }
    }
  }

  /// 在系统资源管理器中打开数据文件夹
  void _openDataDirectory() {
    if (_dbDirPath.isNotEmpty && Platform.isWindows) {
      Process.run('explorer.exe', [_dbDirPath]);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isVadReady = _modelConfig?.isVadReady ?? false;
    final isAsrReady = _modelConfig?.isSenseVoiceReady ?? false;
    final allModelsReady = isVadReady && isAsrReady;
    final isServerRunning = widget.localHttpServer?.isRunning ?? false;
    final currentTheme = ref.watch(themeModeProvider);
    final isCompact = MediaQuery.of(context).size.width < 600;

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        elevation: 0,
        titleSpacing: isCompact ? 12 : 20,
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(7),
              decoration: BoxDecoration(
                color: AppColors.primary.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(Icons.settings_suggest_rounded, color: AppColors.primary, size: 19),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '系统与中枢设置',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (!isCompact)
                    const Text(
                      '视觉外观 · AI 引擎 · 采样调优 · 局域网服务 · 存储管理',
                      style: TextStyle(fontSize: 11, color: AppColors.textMuted),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 860),
          child: ListView(
            padding: EdgeInsets.symmetric(horizontal: isCompact ? 14 : 20, vertical: isCompact ? 16 : 24),
            physics: const BouncingScrollPhysics(),
            children: [
              // 1. 视觉外观与主题风格 (深浅色高质感 Tab)
              _buildSectionTitle(
                title: '视觉外观与主题风格',
                subtitle: '深浅模式切换、系统动态感应与调色板布局',
                icon: Icons.palette_rounded,
                iconColor: const Color(0xFF8B5CF6),
              ),
              const SizedBox(height: 10),
              _buildThemeSelectorCard(currentTheme, isCompact: isCompact),
              SizedBox(height: isCompact ? 20 : 28),

              // 2. AI 离线模型中枢
              _buildSectionTitle(
                title: 'AI 离线模型中枢',
                subtitle: '本地神经网络推理资产管理与自检',
                icon: Icons.memory_rounded,
                iconColor: AppColors.primary,
              ),
              const SizedBox(height: 10),
              _buildModelCenterCard(allModelsReady, isCompact: isCompact),
              SizedBox(height: isCompact ? 20 : 28),

              // 3. 音频采样与识别调优
              _buildSectionTitle(
                title: '音频采样与识别调优',
                subtitle: 'VAD 端点检测灵敏度、角色抗漂移与语种偏好',
                icon: Icons.tune_rounded,
                iconColor: AppColors.amber,
              ),
              const SizedBox(height: 10),
              _buildAudioTuningCard(isCompact: isCompact),
              SizedBox(height: isCompact ? 20 : 28),

              // 4. 本地 STT API 服务中枢
              _buildSectionTitle(
                title: '本地 STT API 服务中枢',
                subtitle: '兼容 OpenAI Whisper 接口协议的局域网与本地调用服务',
                icon: Icons.wifi_tethering_rounded,
                iconColor: AppColors.cyan,
              ),
              const SizedBox(height: 10),
              _buildServerHubCard(isServerRunning),
              SizedBox(height: isCompact ? 20 : 28),

              // 5. 数据存储与维护
              _buildSectionTitle(
                title: '数据存储与空间维护',
                subtitle: 'SQLite 数据库、FTS5 全文索引与音频缓存清理',
                icon: Icons.storage_rounded,
                iconColor: AppColors.emerald,
              ),
              const SizedBox(height: 10),
              _buildStorageMaintenanceCard(),
              SizedBox(height: isCompact ? 20 : 28),

              // 6. 系统保活与关于 PolyScribe
              _buildSectionTitle(
                title: '系统保活与软件关于',
                subtitle: '后台休眠防中断与客户端版本信息',
                icon: Icons.shield_rounded,
                iconColor: const Color(0xFFA855F7),
              ),
              const SizedBox(height: 10),
              _buildAboutAndKeepAliveCard(),
              const SizedBox(height: 36),
            ],
          ),
        ),
      ),
    );
  }

  /// 0. 视觉外观与主题风格选择卡片 (高级深浅色 Segmented Tab 布局)
  Widget _buildThemeSelectorCard(ThemeMode currentTheme, {required bool isCompact}) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.cardBorder),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.18),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      padding: EdgeInsets.all(isCompact ? 16 : 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '主题外观模式',
                      style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Colors.white),
                    ),
                    SizedBox(height: 3),
                    Text(
                      '支持深色沉浸、清爽明亮与自动跟随系统无缝切换',
                      style: TextStyle(fontSize: 12, color: AppColors.textMuted),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: AppColors.primary.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: AppColors.primary.withValues(alpha: 0.35)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      currentTheme == ThemeMode.light
                          ? Icons.light_mode_rounded
                          : currentTheme == ThemeMode.system
                              ? Icons.brightness_auto_rounded
                              : Icons.dark_mode_rounded,
                      size: 13,
                      color: AppColors.primary,
                    ),
                    const SizedBox(width: 5),
                    Text(
                      currentTheme == ThemeMode.light
                          ? '浅色模式'
                          : currentTheme == ThemeMode.system
                              ? '跟随系统'
                              : '深色模式',
                      style: const TextStyle(
                        color: AppColors.primary,
                        fontSize: 11.5,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // 核心：三联高质感深浅色 Tab 选项卡
          LayoutBuilder(
            builder: (context, constraints) {
              final isNarrow = constraints.maxWidth < 540;
              final tabs = [
                _ThemeTabItem(
                  mode: ThemeMode.dark,
                  title: '深色沉浸',
                  subtitle: '科技深蓝黑 · 夜间专注舒适',
                  icon: Icons.dark_mode_rounded,
                  accentColor: const Color(0xFF6366F1),
                  previewBg: const Color(0xFF0F172A),
                  previewCardBg: const Color(0xFF1E293B),
                  previewTextColor: Colors.white70,
                ),
                _ThemeTabItem(
                  mode: ThemeMode.light,
                  title: '明亮清新',
                  subtitle: '极简素雅白 · 日间清晰护眼',
                  icon: Icons.light_mode_rounded,
                  accentColor: const Color(0xFFF59E0B),
                  previewBg: const Color(0xFFF1F5F9),
                  previewCardBg: Colors.white,
                  previewTextColor: const Color(0xFF334155),
                ),
                _ThemeTabItem(
                  mode: ThemeMode.system,
                  title: '跟随系统',
                  subtitle: '感应系统外观模式自动匹配',
                  icon: Icons.brightness_auto_rounded,
                  accentColor: AppColors.emerald,
                  previewBg: const Color(0xFF1A1F2C),
                  previewCardBg: const Color(0xFF283145),
                  previewTextColor: Colors.white60,
                ),
              ];

              if (isNarrow) {
                return Column(
                  children: tabs.map((t) => Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: _buildThemeOptionTile(t, currentTheme),
                  )).toList(),
                );
              }

              return Row(
                children: tabs.map((t) {
                  return Expanded(
                    child: Padding(
                      padding: EdgeInsets.only(
                        left: t.mode == ThemeMode.dark ? 0 : 6,
                        right: t.mode == ThemeMode.system ? 0 : 6,
                      ),
                      child: _buildThemeCardTab(t, currentTheme),
                    ),
                  );
                }).toList(),
              );
            },
          ),
        ],
      ),
    );
  }

  /// 宽屏深浅色卡片 Tab
  Widget _buildThemeCardTab(_ThemeTabItem tab, ThemeMode currentTheme) {
    final isSelected = currentTheme == tab.mode;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () {
          ref.read(themeModeProvider.notifier).setThemeMode(tab.mode);
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: isSelected ? AppColors.surfaceElevated : AppColors.background.withValues(alpha: 0.6),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: isSelected ? AppColors.primary : AppColors.cardBorder,
              width: isSelected ? 1.8 : 1.0,
            ),
            boxShadow: isSelected
                ? [
                    BoxShadow(
                      color: AppColors.primary.withValues(alpha: 0.22),
                      blurRadius: 12,
                      offset: const Offset(0, 3),
                    ),
                  ]
                : [],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 模拟 UI 视窗微缩图
              Container(
                height: 60,
                width: double.infinity,
                padding: const EdgeInsets.all(7),
                decoration: BoxDecoration(
                  color: tab.previewBg,
                  borderRadius: BorderRadius.circular(9),
                  border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
                ),
                child: Row(
                  children: [
                    // 模拟侧边导航条
                    Container(
                      width: 14,
                      decoration: BoxDecoration(
                        color: tab.accentColor.withValues(alpha: 0.4),
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                    const SizedBox(width: 8),
                    // 模拟主界面卡片
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          Container(
                            height: 8,
                            decoration: BoxDecoration(
                              color: tab.previewCardBg,
                              borderRadius: BorderRadius.circular(3),
                            ),
                          ),
                          Container(
                            height: 18,
                            decoration: BoxDecoration(
                              color: tab.previewCardBg,
                              borderRadius: BorderRadius.circular(4),
                              border: Border.all(color: tab.accentColor.withValues(alpha: 0.3)),
                            ),
                            child: Row(
                              children: [
                                const SizedBox(width: 4),
                                Container(
                                  width: 4,
                                  height: 4,
                                  decoration: BoxDecoration(
                                    color: tab.accentColor,
                                    shape: BoxShape.circle,
                                  ),
                                ),
                                const SizedBox(width: 4),
                                Container(
                                  width: 24,
                                  height: 3,
                                  color: tab.previewTextColor,
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Icon(tab.icon, size: 16, color: isSelected ? AppColors.primary : AppColors.textMuted),
                  const SizedBox(width: 6),
                  Text(
                    tab.title,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: isSelected ? FontWeight.bold : FontWeight.w600,
                      color: isSelected ? Colors.white : AppColors.textSecondary,
                    ),
                  ),
                  const Spacer(),
                  // 单选圆点
                  Container(
                    width: 14,
                    height: 14,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: isSelected ? AppColors.primary : AppColors.textMuted,
                        width: isSelected ? 4 : 1.5,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                tab.subtitle,
                style: const TextStyle(fontSize: 10.5, color: AppColors.textMuted, height: 1.3),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 窄屏垂直列表深浅色选项
  Widget _buildThemeOptionTile(_ThemeTabItem tab, ThemeMode currentTheme) {
    final isSelected = currentTheme == tab.mode;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () {
          ref.read(themeModeProvider.notifier).setThemeMode(tab.mode);
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: isSelected ? AppColors.surfaceElevated : AppColors.background,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isSelected ? AppColors.primary : AppColors.cardBorder,
              width: isSelected ? 1.5 : 1.0,
            ),
          ),
          child: Row(
            children: [
              Icon(tab.icon, size: 20, color: isSelected ? AppColors.primary : AppColors.textMuted),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      tab.title,
                      style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: isSelected ? FontWeight.bold : FontWeight.w600,
                        color: isSelected ? Colors.white : AppColors.textPrimary,
                      ),
                    ),
                    Text(
                      tab.subtitle,
                      style: const TextStyle(fontSize: 11, color: AppColors.textMuted),
                    ),
                  ],
                ),
              ),
              Container(
                width: 16,
                height: 16,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: isSelected ? AppColors.primary : AppColors.textMuted,
                    width: isSelected ? 5 : 1.5,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 优雅的分区标题栏
  Widget _buildSectionTitle({
    required String title,
    required String subtitle,
    required IconData icon,
    required Color iconColor,
  }) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: iconColor.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, size: 16, color: iconColor),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                    letterSpacing: 0.3,
                  ),
                ),
                Text(
                  subtitle,
                  style: const TextStyle(fontSize: 11, color: AppColors.textMuted),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 1. AI 模型卡片
  Widget _buildModelCenterCard(bool allReady, {required bool isCompact}) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.cardBorder),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.2),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () async {
            await Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const ModelManagerScreen()),
            );
            _loadSettingsData();
          },
          child: Padding(
            padding: EdgeInsets.all(isCompact ? 14 : 18),
            child: Row(
              children: [
                // 状态指示图标
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: allReady
                        ? AppColors.emerald.withValues(alpha: 0.15)
                        : AppColors.amber.withValues(alpha: 0.15),
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: allReady ? AppColors.emerald : AppColors.amber,
                      width: 1.5,
                    ),
                  ),
                  child: Icon(
                    allReady ? Icons.check_circle_rounded : Icons.cloud_download_rounded,
                    color: allReady ? AppColors.emerald : AppColors.amber,
                    size: 20,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          const Text(
                            '离线 AI 语音模型包管理',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                            ),
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                            decoration: BoxDecoration(
                              color: allReady
                                  ? AppColors.emerald.withValues(alpha: 0.15)
                                  : AppColors.amber.withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              allReady ? '全部就绪' : '待下载',
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                                color: allReady ? AppColors.emerald : AppColors.amber,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 5),
                      Text(
                        allReady
                            ? 'SenseVoice-Small(230MB) / CAM++声纹(25MB) / Silero-VAD(2MB) 本地资产完整'
                            : 'SenseVoice / 声纹模型未就绪，点击进入一键下载与源切换',
                        style: const TextStyle(fontSize: 12, color: AppColors.textSecondary, height: 1.3),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                if (isCompact)
                  const Icon(Icons.chevron_right_rounded, size: 20, color: AppColors.textMuted)
                else
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                    decoration: BoxDecoration(
                      color: AppColors.surfaceElevated,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: AppColors.cardBorder),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('模型管理', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.white)),
                        SizedBox(width: 4),
                        Icon(Icons.arrow_forward_ios_rounded, size: 12, color: AppColors.textMuted),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 2. 本地 STT API 服务卡片
  Widget _buildServerHubCard(bool isServerRunning) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.cardBorder),
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(18),
            child: Row(
              children: [
                // 运行状态指示微光灯
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: isServerRunning ? AppColors.emerald : AppColors.textMuted,
                    boxShadow: isServerRunning
                        ? [
                            BoxShadow(
                              color: AppColors.emerald.withValues(alpha: 0.6),
                              blurRadius: 8,
                              spreadRadius: 1,
                            ),
                          ]
                        : null,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        '本地 HTTP / WebSocket 转发服务',
                        style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.white),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        isServerRunning
                            ? '正在监听 127.0.0.1:${AppConstants.defaultServerPort}，第三方软件可直接调用'
                            : '服务待机中，开启后可用作系统级本地 Whisper 转录替代',
                        style: TextStyle(
                          fontSize: 12,
                          color: isServerRunning ? AppColors.emerald : AppColors.textMuted,
                        ),
                      ),
                    ],
                  ),
                ),
                Switch(
                  value: isServerRunning,
                  activeThumbColor: AppColors.primary,
                  onChanged: (val) {
                    widget.onToggleServer?.call();
                    Future.delayed(const Duration(milliseconds: 200), () => setState(() {}));
                  },
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: AppColors.cardBorder),
          InkWell(
            borderRadius: const BorderRadius.vertical(bottom: Radius.circular(16)),
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => ServerConsoleScreen(
                    server: widget.localHttpServer,
                    onToggleServer: widget.onToggleServer ?? () {},
                  ),
                ),
              );
            },
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 18, vertical: 14),
              child: Row(
                children: [
                  Icon(Icons.terminal_rounded, size: 18, color: AppColors.cyan),
                  SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      '进入服务控制台、查看调用日志与接口测试',
                      style: TextStyle(fontSize: 13, color: AppColors.textPrimary, fontWeight: FontWeight.w500),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Icon(Icons.chevron_right_rounded, size: 18, color: AppColors.textMuted),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 3. 音频采样与识别调优卡片
  Widget _buildAudioTuningCard({required bool isCompact}) {
    return Container(
      padding: EdgeInsets.all(isCompact ? 14 : 18),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // VAD 静音切片阈值
          Row(
            children: [
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'VAD 语音停顿截断阈值',
                      style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.white),
                    ),
                    SizedBox(height: 2),
                    Text(
                      '说话连续停顿超过该秒数时，判定为句子结束并切片转写',
                      style: TextStyle(fontSize: 12, color: AppColors.textMuted),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: AppColors.primary.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppColors.primary.withValues(alpha: 0.3)),
                ),
                child: Text(
                  '${_vadSilenceThreshold.toStringAsFixed(1)} 秒',
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: AppColors.primary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              activeTrackColor: AppColors.primary,
              inactiveTrackColor: AppColors.surfaceElevated,
              thumbColor: Colors.white,
              overlayColor: AppColors.primaryGlow,
              trackHeight: 4,
            ),
            child: Slider(
              value: _vadSilenceThreshold,
              min: 0.4,
              max: 2.0,
              divisions: 16,
              onChanged: (val) {
                setState(() => _vadSilenceThreshold = val);
              },
            ),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('短句敏捷 (0.4s)', style: TextStyle(fontSize: 11, color: AppColors.textMuted)),
                Text('推荐平衡 (0.8s)', style: TextStyle(fontSize: 11, color: AppColors.textSecondary)),
                Text('长段深沉 (2.0s)', style: TextStyle(fontSize: 11, color: AppColors.textMuted)),
              ],
            ),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 14),
            child: Divider(height: 1, color: AppColors.cardBorder),
          ),

          // 短语音角色漂移抑制
          Row(
            children: [
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '短语音角色漂移抑制',
                      style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.white),
                    ),
                    SizedBox(height: 2),
                    Text(
                      '对时长 < 0.8s 的单音节（如“嗯”、“对”）自动继承上一发言人，避免误判为新角色',
                      style: TextStyle(fontSize: 12, color: AppColors.textMuted),
                    ),
                  ],
                ),
              ),
              Switch(
                value: _enableDriftSuppression,
                activeThumbColor: AppColors.primary,
                onChanged: (val) {
                  setState(() => _enableDriftSuppression = val);
                },
              ),
            ],
          ),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 14),
            child: Divider(height: 1, color: AppColors.cardBorder),
          ),

          // 启动软件自动继续转写
          Row(
            children: [
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '进入软件自动继续转写',
                      style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.white),
                    ),
                    SizedBox(height: 2),
                    Text(
                      '冷启动或重新打开软件时，自动恢复未完成与已暂停任务的后台断点转写（默认开启）',
                      style: TextStyle(fontSize: 12, color: AppColors.textMuted),
                    ),
                  ],
                ),
              ),
              Switch(
                value: _autoResumeTranscription,
                activeThumbColor: AppColors.primary,
                onChanged: (val) async {
                  setState(() => _autoResumeTranscription = val);
                  await AppDatabase.instance.saveSetting('auto_resume_transcription', val ? 'true' : 'false');
                  if (mounted) {
                    AppToast.info(context, val ? '已开启自动继续转写' : '已关闭自动继续转写');
                  }
                },
              ),
            ],
          ),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 14),
            child: Divider(height: 1, color: AppColors.cardBorder),
          ),

          // 识别语种偏好
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '目标识别语种偏好',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.white),
              ),
              const SizedBox(height: 4),
              const Text(
                'SenseVoice 具备出色的多语种混合能力，默认自动识别可兼顾中英粤日韩',
                style: TextStyle(fontSize: 12, color: AppColors.textMuted),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  _buildLanguageChip(
                    'auto',
                    isCompact ? '自动识别' : '自动识别 (中/粤/英/日/韩)',
                    Icons.auto_awesome_rounded,
                  ),
                  const SizedBox(width: 8),
                  _buildLanguageChip(
                    'zh',
                    isCompact ? '简体中文' : '强制简体中文',
                    Icons.translate_rounded,
                  ),
                  const SizedBox(width: 8),
                  _buildLanguageChip(
                    'en',
                    isCompact ? '强制英文' : '强制英文',
                    Icons.language_rounded,
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 语种选项药丸胶囊
  Widget _buildLanguageChip(String key, String label, IconData icon) {
    final isSelected = _preferredLanguage == key;
    return Expanded(
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () {
          setState(() => _preferredLanguage = key);
          AppDatabase.instance.saveSetting('preferred_language', key);
          AppToast.info(context, '首选语言已更新为：$label');
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
          decoration: BoxDecoration(
            color: isSelected ? AppColors.primary.withValues(alpha: 0.15) : AppColors.surfaceElevated,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: isSelected ? AppColors.primary : AppColors.cardBorder,
              width: isSelected ? 1.5 : 1.0,
            ),
          ),
          child: Column(
            children: [
              Icon(icon, size: 16, color: isSelected ? AppColors.primary : AppColors.textSecondary),
              const SizedBox(height: 4),
              Text(
                label,
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                  color: isSelected ? Colors.white : AppColors.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 4. 存储与维护卡片
  Widget _buildStorageMaintenanceCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.cardBorder),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppColors.emerald.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(Icons.dns_rounded, color: AppColors.emerald, size: 20),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '本地 SQLite 核心数据库',
                      style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.white),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '包含任务历史、声纹库与 FTS5 索引: $_dbSizeText',
                      style: const TextStyle(fontSize: 12, color: AppColors.textMuted),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.surfaceElevated,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  side: const BorderSide(color: AppColors.cardBorder),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                ),
                icon: _isVacuuming
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.primary),
                      )
                    : const Icon(Icons.cleaning_services_rounded, size: 15, color: AppColors.emerald),
                label: Text(
                  _isVacuuming ? '紧缩中...' : '紧缩优化',
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                ),
                onPressed: _isVacuuming ? null : _vacuumDatabase,
              ),
            ],
          ),
          const SizedBox(height: 14),
          const Divider(height: 1, color: AppColors.cardBorder),
          const SizedBox(height: 12),
          Row(
            children: [
              const Icon(Icons.folder_open_rounded, size: 16, color: AppColors.textMuted),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '存储目录：$_dbDirPath',
                  style: const TextStyle(fontSize: 11, color: AppColors.textMuted),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (Platform.isWindows)
                TextButton(
                  onPressed: _openDataDirectory,
                  child: const Text('打开目录', style: TextStyle(fontSize: 12, color: AppColors.primary)),
                ),
            ],
          ),
        ],
      ),
    );
  }

  /// 5. 关于与保活卡片
  Widget _buildAboutAndKeepAliveCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.cardBorder),
      ),
      child: Column(
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () {
              KeepAliveService.instance.requestIgnoreBatteryOptimizations();
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.greenAccent.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(Icons.battery_charging_full_rounded, color: Colors.greenAccent, size: 20),
                  ),
                  const SizedBox(width: 14),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '后台保活与电池无限制策略',
                          style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.white),
                        ),
                        SizedBox(height: 2),
                        Text(
                          '申请硬件唤醒锁与后台无限制权限，防止长会议转录被系统休眠中断',
                          style: TextStyle(fontSize: 12, color: AppColors.textMuted),
                        ),
                      ],
                    ),
                  ),
                  const Icon(Icons.open_in_new_rounded, size: 16, color: AppColors.textMuted),
                ],
              ),
            ),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Divider(height: 1, color: AppColors.cardBorder),
          ),
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: AppColors.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(Icons.info_outline_rounded, color: AppColors.primary, size: 20),
              ),
              const SizedBox(width: 14),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${AppConstants.appFullName} (${AppConstants.appEnglishName})',
                      style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.white),
                    ),
                    SizedBox(height: 2),
                    Text(
                      '端到端完全离线 · 多角色声纹分离 · 本地长会议纪要中枢',
                      style: TextStyle(fontSize: 12, color: AppColors.textMuted),
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: AppColors.surfaceElevated,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppColors.cardBorder),
                ),
                child: const Text(
                  AppConstants.appVersion,
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: AppColors.textSecondary,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ThemeTabItem {
  final ThemeMode mode;
  final String title;
  final String subtitle;
  final IconData icon;
  final Color accentColor;
  final Color previewBg;
  final Color previewCardBg;
  final Color previewTextColor;

  const _ThemeTabItem({
    required this.mode,
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.accentColor,
    required this.previewBg,
    required this.previewCardBg,
    required this.previewTextColor,
  });
}
