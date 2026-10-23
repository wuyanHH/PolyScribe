import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import '../../core/constants/app_colors.dart';
import '../../core/utils/app_toast.dart';
import '../../engine/model_manager.dart';
import '../../engine/models/model_package_info.dart';
import '../../services/model_download_service.dart';

/// AI 模型下载与更新管理中心 (桌面宽屏自适应 + 多源加速切换 + 实时解压进度)
class ModelManagerScreen extends StatefulWidget {
  const ModelManagerScreen({super.key});

  @override
  State<ModelManagerScreen> createState() => _ModelManagerScreenState();
}

class _ModelManagerScreenState extends State<ModelManagerScreen> {
  final ModelDownloadService _downloadService = ModelDownloadService.instance;
  ModelDownloadSource _selectedSource = ModelDownloadSource.official;

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

  void _openModelFolder() {
    if (_modelDirectoryPath.isNotEmpty && Platform.isWindows) {
      Process.run('explorer.exe', [_modelDirectoryPath]);
    }
  }

  Future<void> _checkUpdates() async {
    AppToast.info(context, '正在联网同步最新的模型版本与 SHA256 签名...');

    final notes = await _downloadService.checkModelUpdates();
    if (!mounted) return;

    final anyMissing = _installedStatus.values.any((v) => !v);

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surfaceElevated,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Icons.system_update_alt_rounded, color: AppColors.primary, size: 22),
            SizedBox(width: 8),
            Text('模型版本检测报告', style: TextStyle(color: Colors.white, fontSize: 16.5, fontWeight: FontWeight.bold)),
          ],
        ),
        content: SizedBox(
          width: 440,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '已成功联网校验本地 ONNX 权重与远程 Release 最新发布版本：',
                style: TextStyle(color: AppColors.textSecondary, fontSize: 12.5),
              ),
              const SizedBox(height: 14),
              ...PredefinedModels.all.map((m) {
                final note = notes[m.id] ?? '最新';
                final isInstalled = _installedStatus[m.id] ?? false;
                final isOk = isInstalled && note == '最新';

                return Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                  decoration: BoxDecoration(
                    color: AppColors.background,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: isOk
                          ? AppColors.cardBorder
                          : AppColors.amber.withValues(alpha: 0.4),
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        isOk ? Icons.check_circle_rounded : Icons.info_outline_rounded,
                        color: isOk ? AppColors.emerald : AppColors.amber,
                        size: 18,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          m.name,
                          style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w500),
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                        decoration: BoxDecoration(
                          color: (isOk ? AppColors.emerald : AppColors.amber).withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          isInstalled ? note : '待部署',
                          style: TextStyle(
                            color: isOk ? AppColors.emerald : AppColors.amber,
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              }),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('完成', style: TextStyle(color: AppColors.textMuted)),
          ),
          if (anyMissing)
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: Colors.white,
              ),
              icon: const Icon(Icons.download_rounded, size: 16),
              label: const Text('一键补齐全部'),
              onPressed: () {
                Navigator.pop(ctx);
                _downloadService.downloadAllMissingModels(source: _selectedSource);
              },
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final states = _downloadService.currentStates;
    final installedCount = _installedStatus.values.where((v) => v).length;
    final totalCount = PredefinedModels.all.length;
    final anyMissing = installedCount < totalCount;

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        elevation: 0,
        title: const Text(
          'AI 端侧模型下载与更新中心',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white),
        ),
        actions: [
          IconButton(
            tooltip: '检查模型版本更新',
            icon: const Icon(Icons.sync_rounded),
            onPressed: _checkUpdates,
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 880),
                child: ListView(
                  padding: const EdgeInsets.all(20),
                  physics: const BouncingScrollPhysics(),
                  children: [
                    _buildTopActionBar(anyMissing, installedCount, totalCount),
                    const SizedBox(height: 16),
                    _buildSourceSelector(),
                    const SizedBox(height: 22),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          '核心推理模型资产清单',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
                        Text(
                          '已就绪 $installedCount / $totalCount',
                          style: const TextStyle(color: AppColors.textMuted, fontSize: 12),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    ...PredefinedModels.all.map((model) {
                      final progress = states[model.id] ?? ModelDownloadProgress(modelId: model.id);
                      final isInstalled = _installedStatus[model.id] ?? false;
                      return _buildModelCard(model, isInstalled, progress);
                    }),
                    const SizedBox(height: 20),
                    _buildStoragePathFooter(),
                  ],
                ),
              ),
            ),
    );
  }

  /// 下载镜像源选择器 (精致单行横向仪表条)
  Widget _buildSourceSelector() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.cardBorder),
      ),
      child: Row(
        children: [
          const Icon(Icons.speed_rounded, color: AppColors.primary, size: 18),
          const SizedBox(width: 8),
          const Text(
            '下载加速网络源',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13.5),
          ),
          const SizedBox(width: 8),
          const Text(
            '(自动多源重试)',
            style: TextStyle(color: AppColors.textMuted, fontSize: 11.5),
          ),
          const Spacer(),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
            decoration: BoxDecoration(
              color: AppColors.background,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppColors.cardBorder),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<ModelDownloadSource>(
                value: _selectedSource,
                dropdownColor: AppColors.surfaceElevated,
                borderRadius: BorderRadius.circular(10),
                isDense: true,
                items: ModelDownloadSource.values.map((src) {
                  return DropdownMenuItem(
                    value: src,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(src.label, style: const TextStyle(color: Colors.white, fontSize: 12.5)),
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                          decoration: BoxDecoration(
                            color: AppColors.emerald.withValues(alpha: 0.16),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            src.badge,
                            style: const TextStyle(
                              color: AppColors.emerald,
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
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
            ),
          ),
        ],
      ),
    );
  }

  /// 顶部全局操作栏 (自适应就绪状态与检查更新操作)
  Widget _buildTopActionBar(bool anyMissing, int installedCount, int totalCount) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            (anyMissing ? AppColors.primary : AppColors.emerald).withValues(alpha: 0.18),
            AppColors.surface,
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: (anyMissing ? AppColors.primary : AppColors.emerald).withValues(alpha: 0.4),
        ),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: (anyMissing ? AppColors.amber : AppColors.emerald).withValues(alpha: 0.16),
              shape: BoxShape.circle,
            ),
            child: Icon(
              anyMissing ? Icons.downloading_rounded : Icons.verified_rounded,
              color: anyMissing ? AppColors.amber : AppColors.emerald,
              size: 26,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  anyMissing ? '检测到部分模型尚未部署 ($installedCount/$totalCount)' : '所有核心 AI 模型均已就绪 ($installedCount/$totalCount)',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                    color: anyMissing ? Colors.white : AppColors.emerald,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  anyMissing
                      ? '建议点击右侧按钮一键补齐缺失模型，下载完成后将自动解压并校验 ONNX 权重。'
                      : '本地端侧神经网络已完整部署，支持全离线长会议转录、声纹聚类与外部音频批处理。',
                  style: const TextStyle(fontSize: 12, color: AppColors.textSecondary, height: 1.4),
                ),
              ],
            ),
          ),
          const SizedBox(width: 14),
          if (anyMissing)
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                elevation: 0,
              ),
              icon: const Icon(Icons.download_rounded, size: 18),
              label: const Text('一键补齐全部', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
              onPressed: () {
                _downloadService.downloadAllMissingModels(source: _selectedSource);
              },
            )
          else
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.emerald,
                side: BorderSide(color: AppColors.emerald.withValues(alpha: 0.5)),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
              icon: const Icon(Icons.sync_rounded, size: 16),
              label: const Text('检查最新版本', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12.5)),
              onPressed: _checkUpdates,
            ),
        ],
      ),
    );
  }

  /// 单个模型卡片展示 (结构对齐、微徽章与精美操作按钮)
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
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isInstalled
              ? AppColors.emerald.withValues(alpha: 0.35)
              : isBusy
                  ? AppColors.primary
                  : AppColors.cardBorder,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: isInstalled
                      ? AppColors.emerald.withValues(alpha: 0.14)
                      : AppColors.surfaceElevated,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  isInstalled ? Icons.check_circle_rounded : Icons.memory_rounded,
                  color: isInstalled ? AppColors.emerald : AppColors.textMuted,
                  size: 22,
                ),
              ),
              const SizedBox(width: 14),
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
                              fontSize: 14.5,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: AppColors.background,
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(color: AppColors.cardBorder),
                          ),
                          child: Text(
                            model.sizeDisplay,
                            style: const TextStyle(
                              fontFamily: 'monospace',
                              color: AppColors.textSecondary,
                              fontSize: 10.5,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      model.description,
                      style: const TextStyle(color: AppColors.textMuted, fontSize: 12, height: 1.35),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              // 右侧按钮交互区 (已部署展示徽章+重新下载，未部署展示醒目操作，下载中展示进度+取消)
              if (isBusy)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                      decoration: BoxDecoration(
                        color: AppColors.primary.withValues(alpha: 0.16),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: AppColors.primary.withValues(alpha: 0.3)),
                      ),
                      child: Text(
                        isExtracting ? '解压中' : '${(progress.progress * 100).toInt()}%',
                        style: const TextStyle(
                          color: AppColors.primary,
                          fontSize: 11.5,
                          fontWeight: FontWeight.bold,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    IconButton(
                      tooltip: '取消任务',
                      icon: const Icon(Icons.cancel_outlined, color: AppColors.rose, size: 20),
                      onPressed: () => _downloadService.cancel(model.id),
                    ),
                  ],
                )
              else if (isInstalled)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                      decoration: BoxDecoration(
                        color: AppColors.emerald.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: AppColors.emerald.withValues(alpha: 0.35)),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.check_rounded, color: AppColors.emerald, size: 14),
                          SizedBox(width: 4),
                          Text(
                            '已就绪',
                            style: TextStyle(
                              color: AppColors.emerald,
                              fontSize: 11.5,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.textSecondary,
                        side: const BorderSide(color: AppColors.cardBorder),
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        minimumSize: Size.zero,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                      icon: const Icon(Icons.refresh_rounded, size: 13, color: AppColors.textMuted),
                      label: const Text('重新下载', style: TextStyle(fontSize: 11.5)),
                      onPressed: () => _downloadService.downloadModel(model, source: _selectedSource),
                    ),
                  ],
                )
              else
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    elevation: 0,
                  ),
                  icon: const Icon(Icons.download_rounded, size: 15),
                  label: const Text('下载部署', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
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
                backgroundColor: AppColors.background,
                valueColor: AlwaysStoppedAnimation<Color>(
                  isExtracting ? AppColors.emerald : AppColors.primary,
                ),
                minHeight: 6,
              ),
            ),
            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  isExtracting ? '正在解压并校验 ONNX 权重...' : '下载进度: ${(progress.progress * 100).toStringAsFixed(1)}%',
                  style: const TextStyle(color: AppColors.textSecondary, fontSize: 11.5),
                ),
                Text(
                  progress.speed,
                  style: const TextStyle(color: AppColors.primary, fontSize: 11.5, fontWeight: FontWeight.bold),
                ),
              ],
            ),
          ],
          if (progress.status == ModelTaskStatus.failed && progress.errorMessage != null) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: AppColors.rose.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  const Icon(Icons.error_outline_rounded, color: AppColors.rose, size: 16),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      progress.errorMessage!,
                      style: const TextStyle(color: AppColors.rose, fontSize: 11.5),
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
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.cardBorder),
      ),
      child: Row(
        children: [
          const Icon(Icons.folder_open_rounded, color: AppColors.textMuted, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '模型物理存储目录: $_modelDirectoryPath',
              style: const TextStyle(color: AppColors.textMuted, fontSize: 11.5),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (Platform.isWindows)
            TextButton(
              onPressed: _openModelFolder,
              child: const Text('打开目录', style: TextStyle(fontSize: 12, color: AppColors.primary)),
            ),
        ],
      ),
    );
  }
}
