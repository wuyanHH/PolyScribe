import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../../core/constants/app_colors.dart';
import '../../data/database/app_database.dart';
import '../../data/models/voice_print.dart';

/// 实名声纹特征库页面
class VoiceprintVaultScreen extends StatefulWidget {
  const VoiceprintVaultScreen({super.key});

  @override
  State<VoiceprintVaultScreen> createState() => _VoiceprintVaultScreenState();
}

class _VoiceprintVaultScreenState extends State<VoiceprintVaultScreen> {
  List<VoicePrint> _voicePrints = [];
  bool _isLoading = true;
  double _similarityThreshold = 0.65;

  @override
  void initState() {
    super.initState();
    _loadVoicePrints();
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
    final personName = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('录入实名声纹', style: TextStyle(color: Colors.white, fontSize: 16)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '输入联系人姓名，后续在实时会议和外部录音转写中将自动比对余弦相似度并自动打标。',
              style: TextStyle(color: Colors.grey, fontSize: 12),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: nameController,
              autofocus: true,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                hintText: '例如: 张总 / 李工程师',
                hintStyle: const TextStyle(color: Colors.grey),
                filled: true,
                fillColor: AppColors.background,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消', style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, nameController.text.trim()),
            child: const Text('确定录入'),
          ),
        ],
      ),
    );

    if (personName != null && personName.isNotEmpty) {
      final now = DateTime.now().millisecondsSinceEpoch;
      final vp = VoicePrint(
        id: 'vp_${DateTime.now().millisecondsSinceEpoch}',
        personName: personName,
        embedding: Float32List(192),
        sampleCount: 1,
        createdAt: now,
        updatedAt: now,
      );
      await AppDatabase.instance.saveVoicePrint(vp);
      _loadVoicePrints();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('实名声纹「$personName」已建立档案')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        title: const Text('实名声纹特征库', style: TextStyle(fontWeight: FontWeight.bold)),
        actions: [
          IconButton(
            tooltip: '录入新声纹',
            icon: const Icon(Icons.person_add_alt_1_rounded),
            onPressed: _addNewVoicePrint,
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _buildSensitivityCard(),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      '已沉淀的实名特征列表',
                      style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Colors.white),
                    ),
                    Text(
                      '共 ${_voicePrints.length} 人',
                      style: const TextStyle(color: Colors.grey, fontSize: 12),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                if (_voicePrints.isEmpty)
                  Container(
                    padding: const EdgeInsets.all(32),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: AppColors.surface,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      children: [
                        Icon(Icons.fingerprint_rounded, size: 50, color: Colors.grey.withValues(alpha: 0.5)),
                        const SizedBox(height: 12),
                        const Text(
                          '暂无实名声纹档案',
                          style: TextStyle(color: Colors.white70, fontSize: 15, fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 6),
                        const Text(
                          '在纪要详情页给角色重命名并勾选入库，或点击右上角添加联系人，开会时即可自动辨识姓名。',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.grey, fontSize: 12),
                        ),
                      ],
                    ),
                  )
                else
                  ..._voicePrints.map((vp) => _buildVoicePrintCard(vp)),
              ],
            ),
    );
  }

  Widget _buildSensitivityCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.surfaceLight),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                '声纹余弦相似度匹配阈值',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.white),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: AppColors.primary.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  _similarityThreshold.toStringAsFixed(2),
                  style: const TextStyle(color: AppColors.primary, fontWeight: FontWeight.bold, fontSize: 12),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            '阈值越高（如 0.75）判定越严格杜绝认错人；阈值越低（如 0.55）越容忍感冒或麦克风音质变异。',
            style: TextStyle(color: Colors.grey, fontSize: 11),
          ),
          Slider(
            value: _similarityThreshold,
            min: 0.50,
            max: 0.85,
            divisions: 35,
            activeColor: AppColors.primary,
            onChanged: (val) {
              setState(() {
                _similarityThreshold = val;
              });
            },
          ),
        ],
      ),
    );
  }

  Widget _buildVoicePrintCard(VoicePrint vp) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.surfaceLight),
      ),
      child: Row(
        children: [
          CircleAvatar(
            backgroundColor: AppColors.primary.withValues(alpha: 0.2),
            child: Text(
              vp.personName.isNotEmpty ? vp.personName.substring(0, 1) : '?',
              style: const TextStyle(color: AppColors.primary, fontWeight: FontWeight.bold),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  vp.personName,
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14),
                ),
                const SizedBox(height: 4),
                Text(
                  'CAM++ 192维向量 • 采样次数: ${vp.sampleCount}',
                  style: const TextStyle(color: Colors.grey, fontSize: 11),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline, size: 18, color: Colors.grey),
            onPressed: () async {
              final db = await AppDatabase.instance.database;
              await db.delete('voice_prints', where: 'id = ?', whereArgs: [vp.id]);
              _loadVoicePrints();
            },
          ),
        ],
      ),
    );
  }
}
