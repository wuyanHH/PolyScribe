import 'dart:async';
import 'package:flutter/material.dart';
import '../../core/constants/app_colors.dart';
import '../../core/constants/app_constants.dart';
import '../widgets/polyscribe_logo.dart';

/// PolyScribe (声织纪要) 品牌动态启动页
/// 采用深空声纹星云 + 五重多角色声波交织徽标 + 端侧引擎自检状态动效，
/// 支持平滑淡出过渡与一键快速跳过，兼顾旗舰级品牌质感与极速生产力体验。
class SplashScreen extends StatefulWidget {
  /// 启动页完成后要进入的目标主页面
  final Widget child;

  /// 是否启用启动屏过渡动画 (单元测试或指定直达时可设为 false)
  final bool enabled;

  /// 启动页持续展示时长
  final Duration duration;

  const SplashScreen({
    super.key,
    required this.child,
    this.enabled = true,
    this.duration = const Duration(milliseconds: 1650),
  });

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  late bool _showSplash;
  late AnimationController _entryController;
  late Animation<double> _fadeIn;
  late Animation<double> _scaleUp;
  late Animation<double> _progressAnim;
  Timer? _dismissTimer;

  @override
  void initState() {
    super.initState();
    _showSplash = widget.enabled;

    _entryController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1350),
    );

    _fadeIn = CurvedAnimation(
      parent: _entryController,
      curve: const Interval(0.0, 0.55, curve: Curves.easeOutCubic),
    );

    _scaleUp = Tween<double>(begin: 0.88, end: 1.0).animate(
      CurvedAnimation(
        parent: _entryController,
        curve: const Interval(0.0, 0.65, curve: Curves.easeOutBack),
      ),
    );

    _progressAnim = CurvedAnimation(
      parent: _entryController,
      curve: const Interval(0.15, 1.0, curve: Curves.easeInOutCubic),
    );

    if (_showSplash) {
      _entryController.forward();
      _dismissTimer = Timer(widget.duration, _finishSplash);
    }
  }

  void _finishSplash() {
    _dismissTimer?.cancel();
    if (mounted && _showSplash) {
      setState(() {
        _showSplash = false;
      });
    }
  }

  @override
  void dispose() {
    _dismissTimer?.cancel();
    _entryController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) {
      return widget.child;
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        // 底层主导航视图预先挂载就绪，确保过渡零白屏、零卡顿
        widget.child,

        // 顶层品牌动态启动遮罩 (平滑淡出并在完成后彻底卸载)
        IgnorePointer(
          ignoring: !_showSplash,
          child: AnimatedOpacity(
            opacity: _showSplash ? 1.0 : 0.0,
            duration: const Duration(milliseconds: 420),
            curve: Curves.easeInOutCubic,
            child: _buildSplashOverlay(context),
          ),
        ),
      ],
    );
  }

  Widget _buildSplashOverlay(BuildContext context) {
    final media = MediaQuery.of(context);
    final isCompact = media.size.height < 640 || media.size.width < 380;

    return Scaffold(
      backgroundColor: const Color(0xFF0B0F19),
      body: Stack(
        fit: StackFit.expand,
        children: [
          // 1. 深空声纹氛围星云光晕背景
          const _SplashAmbientBackdrop(),

          // 2. 右上角快速跳过按钮
          SafeArea(
            child: Align(
              alignment: Alignment.topRight,
              child: Padding(
                padding: const EdgeInsets.only(top: 12, right: 16),
                child: TextButton.icon(
                  onPressed: _finishSplash,
                  style: TextButton.styleFrom(
                    foregroundColor: AppColors.textSecondary,
                    backgroundColor: const Color(0xFF131B2E).withValues(alpha: 0.75),
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(20),
                      side: BorderSide(color: AppColors.cardBorder.withValues(alpha: 0.8)),
                    ),
                  ),
                  icon: const Icon(Icons.bolt_rounded, size: 14, color: AppColors.primary),
                  label: const Text(
                    '进入工作台',
                    style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w500),
                  ),
                ),
              ),
            ),
          ),

          // 3. 中心主品牌视觉区
          SafeArea(
            child: Center(
              child: SingleChildScrollView(
                physics: const NeverScrollableScrollPhysics(),
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: FadeTransition(
                  opacity: _fadeIn,
                  child: ScaleTransition(
                    scale: _scaleUp,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // 动态呼吸「声织纪要」核心徽标
                        PolyScribeLogo(
                          size: isCompact ? 96 : 118,
                          showBackground: true,
                          animate: _showSplash,
                        ),
                        SizedBox(height: isCompact ? 22 : 28),

                        // 品牌中文名 + PRO 徽章
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Text(
                              AppConstants.appFullName,
                              style: TextStyle(
                                color: Color(0xFFF8FAFC),
                                fontSize: 28,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 2.0,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                              decoration: BoxDecoration(
                                gradient: const LinearGradient(
                                  colors: [AppColors.primary, AppColors.primaryDark],
                                ),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: const Text(
                                'PRO',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: 0.8,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),

                        // 英文品牌标识与核心定位 Slogan
                        Text(
                          '${AppConstants.appEnglishName.toUpperCase()}  ·  ${AppConstants.appSlogan}',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Color(0xFF94A3B8),
                            fontSize: 12.5,
                            fontWeight: FontWeight.w500,
                            letterSpacing: 1.1,
                          ),
                        ),
                        SizedBox(height: isCompact ? 20 : 28),

                        // 多角色色彩声纹光谱指示点 (6色声纹调色板呼应)
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: AppColors.speakerPalette.map((spk) {
                            return Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 4),
                              child: Container(
                                width: 6,
                                height: 6,
                                decoration: BoxDecoration(
                                  color: spk.color,
                                  shape: BoxShape.circle,
                                  boxShadow: [
                                    BoxShadow(
                                      color: spk.color.withValues(alpha: 0.5),
                                      blurRadius: 6,
                                    ),
                                  ],
                                ),
                              ),
                            );
                          }).toList(),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),

          // 4. 底部端侧 AI 引擎自检状态胶囊与进度条
          SafeArea(
            child: Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: EdgeInsets.only(
                  left: 24,
                  right: 24,
                  bottom: isCompact ? 18 : 32,
                ),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 320),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // 引擎特性徽章胶囊
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: const Color(0xFF131B2E).withValues(alpha: 0.88),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: const Color(0xFF26334D)),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.shield_rounded, size: 13, color: AppColors.emerald),
                            SizedBox(width: 6),
                            Flexible(
                              child: Text(
                                'SenseVoice INT8 · CAM++ 192D 离线引擎',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: Color(0xFF94A3B8),
                                  fontSize: 11,
                                  fontFamily: 'monospace',
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),

                      // 流光加载进度条
                      AnimatedBuilder(
                        animation: _progressAnim,
                        builder: (context, _) {
                          return ClipRRect(
                            borderRadius: BorderRadius.circular(4),
                            child: SizedBox(
                              height: 3,
                              width: 168,
                              child: LinearProgressIndicator(
                                value: _progressAnim.value,
                                backgroundColor: const Color(0xFF1E293B),
                                valueColor: const AlwaysStoppedAnimation<Color>(AppColors.primary),
                              ),
                            ),
                          );
                        },
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        '100% 本地端侧推理 · 零云端上传',
                        style: TextStyle(
                          color: Color(0xFF64748B),
                          fontSize: 10.5,
                          letterSpacing: 0.6,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 启动页深空声纹星云氛围背景
class _SplashAmbientBackdrop extends StatelessWidget {
  const _SplashAmbientBackdrop();

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _SplashBackdropPainter(),
      child: const SizedBox.expand(),
    );
  }
}

class _SplashBackdropPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;

    // 1. 中心偏上活力珊瑚橙径向星云光晕
    final topGlow = Paint()
      ..shader = RadialGradient(
        center: const Alignment(0.0, -0.18),
        radius: 0.65,
        colors: [
          AppColors.primary.withValues(alpha: 0.14),
          AppColors.primary.withValues(alpha: 0.0),
        ],
      ).createShader(rect);
    canvas.drawRect(rect, topGlow);

    // 2. 左下星云电光蓝环境光
    final bottomLeftGlow = Paint()
      ..shader = RadialGradient(
        center: const Alignment(-0.65, 0.55),
        radius: 0.6,
        colors: [
          const Color(0xFF38BDF8).withValues(alpha: 0.09),
          const Color(0xFF38BDF8).withValues(alpha: 0.0),
        ],
      ).createShader(rect);
    canvas.drawRect(rect, bottomLeftGlow);

    // 3. 右下翡翠薄荷绿微光
    final bottomRightGlow = Paint()
      ..shader = RadialGradient(
        center: const Alignment(0.65, 0.65),
        radius: 0.55,
        colors: [
          AppColors.emerald.withValues(alpha: 0.08),
          AppColors.emerald.withValues(alpha: 0.0),
        ],
      ).createShader(rect);
    canvas.drawRect(rect, bottomRightGlow);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
