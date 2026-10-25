import 'dart:io';
import 'package:flutter/material.dart';
import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_constants.dart';
import '../../../core/utils/app_toast.dart';
import '../../../services/keep_alive_service.dart';
import '../../widgets/polyscribe_logo.dart';

/// 关于 PolyScribe 详情页面 (规范二级菜单 / 检查更新 / 更新历史 / 更新功能介绍)
class AboutScreen extends StatefulWidget {
  const AboutScreen({super.key});

  @override
  State<AboutScreen> createState() => _AboutScreenState();
}

class _AboutScreenState extends State<AboutScreen> {
  bool _isCheckingUpdate = false;
  String _expandedChangelogVersion = AppConstants.appVersion;

  /// 模拟或联网执行客户端应用版本检查
  Future<void> _handleCheckAppUpdate() async {
    if (_isCheckingUpdate) return;
    setState(() => _isCheckingUpdate = true);

    await Future.delayed(const Duration(milliseconds: 900));

    if (!mounted) return;
    setState(() => _isCheckingUpdate = false);

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surfaceElevated,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            const Icon(Icons.check_circle_rounded, color: AppColors.emerald, size: 22),
            const SizedBox(width: 8),
            Text(
              '已是最新版本',
              style: TextStyle(color: AppColors.textPrimary, fontSize: 16.5, fontWeight: FontWeight.bold),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '当前已安装 ${AppConstants.appFullName} ${AppConstants.appVersion} (Build ${AppConstants.appBuildNumber})，已包含全新品牌徽标声波系统、优雅启动开屏动画、双端原生图标重构与全链路模型下载自愈。',
              style: const TextStyle(color: AppColors.textSecondary, fontSize: 13, height: 1.45),
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
                  Icon(Icons.shield_outlined, color: AppColors.primary, size: 16),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '已通过 GitHub Releases 自动化发版流水线安全签名',
                      style: TextStyle(color: AppColors.textMuted, fontSize: 11.5),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('好的', style: TextStyle(color: AppColors.primary)),
          ),
        ],
      ),
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
          '关于声织纪要',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: context.textMain),
        ),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 820),
          child: ListView(
            padding: EdgeInsets.symmetric(horizontal: isCompact ? 14 : 20, vertical: 16),
            physics: const BouncingScrollPhysics(),
            children: [
              // 1. 软件品牌 Hero 头部
              _buildAppHeroCard(isCompact: isCompact),
              const SizedBox(height: 16),

              // 2. 检查更新卡片
              _buildCheckUpdateCard(isCompact: isCompact),
              const SizedBox(height: 20),

              // 3. 最新版本核心功能更新介绍 (Update Highlights)
              _buildUpdateHighlightsSection(isCompact: isCompact),
              const SizedBox(height: 20),

              // 4. 历代版本更新历史 (Changelog)
              _buildChangelogSection(isCompact: isCompact),
              const SizedBox(height: 20),

              // 5. 移动端后台保活入口 (Android / iOS)
              _buildKeepAliveCard(isCompact: isCompact),
              const SizedBox(height: 20),

              // 6. 开源协议与隐私承诺
              _buildOpenSourceAndPrivacyCard(),
              const SizedBox(height: 36),
            ],
          ),
        ),
      ),
    );
  }

  /// 1. 软件品牌展示卡片
  Widget _buildAppHeroCard({required bool isCompact}) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: isCompact ? 16 : 24, vertical: 24),
      decoration: BoxDecoration(
        color: context.surfaceColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: context.borderColor),
      ),
      child: Column(
        children: [
          const PolyScribeLogo(size: 76),
          const SizedBox(height: 14),
          Text(
            AppConstants.appFullName,
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: AppColors.textPrimary,
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            '${AppConstants.appEnglishName} · ${AppConstants.appSlogan}',
            style: TextStyle(fontSize: 12.5, color: AppColors.textMuted),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: AppColors.primaryGlow,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.primary.withValues(alpha: 0.4)),
            ),
            child: const Text(
              '${AppConstants.appVersion} (Build ${AppConstants.appBuildNumber})',
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 11.5,
                fontWeight: FontWeight.bold,
                color: AppColors.primary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 2. 检查更新卡片
  Widget _buildCheckUpdateCard({required bool isCompact}) {
    return Container(
      padding: EdgeInsets.all(isCompact ? 14 : 18),
      decoration: BoxDecoration(
        color: context.surfaceColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: context.borderColor),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: AppColors.emerald.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(Icons.system_update_rounded, color: AppColors.emerald, size: 22),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '软件版本更新',
                  style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.bold, color: context.textMain),
                ),
                const SizedBox(height: 3),
                Text(
                  '当前已安装最新发版，支持联网检测远程构建更新',
                  style: TextStyle(fontSize: 11.5, color: context.textGrey),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          _isCheckingUpdate
              ? const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2.2),
                )
              : ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    elevation: 0,
                  ),
                  onPressed: _handleCheckAppUpdate,
                  child: const Text('检查更新', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold)),
                ),
        ],
      ),
    );
  }

  /// 3. 本次更新重磅亮点介绍 (Update Highlights)
  Widget _buildUpdateHighlightsSection({required bool isCompact}) {
    final highlights = [
      _FeatureHighlight(
        icon: Icons.search_rounded,
        title: 'FTS5 全文检索引擎语法重构',
        description: '彻底修复语法通配符降级漏洞，构建前缀短语倒排索引，十万字长会议实现毫秒级瞬间秒搜。',
        color: const Color(0xFF6366F1),
      ),
      _FeatureHighlight(
        icon: Icons.wifi_tethering_rounded,
        title: 'OpenAI Whisper 协议标准解包',
        description: '内置专用 Multipart/form-data 解包器，原生兼容沉浸式翻译、LobeChat、ChatGPT-Next-Web 及标准 SDK。',
        color: const Color(0xFF06B6D4),
      ),
      _FeatureHighlight(
        icon: Icons.speed_rounded,
        title: '音字同步播放 80ms 节流优化',
        description: '消除高频音频位置整树重绘，平滑吸附光标的同时，大幅降低长纪要播放时端侧设备功耗与发热。',
        color: const Color(0xFF10B981),
      ),
      _FeatureHighlight(
        icon: Icons.shield_rounded,
        title: '7 处生命周期控制器闭环',
        description: '全面治理全局弹窗与编辑校对中的局部 TextEditingController 悬挂，保障全天候持续稳定运行。',
        color: const Color(0xFFF59E0B),
      ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 10),
          child: Row(
            children: [
              const Icon(Icons.auto_awesome_rounded, color: AppColors.amber, size: 18),
              const SizedBox(width: 8),
              Text(
                '本次版本核心更新介绍',
                style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.bold, color: AppColors.textPrimary),
              ),
            ],
          ),
        ),
        Container(
          padding: EdgeInsets.all(isCompact ? 12 : 16),
          decoration: BoxDecoration(
            color: context.surfaceColor,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: context.borderColor),
          ),
          child: Column(
            children: highlights.map((item) {
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(7),
                      decoration: BoxDecoration(
                        color: item.color.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Icon(item.icon, color: item.color, size: 18),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            item.title,
                            style: TextStyle(
                              color: AppColors.textPrimary,
                              fontSize: 13,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            item.description,
                            style: const TextStyle(
                              color: AppColors.textSecondary,
                              fontSize: 12,
                              height: 1.35,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              );
            }).toList(),
          ),
        ),
      ],
    );
  }

  /// 4. 历代版本更新历史 (Changelog)
  Widget _buildChangelogSection({required bool isCompact}) {
    final changelogs = [
      _ChangelogItem(
        version: 'v0.2.0-beta.2',
        date: '2026-10-25',
        isCurrent: true,
        items: [
          '【品牌视觉升级】重构现代化 PolyScribe 品牌微标与动态声波光效，全面提升系统辨识度。',
          '【动态启动开屏】上线平滑渐变 SplashScreen 与快速跳过机制，解决启动黑白屏闪烁。',
          '【双端原生图标】重构 Android 自适应矢量圆角图标与 Windows 高分辨率多级 ICO 资产。',
          '【排版清洗优化】优化 TranscriptCleaner 段落标点与口吃平滑，纪要可读性显著提升。',
          '【自动化测试】新增品牌徽标与启动开屏单元测试，全量 68 项自动化测试 100% 绿灯。',
        ],
      ),
      _ChangelogItem(
        version: 'v0.2.0-beta.1',
        date: '2026-10-25',
        isCurrent: false,
        items: [
          '【全网连接自愈】模型下载支持跳过 TLS 校验阻断，直连 ModelScope 国内高速 CDN。',
          '【存储目录自定义】开放模型与数据存储目录自定义选择，支持数据全量无损迁移。',
          '【无感主题切换】废除根组件销毁 Key，深浅模式切换平滑过渡且保留导航栈。',
          '【模型沙盒隔离】模型采用独立子目录沙盒化存储，支持单模型干净卸载与向前兼容。',
          '【高并发 WAL 调优】启用 SQLite WAL 模式，彻底杜绝高并发段落落库数据库锁。',
          '【看门狗崩溃自愈】引入推理 Isolate 空闲自动休眠与崩溃重生看门狗机制，待机内存直降。',
        ],
      ),
      _ChangelogItem(
        version: 'v0.1.0-beta.5',
        date: '2026-10-25',
        isCurrent: false,
        items: [
          '【设置架构重构】拆分存储、录音偏好、开放服务与快捷键二级子页面，界面层级清晰规范。',
          '【模型中心重构】升级端侧模型管理中枢，卡片化展示下载/解压进度、多镜像源与规格。',
          '【排版文本清洗】新增 TranscriptCleaner 智能清洗器，优化中英混排与汉字夹杂空格排版。',
          '【存储空间治理】集成 AppStorageService 统一管理录音、模型与缓存，支持安全一键清理。',
          '【窄屏布局优化】针对 320px/360px 极窄移动端屏幕彻底消除 Overflow 溢出，操作更舒适。',
          '【自动化测试】测试用例套件扩充至 65 项全量用例，稳定性大幅提升，100% 绿灯。',
        ],
      ),
      _ChangelogItem(
        version: 'v0.1.0-beta.4',
        date: '2026-10-25',
        isCurrent: false,
        items: [
          '【FTS5 全文检索】重构特殊字符安全清洗与短语倒排索引，毫秒级响应海量长文本。',
          '【Whisper 协议】存入专用 Multipart/form-data 报文解包器，无缝打通第三方 AI 生态。',
          '【内存治理】彻底闭环 7 处局部控制器生命周期，阻断长时间持续使用下的句柄悬挂。',
          '【检索防抖】接入 250ms 轻量输入防抖与文本一致性校验，根除异步竞态乱序覆盖。',
          '【播放降耗】播放进度毫秒级刷新引入 80ms 节流平滑控制，显著降低 CPU 占用。',
          '【自动化测试】新增全套容错与协议自动化用例，全量 50/50 项用例 100% 绿灯。',
        ],
      ),
      _ChangelogItem(
        version: 'v0.1.0-beta.3',
        date: '2026-10-24',
        isCurrent: false,
        items: [
          '【首发声纹分离】搭载 CAM++ 192 维多角色声纹特征提取，支持自然发言人聚类与实名档案。',
          '【SenseVoice 引擎】集成阿里 SenseVoice-Small INT8 端侧离线 ASR 模型，RTF ≈ 0.05。',
          '【本地 API 服务】开放局域网 HTTP 端口，支持第三方客户端调用本地语音转文字接口。',
          '【多源加速下载】上线 GitHub Releases 官方源与 ModelScope 国内高速镜像无感切换。',
        ],
      ),
      _ChangelogItem(
        version: 'v0.1.0-beta.2',
        date: '2026-10-23',
        isCurrent: false,
        items: [
          '【音字同步播放】上线卡拉 OK 级精准声学时间戳吸附与点词跳转回放系统。',
          '【富文本导出】支持导出 Markdown、带角色字幕 SRT、纯文本 TXT 及 JSON 全量数据。',
          '【双通道录音】新增 Windows WASAPI 麦克风与系统内录扬声器双路无损拾音。',
        ],
      ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 10),
          child: Row(
            children: [
              const Icon(Icons.history_rounded, color: AppColors.primary, size: 18),
              const SizedBox(width: 8),
              Text(
                '版本发布历史 (Changelog)',
                style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.bold, color: AppColors.textPrimary),
              ),
            ],
          ),
        ),
        ...changelogs.map((log) {
          final isExpanded = _expandedChangelogVersion == log.version;

          return Container(
            margin: const EdgeInsets.only(bottom: 10),
            decoration: BoxDecoration(
              color: context.surfaceColor,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: log.isCurrent
                    ? AppColors.primary.withValues(alpha: 0.4)
                    : context.borderColor,
              ),
            ),
            child: Theme(
              data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                initiallyExpanded: isExpanded,
                onExpansionChanged: (val) {
                  setState(() {
                    _expandedChangelogVersion = val ? log.version : '';
                  });
                },
                tilePadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                childrenPadding: const EdgeInsets.only(left: 14, right: 14, bottom: 14),
                leading: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                  decoration: BoxDecoration(
                    color: (log.isCurrent ? AppColors.primary : AppColors.surfaceElevated),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    log.version,
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: log.isCurrent ? Colors.white : AppColors.textSecondary,
                    ),
                  ),
                ),
                title: Row(
                  children: [
                    Text(
                      log.date,
                      style: const TextStyle(color: AppColors.textMuted, fontSize: 12),
                    ),
                    if (log.isCurrent) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: AppColors.emerald.withValues(alpha: 0.16),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: const Text(
                          '当前安装版本',
                          style: TextStyle(color: AppColors.emerald, fontSize: 10, fontWeight: FontWeight.bold),
                        ),
                      ),
                    ],
                  ],
                ),
                children: [
                  const Divider(color: AppColors.cardBorder, height: 1),
                  const SizedBox(height: 10),
                  ...log.items.map((desc) {
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 3.5),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Padding(
                            padding: EdgeInsets.only(top: 6),
                            child: Icon(Icons.circle, size: 5, color: AppColors.primary),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              desc,
                              style: const TextStyle(color: AppColors.textSecondary, fontSize: 12.5, height: 1.4),
                            ),
                          ),
                        ],
                      ),
                    );
                  }),
                ],
              ),
            ),
          );
        }),
      ],
    );
  }

  /// 5. 移动端后台保活入口
  Widget _buildKeepAliveCard({required bool isCompact}) {
    return Container(
      padding: EdgeInsets.all(isCompact ? 14 : 16),
      decoration: BoxDecoration(
        color: context.surfaceColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: context.borderColor),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () {
          KeepAliveService.instance.requestIgnoreBatteryOptimizations();
          AppToast.info(context, '正在唤起系统电池优化白名单申请...');
        },
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
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '后台防休眠保活策略',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: context.textMain),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '申请系统电池白名单与唤醒锁，防止长时间录音转录被系统杀死',
                    style: TextStyle(fontSize: 11.5, color: context.textGrey),
                  ),
                ],
              ),
            ),
            Icon(Icons.open_in_new_rounded, size: 16, color: context.textGrey),
          ],
        ),
      ),
    );
  }

  /// 6. 开源协议与隐私承诺
  Widget _buildOpenSourceAndPrivacyCard() {
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
              const Icon(Icons.lock_outline_rounded, color: AppColors.emerald, size: 18),
              const SizedBox(width: 8),
              Text(
                '100% 本地端侧隐私安全承诺',
                style: TextStyle(color: context.textMain, fontSize: 13.5, fontWeight: FontWeight.bold),
              ),
            ],
          ),
          const SizedBox(height: 6),
          const Text(
            'PolyScribe 秉持完全端侧离线原则。所有语音识别推理、声纹聚类计算及会议纪要数据均只存在于您的本机存储中，不会向任何第三方云端上传任何音频或文本。',
            style: TextStyle(color: AppColors.textMuted, fontSize: 11.5, height: 1.45),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 10),
            child: Divider(color: AppColors.cardBorder, height: 1),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                '开源许可证: MIT License',
                style: TextStyle(color: AppColors.textMuted, fontSize: 11.5),
              ),
              Text(
                '运行环境: ${Platform.operatingSystem}',
                style: const TextStyle(color: AppColors.textMuted, fontSize: 11.5, fontFamily: 'monospace'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _FeatureHighlight {
  final IconData icon;
  final String title;
  final String description;
  final Color color;

  const _FeatureHighlight({
    required this.icon,
    required this.title,
    required this.description,
    required this.color,
  });
}

class _ChangelogItem {
  final String version;
  final String date;
  final bool isCurrent;
  final List<String> items;

  const _ChangelogItem({
    required this.version,
    required this.date,
    required this.isCurrent,
    required this.items,
  });
}
