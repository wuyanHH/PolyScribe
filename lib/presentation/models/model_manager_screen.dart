import 'dart:async';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import '../../core/constants/app_colors.dart';
import '../../core/utils/app_toast.dart';
import '../../data/database/app_database.dart';
import '../../engine/isolate/inference_worker.dart';
import '../../engine/model_manager.dart';
import '../../engine/models/model_package_info.dart';
import '../../services/app_storage_service.dart';
import '../../services/model_download_service.dart';

/// AI 模型下载与更新管理中心 (桌面宽屏自适应 + 多源加速切换 + 实时解压进度)
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

  void _openModelFolder() {
    if (_modelDirectoryPath.isNotEmpty && Platform.isWindows) {
      Process.run('explorer.exe', [_modelDirectoryPath]);
    }
  }

  /// 调起目录选择与手动输入弹窗，支持全量资产无损迁移与默认重置
  Future<void> _showChangeDirectoryDialog() async {
    final activeBase = await AppStorageService.instance.getActiveBaseDirectory();
    final isCustom = AppStorageService.instance.isCustomDirActive;
    final textController = TextEditingController(text: activeBase.path);

    if (!mounted) return;

    showDialog(
      context: context,
      builder: (ctx) {
        bool migrateAssets = true;
        final screenWidth = MediaQuery.of(ctx).size.width;
        final isDialogCompact = screenWidth < 500;

        return StatefulBuilder(
          builder: (dialogCtx, setDialogState) {
            return AlertDialog(
              backgroundColor: AppColors.surfaceElevated,
              insetPadding: EdgeInsets.symmetric(
                horizontal: isDialogCompact ? 16 : 28,
                vertical: 24,
              ),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
              title: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(7),
                    decoration: BoxDecoration(
                      color: AppColors.primary.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(Icons.folder_shared_rounded, color: AppColors.primary, size: 20),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      '修改模型存储目录',
                      style: TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: isDialogCompact ? 16 : 17,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),
              content: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 480),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        '您可以将模型及相关音频资产迁移至自定义目录（如 SD卡/外部大容量分区/独立固态硬盘）：',
                        style: TextStyle(color: AppColors.textSecondary, fontSize: 12.5, height: 1.4),
                      ),
                      const SizedBox(height: 14),
                      Text(
                        '存储物理路径',
                        style: TextStyle(color: AppColors.textPrimary, fontSize: 12, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 6),
                      TextField(
                        controller: textController,
                        style: const TextStyle(fontSize: 12.5, fontFamily: 'monospace', color: Colors.white),
                        decoration: InputDecoration(
                          hintText: '输入或粘贴目标存储物理路径...',
                          hintStyle: const TextStyle(color: AppColors.textMuted, fontSize: 12),
                          filled: true,
                          fillColor: AppColors.background,
                          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide: const BorderSide(color: AppColors.cardBorder),
                          ),
                          suffixIcon: IconButton(
                            icon: const Icon(Icons.folder_open_rounded, color: AppColors.primary, size: 20),
                            tooltip: '浏览选择文件夹',
                            onPressed: () async {
                              try {
                                final selected = await FilePicker.getDirectoryPath(
                                  dialogTitle: '选择模型存储基准目录',
                                );
                                if (selected != null && selected.trim().isNotEmpty) {
                                  textController.text = selected.trim();
                                }
                              } catch (e) {
                                if (dialogCtx.mounted) {
                                  AppToast.error(dialogCtx, '调起文件夹选择器异常: $e');
                                }
                              }
                            },
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      InkWell(
                        onTap: () => setDialogState(() => migrateAssets = !migrateAssets),
                        borderRadius: BorderRadius.circular(8),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Row(
                            children: [
                              Checkbox(
                                value: migrateAssets,
                                activeColor: AppColors.primary,
                                onChanged: (v) => setDialogState(() => migrateAssets = v ?? true),
                              ),
                              const Expanded(
                                child: Text(
                                  '将现有已下载的模型与音频资产安全迁移至新目录',
                                  style: TextStyle(color: AppColors.textSecondary, fontSize: 12),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      if (isCustom) ...[
                        const SizedBox(height: 6),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton.icon(
                            style: TextButton.styleFrom(
                              foregroundColor: AppColors.amber,
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            ),
                            icon: const Icon(Icons.restore_rounded, size: 16),
                            label: const Text('恢复为系统默认目录', style: TextStyle(fontSize: 12)),
                            onPressed: () async {
                              Navigator.pop(ctx);
                              _executeResetToDefault();
                            },
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              actionsPadding: EdgeInsets.symmetric(
                horizontal: isDialogCompact ? 14 : 20,
                vertical: 12,
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('取消', style: TextStyle(color: AppColors.textMuted)),
                ),
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  icon: const Icon(Icons.check_rounded, size: 17),
                  label: const Text('确认应用'),
                  onPressed: () {
                    final target = textController.text.trim();
                    if (target.isEmpty) {
                      AppToast.warning(context, '目标路径不能为空');
                      return;
                    }
                    Navigator.pop(ctx);
                    _executeDirectoryMigration(target, migrateAssets: migrateAssets);
                  },
                ),
              ],
            );
          },
        );
      },
    );
  }

  /// 执行迁移并展示全局进度弹窗
  Future<void> _executeDirectoryMigration(String targetPath, {required bool migrateAssets}) async {
    final activeBase = await AppStorageService.instance.getActiveBaseDirectory();
    if (p.canonicalize(targetPath) == p.canonicalize(activeBase.path)) {
      if (mounted) {
        AppToast.info(context, '所填目录与当前目录相同，无需变更');
      }
      return;
    }

    if (!mounted) return;

    double currentProgress = 0.0;
    String status = '正在准备目录...';

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (pCtx) {
        return StatefulBuilder(
          builder: (dCtx, setDialogState) {
            return AlertDialog(
              backgroundColor: AppColors.surfaceElevated,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
              title: const Text('正在切换存储并迁移模型', style: TextStyle(color: AppColors.textPrimary, fontSize: 16, fontWeight: FontWeight.bold)),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(status, style: const TextStyle(color: AppColors.textSecondary, fontSize: 12.5)),
                  const SizedBox(height: 14),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: LinearProgressIndicator(
                      value: currentProgress > 0 ? currentProgress : null,
                      backgroundColor: AppColors.background,
                      color: AppColors.primary,
                      minHeight: 7,
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );

    try {
      if (migrateAssets) {
        await AppStorageService.instance.migrateAssetsTo(
          targetDirPath: targetPath,
          deleteSourceFiles: true,
          onProgress: (prog, text) {
            status = text;
            currentProgress = prog;
          },
        );
      } else {
        await AppDatabase.instance.saveSetting('app_custom_storage_directory', targetPath);
        await AppStorageService.instance.init();
      }

      await _refreshStatus();

      if (mounted) {
        Navigator.of(context, rootNavigator: true).pop();
        AppToast.success(context, '存储目录已成功更新！');
      }
    } catch (e) {
      if (mounted) {
        Navigator.of(context, rootNavigator: true).pop();
        AppToast.error(context, '目录更新失败: $e');
      }
    }
  }

  /// 恢复为系统默认目录
  Future<void> _executeResetToDefault() async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );

    try {
      await AppStorageService.instance.resetToDefaultDirectory(migrateBack: true);
      await _refreshStatus();
      if (mounted) {
        Navigator.of(context, rootNavigator: true).pop();
        AppToast.success(context, '已恢复为系统默认存储目录，资产已迁回');
      }
    } catch (e) {
      if (mounted) {
        Navigator.of(context, rootNavigator: true).pop();
        AppToast.error(context, '恢复失败: $e');
      }
    }
  }

  Future<void> _switchAsrModel(String modelId, String modelName) async {
    await ModelManager.instance.setActiveAsrModel(modelId);
    final config = ModelManager.instance.config;
    if (config != null) {
      // 若推理工作线程已在运行，热重载并装配新模型
      if (InferenceWorkerCoordinator.instance.isReady) {
        await InferenceWorkerCoordinator.instance.reloadModel(config);
      }
    }
    if (mounted) {
      setState(() {});
      AppToast.success(context, '已将主语音识别引擎切换为：$modelName');
    }
  }

  Future<void> _checkUpdates() async {
    AppToast.info(context, '正在联网同步最新的模型版本与 SHA256 签名...');

    final notes = await _downloadService.checkModelUpdates();
    if (!mounted) return;

    final anyMissing = _installedStatus.values.any((v) => !v);

    showDialog(
      context: context,
      builder: (ctx) {
        final screenWidth = MediaQuery.of(ctx).size.width;
        final isDialogCompact = screenWidth < 500;

        return AlertDialog(
          backgroundColor: AppColors.surfaceElevated,
          insetPadding: EdgeInsets.symmetric(
            horizontal: isDialogCompact ? 16 : 32,
            vertical: 24,
          ),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Row(
            children: [
              const Icon(Icons.system_update_alt_rounded, color: AppColors.primary, size: 22),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '模型版本检测报告',
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: isDialogCompact ? 15.5 : 17,
                    fontWeight: FontWeight.bold,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: SingleChildScrollView(
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
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
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
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  m.name,
                                  style: TextStyle(
                                    color: AppColors.textPrimary,
                                    fontSize: isDialogCompact ? 12.5 : 13,
                                    fontWeight: FontWeight.w500,
                                  ),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                if (isDialogCompact) ...[
                                  const SizedBox(height: 2),
                                  Text(
                                    m.sizeDisplay,
                                    style: const TextStyle(
                                      color: AppColors.textMuted,
                                      fontSize: 10.5,
                                      fontFamily: 'monospace',
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
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
          ),
          actionsPadding: EdgeInsets.symmetric(
            horizontal: isDialogCompact ? 14 : 20,
            vertical: 12,
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
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                ),
                icon: const Icon(Icons.download_rounded, size: 16),
                label: const Text('一键补齐全部'),
                onPressed: () {
                  Navigator.pop(ctx);
                  _downloadService.downloadAllMissingModels(source: _selectedSource);
                },
              ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final states = _downloadService.currentStates;
    final installedCount = _installedStatus.values.where((v) => v).length;
    final totalCount = PredefinedModels.all.length;
    final anyMissing = installedCount < totalCount;
    final isCompact = MediaQuery.of(context).size.width < 640;

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        elevation: 0,
        title: Text(
          isCompact ? 'AI 端侧模型管理' : 'AI 端侧模型下载与更新中心',
          style: TextStyle(
            fontSize: isCompact ? 15.5 : 16,
            fontWeight: FontWeight.bold,
            color: AppColors.textPrimary,
          ),
        ),
        actions: [
          IconButton(
            tooltip: '检查模型版本更新',
            icon: Icon(Icons.sync_rounded, color: AppColors.textPrimary),
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
                  padding: EdgeInsets.all(isCompact ? 14 : 20),
                  physics: const BouncingScrollPhysics(),
                  children: [
                    _buildTopActionBar(anyMissing, installedCount, totalCount, isCompact: isCompact),
                    const SizedBox(height: 14),
                    _buildSourceSelector(isCompact: isCompact),
                    const SizedBox(height: 18),
                    // 语音识别引擎标题与当前引擎状态胶囊 (自适应流式换行，避免手机端横向溢出)
                    Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      alignment: WrapAlignment.spaceBetween,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.record_voice_over_rounded, color: AppColors.primary, size: 18),
                            const SizedBox(width: 8),
                            Text(
                              '语音识别 (ASR) 引擎',
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.bold,
                                color: AppColors.textPrimary,
                              ),
                            ),
                          ],
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: AppColors.primary.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(color: AppColors.primary.withValues(alpha: 0.3)),
                          ),
                          child: Text(
                            '当前引擎: ${ModelManager.instance.config?.currentAsrName ?? "SenseVoice"}',
                            style: const TextStyle(
                              color: AppColors.primary,
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      '支持按需部署多种识别架构，转写任务与实时会议将优先使用当前选中的默认引擎。',
                      style: TextStyle(color: AppColors.textMuted, fontSize: 12),
                    ),
                    const SizedBox(height: 12),
                    ...PredefinedModels.asrModels.map((model) {
                      final progress = states[model.id] ?? ModelDownloadProgress(modelId: model.id);
                      final isInstalled = _installedStatus[model.id] ?? false;
                      return _buildModelCard(model, isInstalled, progress, isCompact: isCompact);
                    }),
                    const SizedBox(height: 18),
                    Row(
                      children: [
                        const Icon(Icons.tune_rounded, color: AppColors.amber, size: 18),
                        const SizedBox(width: 8),
                        Text(
                          '辅助声学模型 (VAD & 声纹分离)',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.bold,
                            color: AppColors.textPrimary,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      '为人声切片、静音过滤与说话人角色聚类提供支持。',
                      style: TextStyle(color: AppColors.textMuted, fontSize: 12),
                    ),
                    const SizedBox(height: 12),
                    ...PredefinedModels.all.where((m) => !m.isAsrModel).map((model) {
                      final progress = states[model.id] ?? ModelDownloadProgress(modelId: model.id);
                      final isInstalled = _installedStatus[model.id] ?? false;
                      return _buildModelCard(model, isInstalled, progress, isCompact: isCompact);
                    }),
                    const SizedBox(height: 16),
                    _buildStoragePathFooter(),
                  ],
                ),
              ),
            ),
    );
  }

  /// 下载镜像源选择器 (窄屏上下自适应，彻底消除长下拉框导致的横向溢出)
  Widget _buildSourceSelector({required bool isCompact}) {
    final dropdown = Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      decoration: BoxDecoration(
        color: AppColors.background,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.cardBorder),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<ModelDownloadSource>(
          value: _selectedSource,
          isExpanded: isCompact,
          dropdownColor: AppColors.surfaceElevated,
          borderRadius: BorderRadius.circular(10),
          isDense: true,
          items: ModelDownloadSource.values.map((src) {
            return DropdownMenuItem(
              value: src,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      src.label,
                      style: const TextStyle(color: Colors.white, fontSize: 12.5),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
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
    );

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.cardBorder),
      ),
      child: isCompact
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    const Icon(Icons.speed_rounded, color: AppColors.primary, size: 17),
                    const SizedBox(width: 8),
                    Text(
                      '下载加速网络源',
                      style: TextStyle(color: AppColors.textPrimary, fontWeight: FontWeight.bold, fontSize: 13.5),
                    ),
                    const SizedBox(width: 6),
                    const Text(
                      '(自动多源重试)',
                      style: TextStyle(color: AppColors.textMuted, fontSize: 11),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                dropdown,
              ],
            )
          : Row(
              children: [
                const Icon(Icons.speed_rounded, color: AppColors.primary, size: 18),
                const SizedBox(width: 8),
                Text(
                  '下载加速网络源',
                  style: TextStyle(color: AppColors.textPrimary, fontWeight: FontWeight.bold, fontSize: 13.5),
                ),
                const SizedBox(width: 8),
                const Text(
                  '(自动多源重试)',
                  style: TextStyle(color: AppColors.textMuted, fontSize: 11.5),
                ),
                const Spacer(),
                dropdown,
              ],
            ),
    );
  }

  /// 顶部全局操作栏 (窄屏下按钮置于底部全宽展示，杜绝挤压左侧说明文字)
  Widget _buildTopActionBar(bool anyMissing, int installedCount, int totalCount, {required bool isCompact}) {
    final actionBtn = anyMissing
        ? ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primary,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              elevation: 0,
            ),
            icon: const Icon(Icons.download_rounded, size: 18),
            label: const Text('一键补齐全部', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
            onPressed: () {
              _downloadService.downloadAllMissingModels(source: _selectedSource);
            },
          )
        : OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              foregroundColor: AppColors.emerald,
              side: BorderSide(color: AppColors.emerald.withValues(alpha: 0.5)),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            icon: const Icon(Icons.sync_rounded, size: 16),
            label: const Text('检查最新版本', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12.5)),
            onPressed: _checkUpdates,
          );

    return Container(
      padding: EdgeInsets.all(isCompact ? 14 : 18),
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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                padding: EdgeInsets.all(isCompact ? 10 : 12),
                decoration: BoxDecoration(
                  color: (anyMissing ? AppColors.amber : AppColors.emerald).withValues(alpha: 0.16),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  anyMissing ? Icons.downloading_rounded : Icons.verified_rounded,
                  color: anyMissing ? AppColors.amber : AppColors.emerald,
                  size: isCompact ? 22 : 26,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      anyMissing
                          ? '部分模型尚未部署 ($installedCount/$totalCount)'
                          : '所有核心 AI 模型均已就绪 ($installedCount/$totalCount)',
                      style: TextStyle(
                        fontSize: isCompact ? 14 : 15,
                        fontWeight: FontWeight.bold,
                        color: anyMissing ? AppColors.textPrimary : AppColors.emerald,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      anyMissing
                          ? '建议一键补齐缺失模型，下载完成后将自动解压并校验 ONNX 权重。'
                          : '本地神经网络已完整部署，支持全离线长会议转录、声纹聚类与音频批处理。',
                      style: const TextStyle(fontSize: 12, color: AppColors.textSecondary, height: 1.4),
                    ),
                  ],
                ),
              ),
              if (!isCompact) ...[
                const SizedBox(width: 14),
                actionBtn,
              ],
            ],
          ),
          if (isCompact) ...[
            const SizedBox(height: 12),
            actionBtn,
          ],
        ],
      ),
    );
  }

  /// 单个模型卡片展示 (窄屏自适应，确保模型完整名称清晰可见不被按钮挤压)
  Widget _buildModelCard(
    ModelPackageInfo model,
    bool isInstalled,
    ModelDownloadProgress progress, {
    required bool isCompact,
  }) {
    final isDownloading = progress.status == ModelTaskStatus.downloading;
    final isExtracting = progress.status == ModelTaskStatus.extracting;
    final isBusy = isDownloading || isExtracting;

    Widget buildActionControls() {
      if (isBusy) {
        return Row(
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
              visualDensity: VisualDensity.compact,
              tooltip: '取消任务',
              icon: const Icon(Icons.cancel_outlined, color: AppColors.rose, size: 20),
              onPressed: () => _downloadService.cancel(model.id),
            ),
          ],
        );
      } else if (isInstalled) {
        final currentActiveAsrId = ModelManager.instance.config?.activeAsrModelId ?? 'sensevoice_small';
        final isActiveAsr = model.isAsrModel && model.id == currentActiveAsrId;

        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isActiveAsr) ...[
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                decoration: BoxDecoration(
                  color: AppColors.emerald.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: AppColors.emerald.withValues(alpha: 0.6)),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.check_circle_rounded, color: AppColors.emerald, size: 14),
                    SizedBox(width: 4),
                    Text(
                      '当前默认引擎',
                      style: TextStyle(
                        color: AppColors.emerald,
                        fontSize: 11.5,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
            ] else if (model.isAsrModel) ...[
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary.withValues(alpha: 0.16),
                  foregroundColor: AppColors.primary,
                  elevation: 0,
                  side: BorderSide(color: AppColors.primary.withValues(alpha: 0.45)),
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
                icon: const Icon(Icons.swap_horiz_rounded, size: 14),
                label: const Text('设为当前引擎', style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold)),
                onPressed: () => _switchAsrModel(model.id, model.name),
              ),
            ] else ...[
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
            ],
            const SizedBox(width: 8),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.textSecondary,
                side: const BorderSide(color: AppColors.cardBorder),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              icon: const Icon(Icons.refresh_rounded, size: 13, color: AppColors.textMuted),
              label: const Text('重新下载', style: TextStyle(fontSize: 11.5)),
              onPressed: () => _downloadService.downloadModel(model, source: _selectedSource),
            ),
          ],
        );
      } else {
        return ElevatedButton.icon(
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.primary,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            minimumSize: Size.zero,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            elevation: 0,
          ),
          icon: const Icon(Icons.download_rounded, size: 15),
          label: const Text('下载部署', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
          onPressed: () {
            _downloadService.downloadModel(model, source: _selectedSource);
          },
        );
      }
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: EdgeInsets.all(isCompact ? 14 : 16),
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
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: EdgeInsets.all(isCompact ? 8 : 10),
                decoration: BoxDecoration(
                  color: isInstalled
                      ? AppColors.emerald.withValues(alpha: 0.14)
                      : AppColors.surfaceElevated,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  isInstalled ? Icons.check_circle_rounded : Icons.memory_rounded,
                  color: isInstalled ? AppColors.emerald : AppColors.textMuted,
                  size: isCompact ? 20 : 22,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Expanded(
                          child: Text(
                            model.name,
                            style: TextStyle(
                              color: AppColors.textPrimary,
                              fontWeight: FontWeight.bold,
                              fontSize: isCompact ? 13.5 : 14.5,
                            ),
                            maxLines: isCompact ? 2 : 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 6),
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
                    const SizedBox(height: 5),
                    Text(
                      model.description,
                      style: const TextStyle(color: AppColors.textMuted, fontSize: 12, height: 1.35),
                    ),
                  ],
                ),
              ),
              if (!isCompact) ...[
                const SizedBox(width: 12),
                buildActionControls(),
              ],
            ],
          ),
          if (isCompact) ...[
            const SizedBox(height: 12),
            if (isBusy)
              const SizedBox.shrink()
            else if (isInstalled)
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Row(
                          children: [
                            Container(
                              width: 7,
                              height: 7,
                              decoration: const BoxDecoration(
                                color: AppColors.emerald,
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                model.isAsrModel &&
                                        model.id ==
                                            (ModelManager.instance.config?.activeAsrModelId ?? 'sensevoice_small')
                                    ? '当前默认识别引擎'
                                    : '本地权重已就绪 (${model.version})',
                                style: const TextStyle(
                                  color: AppColors.emerald,
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w500,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
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
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        ),
                        icon: const Icon(Icons.refresh_rounded, size: 13, color: AppColors.textMuted),
                        label: const Text('重新下载', style: TextStyle(fontSize: 11.5)),
                        onPressed: () => _downloadService.downloadModel(model, source: _selectedSource),
                      ),
                    ],
                  ),
                  if (model.isAsrModel &&
                      model.id !=
                          (ModelManager.instance.config?.activeAsrModelId ?? 'sensevoice_small')) ...[
                    const SizedBox(height: 8),
                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.primary.withValues(alpha: 0.16),
                        foregroundColor: AppColors.primary,
                        elevation: 0,
                        side: BorderSide(color: AppColors.primary.withValues(alpha: 0.45)),
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                      icon: const Icon(Icons.swap_horiz_rounded, size: 16),
                      label: const Text('设为当前识别引擎', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                      onPressed: () => _switchAsrModel(model.id, model.name),
                    ),
                  ],
                ],
              )
            else
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    elevation: 0,
                  ),
                  icon: const Icon(Icons.download_rounded, size: 16),
                  label: Text('下载部署 (${model.sizeDisplay})', style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold)),
                  onPressed: () {
                    _downloadService.downloadModel(model, source: _selectedSource);
                  },
                ),
              ),
          ],
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
                Expanded(
                  child: Text(
                    isExtracting ? '正在解压并校验 ONNX 权重...' : '下载进度: ${(progress.progress * 100).toStringAsFixed(1)}%',
                    style: const TextStyle(color: AppColors.textSecondary, fontSize: 11.5),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text(
                  progress.speed,
                  style: const TextStyle(color: AppColors.primary, fontSize: 11.5, fontWeight: FontWeight.bold),
                ),
                if (isCompact) ...[
                  const SizedBox(width: 8),
                  InkWell(
                    onTap: () => _downloadService.cancel(model.id),
                    child: const Padding(
                      padding: EdgeInsets.all(2),
                      child: Icon(Icons.cancel_outlined, color: AppColors.rose, size: 18),
                    ),
                  ),
                ],
              ],
            ),
          ],
          if (progress.status == ModelTaskStatus.failed && progress.errorMessage != null) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: AppColors.rose.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppColors.rose.withValues(alpha: 0.3)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Padding(
                        padding: EdgeInsets.only(top: 1),
                        child: Icon(Icons.error_outline_rounded, color: AppColors.rose, size: 16),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          progress.errorMessage!,
                          style: const TextStyle(color: AppColors.rose, fontSize: 11.5, height: 1.3),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton.icon(
                        style: TextButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          foregroundColor: AppColors.primary,
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                        ),
                        icon: const Icon(Icons.refresh_rounded, size: 14),
                        label: const Text('高速镜像一键重试', style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold)),
                        onPressed: () {
                          setState(() => _selectedSource = ModelDownloadSource.modelScope);
                          _downloadService.downloadModel(model, source: ModelDownloadSource.modelScope);
                        },
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 底部存储路径展示 (手机端移动端体验优化，高亮支持一键修改目录与复制路径)
  Widget _buildStoragePathFooter() {
    final isCustom = AppStorageService.instance.isCustomDirActive;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                isCustom ? Icons.folder_special_rounded : Icons.folder_open_rounded,
                color: isCustom ? AppColors.emerald : AppColors.primary,
                size: 18,
              ),
              const SizedBox(width: 8),
              Text(
                '模型物理存储位置',
                style: TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 12.5,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: (isCustom ? AppColors.emerald : AppColors.textMuted).withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  isCustom ? '自定义外部目录' : '系统默认目录',
                  style: TextStyle(
                    color: isCustom ? AppColors.emerald : AppColors.textMuted,
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const Spacer(),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  foregroundColor: Colors.white,
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  elevation: 0,
                ),
                icon: const Icon(Icons.edit_location_alt_rounded, size: 14),
                label: const Text('修改目录', style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold)),
                onPressed: _showChangeDirectoryDialog,
              ),
            ],
          ),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: AppColors.background,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppColors.cardBorder),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    _modelDirectoryPath.isEmpty ? '加载中...' : _modelDirectoryPath,
                    style: const TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 11,
                      fontFamily: 'monospace',
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                InkWell(
                  onTap: () {
                    if (_modelDirectoryPath.isNotEmpty) {
                      Clipboard.setData(ClipboardData(text: _modelDirectoryPath));
                      AppToast.success(context, '已复制模型存储路径到剪贴板');
                    }
                  },
                  borderRadius: BorderRadius.circular(6),
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: const [
                        Icon(Icons.copy_rounded, size: 13, color: AppColors.primary),
                        SizedBox(width: 4),
                        Text('复制', style: TextStyle(fontSize: 11, color: AppColors.primary, fontWeight: FontWeight.bold)),
                      ],
                    ),
                  ),
                ),
                if (Platform.isWindows) ...[
                  const SizedBox(width: 6),
                  InkWell(
                    onTap: _openModelFolder,
                    borderRadius: BorderRadius.circular(6),
                    child: Padding(
                      padding: const EdgeInsets.all(4),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: const [
                          Icon(Icons.open_in_new_rounded, size: 13, color: AppColors.textMuted),
                          SizedBox(width: 3),
                          Text('打开', style: TextStyle(fontSize: 11, color: AppColors.textMuted)),
                        ],
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
