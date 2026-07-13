import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../network/network_controller.dart';
import '../app_theme.dart';
import '../device_display.dart';
import 'adaptive_panel.dart';

class ActiveTransfer extends StatelessWidget {
  final NetworkController network;

  const ActiveTransfer({super.key, required this.network});

  @override
  Widget build(BuildContext context) {
    return BlockSemantics(
      child: FocusScope(
        autofocus: true,
        child: ColoredBox(
          color: const Color(0xA8020807),
          child: AnimatedSwitcher(
            duration: MediaQuery.disableAnimationsOf(context)
                ? Duration.zero
                : const Duration(milliseconds: 360),
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            transitionBuilder: (child, animation) {
              final scale = Tween(begin: 0.97, end: 1.0).animate(animation);
              return FadeTransition(
                opacity: animation,
                child: ScaleTransition(scale: scale, child: child),
              );
            },
            child: switch (network.transferType) {
              'incoming_request' => _IncomingRequest(
                key: const ValueKey('incoming'),
                network: network,
              ),
              'send_requesting' || 'send_confirming' => _WaitingForPeer(
                key: const ValueKey('waiting'),
                network: network,
              ),
              _ => _TransferProgress(
                key: const ValueKey('progress'),
                network: network,
              ),
            },
          ),
        ),
      ),
    );
  }
}

class _IncomingRequest extends StatelessWidget {
  final NetworkController network;

  const _IncomingRequest({super.key, required this.network});

