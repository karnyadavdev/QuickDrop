import 'dart:io';

import 'package:flutter/material.dart';

import '../models/device.dart';
import '../models/local_identity.dart';
import '../network/network_controller.dart';
import 'app_theme.dart';
import 'widgets/active_transfer.dart';
import 'widgets/animated_background.dart';
import 'widgets/connection_core.dart';
import 'widgets/device_list.dart';
import 'widgets/glass_panel.dart';
import 'widgets/settings_dialog.dart';
import 'widgets/send_dialog.dart';

class Dashboard extends StatefulWidget {
  final NetworkController? network;
  final String? deviceId;
  final String? deviceName;
  final String? deviceType;
  final bool encryptOutgoing;

  const Dashboard({
    super.key,
    this.network,
    this.deviceId,
    this.deviceName,
    this.deviceType,
    this.encryptOutgoing = false,
  });

  @override
  State<Dashboard> createState() => _DashboardState();
}

class _DashboardState extends State<Dashboard>
    with SingleTickerProviderStateMixin {
  late final NetworkController _network;
  late final AnimationController _coreMotion;
  String? _startError;
  Route<dynamic>? _openPanelRoute;
  String _lastTransferType = 'none';

  @override
  void initState() {
    super.initState();
    final identity = LocalIdentity.random();
    _network =
        widget.network ??
        NetworkController(
          deviceId: widget.deviceId ?? identity.id,
          deviceName: widget.deviceName ?? identity.name,
          deviceType:
              widget.deviceType ??
              (Platform.isAndroid
                  ? 'mobile'
                  : Platform.isLinux
                  ? 'linux'
                  : 'desktop'),
          encryptOutgoing: widget.encryptOutgoing,
        );
    _coreMotion = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 16),
    );
    _lastTransferType = _network.transferType;
    _network.addListener(_onNetworkChanged);
    _startNetwork();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _coreMotion.stop();
      _coreMotion.value = 0.12;
    } else if (!_coreMotion.isAnimating) {
      _coreMotion.repeat();
    }
  }

  Future<void> _startNetwork() async {
    try {
      await _network.start();
    } catch (error) {
      if (!mounted) return;
      setState(() => _startError = 'Network startup failed: $error');
    }
  }

  @override
  void dispose() {
    _network.removeListener(_onNetworkChanged);
    _coreMotion.dispose();
    if (widget.network == null) _network.dispose();
    super.dispose();
  }

  void _onNetworkChanged() {
    final current = _network.transferType;
    if (_lastTransferType == 'none' && current != 'none') {
      final route = _openPanelRoute;
      if (route != null && route.isActive) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (route.isActive) route.navigator?.removeRoute(route);
        });
      }
    }
    _lastTransferType = current;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: AnimatedBackground(
        child: ListenableBuilder(
          listenable: _network,
          builder: (context, _) {
            return Stack(
              children: [
                IgnorePointer(
                  ignoring: _network.transferType != 'none',
                  child: ExcludeSemantics(
                    excluding: _network.transferType != 'none',
                    child: SafeArea(
                      child: Column(
                        children: [
                          _TopBar(
                            deviceName: _network.deviceName,
                            connected: _network.hasLocalNetwork,
                            onSettings: _showSettings,
                          ),
                          Expanded(child: _home()),
                        ],
                      ),
                    ),
                  ),
                ),
                if (_startError != null) _errorBanner(),
                Positioned.fill(
                  child: IgnorePointer(
                    ignoring: _network.transferType == 'none',
                    child: AnimatedSwitcher(
                      duration: MediaQuery.disableAnimationsOf(context)
                          ? Duration.zero
                          : const Duration(milliseconds: 220),
                      child: _network.transferType == 'none'
                          ? const SizedBox.shrink(key: ValueKey('no-transfer'))
                          : ActiveTransfer(
                              key: const ValueKey('active-transfer'),
                              network: _network,
                            ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _home() {
    final devices = _network.devices;
    return LayoutBuilder(
      builder: (context, constraints) {
        final hasDevices = devices.isNotEmpty;
        final compact = constraints.maxWidth < 600;
        final short = constraints.maxHeight < 480;
        double coreHeight;
        if (short && hasDevices) {
          coreHeight = (constraints.maxHeight - 142).clamp(0.0, 96.0);
        } else if (compact) {
          coreHeight = (constraints.maxHeight * 0.43).clamp(250.0, 315.0);
        } else {
          coreHeight = (constraints.maxHeight * 0.45).clamp(270.0, 340.0);
        }
        final emptyCoreHeight = (constraints.maxHeight - 80).clamp(
          140.0,
          720.0,
        );
        final reduceMotion = MediaQuery.disableAnimationsOf(context);
        return Column(
          children: [
            AnimatedContainer(
              duration: reduceMotion
                  ? Duration.zero
                  : const Duration(milliseconds: 520),
              curve: Curves.easeInOutCubic,
              height: hasDevices ? coreHeight : emptyCoreHeight,
              child: _ScanSection(animation: _coreMotion, compact: hasDevices),
            ),
            Expanded(
              child: AnimatedSwitcher(
                duration: reduceMotion
                    ? Duration.zero
                    : const Duration(milliseconds: 360),
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeInCubic,
                child: hasDevices
                    ? DeviceList(
                        key: const ValueKey('devices'),
                        devices: devices,
                        onSelect: _showSendDialog,
                      )
                    : const SizedBox.shrink(key: ValueKey('empty-list')),
              ),
            ),
            _WifiHint(compact: short),
          ],
        );
      },
    );
  }

  Widget _errorBanner() {
    return Positioned(
      left: 16,
      right: 16,
      bottom: 16,
      child: SafeArea(
        child: GlassPanel(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
          glowColor: AppColors.red,
          child: Row(
            children: [
              const Icon(Icons.error_outline_rounded, color: AppColors.red),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  _startError!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: AppColors.text, fontSize: 12),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showSendDialog(NetworkDevice device) async {
    if (!mounted) return;
    _showPanel(SendDialog(device: device, network: _network), 'Send options');
  }

  void _showSettings() {
    _showPanel(
      SettingsDialog(
        initialName: _network.deviceName,
        initialEncryptOutgoing: _network.encryptOutgoing,
        onSave: (name, encryptOutgoing) => _network.updateProfile(
          name: name,
          deviceType: _network.deviceType,
          encryptOutgoing: encryptOutgoing,
        ),
      ),
      'Settings',
    );
  }

  Future<T?> _showPanel<T>(Widget panel, String label) async {
    final navigator = Navigator.of(context, rootNavigator: true);
    final route = RawDialogRoute<T>(
      barrierColor: Colors.black.withAlpha(165),
      barrierDismissible: true,
      barrierLabel: label,
      transitionDuration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : const Duration(milliseconds: 220),
      pageBuilder: (_, __, ___) => panel,
      transitionBuilder: (_, animation, __, child) {
        final curve = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
        );
        return FadeTransition(
          opacity: curve,
          child: SlideTransition(
            position: Tween(
              begin: const Offset(0, 0.035),
              end: Offset.zero,
            ).animate(curve),
            child: child,
          ),
        );
      },
    );
    _openPanelRoute = route;
    try {
      return await navigator.push<T>(route);
    } finally {
      if (identical(_openPanelRoute, route)) _openPanelRoute = null;
    }
  }
}

class _TopBar extends StatelessWidget {
  final String deviceName;
  final bool connected;
  final VoidCallback onSettings;

  const _TopBar({
    required this.deviceName,
    required this.connected,
    required this.onSettings,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: 92,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const SizedBox(height: 17),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 280),
                child: Text(
                  deviceName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: AppColors.text,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(height: 5),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _StatusDot(connected: connected),
                  const SizedBox(width: 7),
                  Text(
                    connected ? 'Connected' : 'Not connected',
                    style: TextStyle(color: AppColors.muted, fontSize: 10.5),
                  ),
                ],
              ),
            ],
          ),
          Positioned(
            right: 18,
            child: GlassIconButton(
              icon: Icons.settings_outlined,
              label: 'Open settings',
              onPressed: onSettings,
            ),
          ),
        ],
      ),
    );
  }
}

class _ScanSection extends StatelessWidget {
  final Animation<double> animation;
  final bool compact;

  const _ScanSection({required this.animation, required this.compact});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Searching for nearby devices',
      child: Center(
        child: ConnectionCore(animation: animation, compact: compact),
      ),
    );
  }
}

class _WifiHint extends StatelessWidget {
  final bool compact;

  const _WifiHint({this.compact = false});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: compact
          ? const EdgeInsets.fromLTRB(16, 3, 16, 7)
          : const EdgeInsets.fromLTRB(20, 8, 20, 18),
      child: Text(
        'Keep devices connected to Wi-Fi',
        textAlign: TextAlign.center,
        style: TextStyle(
          color: AppColors.muted.withAlpha(185),
          fontSize: compact ? 9.5 : 11,
        ),
      ),
    );
  }
}

class _StatusDot extends StatelessWidget {
  final bool connected;

  const _StatusDot({required this.connected});

  @override
  Widget build(BuildContext context) {
    final color = connected ? AppColors.green : AppColors.red;
    return Container(
      key: const ValueKey('connection-dot'),
      width: 7,
      height: 7,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        boxShadow: [BoxShadow(color: color.withAlpha(120), blurRadius: 6)],
      ),
    );
  }
}
