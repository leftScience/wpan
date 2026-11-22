import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_epub_viewer/flutter_epub_viewer.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:get/get.dart';
import 'package:pdfx/pdfx.dart';

import '../controllers/reader_controller.dart';

class ReaderView extends GetView<ReaderController> {
  const ReaderView({super.key});

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final chrome = _ReaderChromeColors.resolve(controller);
      final exiting = controller.isExiting.value;
      return PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) {
            controller.prepareExit();
          }
        },
        child: Scaffold(
          backgroundColor: chrome.backgroundColor,
          appBar: exiting ? null : _buildFigmaReaderAppBar(context, chrome),
          body: exiting ? const SizedBox.shrink() : _buildBody(),
        ),
      );
    });
  }

  PreferredSizeWidget _buildFigmaReaderAppBar(
    BuildContext context,
    _ReaderChromeColors chrome,
  ) {
    final isDark =
        ThemeData.estimateBrightnessForColor(chrome.backgroundColor) ==
        Brightness.dark;
    final pillFill = isDark
        ? Colors.white.withValues(alpha: 0.14)
        : chrome.accentColor.withValues(alpha: 0.16);
    final pillBorder = isDark
        ? Colors.white.withValues(alpha: 0.22)
        : chrome.accentColor.withValues(alpha: 0.28);

    return AppBar(
      backgroundColor: chrome.surfaceColor,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      leadingWidth: 60.w,
      titleSpacing: 4.w,
      leading: Padding(
        padding: EdgeInsets.only(left: 14.w, top: 7.h, bottom: 7.h),
        child: GestureDetector(
          onTap: () => Navigator.of(context).maybePop(),
          child: Container(
            width: 40.w,
            height: 40.w,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: pillFill,
              border: Border.all(color: pillBorder, width: 1),
            ),
            alignment: Alignment.center,
            child: Icon(
              Icons.arrow_back_rounded,
              color: chrome.textColor,
              size: 20.r,
            ),
          ),
        ),
      ),
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            controller.title.value.trim().isEmpty
                ? '阅读'
                : controller.title.value.trim(),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: chrome.textColor,
              fontSize: 16.5.sp,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.2,
            ),
          ),
          if (controller.canShowNavigation)
            Text(
              _resolveSubtitleText(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: chrome.secondaryTextColor,
                fontSize: 11.sp,
                fontWeight: FontWeight.w600,
              ),
            ),
        ],
      ),
      actions: [
        if (controller.canSelectTheme)
          _buildTopPillIconButton(
            tooltip: '阅读主题与排版',
            icon: Icons.palette_outlined,
            chrome: chrome,
            fill: pillFill,
            border: pillBorder,
            onTap: () => _showThemeSheet(context),
          ),
        if (controller.canAdjustFontSize) ...[
          _buildTopPillIconButton(
            tooltip: '减小字号',
            icon: Icons.text_decrease_rounded,
            chrome: chrome,
            fill: pillFill,
            border: pillBorder,
            onTap: controller.decreaseFontSize,
          ),
          _buildTopPillIconButton(
            tooltip: '增大字号',
            icon: Icons.text_increase_rounded,
            chrome: chrome,
            fill: pillFill,
            border: pillBorder,
            onTap: controller.increaseFontSize,
          ),
        ],
        _buildTopPillIconButton(
          tooltip: controller.navigationTooltip,
          icon: Icons.queue_music_rounded,
          chrome: chrome,
          fill: pillFill,
          border: pillBorder,
          onTap: controller.canShowNavigation
              ? () => _showNavigationSheet(context)
              : null,
        ),
        SizedBox(width: 10.w),
      ],
      bottom: PreferredSize(
        preferredSize: const Size.fromHeight(2.5),
        child: Obx(() {
          final p = controller.progress.value.clamp(0.0, 1.0);
          return LinearProgressIndicator(
            value: p > 0 ? p : 0.0,
            minHeight: 2.2,
            backgroundColor: chrome.dividerColor,
            valueColor: AlwaysStoppedAnimation<Color>(chrome.accentColor),
          );
        }),
      ),
    );
  }

  String _resolveSubtitleText() {
    switch (controller.readerFormat.value) {
      case ReaderFileFormat.txt:
        final seg = controller.currentTxtSegment;
        if (seg != null && seg.title.trim().isNotEmpty) {
          return seg.title.trim();
        }
        return '第 ${controller.currentTxtSegmentIndex.value + 1}/${controller.txtSegments.length} 节';
      case ReaderFileFormat.epub:
        return controller.currentChapterTitle;
      case ReaderFileFormat.pdf:
        if (controller.pdfPageCount.value > 0) {
          return '第 ${controller.currentPdfPage.value} / ${controller.pdfPageCount.value} 页';
        }
        return 'PDF 文档';
      case ReaderFileFormat.unknown:
        return '';
    }
  }

  Widget _buildTopPillIconButton({
    required String tooltip,
    required IconData icon,
    required _ReaderChromeColors chrome,
    required Color fill,
    required Color border,
    required VoidCallback? onTap,
  }) {
    final enabled = onTap != null;
    return Padding(
      padding: EdgeInsets.only(right: 6.w),
      child: Tooltip(
        message: tooltip,
        child: GestureDetector(
          onTap: onTap,
          child: Opacity(
            opacity: enabled ? 1.0 : 0.42,
            child: Container(
              width: 36.w,
              height: 36.w,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: fill,
                border: Border.all(color: border, width: 1),
              ),
              alignment: Alignment.center,
              child: Icon(icon, color: chrome.textColor, size: 18.r),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBody() {
    final chrome = _ReaderChromeColors.resolve(controller);
    if (controller.loading.value) {
      return Center(
        child: CircularProgressIndicator(color: chrome.accentColor),
      );
    }

    final error = controller.error.value.trim();
    if (error.isNotEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                error,
                textAlign: TextAlign.center,
                style: TextStyle(color: chrome.secondaryTextColor, height: 1.6),
              ),
              const SizedBox(height: 16),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: chrome.accentColor,
                  foregroundColor: Colors.white,
                ),
                onPressed: controller.retry,
                child: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }

    switch (controller.readerFormat.value) {
      case ReaderFileFormat.epub:
        return _buildEpubBody();
      case ReaderFileFormat.txt:
        return _TxtReaderBody(controller: controller);
      case ReaderFileFormat.pdf:
        return _PdfReaderBody(controller: controller);
      case ReaderFileFormat.unknown:
        return const SizedBox.shrink();
    }
  }

  Widget _buildEpubBody() {
    final chrome = _ReaderChromeColors.resolve(controller);
    return _EpubInteractionSurface(
      controller: controller,
      child: Stack(
        children: [
          Positioned.fill(
            child: EpubViewer(
              epubController: controller.epubController,
              epubSource: EpubSource.fromUrl(controller.epubUrl.value),
              initialCfi: controller.initialCfi,
              displaySettings: controller.displaySettings,
              onEpubLoaded: controller.onEpubLoaded,
              onChaptersLoaded: controller.onChaptersLoaded,
              onRelocated: controller.onRelocated,
            ),
          ),
          if (controller.viewerLoading.value)
            Positioned.fill(
              child: ColoredBox(
                color: controller.activeTheme.overlayColor,
                child: Center(
                  child: CircularProgressIndicator(color: chrome.accentColor),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 参考音频播放器毛玻璃抽屉风格：26px 顶部圆角 + 定位当前章节按钮 + 胶囊高亮列表
  Future<void> _showNavigationSheet(BuildContext context) {
    final chrome = _ReaderChromeColors.resolve(controller);
    const itemExtent = 58.0;
    final currentIndex = controller.currentNavigationIndex;
    final initialOffset = currentIndex >= 0 ? currentIndex * itemExtent : 0.0;
    final scrollController = ScrollController(
      initialScrollOffset: initialOffset,
    );

    void scrollToCurrent() {
      if (!scrollController.hasClients) return;
      final idx = controller.currentNavigationIndex;
      if (idx < 0) return;
      final target = (idx * itemExtent).clamp(
        scrollController.position.minScrollExtent,
        scrollController.position.maxScrollExtent,
      );
      scrollController.animateTo(
        target,
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
      );
    }

    return showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) {
        return ClipRRect(
          borderRadius: BorderRadius.vertical(top: Radius.circular(26.r)),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
            child: Container(
              height: MediaQuery.of(context).size.height * 0.66,
              decoration: BoxDecoration(
                color: chrome.surfaceColor.withValues(alpha: 0.94),
                borderRadius: BorderRadius.vertical(top: Radius.circular(26.r)),
                border: Border.all(color: chrome.dividerColor, width: 1.2),
              ),
              child: SafeArea(
                top: false,
                child: Column(
                  children: [
                    SizedBox(height: 10.h),
                    Container(
                      width: 38.w,
                      height: 4.h,
                      decoration: BoxDecoration(
                        color: chrome.secondaryTextColor.withValues(
                          alpha: 0.35,
                        ),
                        borderRadius: BorderRadius.circular(99.r),
                      ),
                    ),
                    Padding(
                      padding: EdgeInsets.fromLTRB(20.w, 12.h, 16.w, 10.h),
                      child: Row(
                        children: [
                          Container(
                            width: 34.w,
                            height: 34.w,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: chrome.accentColor.withValues(alpha: 0.16),
                            ),
                            child: Icon(
                              Icons.menu_book_rounded,
                              color: chrome.accentColor,
                              size: 18.r,
                            ),
                          ),
                          SizedBox(width: 10.w),
                          Text(
                            '${controller.navigationTooltip} (${controller.navigationItems.length})',
                            style: TextStyle(
                              color: chrome.textColor,
                              fontSize: 16.sp,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const Spacer(),
                          IconButton(
                            tooltip: '定位当前章节',
                            onPressed: scrollToCurrent,
                            icon: Icon(
                              Icons.my_location_rounded,
                              color: chrome.secondaryTextColor,
                              size: 19.r,
                            ),
                          ),
                          GestureDetector(
                            onTap: () => Navigator.of(context).pop(),
                            child: Container(
                              width: 36.w,
                              height: 36.w,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: chrome.accentColor.withValues(
                                  alpha: 0.14,
                                ),
                              ),
                              child: Icon(
                                Icons.keyboard_arrow_down_rounded,
                                color: chrome.textColor,
                                size: 22.r,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Divider(height: 1, color: chrome.dividerColor),
                    Expanded(
                      child: Material(
                        type: MaterialType.transparency,
                        child: Obx(
                          () => ListView.builder(
                            controller: scrollController,
                            itemExtent: itemExtent,
                            padding: EdgeInsets.symmetric(
                              horizontal: 14.w,
                              vertical: 8.h,
                            ),
                            itemCount: controller.navigationItems.length,
                            itemBuilder: (context, index) {
                              final item = controller.navigationItems[index];
                              final selected =
                                  index == controller.currentNavigationIndex;

                              return Container(
                                margin: EdgeInsets.symmetric(vertical: 3.h),
                                decoration: BoxDecoration(
                                  color: selected
                                      ? chrome.accentColor.withValues(
                                          alpha: 0.16,
                                        )
                                      : Colors.transparent,
                                  borderRadius: BorderRadius.circular(14.r),
                                  border: selected
                                      ? Border.all(
                                          color: chrome.accentColor.withValues(
                                            alpha: 0.35,
                                          ),
                                        )
                                      : null,
                                ),
                                child: ListTile(
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(14.r),
                                  ),
                                  contentPadding: EdgeInsets.only(
                                    left: (14 + item.depth * 16).w,
                                    right: 12.w,
                                  ),
                                  leading: Container(
                                    width: 28.w,
                                    height: 28.w,
                                    decoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(9.r),
                                      color: selected
                                          ? chrome.accentColor
                                          : chrome.secondaryTextColor
                                                .withValues(alpha: 0.12),
                                    ),
                                    alignment: Alignment.center,
                                    child: Text(
                                      '${index + 1}',
                                      style: TextStyle(
                                        fontSize: 11.sp,
                                        fontWeight: FontWeight.w700,
                                        color: selected
                                            ? Colors.white
                                            : chrome.secondaryTextColor,
                                      ),
                                    ),
                                  ),
                                  title: Text(
                                    item.label,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: selected
                                          ? chrome.accentColor
                                          : chrome.textColor,
                                      fontSize: 13.5.sp,
                                      fontWeight: selected
                                          ? FontWeight.w800
                                          : FontWeight.w500,
                                    ),
                                  ),
                                  trailing: Icon(
                                    selected
                                        ? Icons.equalizer_rounded
                                        : Icons.chevron_right_rounded,
                                    color: selected
                                        ? chrome.accentColor
                                        : chrome.secondaryTextColor,
                                    size: 19.r,
                                  ),
                                  onTap: () async {
                                    await controller.openNavigationItem(item);
                                    if (context.mounted) {
                                      Navigator.of(context).pop();
                                    }
                                  },
                                ),
                              );
                            },
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  /// 参考 Figma 播放器设计风格的阅读外观与字号调节抽屉
  Future<void> _showThemeSheet(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return Obx(() {
          final chrome = _ReaderChromeColors.resolve(controller);
          return ClipRRect(
            borderRadius: BorderRadius.vertical(top: Radius.circular(26.r)),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
              child: Container(
                padding: EdgeInsets.fromLTRB(20.w, 12.h, 20.w, 24.h),
                decoration: BoxDecoration(
                  color: chrome.surfaceColor.withValues(alpha: 0.96),
                  borderRadius: BorderRadius.vertical(
                    top: Radius.circular(26.r),
                  ),
                  border: Border.all(color: chrome.dividerColor),
                ),
                child: SafeArea(
                  top: false,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Center(
                        child: Container(
                          width: 38.w,
                          height: 4.h,
                          decoration: BoxDecoration(
                            color: chrome.secondaryTextColor.withValues(
                              alpha: 0.35,
                            ),
                            borderRadius: BorderRadius.circular(99.r),
                          ),
                        ),
                      ),
                      SizedBox(height: 16.h),
                      Row(
                        children: [
                          Icon(
                            Icons.auto_awesome_rounded,
                            color: chrome.accentColor,
                            size: 20.r,
                          ),
                          SizedBox(width: 8.w),
                          Text(
                            '阅读主题与字号',
                            style: TextStyle(
                              color: chrome.textColor,
                              fontSize: 16.sp,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const Spacer(),
                          if (controller.canAdjustFontSize)
                            Container(
                              padding: EdgeInsets.symmetric(
                                horizontal: 10.w,
                                vertical: 4.h,
                              ),
                              decoration: BoxDecoration(
                                color: chrome.accentColor.withValues(
                                  alpha: 0.14,
                                ),
                                borderRadius: BorderRadius.circular(99.r),
                              ),
                              child: Text(
                                '字号 ${controller.fontSize.value.round()} pt',
                                style: TextStyle(
                                  color: chrome.accentColor,
                                  fontSize: 11.5.sp,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                        ],
                      ),
                      if (controller.canAdjustFontSize) ...[
                        SizedBox(height: 14.h),
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton.icon(
                                onPressed: controller.decreaseFontSize,
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: chrome.textColor,
                                  side: BorderSide(color: chrome.dividerColor),
                                  padding: EdgeInsets.symmetric(vertical: 11.h),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(14.r),
                                  ),
                                ),
                                icon: Icon(
                                  Icons.text_decrease_rounded,
                                  size: 18.r,
                                ),
                                label: const Text('A- 减小'),
                              ),
                            ),
                            SizedBox(width: 12.w),
                            Expanded(
                              child: OutlinedButton.icon(
                                onPressed: controller.increaseFontSize,
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: chrome.textColor,
                                  side: BorderSide(color: chrome.dividerColor),
                                  padding: EdgeInsets.symmetric(vertical: 11.h),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(14.r),
                                  ),
                                ),
                                icon: Icon(
                                  Icons.text_increase_rounded,
                                  size: 18.r,
                                ),
                                label: const Text('A+ 增大'),
                              ),
                            ),
                          ],
                        ),
                      ],
                      SizedBox(height: 18.h),
                      Text(
                        '背景色板',
                        style: TextStyle(
                          color: chrome.secondaryTextColor,
                          fontSize: 12.5.sp,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      SizedBox(height: 10.h),
                      Wrap(
                        spacing: 10.w,
                        runSpacing: 10.h,
                        children: ReaderController.themePresets.map((theme) {
                          final selected =
                              theme.id == controller.selectedThemeId.value;
                          return GestureDetector(
                            onTap: () => controller.applyTheme(theme.id),
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 200),
                              padding: EdgeInsets.symmetric(
                                horizontal: 14.w,
                                vertical: 10.h,
                              ),
                              decoration: BoxDecoration(
                                color: theme.backgroundColor,
                                borderRadius: BorderRadius.circular(16.r),
                                border: Border.all(
                                  color: selected
                                      ? theme.accentColor
                                      : theme.textColor.withValues(alpha: 0.18),
                                  width: selected ? 2.0 : 1.0,
                                ),
                                boxShadow: selected
                                    ? [
                                        BoxShadow(
                                          color: theme.accentColor.withValues(
                                            alpha: 0.25,
                                          ),
                                          blurRadius: 12,
                                          offset: const Offset(0, 4),
                                        ),
                                      ]
                                    : null,
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Container(
                                    width: 14.w,
                                    height: 14.w,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: theme.accentColor,
                                    ),
                                  ),
                                  SizedBox(width: 8.w),
                                  Text(
                                    theme.label,
                                    style: TextStyle(
                                      color: theme.textColor,
                                      fontSize: 13.sp,
                                      fontWeight: selected
                                          ? FontWeight.w800
                                          : FontWeight.w600,
                                    ),
                                  ),
                                  if (selected) ...[
                                    SizedBox(width: 6.w),
                                    Icon(
                                      Icons.check_circle_rounded,
                                      color: theme.accentColor,
                                      size: 16.r,
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          );
                        }).toList(growable: false),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        });
      },
    );
  }
}

class _TxtReaderBody extends StatefulWidget {
  const _TxtReaderBody({required this.controller});

  final ReaderController controller;

  @override
  State<_TxtReaderBody> createState() => _TxtReaderBodyState();
}

class _TxtReaderBodyState extends State<_TxtReaderBody> {
  Size? _lastViewport;
  bool _handlingBoundaryTurn = false;

  bool _handleTxtScrollNotification(ScrollNotification notification) {
    if (notification is! OverscrollNotification ||
        notification.metrics.axis != Axis.horizontal ||
        _handlingBoundaryTurn) {
      return false;
    }

    final pages = widget.controller.currentTxtPages;
    if (pages.isEmpty) return false;

    final currentPageIndex = widget.controller.currentTxtPageIndex.value;
    final atFirstPage = currentPageIndex <= 0;
    final atLastPage = currentPageIndex >= pages.length - 1;

    if (notification.overscroll > 0 && atLastPage) {
      unawaited(_turnTxtBoundaryPage(forward: true));
    } else if (notification.overscroll < 0 && atFirstPage) {
      unawaited(_turnTxtBoundaryPage(forward: false));
    }

    return false;
  }

  Future<void> _turnTxtBoundaryPage({required bool forward}) async {
    if (_handlingBoundaryTurn) return;
    _handlingBoundaryTurn = true;
    try {
      if (forward) {
        await widget.controller.goNextPage();
      } else {
        await widget.controller.goPreviousPage();
      }
      await Future<void>.delayed(const Duration(milliseconds: 180));
    } finally {
      _handlingBoundaryTurn = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final viewport = Size(constraints.maxWidth, constraints.maxHeight);
        if (_lastViewport == null ||
            (_lastViewport!.width - viewport.width).abs() >= 1 ||
            (_lastViewport!.height - viewport.height).abs() >= 1) {
          _lastViewport = viewport;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            widget.controller.updateTxtViewport(viewport);
          });
        }

        return Obx(() {
          final activeTheme = widget.controller.activeTheme;
          final currentSegment = widget.controller.currentTxtSegment;
          if (currentSegment == null) {
            return _ReaderPlaceholder(
              text: '没有可显示的文本内容',
              color: activeTheme.secondaryTextColor,
            );
          }
          if (!widget.controller.txtPaginationReady.value) {
            return Center(
              child: CircularProgressIndicator(color: activeTheme.accentColor),
            );
          }

          final pages = widget.controller.currentTxtPages;
          final pageController = widget.controller.txtPageController;
          final version = widget.controller.txtPageControllerVersion.value;

          if (currentSegment.content.trim().isEmpty) {
            return _ReaderPlaceholder(
              text: '文本内容为空',
              color: activeTheme.secondaryTextColor,
            );
          }
          if (pageController == null || pages.isEmpty) {
            return Center(
              child: CircularProgressIndicator(color: activeTheme.accentColor),
            );
          }

          return Stack(
            children: [
              Positioned.fill(
                child: NotificationListener<ScrollNotification>(
                  onNotification: _handleTxtScrollNotification,
                  child: PageView.builder(
                    key: ValueKey(
                      'txt-$version-${widget.controller.currentTxtSegmentIndex.value}',
                    ),
                    controller: pageController,
                    itemCount: pages.length,
                    onPageChanged: widget.controller.onTxtPageChanged,
                    itemBuilder: (context, index) {
                      final page = pages[index];
                      return Padding(
                        padding: ReaderController.txtPagePadding,
                        child: Align(
                          alignment: Alignment.topLeft,
                          child: Text(
                            page.text,
                            style: widget.controller.txtTextStyle,
                            textAlign: TextAlign.justify,
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
              Positioned(
                left: 16.w,
                right: 16.w,
                bottom: 14.h,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    _ReaderBadge(
                      backgroundColor: activeTheme.surfaceColor.withValues(
                        alpha: 0.90,
                      ),
                      borderColor: activeTheme.dividerColor,
                      textColor: activeTheme.accentColor,
                      text:
                          '${(widget.controller.progress.value * 100).toStringAsFixed(1)}%',
                    ),
                    _ReaderBadge(
                      backgroundColor: activeTheme.surfaceColor.withValues(
                        alpha: 0.90,
                      ),
                      borderColor: activeTheme.dividerColor,
                      textColor: activeTheme.secondaryTextColor,
                      text:
                          '第 ${widget.controller.currentTxtSegmentIndex.value + 1}/${widget.controller.txtSegments.length} 节 · '
                          '第 ${widget.controller.currentTxtPageIndex.value + 1}/${widget.controller.txtPageCount.value} 页',
                    ),
                  ],
                ),
              ),
            ],
          );
        });
      },
    );
  }
}

class _PdfReaderBody extends StatelessWidget {
  const _PdfReaderBody({required this.controller});

  final ReaderController controller;

  @override
  Widget build(BuildContext context) {
    final pdfController = controller.pdfController;
    final chrome = _ReaderChromeColors.resolve(controller);
    if (pdfController == null) {
      return Center(
        child: CircularProgressIndicator(color: chrome.accentColor),
      );
    }

    return Stack(
      children: [
        Positioned.fill(
          child: PdfView(
            controller: pdfController,
            renderer: _renderPdfPage,
            scrollDirection: Axis.horizontal,
            backgroundDecoration: BoxDecoration(color: chrome.backgroundColor),
            onDocumentLoaded: controller.onPdfDocumentLoaded,
            onDocumentError: controller.onPdfDocumentError,
            onPageChanged: controller.onPdfPageChanged,
            builders: const PdfViewBuilders<DefaultBuilderOptions>(
              options: DefaultBuilderOptions(),
              documentLoaderBuilder: _emptyBuilder,
              pageLoaderBuilder: _emptyBuilder,
              errorBuilder: _errorBuilder,
            ),
          ),
        ),
        if (controller.viewerLoading.value)
          Positioned.fill(
            child: ColoredBox(
              color: chrome.overlayColor,
              child: Center(
                child: CircularProgressIndicator(color: chrome.accentColor),
              ),
            ),
          ),
        Positioned(
          right: 16,
          bottom: 16,
          child: Obx(
            () => _ReaderBadge(
              backgroundColor: chrome.surfaceColor.withValues(alpha: 0.92),
              borderColor: chrome.dividerColor,
              textColor: chrome.textColor,
              text: controller.pdfPageCount.value > 0
                  ? '第 ${controller.currentPdfPage.value}/${controller.pdfPageCount.value} 页'
                  : '加载页码中...',
            ),
          ),
        ),
      ],
    );
  }
}

class _EpubInteractionSurface extends StatelessWidget {
  const _EpubInteractionSurface({
    required this.controller,
    required this.child,
  });

  final ReaderController controller;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = math.max(1.0, constraints.maxWidth);
        final height = math.max(1.0, constraints.maxHeight);

        return Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: (event) {
            final point = _normalizePointer(event.localPosition, width, height);
            controller.onEpubInteractionStart(point.dx, point.dy);
          },
          onPointerUp: (event) {
            final point = _normalizePointer(event.localPosition, width, height);
            controller.onEpubInteractionEnd(point.dx, point.dy);
          },
          onPointerCancel: (_) => controller.cancelEpubInteraction(),
          child: child,
        );
      },
    );
  }

  Offset _normalizePointer(Offset offset, double width, double height) {
    return Offset(offset.dx / width, offset.dy / height);
  }
}

class _ReaderBadge extends StatelessWidget {
  const _ReaderBadge({
    required this.backgroundColor,
    required this.borderColor,
    required this.textColor,
    required this.text,
  });

  final Color backgroundColor;
  final Color borderColor;
  final Color textColor;
  final String text;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(999),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: backgroundColor,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: borderColor),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Text(
              text,
              style: TextStyle(
                color: textColor,
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ReaderPlaceholder extends StatelessWidget {
  const _ReaderPlaceholder({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(text, style: TextStyle(color: color, fontSize: 14)),
    );
  }
}

Widget _emptyBuilder(BuildContext context) => const SizedBox.shrink();

Widget _errorBuilder(BuildContext context, Exception error) =>
    const SizedBox.shrink();

const _pdfFallbackRenderWidth = 1440.0;
const _pdfFallbackRenderHeight = 2048.0;
const _pdfFallbackAspectRatio = 1 / 1.41421356237;
const _pdfMaxRenderDimension = 2048.0;

Future<PdfPageImage?> _renderPdfPage(PdfPage page) {
  final renderSize = _resolvePdfRenderSize(page);
  return page.render(
    width: renderSize.width,
    height: renderSize.height,
    format: PdfPageImageFormat.jpeg,
    backgroundColor: '#ffffff',
  );
}

Size _resolvePdfRenderSize(PdfPage page) {
  final rawWidth = page.width;
  final rawHeight = page.height;
  final hasValidWidth = _isUsablePdfDimension(rawWidth);
  final hasValidHeight = _isUsablePdfDimension(rawHeight);

  double width = _pdfFallbackRenderWidth;
  double height = _pdfFallbackRenderHeight;

  if (hasValidWidth && hasValidHeight) {
    final desiredWidth = rawWidth * 2;
    final desiredHeight = rawHeight * 2;
    final longestSide = math.max(desiredWidth, desiredHeight);
    final scale = longestSide > _pdfMaxRenderDimension
        ? _pdfMaxRenderDimension / longestSide
        : 1.0;
    width = math.max(1.0, desiredWidth * scale);
    height = math.max(1.0, desiredHeight * scale);
  } else if (hasValidWidth) {
    width = math.min(rawWidth * 2, _pdfMaxRenderDimension);
    height = math.max(1.0, width / _pdfFallbackAspectRatio);
  } else if (hasValidHeight) {
    height = math.min(rawHeight * 2, _pdfMaxRenderDimension);
    width = math.max(1.0, height * _pdfFallbackAspectRatio);
  }

  if (!width.isFinite || width <= 0) {
    width = _pdfFallbackRenderWidth;
  }
  if (!height.isFinite || height <= 0) {
    height = _pdfFallbackRenderHeight;
  }
  return Size(width, height);
}

bool _isUsablePdfDimension(double value) => value.isFinite && value > 1;

class _ReaderChromeColors {
  const _ReaderChromeColors({
    required this.backgroundColor,
    required this.surfaceColor,
    required this.overlayColor,
    required this.textColor,
    required this.secondaryTextColor,
    required this.accentColor,
    required this.dividerColor,
  });

  final Color backgroundColor;
  final Color surfaceColor;
  final Color overlayColor;
  final Color textColor;
  final Color secondaryTextColor;
  final Color accentColor;
  final Color dividerColor;

  static const _pdf = _ReaderChromeColors(
    backgroundColor: Color(0xFFFAF9FE),
    surfaceColor: Color(0xFFF3F0FC),
    overlayColor: Color(0xCCFAF9FE),
    textColor: Color(0xFF333333),
    secondaryTextColor: Color(0xFF828282),
    accentColor: Color(0xFF9570FF),
    dividerColor: Color(0x1F9570FF),
  );

  factory _ReaderChromeColors.resolve(ReaderController controller) {
    if (controller.readerFormat.value == ReaderFileFormat.pdf) {
      return _pdf;
    }

    final theme = controller.activeTheme;
    return _ReaderChromeColors(
      backgroundColor: theme.backgroundColor,
      surfaceColor: theme.surfaceColor,
      overlayColor: theme.overlayColor,
      textColor: theme.textColor,
      secondaryTextColor: theme.secondaryTextColor,
      accentColor: theme.accentColor,
      dividerColor: theme.dividerColor,
    );
  }
}
