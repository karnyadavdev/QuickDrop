import 'dart:ui';
import 'package:flutter/material.dart';
import '../app_theme.dart';

class GlassPanel extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry? padding;
  final double radius;
  final Color? glowColor;
  final bool blur;

  const GlassPanel({
    super.key,
    required this.child,
    this.padding,
    this.radius = 20,
    this.glowColor,
    this.blur = true,
  });

  @override
  Widget build(BuildContext context) {
    final shadow = Colors.black.withAlpha(72);
    final panelTop = const Color(0xFF13221E).withAlpha(82);
    final panelBottom = const Color(0xFF06100E).withAlpha(62);
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        boxShadow: [
          BoxShadow(color: shadow, blurRadius: 28, offset: const Offset(0, 12)),
          if (glowColor != null)
            BoxShadow(
              color: glowColor!.withAlpha(24),
              blurRadius: 34,
              spreadRadius: -12,
            ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: blur
            ? BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                child: _panel(panelTop, panelBottom),
              )
            : _panel(panelTop, panelBottom),
      ),
    );
  }

  Widget _panel(Color panelTop, Color panelBottom) {
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Colors.white.withAlpha(20),
            AppColors.green.withAlpha(28),
            AppColors.green.withAlpha(10),
            Colors.white.withAlpha(5),
          ],
          stops: const [0, 0.24, 0.68, 1],
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(0.8),
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(radius - 0.8),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [panelTop, panelBottom],
            ),
          ),
          child: Padding(padding: padding ?? EdgeInsets.zero, child: child),
        ),
      ),
    );
  }
}

class GlassIconButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  const GlassIconButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: label,
      child: Semantics(
        button: true,
        label: label,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onPressed,
            customBorder: const CircleBorder(),
            child: Ink(
              width: 46,
              height: 46,
              decoration: BoxDecoration(
                color: const Color(0xFF0A1613).withAlpha(62),
                shape: BoxShape.circle,
                border: Border.all(color: AppColors.green.withAlpha(30)),
                boxShadow: [
                  BoxShadow(
                    color: AppColors.green.withAlpha(12),
                    blurRadius: 16,
                  ),
                ],
              ),
              child: Icon(icon, size: 21, color: AppColors.muted),
            ),
          ),
        ),
      ),
    );
  }
}
