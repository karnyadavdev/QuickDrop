import 'package:flutter/material.dart';
import 'glass_panel.dart';

class AdaptivePanel extends StatelessWidget {
  final Widget child;
  final double maxWidth;
  final EdgeInsetsGeometry padding;

  const AdaptivePanel({
    super.key,
    required this.child,
    this.maxWidth = 460,
    this.padding = const EdgeInsets.all(24),
  });

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;
    final compact = size.width < 600;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);

    return AnimatedPadding(
      duration: reduceMotion
          ? Duration.zero
          : const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      padding: EdgeInsets.only(bottom: keyboard),
      child: Material(
        color: Colors.transparent,
        child: SafeArea(
          child: Align(
            alignment: compact ? Alignment.bottomCenter : Alignment.center,
            child: Padding(
              padding: compact
                  ? const EdgeInsets.fromLTRB(10, 12, 10, 10)
                  : const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: maxWidth,
                  maxHeight: size.height - keyboard - (compact ? 22 : 48),
                ),
                child: SingleChildScrollView(
                  child: GlassPanel(
                    radius: compact ? 24 : 22,
                    padding: padding,
                    child: child,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
