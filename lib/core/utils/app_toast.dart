import 'package:flutter/material.dart';
import '../constants/app_colors.dart';

/// 提示气泡类型枚举
enum ToastType {
  info,
  success,
  warning,
  error,
}

/// 全局统一轻量无遮挡提示通知工具
/// 采用现代浮动胶囊设计，避开底部控制器与关键交互区，自动顶替旧通知，杜绝排队堆叠
class AppToast {
  AppToast._();

  /// 弹出统一浮动提示
  static void show(
    BuildContext context,
    String message, {
    ToastType type = ToastType.info,
    Duration duration = const Duration(milliseconds: 1800),
    SnackBarAction? action,
  }) {
    if (!context.mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    // 立即清除当前正在显示的旧通知，杜绝排队堆叠霸屏
    messenger.hideCurrentSnackBar();

    IconData icon;
    Color iconColor;
    Color borderColor;

    switch (type) {
      case ToastType.success:
        icon = Icons.check_circle_rounded;
        iconColor = AppColors.primary;
        borderColor = AppColors.primary.withValues(alpha: 0.35);
        break;
      case ToastType.warning:
        icon = Icons.warning_amber_rounded;
        iconColor = Colors.amber;
        borderColor = Colors.amber.withValues(alpha: 0.35);
        break;
      case ToastType.error:
        icon = Icons.error_outline_rounded;
        iconColor = AppColors.rose;
        borderColor = AppColors.rose.withValues(alpha: 0.35);
        break;
      case ToastType.info:
      default:
        icon = Icons.info_outline_rounded;
        iconColor = Colors.white70;
        borderColor = AppColors.cardBorder;
        break;
    }

    final isWide = MediaQuery.of(context).size.width >= 720;

    messenger.showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        elevation: 8,
        backgroundColor: Colors.transparent,
        padding: EdgeInsets.zero,
        // 避开底部播放器控制条高度(通常约 90-100px)，防止遮挡核心交互
        margin: EdgeInsets.only(
          bottom: 96,
          left: isWide ? (MediaQuery.of(context).size.width - 420) / 2 : 20,
          right: isWide ? (MediaQuery.of(context).size.width - 420) / 2 : 20,
        ),
        duration: duration,
        content: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
          decoration: BoxDecoration(
            color: const Color(0xFF1E222D),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: borderColor, width: 1),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.45),
                blurRadius: 16,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 18, color: iconColor),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  message,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    height: 1.35,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (action != null) ...[
                const SizedBox(width: 8),
                TextButton(
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  onPressed: action.onPressed,
                  child: Text(
                    action.label,
                    style: TextStyle(
                      color: action.textColor ?? AppColors.primary,
                      fontSize: 12.5,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// 成功类提示
  static void success(BuildContext context, String message, {Duration? duration, SnackBarAction? action}) {
    show(
      context,
      message,
      type: ToastType.success,
      duration: duration ?? const Duration(milliseconds: 1800),
      action: action,
    );
  }

  /// 普通信息提示
  static void info(BuildContext context, String message, {Duration? duration, SnackBarAction? action}) {
    show(
      context,
      message,
      type: ToastType.info,
      duration: duration ?? const Duration(milliseconds: 1800),
      action: action,
    );
  }

  /// 警告提示
  static void warning(BuildContext context, String message, {Duration? duration, SnackBarAction? action}) {
    show(
      context,
      message,
      type: ToastType.warning,
      duration: duration ?? const Duration(milliseconds: 2200),
      action: action,
    );
  }

  /// 错误提示
  static void error(BuildContext context, String message, {Duration? duration, SnackBarAction? action}) {
    show(
      context,
      message,
      type: ToastType.error,
      duration: duration ?? const Duration(milliseconds: 2600),
      action: action,
    );
  }
}
