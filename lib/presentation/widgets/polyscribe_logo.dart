import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../core/constants/app_colors.dart';

/// PolyScribe (声织纪要) 品牌视觉核心徽标组件
/// 融合「五重多角色声纹能量柱 + 正弦声织流光丝带 + 192维超球面扫描环 + AI 纪要星芒」
/// 支持静态高清矢量绘制与启动页动态声波呼吸律动模式
class PolyScribeLogo extends StatefulWidget {
  /// 徽标整体宽高尺寸
  final double size;

  /// 是否显示深空琉璃圆角底座 (false 时为透明背景纯图形徽标)
  final bool showBackground;

  /// 是否开启多角色声波呼吸与声纹扫描环动态动效
  final bool animate;

  /// 自定义圆角比例 (默认 0.24 贴合超椭圆视觉)
  final double borderRadiusRatio;

  const PolyScribeLogo({
    super.key,
    this.size = 48.0,
    this.showBackground = true,
    this.animate = false,
    this.borderRadiusRatio = 0.24,
  });

  @override
  State<PolyScribeLogo> createState() => _PolyScribeLogoState();
}

class _PolyScribeLogoState extends State<PolyScribeLogo>
    with SingleTickerProviderStateMixin {
  AnimationController? _controller;

  @override
  void initState() {
    super.initState();
    if (widget.animate) {
      _initAnimation();
    }
  }

  void _initAnimation() {
    _controller ??= AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2600),
    )..repeat();
  }

  @override
  void didUpdateWidget(covariant PolyScribeLogo oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.animate && !oldWidget.animate) {
      _initAnimation();
    } else if (!widget.animate && oldWidget.animate) {
      _controller?.stop();
      _controller?.dispose();
      _controller = null;
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final radius = widget.size * widget.borderRadiusRatio;

    Widget painterWidget;
    if (widget.animate && _controller != null) {
      painterWidget = AnimatedBuilder(
        animation: _controller!,
        builder: (context, _) {
          return CustomPaint(
            size: Size.square(widget.size),
            painter: _PolyScribeLogoPainter(
              phase: _controller!.value * 2 * math.pi,
              showBackground: widget.showBackground,
              borderRadius: radius,
            ),
          );
        },
      );
    } else {
      painterWidget = CustomPaint(
        size: Size.square(widget.size),
        painter: _PolyScribeLogoPainter(
          phase: 0.0,
          showBackground: widget.showBackground,
          borderRadius: radius,
        ),
      );
    }

    if (!widget.showBackground) {
      return SizedBox.square(
        dimension: widget.size,
        child: painterWidget,
      );
    }

    return Container(
      width: widget.size,
      height: widget.size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        boxShadow: [
          BoxShadow(
            color: AppColors.primary.withValues(alpha: 0.32),
            blurRadius: widget.size * 0.28,
            offset: Offset(0, widget.size * 0.1),
          ),
        ],
      ),
      child: painterWidget,
    );
  }
}

/// 声织纪要高精度矢量绘制器 (与桌面/移动端原生图标 100% 视觉同源)
class _PolyScribeLogoPainter extends CustomPainter {
  final double phase;
  final bool showBackground;
  final double borderRadius;

