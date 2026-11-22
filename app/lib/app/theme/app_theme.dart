import 'package:flutter/material.dart';

/// 全局浅色主题色板（参考 Figma Music Player Community & 现代开源媒体客户端设计规范）。
///
/// 核心视觉：
/// - 主品牌色：极光幻紫 `#9570FF`（深色 `#7C4DFF`，亮天青 `#8CC8FF`）
/// - 页面底色：通透暖白极光底 `#FAF9FE`，配合纯白/半透明毛玻璃卡片
/// - 文本层级：高对比石墨黑 `#333333`、柔和中灰 `#828282`、浅灰 `#BDBDBD`
class AppThemeColors {
  // ── 品牌色 (Figma Primary #9570FF & Aurora Palette) ──
  static const primary = Color(0xFF9570FF);
  static const primaryDeep = Color(0xFF7C4DFF);
  static const secondary = Color(0xFF8CC8FF);
  static const accent = Color(0xFFE270FF);

  // ── 页面背景 ──
  static const pageBackground = Color(0xFFFAF9FE);
  static const pageBackgroundDeep = Color(0xFFF3F0FC);

  // ── 卡片 / 表面 ──
  static const surface = Color(0xFFFFFFFF);
  static const surfaceMuted = Color(0xFFF6F5FA);
  static const surfaceSunken = Color(0xFFEFEDF7);

  // ── 边框 / 分割线 ──
  static const border = Color(0xFFECEAF5);
  static const borderStrong = Color(0xFFDFDCF0);
  static const divider = Color(0xFFF2F0F8);

  // ── 文本 (Figma Gray 1 #333333 / Gray 3 #828282 / Gray 4 #BDBDBD) ──
  static const textPrimary = Color(0xFF333333);
  static const textSecondary = Color(0xFF5A5868);
  static const textMuted = Color(0xFF828282);
  static const textDisabled = Color(0xFFBDBDBD);
  static const textOnAccent = Color(0xFFFFFFFF);

  // ── 状态色 (Figma Red #EB5757) ──
  static const success = Color(0xFF12B76A);
  static const warning = Color(0xFFF79009);
  static const danger = Color(0xFFEB5757);

  // ── 阴影 / 遮罩 ──
  static const shadowSoft = Color(0x129570FF);
  static const shadowMedium = Color(0x1F9570FF);
  static const shadowStrong = Color(0x2E333333);
  static const scrim = Color(0x66000000);

  /// 卡片通用柔和阴影（带微弱紫韵环境光）
  static const cardShadow = <BoxShadow>[
    BoxShadow(color: Color(0x0D1E1638), blurRadius: 22, offset: Offset(0, 8)),
  ];

  /// 浮层（底栏 / 悬浮按钮 / 毛玻璃抽屉）阴影
  static const floatingShadow = <BoxShadow>[
    BoxShadow(color: Color(0x16221545), blurRadius: 30, offset: Offset(0, 10)),
  ];
}