  @override
  Widget build(BuildContext context) {
    final short = MediaQuery.sizeOf(context).height < 700;
    return AdaptivePanel(
      maxWidth: 500,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _GlowIcon(icon: Icons.laptop_windows_rounded, size: short ? 78 : 96),
          SizedBox(height: short ? 8 : 14),
          Text(
            'Incoming transfer',
            style: TextStyle(
              color: AppColors.text,
              fontSize: 24,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.5,
            ),
          ),
          SizedBox(height: short ? 4 : 7),
          Text(
            'A nearby device wants to share with you',
            textAlign: TextAlign.center,
            style: TextStyle(color: AppColors.muted, fontSize: 12),
          ),
          SizedBox(height: short ? 12 : 18),
          _PeerRow(
            name: network.transferSenderName,
            deviceType: network.transferSenderDeviceType,
          ),
          SizedBox(height: short ? 8 : 12),
          _FileSummary(network: network),
          if (network.transferCode.isNotEmpty) ...[
            SizedBox(height: short ? 10 : 16),
            _TransferCode(code: network.transferCode),
          ],
          SizedBox(height: short ? 12 : 20),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: network.declineTransfer,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.red,
                    side: BorderSide(color: AppColors.red.withAlpha(100)),
                    shape: const StadiumBorder(),
                  ),
                  icon: const Icon(Icons.close_rounded),
                  label: const Text('Decline'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton.icon(
                  onPressed: network.acceptTransfer,
                  style: FilledButton.styleFrom(shape: const StadiumBorder()),
                  icon: const Icon(Icons.check_rounded),
                  label: const Text('Accept'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _WaitingForPeer extends StatelessWidget {
  final NetworkController network;

  const _WaitingForPeer({super.key, required this.network});

  @override
  Widget build(BuildContext context) {
    final status = network.transferSpeed;
    final packaging = status == 'Packaging...';
    final confirming = network.transferType == 'send_confirming';
    final failed = _isFailure(status);
    final hasCode = network.transferCode.isNotEmpty;
    var stage = 'connecting';
    if (hasCode) stage = 'code';
    if (confirming) stage = 'confirming';
    if (packaging) stage = 'packaging';
    if (failed) stage = 'failed';

    return AdaptivePanel(
      maxWidth: 500,
      child: SizedBox(
        width: double.infinity,
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: packaging ? 340 : 0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: packaging
                ? MainAxisAlignment.center
                : MainAxisAlignment.start,
            children: [
              _GlowIcon(
                icon: failed
                    ? Icons.error_outline_rounded
                    : (packaging ? Icons.folder_outlined : Icons.sync_rounded),
                error: failed,
              ),
              const SizedBox(height: 18),
              AnimatedSwitcher(
                duration: MediaQuery.disableAnimationsOf(context)
                    ? Duration.zero
                    : const Duration(milliseconds: 320),
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeInCubic,
                transitionBuilder: (child, animation) => FadeTransition(
                  opacity: animation,
                  child: SlideTransition(
                    position: Tween(
                      begin: const Offset(0, 0.06),
                      end: Offset.zero,
                    ).animate(animation),
                    child: child,
                  ),
                ),
                child: _WaitingStage(
                  key: ValueKey(stage),
                  status: status,
                  peerName: network.transferPeerName,
                  code: network.transferCode,
                  encrypted: network.isEncrypted,
                  packaging: packaging,
                  confirming: confirming,
                  failed: failed,
                ),
              ),
              const SizedBox(height: 20),
              if (confirming && !failed) ...[
                FilledButton.icon(
                  onPressed: network.confirmTransferCode,
                  icon: const Icon(Icons.verified_rounded),
                  label: const Text('Codes match - Send'),
                ),
                const SizedBox(height: 7),
              ],
              TextButton(
                onPressed: network.cancelActiveTransfer,
                child: const Text(
                  'Cancel',
                  style: TextStyle(color: AppColors.red),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _WaitingStage extends StatelessWidget {
  final String status;
  final String peerName;
  final String code;
  final bool encrypted;
  final bool packaging;
  final bool confirming;
  final bool failed;

  const _WaitingStage({
    super.key,
    required this.status,
    required this.peerName,
    required this.code,
    required this.encrypted,
    required this.packaging,
    required this.confirming,
    required this.failed,
  });

  @override
  Widget build(BuildContext context) {
    final hasCode = code.isNotEmpty;
    var title = 'Connecting to $peerName';
    var message = 'Sending a transfer request...';
    if (hasCode) {
      title = 'Compare this code';
      message = 'The receiver checks the same code, then taps Accept.';
    }
    if (confirming) {
      title = 'Do the codes match?';
      message = 'Only continue if this code matches the receiver screen.';
    }
    if (packaging) {
      title = 'Preparing folder';
      message = 'Gathering files before the request is sent.';
    }
    if (failed) {
      title = _failureTitle(status);
      message = _failureMessage(status);
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: failed ? AppColors.red : AppColors.text,
            fontSize: 23,
            fontWeight: FontWeight.w700,
          ),
        ),
        if (encrypted) ...[
          const SizedBox(height: 9),
          const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.lock_outline_rounded,
                size: 14,
                color: AppColors.green,
              ),
              SizedBox(width: 5),
              Text(
                'Encrypted',
                style: TextStyle(
                  color: AppColors.green,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ],
        const SizedBox(height: 7),
        Text(
          message,
          textAlign: TextAlign.center,
          style: TextStyle(color: AppColors.muted, fontSize: 12),
        ),
        if (!failed && hasCode) ...[
          const SizedBox(height: 22),
          _TransferCode(code: code),
        ],
      ],
    );
  }
}

class _TransferProgress extends StatelessWidget {
  final NetworkController network;

  const _TransferProgress({super.key, required this.network});

  @override
  Widget build(BuildContext context) {
    final speed = network.transferSpeed;
    final done = speed == 'Finished';
    final failed = _isFailure(speed);
    final sending =
        network.transferType == 'send' ||
        network.transferType == 'send_finished';

    if (done || failed) {
      return _TransferResult(
        network: network,
        failed: failed,
        sending: sending,
      );
    }

    final progress = network.transferProgress.clamp(0.0, 1.0);
    final canCancel =
        speed != 'Extracting...' &&
        speed != 'Saving to Downloads...' &&
        speed != 'Finishing...';
    return AdaptivePanel(
      maxWidth: 500,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _GlowIcon(
            icon: sending
                ? Icons.arrow_upward_rounded
                : Icons.arrow_downward_rounded,
          ),
          const SizedBox(height: 14),
          Text(
            'Connected to',
            style: TextStyle(
              color: AppColors.muted.withAlpha(210),
              fontSize: 11,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            network.transferPeerName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: AppColors.text,
              fontSize: 22,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 20),
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: AppColors.card.withAlpha(58),
              borderRadius: BorderRadius.circular(22),
              border: Border.all(color: AppColors.green.withAlpha(32)),
            ),
            child: Column(
              children: [
                _FileSummary(network: network, flat: true),
                Divider(height: 30, color: AppColors.softLine),
                Text(
                  '${(progress * 100).round()}%',
                  style: const TextStyle(
                    color: AppColors.green,
                    fontSize: 38,
                    fontWeight: FontWeight.w400,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  speed,
                  style: TextStyle(color: AppColors.muted, fontSize: 13),
                ),
                const SizedBox(height: 18),
                ClipRRect(
                  borderRadius: BorderRadius.circular(99),
                  child: TweenAnimationBuilder<double>(
                    tween: Tween(end: progress),
                    duration: MediaQuery.disableAnimationsOf(context)
                        ? Duration.zero
                        : const Duration(milliseconds: 260),
                    builder: (context, value, _) => LinearProgressIndicator(
                      value: value,
                      minHeight: 6,
                      backgroundColor: AppColors.progressTrack,
                      valueColor: const AlwaysStoppedAnimation(AppColors.green),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  _phaseText(speed, sending, network.transferPeerName),
                  textAlign: TextAlign.center,
                  style: TextStyle(color: AppColors.muted, fontSize: 11),
                ),
              ],
            ),
          ),
          if (canCancel) ...[
            const SizedBox(height: 16),
            TextButton(
              onPressed: network.cancelActiveTransfer,
              child: const Text(
                'Cancel',
                style: TextStyle(color: AppColors.red),
              ),
            ),
          ],
        ],
      ),
    );
  }

  String _phaseText(String speed, bool sending, String peer) {
    if (speed == 'Extracting...') return 'The folder is being extracted.';
    if (speed == 'Saving to Downloads...') {
      return 'Saving into Downloads/QuickDrop.';
    }
    if (speed == 'Finishing...') return 'Waiting for the receiver to finish.';
    if (speed == 'Connecting...') return 'Starting the local connection.';
    return sending
        ? 'Sending directly to $peer.'
        : 'Receiving directly from $peer.';
  }
}

class _TransferResult extends StatelessWidget {
  final NetworkController network;
  final bool failed;
  final bool sending;

  const _TransferResult({
    required this.network,
    required this.failed,
    required this.sending,
  });

  @override
  Widget build(BuildContext context) {
    return AdaptivePanel(
      maxWidth: 500,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _GlowIcon(
            icon: failed ? Icons.close_rounded : Icons.check_rounded,
            error: failed,
            sparkles: !failed,
            size: 116,
          ),
          const SizedBox(height: 20),
          Text(
            failed ? 'Transfer failed' : 'Transfer complete',
            style: TextStyle(
              color: failed ? AppColors.red : AppColors.text,
              fontSize: 24,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 7),
          Text(
            failed
                ? 'The connection ended before the transfer finished.'
                : (sending ? 'Sent successfully' : 'Saved successfully'),
            textAlign: TextAlign.center,
            style: TextStyle(color: AppColors.muted, fontSize: 12),
          ),
          const SizedBox(height: 22),
          _FileSummary(network: network, showCheck: !failed),
          if (!failed) ...[
            const SizedBox(height: 12),
            _PeerRow(
              name: network.transferPeerName,
              deviceType: network.transferPeerDeviceType,
              title: sending ? 'Sent to' : 'Received from',
            ),
          ],
          const SizedBox(height: 20),
          FilledButton(
            onPressed: network.canDismiss ? network.dismissTransfer : null,
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(50),
              shape: const StadiumBorder(),
            ),
            child: Text(network.canDismiss ? 'Done' : 'Finishing'),
          ),
        ],
      ),
    );
  }
}

class _GlowIcon extends StatelessWidget {
  final IconData icon;
  final bool error;
  final bool sparkles;
  final double size;

  const _GlowIcon({
    required this.icon,
    this.error = false,
    this.sparkles = false,
    this.size = 96,
  });

  @override
  Widget build(BuildContext context) {
    final color = error ? AppColors.red : AppColors.green;
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _OrbPainter(color: color, sparkles: sparkles),
        child: Center(
          child: Icon(icon, color: AppColors.text, size: size * 0.31),
        ),
      ),
    );
  }
}

class _OrbPainter extends CustomPainter {
  final Color color;
  final bool sparkles;

  const _OrbPainter({required this.color, required this.sparkles});

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final haloRadius = size.shortestSide * 0.48;
    final orbRadius = size.shortestSide * 0.31;

    canvas.drawCircle(
      center,
      haloRadius,
      Paint()
        ..shader = RadialGradient(
          colors: [color.withAlpha(18), color.withAlpha(6), Colors.transparent],
          stops: const [0, 0.58, 1],
        ).createShader(Rect.fromCircle(center: center, radius: haloRadius)),
    );
    canvas.drawCircle(
      center,
      orbRadius,
      Paint()..color = const Color(0xFF071510).withAlpha(112),
    );
    canvas.drawCircle(
      center,
      orbRadius,
      Paint()
        ..color = color.withAlpha(120)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );

    if (!sparkles) return;
    const angles = [0.15, 0.82, 1.9, 2.55, 3.28, 4.15, 5.1, 5.72];
    const distances = [0.42, 0.47, 0.43, 0.5, 0.44, 0.49, 0.45, 0.51];
    for (var i = 0; i < angles.length; i++) {
      final point = Offset(
        center.dx + math.cos(angles[i]) * size.width * distances[i],
        center.dy + math.sin(angles[i]) * size.height * distances[i],
      );
      canvas.drawCircle(
        point,
        i.isEven ? 1.5 : 1.0,
        Paint()..color = color.withAlpha(i.isEven ? 170 : 105),
      );
    }
  }

  @override
  bool shouldRepaint(_OrbPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.sparkles != sparkles;
}

class _PeerRow extends StatelessWidget {
  final String name;
  final String deviceType;
  final String? title;

  const _PeerRow({required this.name, required this.deviceType, this.title});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.card.withAlpha(58),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.green.withAlpha(30)),
      ),
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.card.withAlpha(72),
              border: Border.all(color: AppColors.green.withAlpha(40)),
            ),
            child: Icon(
              deviceTypeIcon(deviceType),
              color: AppColors.green,
              size: 23,
            ),
          ),
          const SizedBox(width: 13),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (title != null) ...[
                  Text(
                    title!,
                    style: TextStyle(color: AppColors.muted, fontSize: 10),
                  ),
                  const SizedBox(height: 2),
                ],
                Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: AppColors.text,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  deviceTypeName(deviceType),
                  style: TextStyle(color: AppColors.muted, fontSize: 11),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _FileSummary extends StatelessWidget {
  final NetworkController network;
  final bool flat;
  final bool showCheck;

  const _FileSummary({
    required this.network,
    this.flat = false,
    this.showCheck = false,
  });

  @override
  Widget build(BuildContext context) {
    final content = Row(
      children: [
        Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            color: AppColors.green.withAlpha(26),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(
            network.transferIsFolder
                ? Icons.folder_rounded
                : Icons.description_rounded,
            color: AppColors.green,
          ),
        ),
        const SizedBox(width: 13),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                network.transferFileName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: AppColors.text,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                _formatBytes(network.transferFileSize),
                style: TextStyle(color: AppColors.muted, fontSize: 11),
              ),
              if (network.isEncrypted) ...[
                const SizedBox(height: 3),
                const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.lock_outline_rounded,
                      size: 12,
                      color: AppColors.green,
                    ),
                    SizedBox(width: 4),
                    Text(
                      'Encrypted',
                      style: TextStyle(
                        color: AppColors.green,
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
        if (showCheck)
          const Icon(Icons.check_rounded, color: AppColors.green, size: 20),
      ],
    );

    if (flat) return content;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white.withAlpha(5),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.green.withAlpha(24)),
      ),
      child: content,
    );
  }
}

