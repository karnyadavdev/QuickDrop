import 'package:flutter/material.dart';
import '../../models/device.dart';
import '../app_theme.dart';
import '../device_display.dart';
import 'glass_panel.dart';

class DeviceList extends StatelessWidget {
  final List<NetworkDevice> devices;
  final void Function(NetworkDevice) onSelect;

  const DeviceList({super.key, required this.devices, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    if (devices.isEmpty) return const SizedBox.shrink();

    return LayoutBuilder(
      builder: (context, constraints) {
        if (devices.length == 1) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 18),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 680),
                child: SizedBox(
                  height: 116,
                  child: DeviceCard(
                    device: devices.first,
                    onSelect: onSelect,
                    wide: true,
                  ),
                ),
              ),
            ),
          );
        }

        final listLayout = constraints.maxWidth < 620;
        if (listLayout) {
          return ListView.separated(
            padding: EdgeInsets.fromLTRB(
              constraints.maxWidth < 620 ? 16 : 28,
              8,
              constraints.maxWidth < 620 ? 16 : 28,
              18,
            ),
            itemCount: devices.length,
            separatorBuilder: (_, __) => const SizedBox(height: 12),
            itemBuilder: (context, index) => Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 780),
                child: DeviceCard(
                  device: devices[index],
                  onSelect: onSelect,
                  wide: true,
                ),
              ),
            ),
          );
        }

        final columns = devices.length == 2
            ? 2
            : (constraints.maxWidth / 310).floor().clamp(2, 4);
        return GridView.builder(
          padding: const EdgeInsets.fromLTRB(28, 8, 28, 18),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            crossAxisSpacing: 16,
            mainAxisSpacing: 16,
            childAspectRatio: 1.34,
          ),
          itemCount: devices.length,
          itemBuilder: (context, index) => DeviceCard(
            device: devices[index],
            onSelect: onSelect,
            wide: false,
          ),
        );
      },
    );
  }
}

class DeviceCard extends StatefulWidget {
  final NetworkDevice device;
  final void Function(NetworkDevice) onSelect;
  final bool wide;

  const DeviceCard({
    super.key,
    required this.device,
    required this.onSelect,
    required this.wide,
  });

  @override
  State<DeviceCard> createState() => _DeviceCardState();
}

class _DeviceCardState extends State<DeviceCard> {
  bool _hovered = false;
  bool _entered = false;

  bool get _busy => widget.device.status == 'busy';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _entered = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    return AnimatedOpacity(
      duration: reduceMotion
          ? Duration.zero
          : const Duration(milliseconds: 240),
      curve: Curves.easeOutCubic,
      opacity: reduceMotion || _entered ? 1 : 0,
      child: AnimatedSlide(
        duration: reduceMotion
            ? Duration.zero
            : const Duration(milliseconds: 240),
        curve: Curves.easeOutCubic,
        offset: reduceMotion || _entered ? Offset.zero : const Offset(0, 0.06),
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: AnimatedScale(
            duration: reduceMotion
                ? Duration.zero
                : const Duration(milliseconds: 160),
            scale: _hovered ? 1.01 : 1,
            child: GlassPanel(
              radius: 20,
              glowColor: _busy ? AppColors.warning : AppColors.green,
              blur: false,
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: () => widget.onSelect(widget.device),
                  borderRadius: BorderRadius.circular(20),
                  child: widget.wide ? _wideCard() : _gridCard(),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _wideCard() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        children: [
          _deviceIcon(54),
          const SizedBox(width: 14),
          Expanded(child: _name()),
          const SizedBox(width: 10),
          _status(),
        ],
      ),
    );
  }

  Widget _gridCard() {
    return Padding(
      padding: const EdgeInsets.all(18),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Expanded(child: Center(child: _deviceIcon(86))),
          const SizedBox(height: 8),
          _name(centered: true),
          const SizedBox(height: 10),
          _status(),
        ],
      ),
    );
  }

  Widget _deviceIcon(double size) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: AppColors.card.withAlpha(76),
        border: Border.all(color: AppColors.green.withAlpha(42)),
      ),
      child: Icon(
        deviceTypeIcon(widget.device.deviceType),
        color: _busy ? AppColors.muted : AppColors.green,
        size: size * 0.46,
      ),
    );
  }

  Widget _name({bool centered = false}) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: centered
          ? CrossAxisAlignment.center
          : CrossAxisAlignment.start,
      children: [
        Text(
          widget.device.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: centered ? TextAlign.center : TextAlign.start,
          style: TextStyle(
            color: AppColors.text,
            fontSize: 15,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 5),
        Text(
          deviceTypeName(widget.device.deviceType),
          style: TextStyle(color: AppColors.muted, fontSize: 11),
        ),
      ],
    );
  }

  Widget _status() {
    final color = _busy ? AppColors.warning : AppColors.green;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    return AnimatedSwitcher(
      duration: reduceMotion
          ? Duration.zero
          : const Duration(milliseconds: 180),
      child: Row(
        key: ValueKey(_busy),
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text(
            _busy ? 'Busy' : 'Ready',
            style: TextStyle(
              color: color,
              fontSize: 10,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}
