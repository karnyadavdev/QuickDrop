import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../app_theme.dart';

class ConnectionCore extends StatefulWidget {
  final Animation<double> animation;
  final bool compact;

  const ConnectionCore({
    super.key,
    required this.animation,
    required this.compact,
  });

  @override
  State<ConnectionCore> createState() => _ConnectionCoreState();
}

class _ConnectionCoreState extends State<ConnectionCore> {
  late final Stopwatch _openTime;

  @override
  void initState() {
    super.initState();
    _openTime = Stopwatch()..start();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxSize = widget.compact ? 220.0 : 300.0;
        final size = math.min(
          maxSize,
          math.min(constraints.maxWidth * 0.82, constraints.maxHeight * 0.88),
        );

        return Semantics(
          label: 'Searching for nearby devices',
          child: AnimatedContainer(
            duration: MediaQuery.disableAnimationsOf(context)
                ? Duration.zero
                : const Duration(milliseconds: 520),
            curve: Curves.easeInOutCubic,
            width: size,
            height: size,
            child: RepaintBoundary(
              child: AnimatedBuilder(
                animation: widget.animation,
                builder: (context, _) {
                  final breath =
                      1 +
                      math.sin(widget.animation.value * math.pi * 2) * 0.008;
                  return CustomPaint(
                    painter: RadarPainter(
                      _openTime.elapsedMilliseconds / 16000,
                    ),
                    child: Center(
                      child: Transform.scale(
                        scale: breath,
                        child: Container(
                          width: size * 0.34,
                          height: size * 0.34,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: RadialGradient(
                              colors: [
                                AppColors.green.withAlpha(22),
                                const Color(0xFF071510).withAlpha(132),
                              ],
                            ),
                            border: Border.all(
                              color: AppColors.green.withAlpha(96),
                              width: 1,
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: AppColors.green.withAlpha(22),
                                blurRadius: 24,
                              ),
                            ],
                          ),
                          child: Center(
                            child: Icon(
                              defaultTargetPlatform == TargetPlatform.android
                                  ? Icons.phone_android_rounded
                                  : Icons.laptop_mac_rounded,
                              color: AppColors.green,
                              size: 42,
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        );
      },
    );
  }
}

class RadarPainter extends CustomPainter {
  final double progress;

  RadarPainter(this.progress);

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final maxRadius = size.shortestSide * 0.46;
    const waveCount = 3;

    for (var wave = 0; wave < waveCount; wave++) {
      final waveProgress = progress - wave / waveCount;
      if (waveProgress < 0) continue;
      final phase = waveProgress % 1;
      final growth = Curves.easeOutSine.transform(phase);
      final radius = maxRadius * (0.37 + growth * 0.63);
      final fadeIn = (phase / 0.08).clamp(0.0, 1.0);
      final fadeOut = ((1 - phase) / 0.86).clamp(0.0, 1.0);
      final visibility =
          Curves.easeOutSine.transform(fadeIn) *
          Curves.easeInOutSine.transform(fadeOut);
      const rim = Color(0xFFB9F6CD);
      const film = Colors.white;
      canvas.drawCircle(
        center,
        radius,
        Paint()
          ..shader = RadialGradient(
            colors: [
              AppColors.green.withAlpha((visibility * 3).round()),
              AppColors.green.withAlpha((visibility * 6).round()),
              film.withAlpha((visibility * 12).round()),
            ],
            stops: const [0, 0.72, 1],
          ).createShader(Rect.fromCircle(center: center, radius: radius))
          ..style = PaintingStyle.fill,
      );
      canvas.drawCircle(
        center,
        radius,
        Paint()
          ..color = AppColors.green.withAlpha((visibility * 42).round())
          ..style = PaintingStyle.stroke
          ..strokeWidth = 4
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
      );
      canvas.drawCircle(
        center,
        radius,
        Paint()
          ..color = rim.withAlpha((visibility * 88).round())
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.1,
      );
      canvas.drawCircle(
        center,
        radius - 2.2,
        Paint()
          ..color = film.withAlpha((visibility * 16).round())
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.65,
      );
    }
  }

  @override
  bool shouldRepaint(RadarPainter oldDelegate) =>
      oldDelegate.progress != progress;
}