class _TransferCode extends StatelessWidget {
  final String code;

  const _TransferCode({required this.code});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(
          'MATCH THIS CODE',
          style: TextStyle(
            color: AppColors.muted,
            fontSize: 10,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.3,
          ),
        ),
        const SizedBox(height: 9),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 7,
          children: code.split('').map((letter) {
            return Container(
              width: 42,
              height: 48,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: AppColors.green.withAlpha(9),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.green.withAlpha(48)),
              ),
              child: Text(
                letter,
                style: TextStyle(
                  color: AppColors.text,
                  fontSize: 21,
                  fontWeight: FontWeight.w800,
                ),
              ),
            );
          }).toList(),
        ),
        const SizedBox(height: 7),
        Text(
          'Accept only if the code is identical on both devices.',
          textAlign: TextAlign.center,
          style: TextStyle(color: AppColors.muted, fontSize: 10),
        ),
      ],
    );
  }
}

bool _isFailure(String status) {
  return status == 'Busy' ||
      status == 'Declined' ||
      status == 'Ignored' ||
      status == 'Failed' ||
      status == 'Timeout waiting for approval' ||
      status == 'Confirmation timed out' ||
      status == 'Unsupported encryption' ||
      status == 'The selected folder has no files to send.' ||
      status.contains('did not report the size') ||
      status.startsWith('Fail:') ||
      status.startsWith('Err:') ||
      status.startsWith('Error');
}

