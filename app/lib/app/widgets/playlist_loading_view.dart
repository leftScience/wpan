import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

class PlaylistLoadingView extends StatelessWidget {
  const PlaylistLoadingView({
    super.key,
    required this.message,
    this.icon,
    this.accentColor = AppThemeColors.primary,
    this.textColor = AppThemeColors.textSecondary,
  });

  final String message;
  final IconData? icon;
  final Color accentColor;
  final Color textColor;

  @override
  Widget build(BuildContext context) {
    final trimmedMessage = message.trim();
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircularProgressIndicator(color: accentColor),
          if (trimmedMessage.isNotEmpty) ...[
            const SizedBox(height: 14),
            Text(
              trimmedMessage,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: textColor,
                letterSpacing: 0.2,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
