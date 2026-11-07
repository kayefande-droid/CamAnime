import 'package:flutter/material.dart';

/// CamAnime design tokens — a single source of truth for the app's premium
/// dark interface. Kept intentionally small: colour, radius, spacing and a
/// handful of reusable surfaces.
class CamColors {
  static const bg = Color(0xFF06070B);
  static const surface = Color(0xFF0C0F16);
  static const surfaceAlt = Color(0xFF141925);
  static const surfaceHigh = Color(0xFF1B2130);
  static const line = Color(0xFF232A38);
  static const ink = Color(0xFFF5F7FC);
  static const inkDim = Color(0xFF98A3BA);
  static const accent = Color(0xFFFFB347);
  static const accentAlt = Color(0xFF8B5CF6);
  static const success = Color(0xFF2DD4A7);
  static const info = Color(0xFF4C8DFF);
  static const danger = Color(0xFFFF5E62);
}

class CamRadius {
  static const sm = 10.0;
  static const md = 14.0;
  static const lg = 20.0;
  static const xl = 26.0;
}

class CamSpace {
  static const xs = 6.0;
  static const sm = 10.0;
  static const md = 16.0;
  static const lg = 22.0;
  static const xl = 30.0;
}

/// Dark, cinematic Material 3 theme. `seed` comes from the user's chosen
/// accent theme so the whole interface re-tints without losing contrast.
ThemeData camTheme({required Color seed, required Color background}) {
  final scheme = ColorScheme.fromSeed(
    seedColor: seed,
    brightness: Brightness.dark,
  ).copyWith(
    surface: CamColors.surface,
    primary: seed,
    secondary: CamColors.accentAlt,
    error: CamColors.danger,
  );
  final base = ThemeData.dark(useMaterial3: true);
  return base.copyWith(
    scaffoldBackgroundColor: background,
    colorScheme: scheme,
    splashFactory: InkSparkle.splashFactory,
    appBarTheme: const AppBarTheme(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        fontSize: 19,
        fontWeight: FontWeight.w800,
        color: CamColors.ink,
        letterSpacing: -0.2,
      ),
    ),
    cardTheme: CardThemeData(
      color: CamColors.surface,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(CamRadius.lg),
        side: const BorderSide(color: CamColors.line),
      ),
    ),
    dividerTheme: const DividerThemeData(
      color: CamColors.line,
      thickness: 1,
      space: 1,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: CamColors.surfaceAlt,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(CamRadius.md),
        borderSide: const BorderSide(color: CamColors.line),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(CamRadius.md),
        borderSide: const BorderSide(color: CamColors.line),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(CamRadius.md),
        borderSide: BorderSide(color: seed, width: 1.4),
      ),
      hintStyle: const TextStyle(color: CamColors.inkDim, fontSize: 13),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: CamColors.surfaceHigh,
      contentTextStyle: const TextStyle(color: CamColors.ink, fontSize: 13),
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(CamRadius.md)),
      behavior: SnackBarBehavior.floating,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: seed,
        foregroundColor: Colors.black,
        textStyle: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14),
        minimumSize: const Size(0, 48),
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(CamRadius.md)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: CamColors.ink,
        side: const BorderSide(color: CamColors.line),
        textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
        minimumSize: const Size(0, 48),
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(CamRadius.md)),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: seed),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: CamColors.surfaceAlt,
      side: const BorderSide(color: CamColors.line),
      labelStyle: const TextStyle(color: CamColors.ink, fontSize: 12),
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(CamRadius.sm)),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: seed),
    tabBarTheme: const TabBarThemeData(
      labelColor: CamColors.ink,
      unselectedLabelColor: CamColors.inkDim,
      indicatorSize: TabBarIndicatorSize.label,
      dividerColor: Colors.transparent,
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: CamColors.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
    ),
  );
}

/// Rounded surface with a hairline border — the app's base building block.
class CamCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;
  final Color? color;
  final Gradient? gradient;
  final Border? border;
  final double radius;

  const CamCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(CamSpace.md),
    this.onTap,
    this.color,
    this.gradient,
    this.border,
    this.radius = CamRadius.lg,
  });

  @override
  Widget build(BuildContext context) {
    final content = Container(
      padding: padding,
      decoration: BoxDecoration(
        color: gradient == null ? (color ?? CamColors.surface) : null,
        gradient: gradient,
        borderRadius: BorderRadius.circular(radius),
        border: border ?? Border.all(color: CamColors.line),
      ),
      child: child,
    );
    if (onTap == null) return content;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(radius),
        child: content,
      ),
    );
  }
}

/// Section heading with an optional small eyebrow and trailing action.
class CamSectionTitle extends StatelessWidget {
  final String title;
  final String? eyebrow;
  final Widget? action;
  final EdgeInsetsGeometry padding;

