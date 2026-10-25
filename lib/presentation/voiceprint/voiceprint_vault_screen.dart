import 'dart:async';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../../core/constants/app_colors.dart';
import '../../core/utils/app_toast.dart';
import '../../data/database/app_database.dart';
import '../../data/models/voice_print.dart';

/// 实名声纹特征库页面 (CAM++ 192维向量档案管理 + 特征指纹可视化 + 阈值调优)
class VoiceprintVaultScreen extends StatefulWidget {
  const VoiceprintVaultScreen({super.key});

  @override
  State<VoiceprintVaultScreen> createState() => _VoiceprintVaultScreenState();
}

class _VoiceprintVaultScreenState extends State<VoiceprintVaultScreen> {
  final TextEditingController _searchController = TextEditingController();
  List<VoicePrint> _voicePrints = [];
  bool _isLoading = true;
  double _similarityThreshold = 0.65;
  String _searchQuery = '';
  StreamSubscription<void>? _dbSub;

  @override
  void initState() {
    super.initState();
    _loadVoicePrints();
    _dbSub = AppDatabase.instance.onDatabaseChanged.listen((_) {
      if (mounted) _loadVoicePrints();
    });
  }

  @override
  void dispose() {
    _dbSub?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadVoicePrints() async {
    final list = await AppDatabase.instance.getAllVoicePrints();
    if (mounted) {
      setState(() {
        _voicePrints = list;
        _isLoading = false;
      });
    }
  }

  Future<void> _addNewVoicePrint() async {
    final nameController = TextEditingController();
    String? personName;
    try {
      personName = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: AppColors.surfaceElevated,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Row(
            children: [
              Icon(Icons.person_add_alt_1_rounded, color: AppColors.primary, size: 22),
              SizedBox(width: 10),
              Text('新建实名声纹档案', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '预设联系人实名档案。在实时会议或纪要详情页标注对应发言人后，系统将通过 EMA 指数平滑持续融合其 192 维声纹质心。',
                style: TextStyle(color: AppColors.textSecondary, fontSize: 12.5, height: 1.45),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: nameController,
                autofocus: true,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  hintText: '例如: 张总 / 李工程师 / 客户王经理',
                  hintStyle: const TextStyle(color: AppColors.textMuted, fontSize: 13),
                  filled: true,
                  fillColor: AppColors.background,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
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
              style: ElevatedButton.styleFrom(backgroundColor: AppColors.primary, foregroundColor: Colors.white),
              onPressed: () => Navigator.pop(ctx, nameController.text.trim()),
              child: const Text('创建档案', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      );
    } finally {
      nameController.dispose();
    }

    if (personName != null && personName.isNotEmpty) {
      final now = DateTime.now().millisecondsSinceEpoch;
      final vp = VoicePrint(
        id: 'vp_$now',
        personName: personName,
        embedding: Float32List(192),
        sampleCount: 1,
        createdAt: now,
        updatedAt: now,
      );
      await AppDatabase.instance.saveVoicePrint(vp);
      _loadVoicePrints();
      if (mounted) {
        AppToast.success(context, '实名声纹「$personName」已建立档案');
      }
    }
  }

  Future<void> _renameVoicePrint(VoicePrint vp) async {
    final ctrl = TextEditingController(text: vp.personName);
    String? newName;
    try {
      newName = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: AppColors.surfaceElevated,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Text('修改声纹档案姓名', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
          content: TextField(
            controller: ctrl,
            autofocus: true,
            style: const TextStyle(color: Colors.white),
            decoration: InputDecoration(
              filled: true,
              fillColor: AppColors.background,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消', style: TextStyle(color: AppColors.textMuted)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: AppColors.primary, foregroundColor: Colors.white),
              onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
              child: const Text('保存'),
            ),
          ],
        ),
      );
    } finally {
      ctrl.dispose();
    }

    if (newName != null && newName.isNotEmpty && newName != vp.personName) {
      await AppDatabase.instance.updateVoicePrintName(vp.id, newName);
      _loadVoicePrints();
    }
  }

  Future<void> _deleteVoicePrint(VoicePrint vp) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surfaceElevated,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: AppColors.rose),
            SizedBox(width: 8),
            Text('移除声纹档案', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
          ],
        ),
        content: Text(
          '确定要从本地声纹库中移除「${vp.personName}」的声纹特征向量吗？',
          style: const TextStyle(color: AppColors.textSecondary, fontSize: 13.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消', style: TextStyle(color: AppColors.textMuted)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.rose, foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确认移除'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await AppDatabase.instance.deleteVoicePrint(vp.id);
      _loadVoicePrints();
    }
  }

  List<VoicePrint> get _filteredVoicePrints {
    if (_searchQuery.trim().isEmpty) return _voicePrints;
    final q = _searchQuery.trim().toLowerCase();
    return _voicePrints.where((v) => v.personName.toLowerCase().contains(q)).toList();
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _filteredVoicePrints;
    final isCompact = MediaQuery.of(context).size.width < 600;

    return Scaffold(
      backgroundColor: context.bg,
      appBar: AppBar(
        backgroundColor: context.surfaceColor,
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
              child: const Icon(Icons.fingerprint_rounded, color: AppColors.primary, size: 19),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '实名声纹特征库',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: context.textMain),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (!isCompact)
                    Text(
                      'CAM++ 192维特征向量 · 在线质心池 EMA 平滑演进',
                      style: TextStyle(fontSize: 11, color: context.textGrey),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: Colors.white,
                elevation: 0,
                padding: EdgeInsets.symmetric(horizontal: isCompact ? 10 : 14, vertical: 8),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
              icon: const Icon(Icons.person_add_alt_1_rounded, size: 16),
              label: Text(
                isCompact ? '新建声纹' : '录入新声纹',
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
              ),
              onPressed: _addNewVoicePrint,
            ),
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 920),
                child: ListView(
                  padding: EdgeInsets.all(isCompact ? 14 : 20),
                  physics: const BouncingScrollPhysics(),
                  children: [
                    _buildSensitivityCard(),
                    SizedBox(height: isCompact ? 16 : 22),
                    if (isCompact) ...[
                      Row(
                        children: [
                          const Text(
                            '已沉淀的实名特征档案',
                            style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.bold, color: Colors.white),
                          ),
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                            decoration: BoxDecoration(
                              color: AppColors.primary.withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text(
                              '${_voicePrints.length} 人',
                              style: const TextStyle(color: AppColors.primary, fontSize: 11, fontWeight: FontWeight.bold),
                            ),
                          ),
                        ],
                      ),
                      if (_voicePrints.isNotEmpty) ...[
                        const SizedBox(height: 10),
                        TextField(
                          controller: _searchController,
                          style: const TextStyle(color: Colors.white, fontSize: 12.5),
                          decoration: InputDecoration(
                            hintText: '搜索联系人姓名...',
                            hintStyle: const TextStyle(color: AppColors.textMuted, fontSize: 12),
                            prefixIcon: const Icon(Icons.search_rounded, size: 17, color: AppColors.textMuted),
                            isDense: true,
                            filled: true,
                            fillColor: AppColors.surface,
                            contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8),
                              borderSide: const BorderSide(color: AppColors.cardBorder),
                            ),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8),
                              borderSide: const BorderSide(color: AppColors.cardBorder),
                            ),
                          ),
                          onChanged: (v) => setState(() => _searchQuery = v),
                        ),
                      ],
                    ] else
                      Row(
                        children: [
                          const Text(
                            '已沉淀的实名特征档案',
                            style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Colors.white),
                          ),
                          const SizedBox(width: 10),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                            decoration: BoxDecoration(
                              color: AppColors.primary.withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text(
                              '${_voicePrints.length} 人',
                              style: const TextStyle(color: AppColors.primary, fontSize: 11, fontWeight: FontWeight.bold),
                            ),
                          ),
                          const Spacer(),
                          if (_voicePrints.isNotEmpty)
                            SizedBox(
                              width: 220,
                              child: TextField(
                                controller: _searchController,
                                style: const TextStyle(color: Colors.white, fontSize: 12.5),
                                decoration: InputDecoration(
                                  hintText: '搜索联系人姓名...',
                                  hintStyle: const TextStyle(color: AppColors.textMuted, fontSize: 12),
                                  prefixIcon: const Icon(Icons.search_rounded, size: 17, color: AppColors.textMuted),
                                  isDense: true,
                                  filled: true,
                                  fillColor: AppColors.surface,
                                  contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(8),
                                    borderSide: const BorderSide(color: AppColors.cardBorder),
                                  ),
                                  enabledBorder: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(8),
                                    borderSide: const BorderSide(color: AppColors.cardBorder),
                                  ),
                                ),
                                onChanged: (v) => setState(() => _searchQuery = v),
                              ),
                            ),
                        ],
                      ),
                    const SizedBox(height: 12),
                    if (filtered.isEmpty)
                      _buildEmptyVaultState()
                    else
                      ...filtered.asMap().entries.map((entry) => _buildVoicePrintCard(entry.value, entry.key, isCompact: isCompact)),
                  ],
                ),
              ),
            ),
    );
  }

  Widget _buildEmptyVaultState() {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 48, horizontal: 32),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.cardBorder),
      ),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: AppColors.surfaceElevated,
              shape: BoxShape.circle,
              border: Border.all(color: AppColors.cardBorder),
            ),
            child: const Icon(Icons.fingerprint_rounded, size: 46, color: AppColors.primary),
          ),
          const SizedBox(height: 16),
          const Text(
            '暂无实名声纹档案',
            style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          const Text(
            '在纪要详情页点击角色标签重命名并勾选「沉淀至实名声纹库」，或点击右上角按钮添加联系人，后续会议即可自动识别发言人姓名。',
            textAlign: TextAlign.center,
            style: TextStyle(color: AppColors.textMuted, fontSize: 12.5, height: 1.5),
          ),
          const SizedBox(height: 20),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              foregroundColor: AppColors.primary,
              side: const BorderSide(color: AppColors.primary),
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            ),
            icon: const Icon(Icons.add_rounded, size: 18),
            label: const Text('立即创建首个声纹档案', style: TextStyle(fontWeight: FontWeight.bold)),
            onPressed: _addNewVoicePrint,
          ),
        ],
      ),
    );
  }

  Widget _buildSensitivityCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.radar_rounded, size: 18, color: AppColors.primary),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  '声纹余弦相似度判同阈值',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.white),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                decoration: BoxDecoration(
                  color: AppColors.primary.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: AppColors.primary.withValues(alpha: 0.4)),
                ),
                child: Text(
                  _similarityThreshold.toStringAsFixed(2),
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    color: AppColors.primary,
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          const Text(
            '阈值越高（如 0.75）判定越严格杜绝认错人；阈值越低（如 0.55）越容忍感冒或远场麦克风音质衰减。',
            style: TextStyle(color: AppColors.textMuted, fontSize: 12),
          ),
          const SizedBox(height: 6),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              activeTrackColor: AppColors.primary,
              inactiveTrackColor: AppColors.surfaceElevated,
              thumbColor: Colors.white,
              trackHeight: 4,
            ),
            child: Slider(
              value: _similarityThreshold,
              min: 0.50,
              max: 0.85,
              divisions: 35,
              onChanged: (val) {
                setState(() {
                  _similarityThreshold = val;
                });
              },
            ),
          ),
          // 滑动条刻度说明 (自适应等宽分布与左中右对齐，杜绝大字体溢出)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Row(
              children: const [
                Expanded(
                  child: Text(
                    '宽松远场 (0.50)',
                    style: TextStyle(fontSize: 10.5, color: AppColors.textMuted),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Expanded(
                  child: Text(
                    '黄金平衡 (0.65)',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 10.5, color: AppColors.textSecondary, fontWeight: FontWeight.w600),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Expanded(
                  child: Text(
                    '严苛防串音 (0.85)',
                    textAlign: TextAlign.right,
                    style: TextStyle(fontSize: 10.5, color: AppColors.textMuted),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildVoicePrintCard(VoicePrint vp, int index, {required bool isCompact}) {
    final spkColor = AppColors.getSpeakerColor(null, index: index);
    final dt = DateTime.fromMillisecondsSinceEpoch(vp.updatedAt);
    final dateStr = '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: EdgeInsets.all(isCompact ? 12 : 16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.cardBorder),
      ),
      child: Row(
        children: [
          Container(
            width: isCompact ? 38 : 44,
            height: isCompact ? 38 : 44,
            decoration: BoxDecoration(
              color: spkColor.surfaceColor,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: spkColor.color.withValues(alpha: 0.5), width: 1.2),
            ),
            child: Center(
              child: Text(
                vp.personName.isNotEmpty ? vp.personName.substring(0, 1) : '?',
                style: TextStyle(color: spkColor.color, fontWeight: FontWeight.bold, fontSize: isCompact ? 15 : 17),
              ),
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
                        vp.personName,
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14.5),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: spkColor.color.withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        '融合 ${vp.sampleCount} 次',
                        style: TextStyle(color: spkColor.color, fontSize: 10.5, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  '${vp.embedding.length}维声纹向量 • 更新于 $dateStr',
                  style: const TextStyle(color: AppColors.textMuted, fontSize: 11.5),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          if (!isCompact) ...[
            _buildEmbeddingFingerprintBar(vp, spkColor.color),
            const SizedBox(width: 12),
          ],
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: '重命名联系人',
            icon: const Icon(Icons.edit_outlined, size: 18, color: AppColors.textSecondary),
            onPressed: () => _renameVoicePrint(vp),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: '移除声纹档案',
            icon: const Icon(Icons.delete_outline_rounded, size: 18, color: AppColors.textMuted),
            onPressed: () => _deleteVoicePrint(vp),
          ),
        ],
      ),
    );
  }

  /// 基于联系人哈希或真实向量绘制 12 根特征柱状指纹
  Widget _buildEmbeddingFingerprintBar(VoicePrint vp, Color color) {
    final seed = vp.personName.hashCode;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(12, (i) {
        final v = vp.embedding.isNotEmpty && vp.embedding[i].abs() > 0.001
            ? vp.embedding[i].abs().clamp(0.15, 1.0)
            : (0.25 + 0.65 * ((sin(seed + i * 1.7) + 1) / 2));
        return Container(
          width: 3,
          height: 24 * v,
          margin: const EdgeInsets.symmetric(horizontal: 1.2),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.65),
            borderRadius: BorderRadius.circular(2),
          ),
        );
      }),
    );
  }
}
