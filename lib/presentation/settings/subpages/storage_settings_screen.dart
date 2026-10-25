import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../../../core/constants/app_colors.dart';
import '../../../core/utils/app_toast.dart';
import '../../../data/database/app_database.dart';
import '../../../services/app_storage_service.dart';

/// 数据存储与空间维护二级页面 (支持自定义外部目录与资产一键迁移)
class StorageSettingsScreen extends StatefulWidget {
  const StorageSettingsScreen({super.key});

  @override
  State<StorageSettingsScreen> createState() => _StorageSettingsScreenState();
}

class _StorageSettingsScreenState extends State<StorageSettingsScreen> {
  String _dbSizeText = '计算中...';
  String _dbDirPath = '';
  String _activeStoragePath = '';
  bool _isCustomStorage = false;
  StorageMigrationStats? _currentStats;
  bool _isVacuuming = false;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadStorageData();
  }

  Future<void> _loadStorageData() async {
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

    final activeDir = await AppStorageService.instance.getActiveBaseDirectory();
    _activeStoragePath = activeDir.path;
    _isCustomStorage = AppStorageService.instance.isCustomDirActive;

    final stats = await AppStorageService.instance.inspectCurrentAssets();

    if (mounted) {
      setState(() {
        _dbSizeText = sizeStr;
        _currentStats = stats;
        _isLoading = false;
      });
    }
  }

  Future<void> _vacuumDatabase() async {
    if (_isVacuuming) return;
    setState(() => _isVacuuming = true);

    try {
      final db = await AppDatabase.instance.database;
      await db.execute('VACUUM');
      await _loadStorageData();
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

  void _openDirectory(String dirPath) {
    if (dirPath.isNotEmpty && Platform.isWindows) {
      Process.run('explorer.exe', [dirPath]);
    }
  }

  /// 选取外部新目录并引导迁移 (支持文件选择器与手动输入/粘贴双通道)
  Future<void> _selectCustomDirectory() async {
    final textController = TextEditingController(text: _activeStoragePath);

    await showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: context.surfaceColor,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
          title: Row(
            children: [
              const Icon(Icons.folder_shared_rounded, color: AppColors.primary, size: 22),
              const SizedBox(width: 10),
              Text('选择或输入存储目录', style: TextStyle(fontSize: 16.5, fontWeight: FontWeight.bold, color: context.textMain)),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '建议选择拥有足够剩余空间的外部分区或存储卡，系统将把全部离线模型与媒体资产移动至此：',
                style: TextStyle(fontSize: 12.5, color: context.textSub),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: textController,
                style: TextStyle(fontSize: 12.5, fontFamily: 'monospace', color: context.textMain),
                decoration: InputDecoration(
                  hintText: '输入或粘贴目标存储目录物理路径...',
                  hintStyle: TextStyle(color: context.textGrey, fontSize: 12),
                  filled: true,
                  fillColor: context.bg,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide(color: context.borderColor),
                  ),
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.folder_open_rounded, color: AppColors.primary),
                    tooltip: '浏览文件夹',
                    onPressed: () async {
                      try {
                        final selected = await FilePicker.getDirectoryPath(
                          dialogTitle: '选择外部存储目录',
                        );
                        if (selected != null && selected.trim().isNotEmpty) {
                          textController.text = selected.trim();
                        }
                      } catch (e) {
                        if (ctx.mounted) {
                          AppToast.error(ctx, '调起文件夹选择器失败: $e');
                        }
                      }
                    },
                  ),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消', style: TextStyle(color: AppColors.textMuted)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
              onPressed: () {
                final target = textController.text.trim();
                if (target.isEmpty) {
                  AppToast.warning(context, '目标路径不能为空');
                  return;
                }
                Navigator.pop(ctx);
                if (p.canonicalize(target) == p.canonicalize(_activeStoragePath)) {
                  AppToast.info(context, '所选目录与当前存储目录相同，无需变更');
                  return;
                }
                _showMigrationDialog(target, isResetToDefault: false);
              },
              child: const Text('下一步: 迁移资产'),
            ),
          ],
        );
      },
    );
  }

  /// 恢复为系统默认目录
  Future<void> _resetToDefault() async {
    final defaultBase = await AppStorageService.instance.getDefaultBaseDirectory();
    if (!mounted) return;
    _showMigrationDialog(defaultBase.path, isResetToDefault: true);
  }

  /// 弹出资产迁移确认与实时进度面板
  void _showMigrationDialog(String targetPath, {required bool isResetToDefault}) {
    bool deleteSource = true;
    bool isMigrating = false;
    double migrationProgress = 0.0;
    String statusText = '准备就绪，点击下方按钮开始迁移';

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (dialogCtx, setDialogState) {
            final isDialogCompact = MediaQuery.of(dialogCtx).size.width < 500;

            return AlertDialog(
              backgroundColor: context.surfaceColor,
              insetPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 24),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
              titlePadding: const EdgeInsets.fromLTRB(20, 20, 20, 10),
              title: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: AppColors.primary.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(Icons.drive_file_move_rounded, color: AppColors.primary, size: 22),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      isResetToDefault ? '恢复默认存储并迁回资产' : '设定外部存储并迁移资产',
                      style: TextStyle(
                        fontSize: isDialogCompact ? 15.5 : 17,
                        fontWeight: FontWeight.bold,
                        color: context.textMain,
                      ),
                    ),
                  ),
                ],
              ),
              content: SingleChildScrollView(
                physics: const BouncingScrollPhysics(),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      isResetToDefault
                          ? '将所有离线 AI 模型、转入音频与录音母带从外部目录迁回系统默认应用目录：'
                          : '系统将自动在目标目录创建规范子目录，并将现有 AI 推理模型、转入音频及录音完整移动过去，同时自动更新纪要库的关联路径：',
                      style: TextStyle(fontSize: 12.5, color: context.textSub, height: 1.4),
                    ),
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      decoration: BoxDecoration(
                        color: context.bg,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: context.borderColor),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(Icons.folder_open_rounded, size: 16, color: AppColors.emerald),
                              const SizedBox(width: 6),
                              Text(
                                '新目标路径',
                                style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: context.textMain),
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Text(
                            targetPath,
                            style: const TextStyle(fontSize: 11.5, fontFamily: 'monospace', color: AppColors.cyan),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 14),
                    // 资产清单概览
                    if (_currentStats != null) ...[
                      Text(
                        '待迁移资产清单统计',
                        style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold, color: context.textMain),
                      ),
                      const SizedBox(height: 8),
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: context.bg,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: context.borderColor),
                        ),
                        child: Column(
                          children: [
                            _buildDialogRow('🤖 AI 端侧模型', '${_currentStats!.modelFilesCount} 个文件', _currentStats!.modelSizeDisplay),
                            const Divider(height: 12),
                            _buildDialogRow('🎵 导入音频文件', '${_currentStats!.audioFilesCount} 个录音', _currentStats!.audioSizeDisplay),
                            const Divider(height: 12),
                            _buildDialogRow(
                              '📦 总计迁移容量',
                              '共 ${_currentStats!.totalFiles} 个文件',
                              _currentStats!.totalSizeDisplay,
                              isHighlight: true,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                    ],
                    // 清理选项
                    if (!isMigrating)
                      CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        activeColor: AppColors.primary,
                        title: Text(
                          '迁移校验通过后，清理原目录以释放空间 (推荐)',
                          style: TextStyle(fontSize: 12, color: context.textMain),
                        ),
                        value: deleteSource,
                        onChanged: (val) {
                          setDialogState(() => deleteSource = val ?? true);
                        },
                      ),
                    // 迁移进度与状态
                    if (isMigrating) ...[
                      const SizedBox(height: 6),
                      LinearProgressIndicator(
                        value: migrationProgress > 0 ? migrationProgress : null,
                        backgroundColor: context.borderColor,
                        valueColor: const AlwaysStoppedAnimation<Color>(AppColors.primary),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        statusText,
                        style: TextStyle(fontSize: 12, color: context.textSub, fontStyle: FontStyle.italic),
                      ),
                    ],
                  ],
                ),
              ),
              actionsPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              actions: [
                if (!isMigrating)
                  TextButton(
                    onPressed: () => Navigator.pop(dialogCtx),
                    child: Text('取消', style: TextStyle(color: context.textGrey)),
                  ),
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  ),
                  icon: isMigrating
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                        )
                      : const Icon(Icons.check_rounded, size: 16),
                  label: Text(isMigrating ? '正在安全迁移中...' : '开始执行迁移'),
                  onPressed: isMigrating
                      ? null
                      : () async {
                          setDialogState(() {
                            isMigrating = true;
                            statusText = '正在扫描并初始化迁移管线...';
                          });

                          try {
                            if (isResetToDefault) {
                              await AppStorageService.instance.resetToDefaultDirectory(
                                migrateBack: true,
                                onProgress: (prog, text) {
                                  setDialogState(() {
                                    migrationProgress = prog;
                                    statusText = text;
                                  });
                                },
                              );
                            } else {
                              await AppStorageService.instance.migrateAssetsTo(
                                targetDirPath: targetPath,
                                deleteSourceFiles: deleteSource,
                                onProgress: (prog, text) {
                                  setDialogState(() {
                                    migrationProgress = prog;
                                    statusText = text;
                                  });
                                },
                              );
                            }

                            await _loadStorageData();
                            if (dialogCtx.mounted) {
                              Navigator.pop(dialogCtx);
                            }
                            if (mounted) {
                              AppToast.success(context, '外部存储目录配置与资产迁移成功！');
                            }
                          } catch (e) {
                            setDialogState(() {
                              isMigrating = false;
                              statusText = '迁移发生异常: $e';
                            });
                            if (mounted) {
                              AppToast.error(context, '迁移失败: $e');
                            }
                          }
                        },
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildDialogRow(String title, String count, String size, {bool isHighlight = false}) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          title,
          style: TextStyle(
            fontSize: 12,
            fontWeight: isHighlight ? FontWeight.bold : FontWeight.normal,
            color: context.textMain,
          ),
        ),
        Row(
          children: [
            Text(
              count,
              style: TextStyle(fontSize: 11.5, color: context.textGrey),
            ),
            const SizedBox(width: 8),
            Text(
              size,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
                fontWeight: isHighlight ? FontWeight.bold : FontWeight.w500,
                color: isHighlight ? AppColors.emerald : context.textMain,
              ),
            ),
          ],
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final isCompact = MediaQuery.of(context).size.width < 640;

    return Scaffold(
      backgroundColor: context.bg,
      appBar: AppBar(
        backgroundColor: context.surfaceColor,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back_ios_new_rounded, size: 18, color: context.textMain),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          '数据存储与空间维护',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: context.textMain),
        ),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 820),
                child: ListView(
                  padding: EdgeInsets.symmetric(horizontal: isCompact ? 14 : 20, vertical: 16),
                  physics: const BouncingScrollPhysics(),
                  children: [
                    // 自定义外部存储目录卡片
                    _buildExternalStorageCard(isCompact),
                    const SizedBox(height: 16),

                    // 本地 SQLite 核心数据库卡片
                    _buildDatabaseCard(isCompact),
                    const SizedBox(height: 16),

                    // 存储使用说明与安全保障
                    _buildStorageTipsCard(),
                  ],
                ),
              ),
            ),
    );
  }

  /// 外部存储目录与迁移核心卡片
  Widget _buildExternalStorageCard(bool isCompact) {
    return Container(
      padding: EdgeInsets.all(isCompact ? 14 : 18),
      decoration: BoxDecoration(
        color: context.surfaceColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _isCustomStorage ? AppColors.emerald.withValues(alpha: 0.4) : context.borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: (_isCustomStorage ? AppColors.emerald : AppColors.primary).withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  _isCustomStorage ? Icons.folder_special_rounded : Icons.folder_shared_rounded,
                  color: _isCustomStorage ? AppColors.emerald : AppColors.primary,
                  size: 22,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 标题与状态徽标自适应流式排布，彻底杜绝手机端横向溢出
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          '多媒体音频与 AI 模型存储位置',
                          style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.bold, color: context.textMain),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: (_isCustomStorage ? AppColors.emerald : AppColors.cyan).withValues(alpha: 0.16),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            _isCustomStorage ? '已启用外部存储' : '系统默认路径',
                            style: TextStyle(
                              fontSize: 10.5,
                              fontWeight: FontWeight.bold,
                              color: _isCustomStorage ? AppColors.emerald : AppColors.cyan,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '支持自定义大容量硬盘/外部移动目录，将模型与音频资产全量外迁，避免占用系统盘',
                      style: TextStyle(fontSize: 12, color: context.textGrey),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),

          // 路径展示行
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: context.bg,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: context.borderColor),
            ),
            child: Row(
              children: [
                const Icon(Icons.storage_rounded, size: 16, color: AppColors.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _activeStoragePath,
                    style: const TextStyle(fontSize: 11.5, fontFamily: 'monospace', color: AppColors.cyan),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                if (Platform.isWindows)
                  IconButton(
                    tooltip: '在文件资源管理器中打开',
                    icon: const Icon(Icons.open_in_new_rounded, size: 16, color: AppColors.primary),
                    onPressed: () => _openDirectory(_activeStoragePath),
                    visualDensity: VisualDensity.compact,
                  ),
                IconButton(
                  tooltip: '复制完整路径',
                  icon: Icon(Icons.copy_rounded, size: 16, color: context.textGrey),
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: _activeStoragePath));
                    AppToast.success(context, '已复制当前存储路径');
                  },
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),

          // 资产占用统计与操作按钮
          if (_currentStats != null) ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: context.bg.withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  _buildStatPill('AI 模型占用', _currentStats!.modelSizeDisplay),
                  Container(height: 16, width: 1, color: context.borderColor),
                  _buildStatPill('音频媒体占用', _currentStats!.audioSizeDisplay),
                  Container(height: 16, width: 1, color: context.borderColor),
                  _buildStatPill('总资产容量', _currentStats!.totalSizeDisplay, isEmerald: true),
                ],
              ),
            ),
            const SizedBox(height: 14),
          ],

          // 操作按钮条 (手机窄屏下双按钮垂直排列，避免横向挤压与文字溢出)
          if (isCompact && _isCustomStorage)
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    padding: const EdgeInsets.symmetric(vertical: 11),
                  ),
                  icon: const Icon(Icons.drive_file_move_rounded, size: 16),
                  label: const Text(
                    '更改外部存储目录并迁移',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                  ),
                  onPressed: _selectCustomDirectory,
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: context.textMain,
                    side: BorderSide(color: context.borderColor),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    padding: const EdgeInsets.symmetric(vertical: 11),
                  ),
                  icon: const Icon(Icons.restore_rounded, size: 16, color: AppColors.rose),
                  label: const Text('还原为默认目录', style: TextStyle(fontSize: 12.5)),
                  onPressed: _resetToDefault,
                ),
              ],
            )
          else
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.primary,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      padding: const EdgeInsets.symmetric(vertical: 11),
                    ),
                    icon: const Icon(Icons.drive_file_move_rounded, size: 16),
                    label: Text(
                      _isCustomStorage ? '更改外部存储目录并迁移' : '设定外部存储目录并迁移资产',
                      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                    ),
                    onPressed: _selectCustomDirectory,
                  ),
                ),
                if (_isCustomStorage) ...[
                  const SizedBox(width: 10),
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: context.textMain,
                      side: BorderSide(color: context.borderColor),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
                    ),
                    icon: const Icon(Icons.restore_rounded, size: 16, color: AppColors.rose),
                    label: const Text('还原为默认目录', style: TextStyle(fontSize: 12.5)),
                    onPressed: _resetToDefault,
                  ),
                ],
              ],
            ),
        ],
      ),
    );
  }

  Widget _buildStatPill(String label, String value, {bool isEmerald = false}) {
    return Column(
      children: [
        Text(label, style: TextStyle(fontSize: 11, color: context.textGrey)),
        const SizedBox(height: 2),
        Text(
          value,
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.bold,
            fontFamily: 'monospace',
            color: isEmerald ? AppColors.emerald : context.textMain,
          ),
        ),
      ],
    );
  }

  /// 本地 SQLite 核心数据库卡片
  Widget _buildDatabaseCard(bool isCompact) {
    return Container(
      padding: EdgeInsets.all(isCompact ? 14 : 18),
      decoration: BoxDecoration(
        color: context.surfaceColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: context.borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppColors.cyan.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(Icons.dns_rounded, color: AppColors.cyan, size: 22),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '本地 SQLite 结构化核心数据库',
                      style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.bold, color: context.textMain),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '记录会议任务元数据、192维声纹质心池与 FTS5 全文索引',
                      style: TextStyle(fontSize: 12, color: context.textGrey),
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                decoration: BoxDecoration(
                  color: AppColors.emerald.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  _dbSizeText,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: AppColors.emerald,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Divider(height: 1, color: context.borderColor),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'SQLite 数据库紧缩与索引碎片整理',
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: context.textMain),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '释放频繁删除会议与声纹后留下的未分配页面，重构 B-Tree 索引',
                      style: TextStyle(fontSize: 11.5, color: context.textGrey),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: context.surfaceElevatedColor,
                  foregroundColor: context.textMain,
                  elevation: 0,
                  side: BorderSide(color: context.borderColor),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
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
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: context.bg,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: context.borderColor),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '物理路径: $_dbDirPath',
                    style: TextStyle(fontSize: 11, color: context.textGrey, fontFamily: 'monospace'),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 6),
                if (Platform.isWindows)
                  InkWell(
                    onTap: () => _openDirectory(_dbDirPath),
                    child: const Text('打开', style: TextStyle(fontSize: 11, color: AppColors.primary)),
                  )
                else
                  InkWell(
                    onTap: () {
                      Clipboard.setData(ClipboardData(text: _dbDirPath));
                      AppToast.success(context, '已复制数据库物理路径');
                    },
                    child: const Text('复制', style: TextStyle(fontSize: 11, color: AppColors.primary)),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 存储使用说明与安全保障卡片
  Widget _buildStorageTipsCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: context.surfaceColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: context.borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.security_rounded, color: AppColors.emerald, size: 18),
              const SizedBox(width: 8),
              Text(
                '资产迁移与物理隔离保障说明',
                style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.bold, color: context.textMain),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '1. 外部存储支持机械硬盘、固态扩展盘或 NAS 挂载目录。\n'
            '2. 迁移过程中采用字节对齐校验，全部拷贝校验通过后才会安全替换索引，避免意外断电造成音频损坏。\n'
            '3. 迁移完毕后，纪要库中的全部历史会议音频与同步点播将无缝重连，不会影响任何已转录的内容。',
            style: TextStyle(fontSize: 12, color: context.textSub, height: 1.5),
          ),
        ],
      ),
    );
  }
}