String _failureTitle(String status) {
  if (status == 'Busy') return 'Device is busy';
  if (status == 'Declined') return 'Request declined';
  if (status == 'Ignored') return 'Request ignored';
  if (status == 'Timeout waiting for approval') return 'Approval timed out';
  if (status == 'Confirmation timed out') return 'Confirmation timed out';
  if (status == 'Unsupported encryption') return 'Encryption not supported';
  if (status == 'The selected folder has no files to send.') {
    return 'Folder has no files';
  }
  if (status.contains('did not report the size')) return 'Unknown file size';
  if (status.startsWith('Error packing')) return 'Could not prepare folder';
  return 'Connection failed';
}

String _failureMessage(String status) {
  if (status == 'Busy') {
    return 'The other device is already transferring something.';
  }
  if (status == 'Declined') return 'The receiver declined this transfer.';
  if (status == 'Ignored') {
    return 'The receiver did not answer repeated requests.';
  }
  if (status == 'Timeout waiting for approval') {
    return 'The receiver did not answer before the request expired.';
  }
  if (status == 'Confirmation timed out') {
    return 'No file was sent because the code was not confirmed.';
  }
  if (status == 'Unsupported encryption') {
    return 'The other device does not support this encryption setting.';
  }
  if (status == 'The selected folder has no files to send.') return status;
  if (status.contains('did not report the size')) return status;
  return 'QuickDrop could not reach the other device.';
}

String _formatBytes(int bytes) {
  if (bytes <= 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return '${value.toStringAsFixed(1)} ${units[unit]}';
}
