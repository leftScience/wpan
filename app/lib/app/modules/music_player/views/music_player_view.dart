import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:get/get.dart';

import '../../../theme/app_theme.dart';
import '../../../widgets/playlist_loading_view.dart';
import '../controllers/music_player_controller.dart';

class MusicPlayerView extends StatefulWidget {
  const MusicPlayerView({super.key});

  static const double _playlistItemExtent = 74;

  @override
  State<MusicPlayerView> createState() => _MusicPlayerViewState();
}

class _MusicPlayerViewState extends State<MusicPlayerView>
    with SingleTickerProviderStateMixin {
  final MusicPlayerController controller = Get.find<MusicPlayerController>();

  // Figma Community Design Palette (#9570FF, #333333, #828282, #BDBDBD, #EB5757)
  static const Color _figmaPrimary = Color(0xFF9570FF);
  static const Color _figmaTextDark = Color(0xFF333333);
  static const Color _figmaTextMuted = Color(0xFF828282);
  static const Color _figmaGrayLight = Color(0xFFBDBDBD);
  static const Color _figmaHeartRed = Color(0xFFEB5757);
  static const Color _figmaBorderLight = Color(0xFFF2F2F2);

  late final PageController _carouselController;
  late final AnimationController _vinylAnimController;
  Worker? _indexWorker;
  bool _isSyncingCarousel = false;
  int _carouselSyncToken = 0;
  bool _isBottomPanelExpanded = false;
  int _bottomTabIndex = 0; // 0: 播放队列, 1: 曲目详情与章节

  static const List<List<Color>> _artworkGradients = <List<Color>>[
    [Color(0xFF8CC8FF), Color(0xFF9570FF), Color(0xFFE270FF)],
    [Color(0xFFFF9A9E), Color(0xFFFECFEF), Color(0xFFA18CD1)],
    [Color(0xFF84FAB0), Color(0xFF8FD3F4), Color(0xFF707AFF)],
    [Color(0xFFFCCb90), Color(0xFFD57EEB), Color(0xFF7C4DFF)],
    [Color(0xFFA1C4FD), Color(0xFFC2E9FB), Color(0xFF667EEA)],
  ];

  @override
  void initState() {
    super.initState();
    _carouselController = PageController(
      viewportFraction: 0.66,
      initialPage: controller.currentIndex.value,
    );
    _vinylAnimController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 18),
    )..repeat();

    _indexWorker = ever<int>(controller.currentIndex, (nextIndex) {
      if (!mounted || !_carouselController.hasClients) return;
      final currentPage = _carouselController.page?.round();
      if (currentPage == nextIndex) return;
      final token = ++_carouselSyncToken;
      _isSyncingCarousel = true;
      final lifecycle = WidgetsBinding.instance.lifecycleState;
      final isForeground =
          lifecycle == null || lifecycle == AppLifecycleState.resumed;
      if (!isForeground) {
        _carouselController.jumpToPage(nextIndex);
        if (token == _carouselSyncToken) {
          _isSyncingCarousel = false;
        }
        return;
      }
      _carouselController
          .animateToPage(
            nextIndex,
            duration: const Duration(milliseconds: 360),
            curve: Curves.easeOutCubic,
          )
          .whenComplete(() {
            if (token == _carouselSyncToken) {
              _isSyncingCarousel = false;
            }
          });
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      controller.handleRouteArguments(Get.arguments);
    });
  }

  @override
  void dispose() {
    _indexWorker?.dispose();
    _carouselController.dispose();
    _vinylAnimController.dispose();
    super.dispose();
  }

  List<Color> _paletteForIndex(int index) {
    if (index < 0) return _artworkGradients.first;
    return _artworkGradients[index % _artworkGradients.length];
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: Obx(() {
        final idx = controller.currentIndex.value;
        final palette = _paletteForIndex(idx);
        return Stack(
          children: [
            _buildAmbientBackdrop(palette),
            SafeArea(
              bottom: false,
              child: Column(
                children: [
                  _buildFigmaHeader(context),
                  Expanded(
                    child: Obx(() {
                      if (controller.isLoadingPlaylist.value) {
                        return const PlaylistLoadingView(
                          message: '正在加载播放列表...',
                          accentColor: _figmaPrimary,
                        );
                      }
                      if (controller.tracks.isEmpty) {
                        return const Center(
                          child: Text(
                            '播放列表为空',
                            style: TextStyle(color: _figmaTextMuted),
                          ),
                        );
                      }
                      return Stack(
                        alignment: Alignment.bottomCenter,
                        children: [
                          Positioned.fill(
                            child: Column(
                              children: [
                                SizedBox(height: 12.h),
                                _buildArtworkCarouselWithNotch(context),
                                SizedBox(height: 18.h),
                                _buildTrackTitleAndSubtitle(context),
                                SizedBox(height: 14.h),
                                _buildOpenSourceAuxiliaryBar(context),
                                const Spacer(),
                                _buildProgressBarSection(context),
                                SizedBox(height: 14.h),
                                _buildTransportControlsRow(context),
                                SizedBox(height: 148.h),
                              ],
                            ),
                          ),
                          _buildGlassBottomDrawer(context),
                        ],
                      );
                    }),
                  ),
                ],
              ),
            ),
          ],
        );
      }),
    );
  }

  /// 参考主流开源播放器（Harmonoid / Auxio / Metro）的柔和动态氛围光晕背景
  Widget _buildAmbientBackdrop(List<Color> palette) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 600),
      curve: Curves.easeOut,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.white,
            palette.first.withValues(alpha: 0.08),
            palette[1].withValues(alpha: 0.06),
            Colors.white,
          ],
          stops: const [0.0, 0.35, 0.7, 1.0],
        ),
      ),
      child: Stack(
        children: [
          Positioned(
            top: 110.h,
            left: -40.w,
            child: Container(
              width: 220.w,
              height: 220.w,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: palette.first.withValues(alpha: 0.14),
              ),
            ),
          ),
          Positioned(
            top: 190.h,
            right: -50.w,
            child: Container(
              width: 240.w,
              height: 240.w,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: palette.last.withValues(alpha: 0.12),
              ),
            ),
          ),
          BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 60, sigmaY: 60),
            child: const SizedBox.expand(),
          ),
        ],
      ),
    );
  }

  /// Figma Header (node 40:33 & 48:405) + 音频快捷工具按钮
  Widget _buildFigmaHeader(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(20.w, 12.h, 20.w, 8.h),
      child: Row(
        children: [
          // Figma 43x43 淡紫色圆形返回键 (#9570FF 19% 透明度)
          GestureDetector(
            onTap: () => Navigator.of(context).maybePop(),
            child: Container(
              width: 43.w,
              height: 43.w,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _figmaPrimary.withValues(alpha: 0.19),
              ),
              alignment: Alignment.center,
              child: Icon(
                Icons.arrow_back_rounded,
                color: _figmaTextDark,
                size: 20.r,
              ),
            ),
          ),
          Expanded(
            child: Obx(() {
              final folderTitle = controller.playlistTitle.value.trim();
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Now Playing',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: _figmaTextDark,
                      fontSize: 22.sp,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.3,
                      height: 1.2,
                    ),
                  ),
                  if (folderTitle.isNotEmpty)
                    Padding(
                      padding: EdgeInsets.only(top: 2.h),
                      child: Text(
                        folderTitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: _figmaTextMuted,
                          fontSize: 11.sp,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                ],
              );
            }),
          ),
          // 右侧对称功能触发圆钮（聚合片头片尾、定时、音量或快捷菜单）
          _buildHeaderToolsButton(context),
        ],
      ),
    );
  }

  Widget _buildHeaderToolsButton(BuildContext context) {
    return Obx(() {
      final hasTimer = controller.sleepRemaining.value != null;
      final hasSkip =
          controller.skipIntro.value > Duration.zero ||
          controller.skipOutro.value > Duration.zero;
      final isActive = hasTimer || hasSkip;
      return GestureDetector(
        onTap: controller.actionsReady.value
            ? () => _showAudioToolsOverviewSheet(context)
            : null,
        child: Container(
          width: 43.w,
          height: 43.w,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: isActive
                ? _figmaPrimary.withValues(alpha: 0.19)
                : const Color(0xFFF5F3FF),
            border: Border.all(
              color: isActive
                  ? _figmaPrimary.withValues(alpha: 0.4)
                  : _figmaBorderLight,
            ),
          ),
          alignment: Alignment.center,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Icon(
                Icons.tune_rounded,
                color: isActive ? _figmaPrimary : _figmaTextDark,
                size: 20.r,
              ),
              if (isActive)
                Positioned(
                  right: -2,
                  top: -2,
                  child: Container(
                    width: 8.w,
                    height: 8.w,
                    decoration: const BoxDecoration(
                      color: _figmaHeartRed,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
    });
  }

  /// Figma 核心视觉：三卡轮播画廊 (node 44:288) + 底部凹陷波浪弧形遮罩 (node 48:204) + 悬浮红心按钮 (node 48:277)
  Widget _buildArtworkCarouselWithNotch(BuildContext context) {
    return SizedBox(
      height: 286.h,
      child: Stack(
        alignment: Alignment.topCenter,
        clipBehavior: Clip.none,
        children: [
          SizedBox(
            height: 256.h,
            child: Obx(() {
              final count = controller.tracks.length;
              final currentIdx = controller.currentIndex.value;
              final playing = controller.isPlaying.value;
              return PageView.builder(
                controller: _carouselController,
                itemCount: count,
                onPageChanged: (index) {
                  if (_isSyncingCarousel) return;
                  if (index != controller.currentIndex.value) {
                    controller.playAt(index);
                  }
                },
                itemBuilder: (context, index) {
                  final isCurrent = index == currentIdx;
                  final track = controller.tracks[index];
                  final palette = _paletteForIndex(index);
                  return AnimatedBuilder(
                    animation: _carouselController,
                    builder: (context, child) {
                      double scale = isCurrent ? 1.0 : 0.80;
                      double opacity = isCurrent ? 1.0 : 0.50;
                      if (_carouselController.hasClients &&
                          _carouselController.position.haveDimensions) {
                        final page =
                            _carouselController.page ?? currentIdx.toDouble();
                        final diff = (page - index).abs().clamp(0.0, 1.0);
                        scale = 1.0 - (diff * 0.20);
                        opacity = 1.0 - (diff * 0.50);
                      }
                      return Center(
                        child: Opacity(
                          opacity: opacity,
                          child: Transform.scale(
                            scale: scale,
                            child: _buildSingleArtworkCard(
                              track: track,
                              index: index,
                              isCurrent: isCurrent,
                              isPlaying: playing && isCurrent,
                              palette: palette,
                            ),
                          ),
                        ),
                      );
                    },
                  );
                },
              );
            }),
          ),
          // 悬浮于中心卡片凹陷处的 50x50 白色投影爱心按钮 (Figma node 48:277)
          Positioned(
            bottom: 4.h,
            child: Obx(() {
              final isFav = controller.isTrackFavorite(controller.currentTrack);
              return GestureDetector(
                onTap: controller.toggleCurrentFavorite,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 220),
                  width: 50.w,
                  height: 50.w,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    shape: BoxShape.circle,
                    border: Border.all(color: _figmaBorderLight, width: 1),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.11),
                        blurRadius: 24,
                        offset: const Offset(0, 6),
                      ),
                    ],
                  ),
                  alignment: Alignment.center,
                  child: Icon(
                    isFav
                        ? Icons.favorite_rounded
                        : Icons.favorite_border_rounded,
                    color: _figmaHeartRed,
                    size: 23.r,
                  ),
                ),
              );
            }),
          ),
        ],
      ),
    );
  }

  Widget _buildSingleArtworkCard({
    required MusicTrack track,
    required int index,
    required bool isCurrent,
    required bool isPlaying,
    required List<Color> palette,
  }) {
    final ext = _extractExtensionBadge(track.title, track.path);
    return Container(
      width: 228.w,
      height: 254.h,
      margin: EdgeInsets.symmetric(horizontal: 6.w),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(30.r),
        boxShadow: isCurrent
            ? [
                BoxShadow(
                  color: palette[1].withValues(alpha: 0.28),
                  blurRadius: 30,
                  offset: const Offset(0, 14),
                ),
              ]
            : null,
      ),
      child: ClipPath(
        clipper: isCurrent ? _FigmaNotchedCardClipper(radius: 30.r) : null,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(30.r),
          child: Stack(
            fit: StackFit.expand,
            children: [
              // 艺术流体渐变底色 (Figma #8CC8FF + 多彩星云圆斑)
              Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: palette,
                  ),
                ),
              ),
              // 装饰性几何星云圆环与黑胶纹理（致敬 Figma 原稿中心抽象唱片插画）
              Center(
                child: RotationTransition(
                  turns: isPlaying
                      ? _vinylAnimController
                      : const AlwaysStoppedAnimation(0.0),
                  child: Container(
                    width: 158.w,
                    height: 158.w,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: RadialGradient(
                        colors: [
                          const Color(0xFF143D66),
                          const Color(0xFF5D1966).withValues(alpha: 0.92),
                          const Color(0xFFB8255F).withValues(alpha: 0.85),
                        ],
                        stops: const [0.25, 0.68, 1.0],
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.18),
                          blurRadius: 16,
                        ),
                      ],
                    ),
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        // 唱片高光圆点（呼应 Figma 插画中的黄/橙色星球斑点）
                        Positioned(
                          top: 22.w,
                          left: 48.w,
                          child: Container(
                            width: 22.w,
                            height: 22.w,
                            decoration: const BoxDecoration(
                              color: Color(0xFFF5E68E),
                              shape: BoxShape.circle,
                            ),
                          ),
                        ),
                        Positioned(
                          bottom: 24.w,
                          right: 42.w,
                          child: Container(
                            width: 24.w,
                            height: 24.w,
                            decoration: const BoxDecoration(
                              color: Color(0xFFF5E68E),
                              shape: BoxShape.circle,
                            ),
                          ),
                        ),
                        Positioned(
                          top: 48.w,
                          right: 16.w,
                          child: Container(
                            width: 14.w,
                            height: 14.w,
                            decoration: const BoxDecoration(
                              color: Color(0xFFFF8A5B),
                              shape: BoxShape.circle,
                            ),
                          ),
                        ),
                        // 中心深蓝唱片孔
                        Container(
                          width: 56.w,
                          height: 56.w,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: const Color(0xFF103F6E),
                            border: Border.all(
                              color: Colors.white.withValues(alpha: 0.22),
                              width: 2,
                            ),
                          ),
                          child: Icon(
                            Icons.graphic_eq_rounded,
                            color: Colors.white.withValues(alpha: 0.9),
                            size: 26.r,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              // 右上角无损/音频格式与曲目序号胶囊（参考主流开源播放器 Auxio/Symphony）
              Positioned(
                top: 14.h,
                left: 14.w,
                right: 14.w,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Container(
                      padding: EdgeInsets.symmetric(
                        horizontal: 9.w,
                        vertical: 3.h,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.22),
                        borderRadius: BorderRadius.circular(12.r),
                      ),
                      child: Text(
                        '#${index + 1}/${controller.tracks.length}',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 10.sp,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    if (ext.isNotEmpty)
                      Container(
                        padding: EdgeInsets.symmetric(
                          horizontal: 9.w,
                          vertical: 3.h,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.28),
                          borderRadius: BorderRadius.circular(12.r),
                        ),
                        child: Text(
                          ext,
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 10.sp,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.5,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Figma 居中主副标题区域 (node 48:287: 23px ExtraBold #333333 + 17px Medium #828282)
  Widget _buildTrackTitleAndSubtitle(BuildContext context) {
    return Obx(() {
      final track = controller.currentTrack;
      final rawTitle = track?.title ?? '未选择音频';
      final cleanTitle = _cleanDisplayTitle(rawTitle);
      final subtitle = _resolveSubtitle(track);

      return Padding(
        padding: EdgeInsets.symmetric(horizontal: 28.w),
        child: Column(
          children: [
            Text(
              cleanTitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: _figmaTextDark,
                fontSize: 22.sp,
                fontWeight: FontWeight.w800,
                height: 1.3,
              ),
            ),
            SizedBox(height: 6.h),
            Text(
              subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: _figmaTextMuted,
                fontSize: 15.sp,
                fontWeight: FontWeight.w500,
                height: 1.3,
              ),
            ),
          ],
        ),
      );
    });
  }

  /// 参考主流开源播放器（AntennaPod / Auxio / Metro）的快捷功能胶囊栏：
  /// 播放模式、倍速调节、定时关闭、片头片尾跳过、音量控制一目了然
  Widget _buildOpenSourceAuxiliaryBar(BuildContext context) {
    return Obx(() {
      final mode = controller.playMode.value;
      final speed = controller.playbackSpeed.value;
      final remaining = controller.sleepRemaining.value;
      final hasSkip =
          controller.skipIntro.value > Duration.zero ||
          controller.skipOutro.value > Duration.zero;
      final vol = controller.volume.value.clamp(0.0, 1.0);

      return SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.symmetric(horizontal: 24.w),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _buildAuxPill(
              icon: _playModeIcon(mode),
              label: _playModeLabel(mode),
              isActive: mode != PlayMode.sequential,
              onTap: controller.cyclePlayMode,
            ),
            SizedBox(width: 8.w),
            _buildAuxPill(
              icon: Icons.speed_rounded,
              label: '${speed.toStringAsFixed(speed % 1 == 0 ? 1 : 2)}x',
              isActive: (speed - 1.0).abs() > 0.01,
              onTap: () => _showSpeedSheet(context),
            ),
            SizedBox(width: 8.w),
            _buildAuxPill(
              icon: Icons.timer_outlined,
              label: remaining != null
                  ? controller.formatDuration(remaining)
                  : '定时',
              isActive: remaining != null,
              onTap: () => _showSleepTimerSheet(context),
            ),
            SizedBox(width: 8.w),
            _buildAuxPill(
              icon: Icons.content_cut_rounded,
              label: hasSkip ? '已设片头尾' : '跳过片头尾',
              isActive: hasSkip,
              onTap: () => _showSkipSettingsSheet(context),
            ),
            SizedBox(width: 8.w),
            _buildAuxPill(
              icon: vol == 0
                  ? Icons.volume_off_rounded
                  : vol < 0.5
                  ? Icons.volume_down_rounded
                  : Icons.volume_up_rounded,
              label: '${(vol * 100).round()}%',
              isActive: false,
              onTap: () => _showVolumeSheet(context),
            ),
          ],
        ),
      );
    });
  }

  Widget _buildAuxPill({
    required IconData icon,
    required String label,
    required bool isActive,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(18.r),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: EdgeInsets.symmetric(horizontal: 11.w, vertical: 6.h),
        decoration: BoxDecoration(
          color: isActive
              ? _figmaPrimary.withValues(alpha: 0.14)
              : const Color(0xFFF6F5FA),
          borderRadius: BorderRadius.circular(18.r),
          border: Border.all(
            color: isActive
                ? _figmaPrimary.withValues(alpha: 0.38)
                : const Color(0xFFECEAF4),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 14.r,
              color: isActive ? _figmaPrimary : _figmaTextMuted,
            ),
            SizedBox(width: 4.w),
            Text(
              label,
              style: TextStyle(
                fontSize: 11.sp,
                fontWeight: isActive ? FontWeight.w700 : FontWeight.w500,
                color: isActive ? _figmaPrimary : _figmaTextMuted,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Figma 极简紫韵进度条 (node 48:328: 激活轨 #9570FF, 底轨 #F2F2F2)
  Widget _buildProgressBarSection(BuildContext context) {
    return Obx(() {
      final total = controller.duration.value;
      final totalMs = total.inMilliseconds;
      final position = controller.position.value;
      final currentMs = position.inMilliseconds;
      final double sliderMax = totalMs > 0 ? totalMs.toDouble() : 1.0;
      final double sliderValue = totalMs > 0
          ? currentMs.clamp(0, totalMs).toDouble()
          : currentMs.toDouble().clamp(0.0, 1.0);

      return Padding(
        padding: EdgeInsets.symmetric(horizontal: 24.w),
        child: SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 3.5.h,
            activeTrackColor: _figmaPrimary,
            inactiveTrackColor: _figmaBorderLight,
            thumbColor: _figmaPrimary,
            overlayColor: _figmaPrimary.withValues(alpha: 0.14),
            thumbShape: RoundSliderThumbShape(enabledThumbRadius: 6.r),
            overlayShape: RoundSliderOverlayShape(overlayRadius: 14.r),
          ),
          child: Slider(
            value: sliderValue,
            min: 0,
            max: sliderMax,
            onChanged: totalMs > 0
                ? (value) =>
                      controller.seekTo(Duration(milliseconds: value.round()))
                : null,
          ),
        ),
      );
    });
  }

  /// Figma 播放控制栏 (node 48:152):
  /// 左侧紫色当前时间 0:36 (#9570FF) | -10s | 上一首 | 61x61 全息极光圆钮 | 下一首 | +10s | 右侧灰色总时长 3:40 (#BDBDBD)
  Widget _buildTransportControlsRow(BuildContext context) {
    return Obx(() {
      final playing = controller.isPlaying.value;
      final buffering = controller.isBuffering.value;
      final canSkip = controller.tracks.length > 1 && !buffering;
      final position = controller.position.value;
      final total = controller.duration.value;

      return Padding(
        padding: EdgeInsets.symmetric(horizontal: 20.w),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            // 左侧当前时间 (#9570FF SemiBold 12px)
            SizedBox(
              width: 44.w,
              child: Text(
                controller.formatDuration(position),
                maxLines: 1,
                style: TextStyle(
                  color: _figmaPrimary,
                  fontSize: 11.5.sp,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            // 快退 10 秒（开源播客/音频播放器高频按键）
            IconButton(
              tooltip: '快退 10 秒',
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: BoxConstraints(minWidth: 36.w, minHeight: 36.w),
              onPressed: buffering
                  ? null
                  : () => controller.seekRelative(const Duration(seconds: -10)),
              icon: Icon(
                Icons.replay_10_rounded,
                color: _figmaTextMuted,
                size: 22.r,
              ),
            ),
            // 上一首 (Figma 27px #333333)
            IconButton(
              tooltip: '上一首',
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: BoxConstraints(minWidth: 40.w, minHeight: 40.w),
              onPressed: canSkip ? controller.playPrevious : null,
              icon: Icon(
                Icons.skip_previous_rounded,
                color: canSkip ? _figmaTextDark : _figmaGrayLight,
                size: 30.r,
              ),
            ),
            // 中心 64x64 极光网格渐变圆形播放按钮 (Figma Component 3 node 48:154)
            _buildAuroraPlayButton(playing: playing, buffering: buffering),
            // 下一首 (Figma 27px #333333)
            IconButton(
              tooltip: '下一首',
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: BoxConstraints(minWidth: 40.w, minHeight: 40.w),
              onPressed: canSkip
                  ? () => controller.playNext(fromAutoComplete: false)
                  : null,
              icon: Icon(
                Icons.skip_next_rounded,
                color: canSkip ? _figmaTextDark : _figmaGrayLight,
                size: 30.r,
              ),
            ),
            // 快进 10 秒
            IconButton(
              tooltip: '快进 10 秒',
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: BoxConstraints(minWidth: 36.w, minHeight: 36.w),
              onPressed: buffering
                  ? null
                  : () => controller.seekRelative(const Duration(seconds: 10)),
              icon: Icon(
                Icons.forward_10_rounded,
                color: _figmaTextMuted,
                size: 22.r,
              ),
            ),
            // 右侧总时长 (#BDBDBD SemiBold 12px)
            SizedBox(
              width: 44.w,
              child: Text(
                controller.formatDuration(total),
                maxLines: 1,
                textAlign: TextAlign.right,
                style: TextStyle(
                  color: _figmaGrayLight,
                  fontSize: 11.5.sp,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
      );
    });
  }

  /// 还原 Figma node 48:154 的全息极光弥散圆钮 (#70C8FF + #9570FF + #70FFB9 + #E270FF + #333333 图标)
  Widget _buildAuroraPlayButton({
    required bool playing,
    required bool buffering,
  }) {
    return GestureDetector(
      onTap: buffering ? null : controller.togglePlayback,
      child: Container(
        width: 64.w,
        height: 64.w,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: const SweepGradient(
            center: Alignment.center,
            colors: [
              Color(0xFF70F8FF),
              Color(0xFF9570FF),
              Color(0xFFE270FF),
              Color(0xFF707AFF),
              Color(0xFF70FFB9),
              Color(0xFF70F8FF),
            ],
          ),
          boxShadow: [
            BoxShadow(
              color: _figmaPrimary.withValues(alpha: 0.26),
              blurRadius: 24,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        padding: EdgeInsets.all(3.w),
        child: Container(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: RadialGradient(
              center: const Alignment(-0.2, -0.3),
              radius: 1.1,
              colors: [
                Colors.white.withValues(alpha: 0.90),
                const Color(0xFFD9ECFF).withValues(alpha: 0.78),
                const Color(0xFFE8D8FF).withValues(alpha: 0.85),
              ],
            ),
          ),
          alignment: Alignment.center,
          child: buffering
              ? SizedBox(
                  width: 24.w,
                  height: 24.w,
                  child: const CircularProgressIndicator(
                    strokeWidth: 2.2,
                    color: _figmaTextDark,
                  ),
                )
              : Icon(
                  playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                  color: _figmaTextDark,
                  size: 32.r,
                ),
        ),
      ),
    );
  }

  /// Figma 底部毛玻璃抽屉 (node 40:8 收起态 & node 48:406 展开态)
  /// 结合开源播放器实用性：支持「队列 / 歌词与详情」双视图切换与丝滑展开
  Widget _buildGlassBottomDrawer(BuildContext context) {
    final screenHeight = MediaQuery.of(context).size.height;
    final collapsedHeight = 136.h;
    final expandedHeight = math.min(screenHeight * 0.58, 470.h);

    return AnimatedContainer(
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
      height: _isBottomPanelExpanded ? expandedHeight : collapsedHeight,
      width: double.infinity,
      child: ClipRRect(
        borderRadius: BorderRadius.vertical(top: Radius.circular(26.r)),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
          child: Material(
            type: MaterialType.transparency,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.white.withValues(
                  alpha: _isBottomPanelExpanded ? 0.88 : 0.78,
                ),
              borderRadius: BorderRadius.vertical(top: Radius.circular(26.r)),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.7),
                width: 1.2,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.06),
                  blurRadius: 47,
                  offset: const Offset(0, -19),
                ),
              ],
            ),
            child: Column(
              children: [
                // 顶部栏 (Figma node 40:11: 音符图标 + 标题 + 43x43 上下折叠圆钮)
                Padding(
                  padding: EdgeInsets.fromLTRB(16.w, 12.h, 16.w, 8.h),
                  child: Row(
                    children: [
                      Icon(
                        Icons.music_note_rounded,
                        color: _figmaTextDark,
                        size: 22.r,
                      ),
                      SizedBox(width: 6.w),
                      Expanded(
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              _buildDrawerTabChip(
                                index: 0,
                                title: '播放列表 (${controller.tracks.length})',
                              ),
                              SizedBox(width: 6.w),
                              _buildDrawerTabChip(
                                index: 1,
                                title: '曲目详情',
                              ),
                            ],
                          ),
                        ),
                      ),
                      // 定位当前曲目按钮（展开且在播放队列时显示）
                      if (_isBottomPanelExpanded && _bottomTabIndex == 0)
                        IconButton(
                          tooltip: '完整队列弹窗',
                          visualDensity: VisualDensity.compact,
                          padding: EdgeInsets.zero,
                          constraints: BoxConstraints(
                            minWidth: 34.w,
                            minHeight: 34.w,
                          ),
                          onPressed: () => _showPlaylistSheet(context),
                          icon: Icon(
                            Icons.open_in_full_rounded,
                            size: 17.r,
                            color: _figmaTextMuted,
                          ),
                        ),
                      SizedBox(width: 4.w),
                      // Figma 40x40 白色圆形折叠/展开按钮 (node 40:15 / 48:446)
                      GestureDetector(
                        onTap: () {
                          setState(() {
                            _isBottomPanelExpanded = !_isBottomPanelExpanded;
                          });
                        },
                        child: Container(
                          width: 40.w,
                          height: 40.w,
                          decoration: BoxDecoration(
                            color: Colors.white,
                            shape: BoxShape.circle,
                            border: Border.all(color: _figmaBorderLight),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.05),
                                blurRadius: 16,
                                offset: const Offset(0, 2),
                              ),
                            ],
                          ),
                          alignment: Alignment.center,
                          child: Icon(
                            _isBottomPanelExpanded
                                ? Icons.keyboard_arrow_down_rounded
                                : Icons.keyboard_arrow_up_rounded,
                            color: _figmaTextDark,
                            size: 22.r,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: _bottomTabIndex == 0
                      ? _buildDrawerQueueContent(context)
                      : _buildDrawerLyricsInfoContent(context),
                ),
              ],
            ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDrawerTabChip({required int index, required String title}) {
    final selected = _bottomTabIndex == index;
    return GestureDetector(
      onTap: () {
        setState(() {
          _bottomTabIndex = index;
          if (!_isBottomPanelExpanded) {
            _isBottomPanelExpanded = true;
          }
        });
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: EdgeInsets.symmetric(horizontal: 10.w, vertical: 5.h),
        decoration: BoxDecoration(
          color: selected
              ? _figmaPrimary.withValues(alpha: 0.14)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(14.r),
        ),
        child: Text(
          title,
          style: TextStyle(
            color: selected ? _figmaTextDark : _figmaTextMuted,
            fontSize: 13.5.sp,
            fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
          ),
        ),
      ),
    );
  }

  Widget _buildDrawerQueueContent(BuildContext context) {
    return Obx(() {
      final tracks = controller.tracks;
      final current = controller.currentIndex.value;
      if (!_isBottomPanelExpanded) {
        // 收起态：预览当前与下一首曲目，点击快速展开或切歌
        final nextIdx = tracks.length > 1 ? (current + 1) % tracks.length : current;
        final nextTrack = tracks[nextIdx];
        return InkWell(
          onTap: () => setState(() => _isBottomPanelExpanded = true),
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 24.w, vertical: 4.h),
            child: Row(
              children: [
                Container(
                  padding: EdgeInsets.symmetric(horizontal: 8.w, vertical: 3.h),
                  decoration: BoxDecoration(
                    color: _figmaPrimary.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(8.r),
                  ),
                  child: Text(
                    'NEXT',
                    style: TextStyle(
                      color: _figmaPrimary,
                      fontSize: 10.sp,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                SizedBox(width: 10.w),
                Expanded(
                  child: Text(
                    '${nextIdx + 1}. ${_cleanDisplayTitle(nextTrack.title)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: _figmaTextDark,
                      fontSize: 14.sp,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: () => _showPlaylistSheet(context),
                  child: Text(
                    '全部列表',
                    style: TextStyle(
                      color: _figmaPrimary,
                      fontSize: 12.sp,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      }

      // 展开态：直接在毛玻璃面板内浏览与切换播放队列
      final scrollController = ScrollController(
        initialScrollOffset:
            (current * (MusicPlayerView._playlistItemExtent.h + 1)).clamp(
              0.0,
              double.infinity,
            ),
      );
      return _buildPlaylist(context, scrollController: scrollController);
    });
  }

  /// 还原 Figma node 48:447 的对比度排版风格，展示当前音频的详情、路径与动态播放状态行
  Widget _buildDrawerLyricsInfoContent(BuildContext context) {
    return Obx(() {
      final track = controller.currentTrack;
      final cleanTitle = _cleanDisplayTitle(track?.title ?? '未选择音频');
      final path = track?.path ?? '';
      final folder = controller.folderPath.value;
      final pos = controller.formatDuration(controller.position.value);
      final dur = controller.formatDuration(controller.duration.value);
      final speed = controller.playbackSpeed.value;
      final intro = controller.skipIntro.value;
      final outro = controller.skipOutro.value;

      return SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(24.w, 6.h, 24.w, 20.h),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              cleanTitle,
              style: TextStyle(
                color: _figmaTextDark,
                fontSize: 20.sp,
                fontWeight: FontWeight.w800,
                height: 1.5,
              ),
            ),
            SizedBox(height: 6.h),
            RichText(
              text: TextSpan(
                style: TextStyle(
                  fontSize: 16.sp,
                  fontWeight: FontWeight.w700,
                  height: 1.6,
                ),
                children: [
                  TextSpan(
                    text: '播放进度 $pos ',
                    style: const TextStyle(color: _figmaTextDark),
                  ),
                  TextSpan(
                    text: '/ 总时长 $dur · ${speed}x 倍速',
                    style: const TextStyle(color: _figmaGrayLight),
                  ),
                ],
              ),
            ),
            if (folder.isNotEmpty)
              Padding(
                padding: EdgeInsets.only(top: 6.h),
                child: Text(
                  '所属目录：$folder',
                  style: TextStyle(
                    color: _figmaGrayLight,
                    fontSize: 14.sp,
                    fontWeight: FontWeight.w700,
                    height: 1.5,
                  ),
                ),
              ),
            if (path.isNotEmpty)
              Padding(
                padding: EdgeInsets.only(top: 4.h),
                child: Text(
                  '文件路径：$path',
                  style: TextStyle(
                    color: _figmaGrayLight,
                    fontSize: 13.sp,
                    fontWeight: FontWeight.w600,
                    height: 1.5,
                  ),
                ),
              ),
            if (intro > Duration.zero || outro > Duration.zero)
              Padding(
                padding: EdgeInsets.only(top: 10.h),
                child: Wrap(
                  spacing: 8.w,
                  runSpacing: 6.h,
                  children: [
                    if (intro > Duration.zero)
                      _buildInfoTag('跳过片头 ${_formatBrief(intro)}'),
                    if (outro > Duration.zero)
                      _buildInfoTag('跳过片尾 ${_formatBrief(outro)}'),
                  ],
                ),
              ),
          ],
        ),
      );
    });
  }

  void _showAudioToolsOverviewSheet(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppThemeColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24.r)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: EdgeInsets.symmetric(vertical: 12.h),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  leading: const Icon(Icons.speed_rounded, color: _figmaPrimary),
                  title: const Text('播放倍速'),
                  subtitle: Obx(
                    () => Text('当前：${controller.playbackSpeed.value}x'),
                  ),
                  onTap: () {
                    Navigator.of(ctx).pop();
                    _showSpeedSheet(context);
                  },
                ),
                ListTile(
                  leading: const Icon(
                    Icons.timer_outlined,
                    color: _figmaPrimary,
                  ),
                  title: const Text('定时关闭'),
                  subtitle: Obx(() {
                    final rem = controller.sleepRemaining.value;
                    return Text(
                      rem != null
                          ? '将在 ${controller.formatDuration(rem)} 后停止'
                          : '未开启',
                    );
                  }),
                  onTap: () {
                    Navigator.of(ctx).pop();
                    _showSleepTimerSheet(context);
                  },
                ),
                ListTile(
                  leading: const Icon(
                    Icons.content_cut_rounded,
                    color: _figmaPrimary,
                  ),
                  title: const Text('跳过片头 / 片尾'),
                  subtitle: Obx(
                    () => Text(
                      '片头 ${controller.skipIntro.value.inSeconds}s · 片尾 ${controller.skipOutro.value.inSeconds}s',
                    ),
                  ),
                  onTap: () {
                    Navigator.of(ctx).pop();
                    _showSkipSettingsSheet(context);
                  },
                ),
                ListTile(
                  leading: const Icon(
                    Icons.volume_up_rounded,
                    color: _figmaPrimary,
                  ),
                  title: const Text('音量调节'),
                  subtitle: Obx(
                    () => Text(
                      '当前：${(controller.volume.value * 100).round()}%',
                    ),
                  ),
                  onTap: () {
                    Navigator.of(ctx).pop();
                    _showVolumeSheet(context);
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _showSpeedSheet(BuildContext context) {
    const speeds = <double>[0.75, 1.0, 1.25, 1.5, 1.75, 2.0];
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppThemeColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24.r)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.speed_rounded, color: _figmaPrimary),
                title: const Text('播放倍速'),
                trailing: TextButton(
                  onPressed: () {
                    controller.setPlaybackSpeed(1.0);
                    Navigator.of(ctx).pop();
                  },
                  child: const Text('重置 1.0x'),
                ),
              ),
              const Divider(height: 1),
              ...speeds.map(
                (s) => Obx(() {
                  final selected =
                      (controller.playbackSpeed.value - s).abs() < 0.01;
                  return ListTile(
                    leading: Icon(
                      selected
                          ? Icons.radio_button_checked_rounded
                          : Icons.radio_button_off_rounded,
                      color: selected ? _figmaPrimary : _figmaTextMuted,
                    ),
                    title: Text(
                      '${s}x',
                      style: TextStyle(
                        fontWeight: selected
                            ? FontWeight.w700
                            : FontWeight.w500,
                        color: selected ? _figmaPrimary : _figmaTextDark,
                      ),
                    ),
                    onTap: () {
                      controller.setPlaybackSpeed(s);
                      Navigator.of(ctx).pop();
                    },
                  );
                }),
              ),
            ],
          ),
        );
      },
    );
  }

  void _showVolumeSheet(BuildContext context) {
    double value = (controller.volume.value.clamp(0.0, 1.0) * 100)
        .roundToDouble();
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppThemeColors.surface,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setState) {
            return SafeArea(
              child: Padding(
                padding: EdgeInsets.only(
                  left: 16.w,
                  right: 16.w,
                  top: 12.h,
                  bottom: 12.h + MediaQuery.of(ctx).viewPadding.bottom,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        const Icon(
                          Icons.volume_up_rounded,
                          color: AppThemeColors.textPrimary,
                        ),
                        SizedBox(width: 8.w),
                        Text(
                          '音量 ${value.round()}%',
                          style:
                              Theme.of(ctx).textTheme.titleMedium?.copyWith(
                                color: AppThemeColors.textPrimary,
                                fontWeight: FontWeight.w600,
                              ) ??
                              const TextStyle(
                                color: AppThemeColors.textPrimary,
                                fontWeight: FontWeight.w600,
                              ),
                        ),
                        const Spacer(),
                        IconButton(
                          onPressed: () => Navigator.of(ctx).pop(),
                          icon: const Icon(
                            Icons.close_rounded,
                            color: AppThemeColors.textMuted,
                          ),
                        ),
                      ],
                    ),
                    SliderTheme(
                      data: SliderTheme.of(ctx).copyWith(
                        activeTrackColor: _figmaPrimary,
                        inactiveTrackColor: AppThemeColors.borderStrong,
                        thumbColor: _figmaPrimary,
                        overlayColor: _figmaPrimary.withValues(alpha: 0.12),
                      ),
                      child: Slider(
                        value: value,
                        min: 0,
                        max: 100,
                        divisions: 100,
                        label: '${value.round()}%',
                        onChanged: (v) {
                          setState(() => value = v);
                          controller.setVolume(v / 100, persist: true);
                        },
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  void _showSleepTimerSheet(BuildContext context) {
    final options = <Duration>[
      const Duration(minutes: 15),
      const Duration(minutes: 30),
      const Duration(minutes: 45),
      const Duration(hours: 1),
      const Duration(hours: 2),
    ];

    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppThemeColors.surface,
      builder: (ctx) {
        final remaining = controller.sleepRemaining.value;
        final isActive = controller.isSleepTimerActive && remaining != null;
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.timer_outlined),
                title: const Text('定时关闭'),
                subtitle: Text(
                  isActive
                      ? '将在 ${controller.formatDuration(remaining)} 后执行'
                      : '未开启定时关闭',
                ),
              ),
              const Divider(height: 1),
              ...options.map(
                (duration) => ListTile(
                  leading: const Icon(Icons.schedule_rounded),
                  title: Text('${duration.inMinutes} 分钟后停止'),
                  onTap: () {
                    Navigator.of(ctx).pop();
                    controller.startSleepTimer(duration);
                  },
                ),
              ),
              if (isActive) const Divider(height: 1),
              if (isActive)
                ListTile(
                  leading: const Icon(Icons.close_rounded),
                  title: const Text('取消定时'),
                  onTap: () {
                    Navigator.of(ctx).pop();
                    controller.cancelSleepTimer();
                  },
                ),
            ],
          ),
        );
      },
    );
  }

  void _showSkipSettingsSheet(BuildContext context) {
    const maxSeconds = 300.0;
    double introValue = controller.skipIntro.value.inSeconds
        .clamp(0, maxSeconds.toInt())
        .toDouble();
    double outroValue = controller.skipOutro.value.inSeconds
        .clamp(0, maxSeconds.toInt())
        .toDouble();

    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppThemeColors.surface,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setState) {
            return SafeArea(
              child: Padding(
                padding: EdgeInsets.only(
                  bottom: MediaQuery.of(ctx).viewPadding.bottom,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(height: 8.h),
                    ListTile(
                      leading: const Icon(Icons.subtitles_outlined),
                      title: const Text('跳过片头'),
                      subtitle: Text('当前：${introValue.round()} 秒'),
                    ),
                    Slider(
                      value: introValue,
                      min: 0,
                      max: maxSeconds,
                      divisions: maxSeconds.toInt(),
                      label: '${introValue.round()}s',
                      onChanged: (value) {
                        setState(() => introValue = value);
                        controller.setSkipIntro(
                          Duration(seconds: value.round()),
                        );
                      },
                    ),
                    const Divider(height: 1),
                    ListTile(
                      leading: const Icon(Icons.notes_rounded),
                      title: const Text('跳过片尾'),
                      subtitle: Text('当前：${outroValue.round()} 秒'),
                    ),
                    Slider(
                      value: outroValue,
                      min: 0,
                      max: maxSeconds,
                      divisions: maxSeconds.toInt(),
                      label: '${outroValue.round()}s',
                      onChanged: (value) {
                        setState(() => outroValue = value);
                        controller.setSkipOutro(
                          Duration(seconds: value.round()),
                        );
                      },
                    ),
                    SizedBox(height: 12.h),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildPlaylist(
    BuildContext context, {
    required ScrollController scrollController,
  }) {
    return Obx(() {
      final current = controller.currentIndex.value;
      final playing = controller.isPlaying.value;
      final buffering = controller.isBuffering.value;
      final total = controller.tracks.length;
      final itemExtent = MusicPlayerView._playlistItemExtent.h;
      final rowExtent = itemExtent + 1;
      return Material(
        type: MaterialType.transparency,
        child: ListView.builder(
          padding: EdgeInsets.only(bottom: 16.h),
          controller: scrollController,
          itemExtent: rowExtent,
          addAutomaticKeepAlives: false,
          itemCount: total,
          itemBuilder: (context, index) {
            final item = controller.tracks[index];
            final isCurrent = index == current;
            return Container(
              height: rowExtent,
              decoration: const BoxDecoration(
                border: Border(
                  bottom: BorderSide(color: AppThemeColors.divider, width: 1),
                ),
              ),
              child: ListTile(
                onTap: () => controller.playAt(index),
                contentPadding: EdgeInsets.symmetric(horizontal: 18.w),
                minVerticalPadding: 0,
                minTileHeight: itemExtent,
                leading: Container(
                  width: 36.w,
                  height: 36.w,
                  decoration: BoxDecoration(
                    color: isCurrent
                        ? _figmaPrimary.withValues(alpha: 0.16)
                        : AppThemeColors.surfaceMuted,
                    borderRadius: BorderRadius.circular(12.r),
                  ),
                  child: Icon(
                    isCurrent
                        ? Icons.equalizer_rounded
                        : Icons.music_note_outlined,
                    color: isCurrent
                        ? _figmaPrimary
                        : AppThemeColors.textSecondary,
                  ),
                ),
                title: Text(
                  item.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: isCurrent ? _figmaPrimary : _figmaTextDark,
                    fontWeight: isCurrent ? FontWeight.w700 : FontWeight.w500,
                  ),
                ),
                subtitle: item.path.isEmpty
                    ? null
                    : Text(
                        item.path,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12.sp,
                          color: AppThemeColors.textMuted,
                        ),
                      ),
                trailing: SizedBox(
                  width: 36.w,
                  height: 36.w,
                  child: Center(
                    child: isCurrent && buffering
                        ? SizedBox(
                            width: 22.w,
                            height: 22.w,
                            child: const CircularProgressIndicator(
                              strokeWidth: 2,
                              color: _figmaPrimary,
                            ),
                          )
                        : isCurrent
                        ? Icon(
                            playing
                                ? Icons.pause_circle_filled_rounded
                                : Icons.play_circle_filled_rounded,
                            color: _figmaPrimary,
                          )
                        : IconButton(
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(),
                            icon: const Icon(
                              Icons.play_arrow_rounded,
                              color: AppThemeColors.textSecondary,
                            ),
                            onPressed: () => controller.playAt(index),
                          ),
                  ),
                ),
              ),
            );
          },
        ),
      );
    });
  }

  void _showPlaylistSheet(BuildContext context) {
    final itemExtent = MusicPlayerView._playlistItemExtent.h;
    final rowExtent = itemExtent + 1;
    final scrollController = ScrollController(
      initialScrollOffset: controller.playlistSheetInitialOffset,
    );

    void persistPlaylistOffset({bool allowInitial = false}) {
      if (scrollController.hasClients) {
        controller.savePlaylistSheetOffset(scrollController.offset);
        return;
      }
      if (allowInitial) {
        controller.savePlaylistSheetOffset(
          scrollController.initialScrollOffset,
        );
      }
    }

    scrollController.addListener(persistPlaylistOffset);
    final sheetFuture = showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppThemeColors.surface,
      isScrollControlled: true,
      builder: (ctx) {
        void scrollToCurrentTrack() {
          final total = controller.tracks.length;
          if (total <= 0) return;
          if (!scrollController.hasClients) return;

          final current = controller.currentIndex.value.clamp(0, total - 1);
          final target = current * rowExtent;
          final position = scrollController.position;
          final clamped = target.clamp(
            position.minScrollExtent,
            position.maxScrollExtent,
          );
          scrollController.animateTo(
            clamped,
            duration: const Duration(milliseconds: 260),
            curve: Curves.easeOutCubic,
          );
        }

        return SafeArea(
          child: SizedBox(
            height: MediaQuery.of(ctx).size.height * 0.65,
            child: Column(
              children: [
                Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: 16.w,
                    vertical: 12.h,
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.queue_music,
                        color: AppThemeColors.textPrimary,
                      ),
                      SizedBox(width: 8.w),
                      Text(
                        '播放列表',
                        style: Theme.of(ctx).textTheme.titleMedium?.copyWith(
                          color: AppThemeColors.textPrimary,
                        ),
                      ),
                      const Spacer(),
                      IconButton(
                        tooltip: '定位当前音频',
                        onPressed: scrollToCurrentTrack,
                        icon: const Icon(
                          Icons.my_location_rounded,
                          color: AppThemeColors.textMuted,
                        ),
                      ),
                      IconButton(
                        onPressed: () => Navigator.of(ctx).pop(),
                        icon: const Icon(
                          Icons.close_rounded,
                          color: AppThemeColors.textMuted,
                        ),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1, color: AppThemeColors.divider),
                Expanded(
                  child: _buildPlaylist(
                    ctx,
                    scrollController: scrollController,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
    sheetFuture.whenComplete(() {
      persistPlaylistOffset(allowInitial: true);
      scrollController.removeListener(persistPlaylistOffset);
      scrollController.dispose();
    });
  }

  IconData _playModeIcon(PlayMode mode) {
    switch (mode) {
      case PlayMode.single:
        return Icons.repeat_one_rounded;
      case PlayMode.shuffle:
        return Icons.shuffle_rounded;
      case PlayMode.sequential:
        return Icons.repeat_rounded;
    }
  }

  String _playModeLabel(PlayMode mode) {
    switch (mode) {
      case PlayMode.single:
        return '单曲循环';
      case PlayMode.shuffle:
        return '随机播放';
      case PlayMode.sequential:
        return '顺序播放';
    }
  }

  Widget _buildInfoTag(String text) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 10.w, vertical: 4.h),
      decoration: BoxDecoration(
        color: _figmaPrimary.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12.r),
        border: Border.all(color: _figmaPrimary.withValues(alpha: 0.3)),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12.sp,
          color: _figmaPrimary,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  String _formatBrief(Duration duration) {
    if (duration.inMinutes == 0) {
      return '${duration.inSeconds}s';
    }
    if (duration.inMinutes < 60 && duration.inSeconds % 60 == 0) {
      return '${duration.inMinutes}m';
    }
    return controller.formatDuration(duration);
  }

  String _cleanDisplayTitle(String rawTitle) {
    final trimmed = rawTitle.trim();
    if (trimmed.isEmpty) return '未选择音频';
    final dotIndex = trimmed.lastIndexOf('.');
    if (dotIndex > 0 && dotIndex >= trimmed.length - 6) {
      return trimmed.substring(0, dotIndex);
    }
    return trimmed;
  }

  String _resolveSubtitle(MusicTrack? track) {
    final title = track?.title.trim() ?? '';
    if (title.contains(' - ')) {
      final parts = title.split(' - ');
      if (parts.first.trim().isNotEmpty) {
        return parts.first.trim();
      }
    }
    final album = controller.playlistTitle.value.trim();
    if (album.isNotEmpty) {
      return '$album · ${controller.currentIndex.value + 1}/${controller.tracks.length}';
    }
    return 'Track ${controller.currentIndex.value + 1} of ${controller.tracks.length}';
  }

  String _extractExtensionBadge(String title, String path) {
    final source = path.trim().isNotEmpty ? path.trim() : title.trim();
    final dot = source.lastIndexOf('.');
    if (dot < 0 || dot == source.length - 1) return 'AUDIO';
    final ext = source.substring(dot + 1).toUpperCase();
    if (ext.length > 5) return 'AUDIO';
    return ext;
  }
}

/// 精确还原 Figma node I48:204;48:263 的底部波浪凹槽遮罩曲线
/// 原 SVG viewBox: 232 x 260，底部中心向上平滑凹陷以容纳 50x50 悬浮爱心圆钮
class _FigmaNotchedCardClipper extends CustomClipper<Path> {
  const _FigmaNotchedCardClipper({required this.radius});

  final double radius;

  @override
  Path getClip(Size size) {
    final w = size.width;
    final h = size.height;
    final sx = w / 232.0;
    final sy = h / 260.0;

    final path = Path()
      ..moveTo(0, radius)
      ..quadraticBezierTo(0, 0, radius, 0)
      ..lineTo(w - radius, 0)
      ..quadraticBezierTo(w, 0, w, radius)
      ..lineTo(w, h - radius)
      ..quadraticBezierTo(w, h, w - radius, h)
      ..lineTo(181.305 * sx, h)
      ..cubicTo(
        176.493 * sx,
        260 * sy,
        171.74 * sx,
        258.948 * sy,
        167.378 * sx,
        256.917 * sy,
      )
      ..lineTo(137.101 * sx, 242.823 * sy)
      ..cubicTo(
        123.723 * sx,
        236.595 * sy,
        108.277 * sx,
        236.595 * sy,
        94.8985 * sx,
        242.823 * sy,
      )
      ..lineTo(68.0338 * sx, 255.329 * sy)
      ..cubicTo(
        61.4246 * sx,
        258.406 * sy,
        54.2225 * sx,
        260 * sy,
        46.9323 * sx,
        260 * sy,
      )
      ..lineTo(radius, h)
      ..quadraticBezierTo(0, h, 0, h - radius)
      ..close();
    return path;
  }

  @override
  bool shouldReclip(covariant _FigmaNotchedCardClipper oldClipper) {
    return oldClipper.radius != radius;
  }
}
