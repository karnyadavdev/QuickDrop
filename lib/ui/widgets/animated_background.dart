import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../app_theme.dart';

class AnimatedBackground extends StatefulWidget {
  final Widget child;

  const AnimatedBackground({super.key, required this.child});

  @override
  State<AnimatedBackground> createState() => _AnimatedBackgroundState();
}

class _AnimatedBackgroundState extends State<AnimatedBackground>
    with SingleTickerProviderStateMixin {
  late final AnimationController motion;

  @override
  void initState() {
    super.initState();
    motion = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 20),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      motion.stop();
      motion.value = 0.25;
    } else if (!motion.isAnimating) {
      motion.repeat();
    }
  }

  @override
  void dispose() {
    motion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: Stack(
        fit: StackFit.expand,
        children: [
          AnimatedBuilder(
            animation: motion,
            builder: (context, _) =>
                CustomPaint(painter: BackgroundPainter(motion.value)),
          ),
          Positioned.fill(
            child: IgnorePointer(
              child: Opacity(
                opacity: 0.32,
                child: Image.asset(
                  'assets/ui/green_waves.webp',
                  fit: BoxFit.cover,
                  alignment: Alignment.bottomCenter,
                  filterQuality: FilterQuality.high,
                ),
              ),
            ),
          ),
          widget.child,
        ],
      ),
    );
  }
}

class BackgroundPainter extends CustomPainter {
  final double time;

  BackgroundPainter(this.time);

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    const colors = [Color(0xFF061411), Color(0xFF020A0B), Color(0xFF07120E)];

    canvas.drawRect(
      rect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: colors,
        ).createShader(rect),
    );

    final glow = AppColors.green.withAlpha(20);
    canvas.drawCircle(
      Offset(
        size.width * (0.72 + math.sin(time * math.pi * 2) * 0.03),
        size.height * 0.2,
      ),
      size.shortestSide * 0.54,
      Paint()
        ..shader = RadialGradient(colors: [glow, Colors.transparent])
            .createShader(
              Rect.fromCircle(
                center: Offset(
                  size.width * (0.72 + math.sin(time * math.pi * 2) * 0.03),
                  size.height * 0.2,
                ),
                radius: size.shortestSide * 0.54,
              ),
            ),
    );
  }

  @override
  bool shouldRepaint(BackgroundPainter oldDelegate) => oldDelegate.time != time;
}
