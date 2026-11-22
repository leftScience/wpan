import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:get/get.dart';
import 'package:media_kit/media_kit.dart';
import 'package:ohome/app/modules/home/controllers/home_controller.dart';
import 'package:ohome/app/services/index_services.dart';
import 'package:ohome/app/services/startup_recovery_service.dart';
import 'package:ohome/app/theme/app_theme.dart';
import 'package:ohome/app/utils/app_env.dart';

import 'app/routes/app_pages.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  await AppEnv.init();
  final startupRecovery = await StartupRecoveryService().recover();

  await IndexServices.init();
  runApp(_buildApp(initialRoute: startupRecovery.shouldOpenLogin ? Routes.LOGIN : AppPages.INITIAL));
}

Widget _buildApp({required String initialRoute}) {
  return ScreenUtilInit(
    designSize: const Size(375, 876),
    minTextAdapt: true,
    builder: (context, child) => GetMaterialApp(
      title: '王盘',
      locale: const Locale('zh', 'CN'),
      fallbackLocale: const Locale('zh', 'CN'),
      supportedLocales: const <Locale>[Locale('zh', 'CN')],
      localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      themeMode: ThemeMode.light,
      theme: ThemeData(
        brightness: Brightness.light,
        useMaterial3: true,
        scaffoldBackgroundColor: AppThemeColors.pageBackground,
        canvasColor: AppThemeColors.pageBackground,
        colorScheme: ColorScheme.fromSeed(
          seedColor: AppThemeColors.primary,
          brightness: Brightness.light,
          primary: AppThemeColors.primary,
          onPrimary: AppThemeColors.textOnAccent,
          secondary: AppThemeColors.secondary,
          onSecondary: AppThemeColors.textOnAccent,
          surface: AppThemeColors.surface,
          onSurface: AppThemeColors.textPrimary,
          error: AppThemeColors.danger,
        ),
        actionIconTheme: ActionIconThemeData(
          backButtonIconBuilder: (context) => Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppThemeColors.primary.withValues(alpha: 0.19),
            ),
            alignment: Alignment.center,
            child: const Icon(
              Icons.arrow_back_rounded,
              color: AppThemeColors.textPrimary,
              size: 20,
            ),
          ),
        ),
        appBarTheme: AppBarTheme(
          backgroundColor: Colors.transparent,
          surfaceTintColor: Colors.transparent,
          foregroundColor: AppThemeColors.textPrimary,
          elevation: 0,
          scrolledUnderElevation: 0,
          centerTitle: true,
          leadingWidth: 64,
          titleSpacing: 8,
          iconTheme: const IconThemeData(color: AppThemeColors.textPrimary),
          titleTextStyle: TextStyle(
            fontSize: 20.sp,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.2,
            color: AppThemeColors.textPrimary,
          ),
        ),
        textTheme: const TextTheme(
          bodyLarge: TextStyle(
            color: AppThemeColors.textPrimary,
            decoration: TextDecoration.none,
          ),
          bodyMedium: TextStyle(
            color: AppThemeColors.textPrimary,
            decoration: TextDecoration.none,
          ),
          bodySmall: TextStyle(
            color: AppThemeColors.textMuted,
            decoration: TextDecoration.none,
          ),
          titleLarge: TextStyle(
            color: AppThemeColors.textPrimary,
            fontWeight: FontWeight.bold,
            decoration: TextDecoration.none,
          ),
        ),
        iconTheme: const IconThemeData(color: AppThemeColors.textSecondary),
        dividerColor: AppThemeColors.divider,
        dividerTheme: const DividerThemeData(
          color: AppThemeColors.divider,
          thickness: 1,
          space: 1,
        ),
        cardTheme: CardThemeData(
          color: AppThemeColors.surface,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
            side: const BorderSide(color: AppThemeColors.border),
          ),
        ),
        dialogTheme: const DialogThemeData(
          backgroundColor: AppThemeColors.surface,
          surfaceTintColor: Colors.transparent,
          titleTextStyle: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w700,
            color: AppThemeColors.textPrimary,
          ),
          contentTextStyle: TextStyle(
            fontSize: 14,
            color: AppThemeColors.textSecondary,
          ),
        ),
        bottomSheetTheme: const BottomSheetThemeData(
          backgroundColor: AppThemeColors.surface,
          modalBackgroundColor: AppThemeColors.surface,
          surfaceTintColor: Colors.transparent,
          dragHandleColor: AppThemeColors.borderStrong,
        ),
        snackBarTheme: const SnackBarThemeData(
          backgroundColor: AppThemeColors.textPrimary,
          contentTextStyle: TextStyle(color: Colors.white),
          behavior: SnackBarBehavior.floating,
        ),
        progressIndicatorTheme: const ProgressIndicatorThemeData(
          color: AppThemeColors.primary,
        ),
        textSelectionTheme: const TextSelectionThemeData(
          cursorColor: AppThemeColors.primary,
          selectionColor: Color(0x339570FF),
          selectionHandleColor: AppThemeColors.primary,
        ),
      ),
      initialRoute: initialRoute,
      getPages: AppPages.routes,
      navigatorObservers: const <NavigatorObserver>[],
      routingCallback: (routing) {
        if (routing?.current != Routes.MAIN) return;
        if (!Get.isRegistered<HomeController>()) return;
        Get.find<HomeController>().refreshRecentHistory();
      },
    ),
  );
}