  const _PolyScribeLogoPainter({
    required this.phase,
    required this.showBackground,
    required this.borderRadius,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width;
    final center = Offset(s / 2, s / 2);
    final rect = Offset.zero & size;

    // 1. 绘制深空暗夜琉璃底座与内部多角色环境光晕
    if (showBackground) {
      final rrect = RRect.fromRectAndRadius(rect, Radius.circular(borderRadius));
      canvas.save();
      canvas.clipRRect(rrect);

      // 深空渐变底板
      final bgPaint = Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color(0xFF17223B),
            Color(0xFF0B0F19),
            Color(0xFF070A12),
          ],
          stops: [0.0, 0.55, 1.0],
        ).createShader(rect);
      canvas.drawRect(rect, bgPaint);

      // 中心珊瑚橙暖光晕
      final orangeGlowPaint = Paint()
        ..shader = RadialGradient(
          center: const Alignment(0.0, -0.05),
          radius: 0.58,
          colors: [
            AppColors.primary.withValues(alpha: 0.28),
            AppColors.primary.withValues(alpha: 0.0),
          ],
        ).createShader(rect);
      canvas.drawRect(rect, orangeGlowPaint);

      // 左下星云蓝环境微光
      final cyanGlowPaint = Paint()
        ..shader = RadialGradient(
          center: const Alignment(-0.48, 0.45),
          radius: 0.52,
          colors: [
            const Color(0xFF38BDF8).withValues(alpha: 0.20),
            const Color(0xFF38BDF8).withValues(alpha: 0.0),
          ],
        ).createShader(rect);
      canvas.drawRect(rect, cyanGlowPaint);

      canvas.restore();

      // 琉璃高光内描边
      final borderPaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(1.0, s * 0.022)
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            AppColors.primary.withValues(alpha: 0.65),
            const Color(0xFF38BDF8).withValues(alpha: 0.35),
            const Color(0xFF26334D).withValues(alpha: 0.55),
          ],
        ).createShader(rect);
      canvas.drawRRect(
        rrect.deflate(math.max(0.5, s * 0.011)),
        borderPaint,
      );
    }

    // 2. 绘制 192维超球面声纹轨道环 (仅在中大尺寸 >= 32px 时展现细节)
    if (s >= 32) {
      final outerRadius = s * 0.37;
      final innerRadius = s * 0.285;

      final orbitPaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(1.0, s * 0.012)
        ..color = const Color(0xFF38BDF8).withValues(alpha: 0.16);
      canvas.drawCircle(center, outerRadius, orbitPaint);

      final innerOrbitPaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(0.8, s * 0.01)
        ..color = AppColors.primary.withValues(alpha: 0.18);
      canvas.drawCircle(center, innerRadius, innerOrbitPaint);

      // 旋转声纹扫描高亮弧段
      final arcRect = Rect.fromCircle(center: center, radius: outerRadius);
      final arcPaintCyan = Paint()
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeWidth = math.max(1.4, s * 0.018)
        ..color = const Color(0xFF38BDF8).withValues(alpha: 0.62);
      canvas.drawArc(
        arcRect,
        -2.45 + phase * 0.5,
        0.85,
        false,
        arcPaintCyan,
      );

      final arcPaintOrange = Paint()
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeWidth = math.max(1.4, s * 0.018)
        ..color = AppColors.primary.withValues(alpha: 0.68);
      canvas.drawArc(
        arcRect,
        0.55 + phase * 0.5,
        0.85,
        false,
        arcPaintOrange,
      );
    }

    // 3. 绘制「声织」双股正弦交织丝带 (Sonic Weave Sine Ribbons)
    _drawSonicWeaveRibbons(canvas, center, s);

    // 4. 绘制五重多角色声波能量柱 (5 Poly-Speaker Capsule Bars)
    _drawPolySpeakerBars(canvas, center, s);

    // 5. 绘制右上角「AI 纪要灵光」四角星芒与左下声纹节点
    _drawScribeSparkle(canvas, center, s);
  }

  void _drawSonicWeaveRibbons(Canvas canvas, Offset center, double s) {
    final span = s * 0.68;
    final startX = center.dx - span / 2;
    final pathA = Path();
    final pathB = Path();
    const steps = 36;

    for (int i = 0; i <= steps; i++) {
      final t = i / steps;
      final x = startX + t * span;
      final envelope = math.sin(t * math.pi);
      final wave = math.sin(t * math.pi * 2.2 - 0.4 + phase);
      final yA = center.dy + wave * (s * 0.105 * envelope);
      final yB = center.dy - wave * (s * 0.085 * envelope);

      if (i == 0) {
        pathA.moveTo(x, yA);
        pathB.moveTo(x, yB);
      } else {
        pathA.lineTo(x, yA);
        pathB.lineTo(x, yB);
      }
    }

    final ribbonRect = Rect.fromCenter(center: center, width: span, height: s * 0.3);
    final paintA = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = math.max(1.2, s * 0.022)
      ..shader = LinearGradient(
        colors: [
          const Color(0xFF38BDF8).withValues(alpha: 0.0),
          const Color(0xFF38BDF8).withValues(alpha: 0.72),
          const Color(0xFF10B981).withValues(alpha: 0.75),
          AppColors.primary.withValues(alpha: 0.0),
        ],
        stops: const [0.0, 0.3, 0.7, 1.0],
      ).createShader(ribbonRect);

    final paintB = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = math.max(1.2, s * 0.02)
      ..shader = LinearGradient(
        colors: [
          const Color(0xFFF59E0B).withValues(alpha: 0.0),
          AppColors.primary.withValues(alpha: 0.75),
          const Color(0xFFA855F7).withValues(alpha: 0.70),
          const Color(0xFFA855F7).withValues(alpha: 0.0),
        ],
        stops: const [0.0, 0.3, 0.7, 1.0],
      ).createShader(ribbonRect);

    canvas.drawPath(pathA, paintA);
    canvas.drawPath(pathB, paintB);
  }

  void _drawPolySpeakerBars(Canvas canvas, Offset center, double s) {
    // (相对X偏移, 基础高度比例, 动态相位偏移, 顶部颜色, 底部颜色)
    const specs = [
      // 左2: 参会嘉宾 B (星云电光蓝)
      (-0.23, 0.25, 0.8, Color(0xFF7DD3FC), Color(0xFF0284C7)),
      // 左1: 主要嘉宾 A (翡翠薄荷绿)
      (-0.115, 0.43, 1.9, Color(0xFF6EE7B7), Color(0xFF059669)),
      // 中心主峰: 主讲人 (活力珊瑚橙)
      (0.0, 0.60, 0.0, Color(0xFFFDBA74), Color(0xFFEA580C)),
      // 右1: 谐波共鸣柱 (琥珀金 -> 珊瑚橙)
      (0.115, 0.46, 1.1, Color(0xFFFDE047), Color(0xFFEA580C)),
      // 右2: 参会嘉宾 C (紫罗兰)
      (0.23, 0.27, 2.5, Color(0xFFD8B4FE), Color(0xFF7E22CE)),
    ];

    final barWidth = math.max(2.4, s * 0.074);
    final barRadius = Radius.circular(barWidth / 2);

    for (final spec in specs) {
      final relX = spec.$1;
      final baseRelH = spec.$2;
      final phaseOffset = spec.$3;
      final topColor = spec.$4;
      final bottomColor = spec.$5;

      // 动态模式下平滑呼吸律动
      final pulse = phase == 0.0
          ? 1.0
          : (1.0 + 0.14 * math.sin(phase * 2.0 + phaseOffset));
      final barHeight = math.max(barWidth, s * baseRelH * pulse);
      final bx = center.dx + relX * s;

      final barRect = Rect.fromCenter(
        center: Offset(bx, center.dy),
        width: barWidth,
        height: barHeight,
      );
      final barRRect = RRect.fromRectAndRadius(barRect, barRadius);

      // 中心主柱柔光投影
      if (relX == 0.0 && s >= 36) {
        final glowPaint = Paint()
          ..color = AppColors.primary.withValues(alpha: 0.38)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, s * 0.045);
        canvas.drawRRect(barRRect, glowPaint);
      }

      // 胶囊主体渐变
      final barPaint = Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [topColor, bottomColor],
        ).createShader(barRect);
      canvas.drawRRect(barRRect, barPaint);
    }
  }

  void _drawScribeSparkle(Canvas canvas, Offset center, double s) {
    final sx = center.dx + s * 0.225;
    final sy = center.dy - s * 0.225;
    final scale = phase == 0.0 ? 1.0 : (0.9 + 0.18 * math.sin(phase * 2.0));
    final outerR = s * 0.064 * scale;
    final innerR = s * 0.019 * scale;

    final starPath = Path();
    for (int i = 0; i < 8; i++) {
      final angle = i * math.pi / 4.0 - math.pi / 2.0;
      final r = i.isEven ? outerR : innerR;
      final px = sx + math.cos(angle) * r;
      final py = sy + math.sin(angle) * r;
      if (i == 0) {
        starPath.moveTo(px, py);
      } else {
        starPath.lineTo(px, py);
      }
    }
    starPath.close();

    final starPaint = Paint()
      ..color = const Color(0xFFFDE047)
      ..style = PaintingStyle.fill;
    canvas.drawPath(starPath, starPaint);

    // 左下对称星云蓝声纹微粒
    final nx = center.dx - s * 0.23;
    final ny = center.dy + s * 0.215;
    final nodePaint = Paint()..color = const Color(0xFF38BDF8);
    canvas.drawCircle(Offset(nx, ny), math.max(1.2, s * 0.018), nodePaint);
  }

  @override
  bool shouldRepaint(covariant _PolyScribeLogoPainter oldDelegate) {
    return oldDelegate.phase != phase ||
        oldDelegate.showBackground != showBackground ||
        oldDelegate.borderRadius != borderRadius;
  }
}
