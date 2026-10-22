import 'dart:async';
import 'package:flutter/material.dart';
import '../../core/constants/app_colors.dart';
import '../../engine/model_manager.dart';
import '../../engine/models/model_package_info.dart';
import '../../services/model_download_service.dart';

/// AI 模型下载与更新管理中心
class ModelManagerScreen extends StatefulWidget {
  const ModelManagerScreen({super.key});

  @override
  State<ModelManagerScreen> createState() => _ModelManagerScreenState();
}

class _ModelManagerScreenState extends State<ModelManagerScreen> {
  final ModelDownloadService _downloadService = ModelDownloadService.instance;
  ModelDownloadSource _selectedSource = ModelDownloadSource.modelScope;

  final Map<String, bool> _installedStatus = {};
  String _modelDirectoryPath = '';
  bool _isLoading = true;
  StreamSubscription? _progressSub;

  @override
  void initState() {
    super.initState();
    _refreshStatus();

    _progressSub = _downloadService.stateStream.listen((_) {
      if (mounted) {
        _checkInstalledOnly();
      }
    });
  }

  @override
  void dispose() {
    _progressSub?.cancel();
    super.dispose();
  }

  Future<void> _refreshStatus() async {
    setState(() => _isLoading = true);
    final dir = await ModelManager.instance.getModelDirectory();
    _modelDirectoryPath = dir.path;

    for (final model in PredefinedModels.all) {
      _installedStatus[model.id] = await _downloadService.checkInstalled(model);
    }

    if (mounted) {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _checkInstalledOnly() async {
    for (final model in PredefinedModels.all) {
      _installedStatus[model.id] = await _downloadService.checkInstalled(model);
    }
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _checkUpdates() async {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('正在联网同步最新的模型版本与 SHA256 签名...'),
        duration: Duration(seconds: 1),
      ),
    );

    final notes = await _downloadService.checkModelUpdates();
    if (!mounted) return;

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Row(
          children: [
            Icon(Icons.system_update_alt, color: AppColors.primary),
            SizedBox(width: 8),
            Text('模型版本检测报告', style: TextStyle(color: Colors.white, fontSize: 18)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: PredefinedModels.all.map((m) {
            final note = notes[m.id] ?? '最新';
            final isInstalled = _installedStatus[m.id] ?? false;
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                children: [
                  Icon(
                    isInstalled ? Icons.check_circle : Icons.warning_amber_rounded,
                    color: isInstalled ? Colors.greenAccent : Colors.orangeAccent,
                    size: 18,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${m.name}: $note',
                      style: const TextStyle(color: Colors.white70, fontSize: 13),
                    ),
                  ),
                ],
              ),
            );
          }).toList(),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('我知道了'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final states = _downloadService.currentStates;
    final anyMissing = _installedStatus.values.any((installed) => !installed);

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        elevation: 0,
        title: const Text('AI 端侧模型下载与更新中心'),
        actions: [
          IconButton(
            tooltip: '检查模型版本更新',
            icon: const Icon(Icons.sync),
            onPressed: _checkUpdates,
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _buildSourceSelector(),
                const SizedBox(height: 16),
                _buildTopActionBar(anyMissing),
                const SizedBox(height: 20),
                const Text(
                  '核心模型资产列表',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 12),
                ...PredefinedModels.all.map((model) {
                  final progress = states[model.id] ?? ModelDownloadProgress(modelId: model.id);
                  final isInstalled = _installedStatus[model.id] ?? false;
                  return _buildModelCard(model, isInstalled, progress);
                }),
                const SizedBox(height: 24),
                _buildStoragePathFooter(),
              ],
            ),
    );
  }

  /// 下载镜像源选择器
  Widget _buildSourceSelector() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.surfaceLight),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.cloud_download_outlined, color: AppColors.primary, size: 20),
              SizedBox(width: 8),
              Text(
                '下载加速网络源',
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14),
              ),
            ],
          ),
          const SizedBox(height: 10),
          DropdownButtonFormField<ModelDownloadSource>(
            initialValue: _selectedSource,
            dropdownColor: AppColors.surface,
            decoration: InputDecoration(
              filled: true,
              fillColor: AppColors.surfaceLight,
              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide.none,
              ),
            ),
            items: ModelDownloadSource.values.map((src) {
              return DropdownMenuItem(
                value: src,
                child: Row(
                  children: [
                    Text(src.label, style: const TextStyle(color: Colors.white, fontSize: 13)),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: src == ModelDownloadSource.modelScope ? Colors.green.withValues(alpha: 0.2) : Colors.white10,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        src.badge,
                        style: TextStyle(
                          color: src == ModelDownloadSource.modelScope ? Colors.greenAccent : Colors.grey,
                          fontSize: 10,
                        ),
                      ),
                    ),
                  ],
                ),
              );
            }).toList(),
            onChanged: (val) {
              if (val != null) setState(() => _selectedSource = val);
            },
          ),
        ],
      ),
    );
  }

  /// 顶部全局操作栏
  Widget _buildTopActionBar(bool anyMissing) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            AppColors.primary.withValues(alpha: 0.2),
            AppColors.surface,
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.primary.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  anyMissing ? '检测到部分模型尚未部署' : '🎉 所有核心模型均已就绪',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                    color: anyMissing ? Colors.orangeAccent : Colors.greenAccent,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  anyMissing
                      ? '建议点击右侧按钮一键下载全部缺失模型，自动解压部署。'
                      : '模型全部就绪，已支持全离线会议转写、实时投屏与声纹分离。',
                  style: const TextStyle(fontSize: 12, color: Colors.white70),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primary,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            icon: const Icon(Icons.download, size: 18),
            label: const Text('一键补齐全部', style: TextStyle(fontWeight: FontWeight.bold)),
            onPressed: () {
              _downloadService.downloadAllMissingModels(source: _selectedSource);
            },
          ),
        ],
      ),
    );
  }

  /// 单个模型卡片展示
  Widget _buildModelCard(
    ModelPackageInfo model,
    bool isInstalled,
    ModelDownloadProgress progress,
  ) {
    final isDownloading = progress.status == ModelTaskStatus.downloading;
    final isExtracting = progress.status == ModelTaskStatus.extracting;
    final isBusy = isDownloading || isExtracting;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isInstalled
              ? Colors.green.withValues(alpha: 0.25)
              : isBusy
                  ? AppColors.primary
                  : AppColors.surfaceLight,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: isInstalled
                      ? Colors.green.withValues(alpha: 0.15)
                      : AppColors.surfaceLight,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(
                  isInstalled ? Icons.check_circle : Icons.album_outlined,
                  color: isInstalled ? Colors.greenAccent : Colors.grey,
                  size: 22,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            model.name,
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 14,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: Colors.white10,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            model.sizeDisplay,
                            style: const TextStyle(color: Colors.white60, fontSize: 11),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      model.description,
                      style: const TextStyle(color: Colors.grey, fontSize: 12),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              if (isBusy)
                IconButton(
                  tooltip: '取消下载',
                  icon: const Icon(Icons.close, color: Colors.redAccent, size: 20),
                  onPressed: () => _downloadService.cancel(model.id),
                )
              else
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    side: BorderSide(color: isInstalled ? Colors.white24 : AppColors.primary),
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                  ),
                  icon: Icon(
                    isInstalled ? Icons.refresh : Icons.download,
                    size: 14,
                    color: isInstalled ? Colors.white70 : AppColors.primary,
                  ),
                  label: Text(
                    isInstalled ? '重新下载' : '下载部署',
                    style: TextStyle(
                      fontSize: 12,
                      color: isInstalled ? Colors.white70 : AppColors.primary,
                    ),
                  ),
                  onPressed: () {
                    _downloadService.downloadModel(model, source: _selectedSource);
                  },
                ),
            ],
          ),
          if (isBusy) ...[
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: isExtracting ? null : progress.progress,
                backgroundColor: Colors.white10,
                valueColor: AlwaysStoppedAnimation<Color>(
                  isExtracting ? Colors.tealAccent : AppColors.primary,
                ),
                minHeight: 6,
              ),
            ),
            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  isExtracting ? '正在解压并校验权重...' : '下载进度: ${(progress.progress * 100).toStringAsFixed(1)}%',
                  style: const TextStyle(color: Colors.white70, fontSize: 11),
                ),
                Text(
                  progress.speed,
                  style: const TextStyle(color: AppColors.primary, fontSize: 11, fontWeight: FontWeight.bold),
                ),
              ],
            ),
          ],
          if (progress.status == ModelTaskStatus.failed && progress.errorMessage != null) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.red.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(
                children: [
                  const Icon(Icons.error_outline, color: Colors.redAccent, size: 16),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      progress.errorMessage!,
                      style: const TextStyle(color: Colors.redAccent, fontSize: 11),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 底部存储路径展示
  Widget _buildStoragePathFooter() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surfaceLight.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          const Icon(Icons.folder_open, color: Colors.grey, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '模型文件存储目录: $_modelDirectoryPath',
              style: const TextStyle(color: Colors.white60, fontSize: 11),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}