  const CamSectionTitle(
    this.title, {
    super.key,
    this.eyebrow,
    this.action,
    this.padding = const EdgeInsets.fromLTRB(16, 22, 16, 10),
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (eyebrow != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(
                      eyebrow!.toUpperCase(),
                      style: const TextStyle(
                        color: CamColors.inkDim,
                        fontSize: 10,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1.4,
                      ),
                    ),
                  ),
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.3,
                    color: CamColors.ink,
                  ),
                ),
              ],
            ),
          ),
          if (action != null) action!,
        ],
      ),
    );
  }
}

class MetaPill extends StatelessWidget {
  final String text;
  final IconData? icon;
  final Color color;
  const MetaPill(this.text,
      {super.key, this.icon, this.color = CamColors.inkDim});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(99),
          border: Border.all(color: color.withValues(alpha: 0.28)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (icon != null) ...[
            Icon(icon, size: 12, color: color),
            const SizedBox(width: 4),
          ],
          Text(
            text,
            style: TextStyle(
              color: color,
              fontSize: 10.5,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.2,
            ),
          ),
        ]),
      );
}

/// Gradient primary action used for playback.
class CamPrimaryButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback? onPressed;
  final bool expand;
  const CamPrimaryButton({
    super.key,
    required this.label,
    this.icon = Icons.play_arrow_rounded,
    this.onPressed,
    this.expand = true,
  });

  @override
  Widget build(BuildContext context) {
    final button = DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(CamRadius.md),
        gradient: const LinearGradient(colors: [
          Color(0xFFFFC46B),
          Color(0xFFFF9A3D),
        ]),
      ),
      child: FilledButton.icon(
        style: FilledButton.styleFrom(
          backgroundColor: Colors.transparent,
          foregroundColor: Colors.black,
          shadowColor: Colors.transparent,
          minimumSize: const Size(0, 50),
          padding: const EdgeInsets.symmetric(horizontal: 18),
        ),
        onPressed: onPressed,
        icon: Icon(icon, size: 20),
        label: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
    );
    return expand ? SizedBox(width: double.infinity, child: button) : button;
  }
}

class CamGhostButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback? onPressed;
  final bool expand;
  const CamGhostButton({
    super.key,
    required this.label,
    this.icon = Icons.download_rounded,
    this.onPressed,
    this.expand = true,
  });

  @override
  Widget build(BuildContext context) {
    final button = OutlinedButton.icon(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 50),
        padding: const EdgeInsets.symmetric(horizontal: 16),
        side: const BorderSide(color: CamColors.line),
        backgroundColor: CamColors.surfaceAlt,
      ),
      onPressed: onPressed,
      icon: Icon(icon, size: 19),
      label: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
    );
    return expand ? SizedBox(width: double.infinity, child: button) : button;
  }
}

class EmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String message;
  final Widget? action;
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.action,
  });

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 30, vertical: 46),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: CamColors.surfaceAlt,
              shape: BoxShape.circle,
              border: Border.all(color: CamColors.line),
            ),
            child: Icon(icon, size: 32, color: CamColors.inkDim),
          ),
          const SizedBox(height: 16),
          Text(title,
              textAlign: TextAlign.center,
              style:
                  const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
          const SizedBox(height: 6),
          Text(message,
              textAlign: TextAlign.center,
              style: const TextStyle(
                  color: CamColors.inkDim, fontSize: 12.5, height: 1.45)),
          if (action != null) ...[const SizedBox(height: 18), action!],
        ]),
      );
}

/// Thin gradient progress line used by downloads.
class CamProgress extends StatelessWidget {
  final double? value;
  final Color color;
  final double height;
  const CamProgress({
    super.key,
    required this.value,
    this.color = CamColors.success,
    this.height = 6,
  });

  @override
  Widget build(BuildContext context) => ClipRRect(
        borderRadius: BorderRadius.circular(height),
        child: LinearProgressIndicator(
          value: value,
          minHeight: height,
          backgroundColor: CamColors.surfaceHigh,
          valueColor: AlwaysStoppedAnimation(color),
        ),
      );
}

class CamSkeleton extends StatelessWidget {
  final double height;
  final double? width;
  final double radius;
  const CamSkeleton({super.key, this.height = 12, this.width, this.radius = 8});

  @override
  Widget build(BuildContext context) => Container(
        height: height,
        width: width,
        decoration: BoxDecoration(
          color: CamColors.surfaceAlt,
          borderRadius: BorderRadius.circular(radius),
        ),
      );
}

String compactBytes(int bytes) {
  if (bytes <= 0) return '0 MB';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var size = bytes.toDouble();
  var unit = 0;
  while (size >= 1024 && unit < units.length - 1) {
    size /= 1024;
    unit += 1;
  }
  final digits = size >= 100 || unit <= 1 ? 0 : 1;
  return '${size.toStringAsFixed(digits)} ${units[unit]}';
}

String compactDuration(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes.remainder(60);
  if (h > 0) return '${h}h ${m}m';
  return '${m}m';
}
