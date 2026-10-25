import 'package:flutter/material.dart';
import '../../../core/constants/app_colors.dart';
import '../../../core/utils/app_toast.dart';
import '../../../data/database/app_database.dart';

/// 音频采样与识别调优二级设置页面
class AudioTuningSettingsScreen extends StatefulWidget {
  const AudioTuningSettingsScreen({super.key});

  @override
  State<AudioTuningSettingsScreen> createState() => _AudioTuningSettingsScreenState();
}

class _AudioTuningSettingsScreenState extends State<AudioTuningSettingsScreen> {
  double _vadSilenceThreshold = 0.8;
  bool _enableDriftSuppression = true;
  String _preferredLanguage = 'zh';
  bool _autoResumeTranscription = true;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final savedLang = await AppDatabase.instance.getSetting('preferred_language') ?? 'zh';
    final autoResumeVal = await AppDatabase.instance.getSetting('auto_resume_transcription');
    final autoResume = autoResumeVal == null ? true : (autoResumeVal == 'true');

    if (mounted) {
      setState(() {
        _preferredLanguage = savedLang;
        _autoResumeTranscription = autoResume;
        _isLoading = false;
      });
    }
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
          '音频采样与识别调优',
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
                    // 1. 识别语种偏好（强化中文识别建议）
                    _buildLanguageSection(isCompact: isCompact),
                    const SizedBox(height: 16),

                    // 2. VAD 静音截断与抗漂移
                    _buildVadTuningCard(isCompact: isCompact),
                    const SizedBox(height: 16),

                    // 3. 任务自愈与断点续转
                    _buildTaskResumeCard(isCompact: isCompact),
                    const SizedBox(height: 36),
                  ],
                ),
              ),
            ),
    );
  }

  Widget _buildLanguageSection({required bool isCompact}) {
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
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: AppColors.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(Icons.translate_rounded, color: AppColors.primary, size: 20),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '目标识别语种偏好',
                      style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.bold, color: AppColors.textPrimary),
                    ),
                    const SizedBox(height: 2),
                    const Text(
                      '指定首选母语可大幅提升中文断句与生僻词识别置信度',
                      style: TextStyle(fontSize: 12, color: AppColors.textMuted),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              _buildLanguageChip('zh', '简体中文 (推荐)', Icons.translate_rounded),
              const SizedBox(width: 8),
              _buildLanguageChip('auto', '自动多语种', Icons.auto_awesome_rounded),
              const SizedBox(width: 8),
              _buildLanguageChip('en', '强制英文', Icons.language_rounded),
            ],
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: AppColors.background,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppColors.cardBorder),
            ),
            child: const Row(
              children: [
                Icon(Icons.lightbulb_outline_rounded, color: AppColors.amber, size: 16),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '提示：如果感觉识别率偏低，推荐将语种偏好设置为「简体中文」，可显著避免自动模式误判为英文或粤语。',
                    style: TextStyle(color: AppColors.textSecondary, fontSize: 11.5, height: 1.35),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

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
          padding: const EdgeInsets.symmetric(vertical: 11, horizontal: 6),
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
                  color: isSelected ? AppColors.primary : AppColors.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildVadTuningCard({required bool isCompact}) {
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
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'VAD 语音停顿截断阈值',
                      style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.bold, color: AppColors.textPrimary),
                    ),
                    const SizedBox(height: 2),
                    const Text(
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
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '短语音角色漂移抑制',
                      style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: AppColors.textPrimary),
                    ),
                    const SizedBox(height: 2),
                    const Text(
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
        ],
      ),
    );
  }

  Widget _buildTaskResumeCard({required bool isCompact}) {
    return Container(
      padding: EdgeInsets.all(isCompact ? 14 : 18),
      decoration: BoxDecoration(
        color: context.surfaceColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: context.borderColor),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '进入软件自动继续转写',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: AppColors.textPrimary),
                ),
                const SizedBox(height: 2),
                const Text(
                  '冷启动或重新打开软件时，自动恢复未完成与已暂停任务的后台断点转写',
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
    );
  }
}
