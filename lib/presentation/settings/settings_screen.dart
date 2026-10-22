import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../../core/constants/app_colors.dart';
import '../../core/constants/app_constants.dart';
import '../../data/database/app_database.dart';
import '../../engine/model_manager.dart';
import '../../services/keep_alive_service.dart';
import '../../services/server/http_server.dart';
import '../models/model_manager_screen.dart';
import '../server/server_console_screen.dart';

/// 系统中枢与偏好设置页面
class SettingsScreen extends StatefulWidget {
  final LocalHttpServer? localHttpServer;
  final VoidCallback? onToggleServer;

  const SettingsScreen({
    super.key,
    this.localHttpServer,
    this.onToggleServer,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  ModelConfig? _modelConfig;
  double _vadSilenceThreshold = 0.8;
  bool _enableDriftSuppression = true;
  String _preferredLanguage = 'auto';
  String _dbSizeText = '计算中...';

  @override
  void initState() {
    super.initState();
    _loadSettingsData();
  }

  Future<void> _loadSettingsData() async {
    final config = await ModelManager.instance.resolveModels();
    final dbDir = await getApplicationDocumentsDirectory();
    final dbFile = File(p.join(dbDir.path, 'polyscribe.db'));
    String sizeStr = '0 KB';
    if (dbFile.existsSync()) {
      final bytes = await dbFile.length();
      sizeStr = bytes > 1024 * 1024
          ? '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB'
          : '${(bytes / 1024).toStringAsFixed(1)} KB';
    }

    if (mounted) {
      setState(() {
        _modelConfig = config;
        _dbSizeText = sizeStr;
      });
    }
  }

  Future<void> _vacuumDatabase() async {
    final db = await AppDatabase.instance.database;
    await db.execute('VACUUM');
    await _loadSettingsData();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('SQLite 数据库紧缩与索引重建完成')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final isVadReady = _modelConfig?.isVadReady ?? false;
    final isAsrReady = _modelConfig?.isSenseVoiceReady ?? false;
    final allModelsReady = isVadReady && isAsrReady;
    final isServerRunning = widget.localHttpServer?.isRunning ?? false;

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        title: const Text('系统与中枢设置', style: TextStyle(fontWeight: FontWeight.bold)),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // 1. AI 离线模型中心
          _buildSectionHeader('AI 离线模型中心', Icons.memory_rounded),
          Material(
            color: AppColors.surface,
            clipBehavior: Clip.antiAlias,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: const BorderSide(color: AppColors.surfaceLight),
            ),
            child: ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              title: const Text('AI 离线模型下载与管理', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
              subtitle: Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  allModelsReady
                      ? 'SenseVoice(230MB) / CAM++(25MB) / VAD(2MB) 全部就绪'
                      : '检测到部分模型尚未下载，点击前往一键离线下载',
                  style: TextStyle(
                    color: allModelsReady ? Colors.greenAccent : Colors.orangeAccent,
                    fontSize: 12,
                  ),
                ),
              ),
              trailing: const Icon(Icons.chevron_right, color: Colors.grey),
              onTap: () async {
                await Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const ModelManagerScreen()),
                );
                _loadSettingsData();
              },
            ),
          ),
          const SizedBox(height: 20),

          // 2. 本地 STT API 转发中枢
          _buildSectionHeader('本地 STT API 转发中枢', Icons.wifi_tethering_rounded),
          Material(
            color: AppColors.surface,
            clipBehavior: Clip.antiAlias,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: const BorderSide(color: AppColors.surfaceLight),
            ),
            child: Column(
              children: [
                SwitchListTile(
                  title: const Text('本地 HTTP / WebSocket 转发服务', style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold)),
                  subtitle: Text(
                    isServerRunning
                        ? '正在监听 :${AppConstants.defaultServerPort} (兼容 OpenAI Whisper 规范)'
                        : '服务待机中，开启后第三方听书/翻译软件可直接调用',
                    style: TextStyle(color: isServerRunning ? Colors.greenAccent : Colors.grey, fontSize: 11),
                  ),
                  value: isServerRunning,
                  activeThumbColor: AppColors.primary,
                  onChanged: (val) {
                    widget.onToggleServer?.call();
                    Future.delayed(const Duration(milliseconds: 200), () => setState(() {}));
                  },
                ),
                const Divider(height: 1, color: AppColors.surfaceLight),
                ListTile(
                  title: const Text('打开服务控制台与调用日志', style: TextStyle(color: Colors.white, fontSize: 13)),
                  trailing: const Icon(Icons.chevron_right, color: Colors.grey, size: 20),
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
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),

          // 3. 录音与识别调优
          _buildSectionHeader('录音与识别调优', Icons.tune_rounded),
          Material(
            color: AppColors.surface,
            clipBehavior: Clip.antiAlias,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: const BorderSide(color: AppColors.surfaceLight),
            ),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('VAD 静音切片阈值', style: TextStyle(color: Colors.white, fontSize: 14)),
                      Text('${_vadSilenceThreshold.toStringAsFixed(1)} 秒', style: const TextStyle(color: AppColors.primary, fontWeight: FontWeight.bold)),
                    ],
                  ),
                  const SizedBox(height: 4),
                  const Text('说话停顿超过该时长自动截断并转写为一句话', style: TextStyle(color: Colors.grey, fontSize: 11)),
                  Slider(
                    value: _vadSilenceThreshold,
                    min: 0.4,
                    max: 2.0,
                    divisions: 16,
                    activeColor: AppColors.primary,
                    onChanged: (val) {
                      setState(() => _vadSilenceThreshold = val);
                    },
                  ),
                  const Divider(color: AppColors.surfaceLight),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('短语音角色漂移抑制', style: TextStyle(color: Colors.white, fontSize: 14)),
                    subtitle: const Text('对时长小于 0.8 秒的极短语音自动继承上一发言人，消除“嗯、啊、对”误识别', style: TextStyle(color: Colors.grey, fontSize: 11)),
                    value: _enableDriftSuppression,
                    activeThumbColor: AppColors.primary,
                    onChanged: (val) {
                      setState(() => _enableDriftSuppression = val);
                    },
                  ),
                  const Divider(color: AppColors.surfaceLight),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('识别语种偏好', style: TextStyle(color: Colors.white, fontSize: 14)),
                      DropdownButton<String>(
                        value: _preferredLanguage,
                        dropdownColor: AppColors.surface,
                        style: const TextStyle(color: Colors.white, fontSize: 13),
                        underline: const SizedBox(),
                        items: const [
                          DropdownMenuItem(value: 'auto', child: Text('自动识别 (中/粤/英/日/韩)')),
                          DropdownMenuItem(value: 'zh', child: Text('强制简体中文')),
                          DropdownMenuItem(value: 'en', child: Text('强制英语')),
                        ],
                        onChanged: (val) {
                          if (val != null) {
                            setState(() => _preferredLanguage = val);
                          }
                        },
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),

          // 4. 数据维护与存储
          _buildSectionHeader('数据维护与存储', Icons.storage_rounded),
          Material(
            color: AppColors.surface,
            clipBehavior: Clip.antiAlias,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: const BorderSide(color: AppColors.surfaceLight),
            ),
            child: Column(
              children: [
                ListTile(
                  title: const Text('本地数据库占用', style: TextStyle(color: Colors.white, fontSize: 14)),
                  subtitle: Text('SQLite + FTS5: $_dbSizeText', style: const TextStyle(color: Colors.grey, fontSize: 12)),
                  trailing: OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white70,
                      side: const BorderSide(color: AppColors.surfaceLight),
                    ),
                    onPressed: _vacuumDatabase,
                    child: const Text('紧缩优化'),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),

          // 5. 关于与系统保活
          _buildSectionHeader('关于与保活', Icons.info_outline_rounded),
          Material(
            color: AppColors.surface,
            clipBehavior: Clip.antiAlias,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: const BorderSide(color: AppColors.surfaceLight),
            ),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.battery_charging_full_rounded, color: Colors.greenAccent),
                    title: const Text('后台保活与电池无限制策略', style: TextStyle(color: Colors.white, fontSize: 14)),
                    subtitle: const Text('保证息屏或切后台时长录音不被系统杀死', style: TextStyle(color: Colors.grey, fontSize: 11)),
                    trailing: const Icon(Icons.open_in_new, size: 16, color: Colors.grey),
                    onTap: () {
                      KeepAliveService.instance.requestIgnoreBatteryOptimizations();
                    },
                  ),
                  const Divider(color: AppColors.surfaceLight),
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('客户端版本', style: TextStyle(color: Colors.white, fontSize: 14)),
                        Text('${AppConstants.appEnglishName} ${AppConstants.appVersion}', style: const TextStyle(color: Colors.grey, fontSize: 13)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(String title, IconData icon) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8),
      child: Row(
        children: [
          Icon(icon, size: 16, color: AppColors.primary),
          const SizedBox(width: 8),
          Text(
            title,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.bold,
              color: Colors.grey,
            ),
          ),
        ],
      ),
    );
  }
}
