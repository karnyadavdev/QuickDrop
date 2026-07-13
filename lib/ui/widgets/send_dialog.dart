import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;
import '../../models/device.dart';
import '../../network/network_controller.dart';
import '../app_theme.dart';
import '../device_display.dart';
import 'adaptive_panel.dart';
import 'glass_panel.dart';

class SendDialog extends StatefulWidget {
  final NetworkDevice device;
  final NetworkController network;

  const SendDialog({super.key, required this.device, required this.network});

  @override
  State<SendDialog> createState() => _SendDialogState();
}

class _SendDialogState extends State<SendDialog> {
  final List<File> _files = [];
  final List<AndroidFile> _androidFiles = [];
  String? _folder;
  String? _folderName;

  bool get _hasSelection =>
      _files.isNotEmpty || _androidFiles.isNotEmpty || _folder != null;

  NetworkDevice? get _liveDevice {
    for (final device in widget.network.devices) {
      if (device.id == widget.device.id) return device;
    }
    return null;
  }

  NetworkDevice get _currentDevice =>
      _liveDevice ?? widget.device.copyWith(status: 'offline');

  bool get _deviceIsReady =>
      _liveDevice != null &&
      _liveDevice!.status != 'busy' &&
      widget.network.transferType == 'none';

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.network,
      builder: (context, _) => AdaptivePanel(
        maxWidth: 500,
        padding: const EdgeInsets.all(22),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                IconButton.outlined(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.arrow_back_rounded, size: 20),
                ),
                const Spacer(),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              'Send files',
              style: TextStyle(
                color: AppColors.text,
                fontSize: 27,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.7,
              ),
            ),
            const SizedBox(height: 5),
            Text(
              'Choose what to send to ${_currentDevice.name}',
              style: TextStyle(color: AppColors.muted, fontSize: 12),
            ),
            const SizedBox(height: 22),
            _DeviceRow(device: _currentDevice),
            const SizedBox(height: 10),
            _EncryptionMode(enabled: widget.network.encryptOutgoing),
            const SizedBox(height: 22),
            Row(
              children: [
                Text(
                  'Select files',
                  style: TextStyle(color: AppColors.muted, fontSize: 12),
                ),
                const Spacer(),
                if (_hasSelection)
                  Text(
                    _selectionSummary(),
                    style: const TextStyle(
                      color: AppColors.green,
                      fontSize: 12,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            AnimatedSwitcher(
              duration: MediaQuery.disableAnimationsOf(context)
                  ? Duration.zero
                  : const Duration(milliseconds: 220),
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeInCubic,
              transitionBuilder: (child, animation) => FadeTransition(
                opacity: animation,
                child: SizeTransition(
                  sizeFactor: animation,
                  alignment: Alignment.topCenter,
                  child: child,
                ),
              ),
              child: _hasSelection
                  ? Column(
                      key: const ValueKey('selected-files'),
                      children: [
                        _SelectedItems(
                          files: _files,
                          androidFiles: _androidFiles,
                          folder: _folder,
                          folderName: _folderName,
                        ),
                        const SizedBox(height: 10),
                        TextButton.icon(
                          onPressed: _clearSelection,
                          icon: const Icon(Icons.refresh_rounded, size: 17),
                          label: const Text('Choose something else'),
                        ),
                      ],
                    )
                  : Column(
                      key: const ValueKey('choose-files'),
                      children: [
                        _PickOption(
                          icon: Icons.file_copy_outlined,
                          title: 'Choose files',
                          detail: 'Select one or more files',
                          onTap: _pickFiles,
                        ),
                        const SizedBox(height: 10),
                        _PickOption(
                          icon: Icons.folder_outlined,
                          title: 'Choose folder',
                          detail: 'Keep the folder structure',
                          onTap: _pickFolder,
                        ),
                      ],
                    ),
            ),
            const SizedBox(height: 18),
            _SendButton(
              enabled: _hasSelection && _deviceIsReady,
              label: _deviceIsReady
                  ? 'Send to ${_currentDevice.name}'
                  : (_liveDevice == null
                        ? 'Device is offline'
                        : 'Waiting for device...'),
              onPressed: _startTransfer,
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickFiles() async {
    if (Platform.isAndroid) {
      List<AndroidFile>? files;
      try {
        files = await widget.network.pickAndroidFiles();
      } catch (error) {
        if (mounted) _showSelectionError(error);
        return;
      }
      if (!mounted || files == null) return;
      final selectedFiles = files;
      setState(() {
        _folder = null;
        _folderName = null;
        _files.clear();
        _androidFiles
          ..clear()
          ..addAll(selectedFiles);
      });
      return;
    }
    final result = await FilePicker.platform.pickFiles(allowMultiple: true);
    if (!mounted || result == null) return;
    setState(() {
      _folder = null;
      _folderName = null;
      _androidFiles.clear();
      _files
        ..clear()
        ..addAll(result.paths.whereType<String>().map(File.new));
    });
  }

  Future<void> _pickFolder() async {
    String? folder;
    String? folderName;
    if (Platform.isAndroid) {
      AndroidFolder? choice;
      try {
        choice = await widget.network.pickAndroidFolder();
      } catch (error) {
        if (mounted) _showSelectionError(error);
        return;
      }
      folder = choice?.uri;
      folderName = choice?.name;
    } else {
      folder = await FilePicker.platform.getDirectoryPath();
      if (folder != null) folderName = path.basename(folder);
    }
    if (!mounted || folder == null) return;
    setState(() {
      _files.clear();
      _androidFiles.clear();
      _folder = folder;
      _folderName = folderName ?? 'Folder';
    });
  }

  void _showSelectionError(Object error) {
    var message = error.toString();
    if (error is PlatformException) {
      message = error.message ?? 'Could not read the selected item.';
    }
    if (message.length > 180) message = '${message.substring(0, 180)}...';
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  void _clearSelection() {
    setState(() {
      _files.clear();
      _androidFiles.clear();
      _folder = null;
      _folderName = null;
    });
  }

  Future<void> _startTransfer() async {
    if (!_deviceIsReady) return;
    final device = _currentDevice;
    final folder = _folder;
    final folderName = _folderName;
    final files = List<File>.from(_files);
    final androidFiles = List<AndroidFile>.from(_androidFiles);
    final closeTime = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 240);
    Navigator.pop(context);
    await Future<void>.delayed(closeTime);
    if (folder != null) {
      await widget.network.sendFolder(device, folder, folderName: folderName);
    } else if (androidFiles.length == 1) {
      await widget.network.sendAndroidFile(device, androidFiles.first);
    } else if (androidFiles.length > 1) {
      await widget.network.sendAndroidFiles(device, androidFiles);
    } else if (files.length == 1) {
      await widget.network.sendFile(device, files.first);
    } else if (files.length > 1) {
      widget.network.sendMultipleFiles(
        device,
        files.map((file) => file.path).toList(),
      );
    }
  }

  String _selectionSummary() {
    if (_folder != null) return '1 folder';
    if (_androidFiles.isNotEmpty) {
      final bytes = _androidFiles.fold<int>(0, (sum, file) => sum + file.size);
      return '${_androidFiles.length} selected - ${_formatBytes(bytes)}';
    }
    final bytes = _files.fold<int>(0, (sum, file) {
      try {
        return sum + file.lengthSync();
      } catch (_) {
        return sum;
      }
    });
    return '${_files.length} selected - ${_formatBytes(bytes)}';
  }
}

class _DeviceRow extends StatelessWidget {
  final NetworkDevice device;

  const _DeviceRow({required this.device});

  @override
  Widget build(BuildContext context) {
    var status = 'Ready';
    var statusColor = AppColors.green;
    if (device.status == 'busy') {
      status = 'Busy';
      statusColor = AppColors.warning;
    } else if (device.status == 'offline') {
      status = 'Offline';
      statusColor = AppColors.red;
    }
    return GlassPanel(
      radius: 18,
      padding: const EdgeInsets.all(14),
      glowColor: AppColors.green,
      child: Row(
        children: [
          _RoundIcon(icon: deviceTypeIcon(device.deviceType)),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  device.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: AppColors.text,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  deviceTypeName(device.deviceType),
                  style: TextStyle(color: AppColors.muted, fontSize: 11),
                ),
                const SizedBox(height: 3),
                Text(
                  status,
                  style: TextStyle(color: statusColor, fontSize: 11),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _EncryptionMode extends StatelessWidget {
  final bool enabled;

  const _EncryptionMode({required this.enabled});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(
          enabled ? Icons.lock_outline_rounded : Icons.lock_open_rounded,
          size: 16,
          color: enabled ? AppColors.green : AppColors.muted,
        ),
        const SizedBox(width: 7),
        Text(
          enabled ? 'Encrypted transfer' : 'Encryption off',
          style: TextStyle(
            color: enabled ? AppColors.green : AppColors.muted,
            fontSize: 11,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }
}

class _SelectedItems extends StatelessWidget {
  final List<File> files;
  final List<AndroidFile> androidFiles;
  final String? folder;
  final String? folderName;

  const _SelectedItems({
    required this.files,
    required this.androidFiles,
    required this.folder,
    required this.folderName,
  });

  @override
  Widget build(BuildContext context) {
    final items = folder == null ? files.take(4).toList() : <File>[];
    final documents = folder == null
        ? androidFiles.take(4).toList()
        : <AndroidFile>[];
    return Container(
      decoration: BoxDecoration(
        color: AppColors.card.withAlpha(58),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.green.withAlpha(30)),
      ),
      child: Column(
        children: [
          if (folder != null)
            _SelectedRow(
              name: folderName ?? path.basename(folder!),
              detail: 'Folder',
              icon: Icons.folder_rounded,
            ),
          for (var index = 0; index < items.length; index++) ...[
            if (index > 0) Divider(height: 1, color: AppColors.softLine),
            _SelectedRow(
              name: path.basename(items[index].path),
              detail: _fileSize(items[index]),
              icon: _fileIcon(items[index].path),
            ),
          ],
          for (var index = 0; index < documents.length; index++) ...[
            if (index > 0 || items.isNotEmpty)
              Divider(height: 1, color: AppColors.softLine),
            _SelectedRow(
              name: documents[index].name,
              detail: _formatBytes(documents[index].size),
              icon: _fileIcon(documents[index].name),
            ),
          ],
          if (files.length > 4 || androidFiles.length > 4)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 8, 14, 12),
              child: Text(
                '+ ${(files.isNotEmpty ? files.length : androidFiles.length) - 4} more files',
                style: const TextStyle(color: AppColors.green, fontSize: 11),
              ),
            ),
        ],
      ),
    );
  }

  static String _fileSize(File file) {
    try {
      return _formatBytes(file.lengthSync());
    } catch (_) {
      return 'File';
    }
  }

  static IconData _fileIcon(String filePath) {
    final extension = path.extension(filePath).toLowerCase();
    if (['.jpg', '.jpeg', '.png', '.webp'].contains(extension)) {
      return Icons.image_outlined;
    }
    if (['.mp4', '.mkv', '.mov'].contains(extension)) {
      return Icons.play_circle_outline_rounded;
    }
    if (['.mp3', '.wav', '.flac'].contains(extension)) {
      return Icons.music_note_rounded;
    }
    return Icons.description_outlined;
  }
}

class _SelectedRow extends StatelessWidget {
  final String name;
  final String detail;
  final IconData icon;

  const _SelectedRow({
    required this.name,
    required this.detail,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      child: Row(
        children: [
          const Icon(
            Icons.check_circle_outline_rounded,
            color: AppColors.green,
            size: 22,
          ),
          const SizedBox(width: 12),
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: AppColors.green.withAlpha(18),
              borderRadius: BorderRadius.circular(11),
            ),
            child: Icon(icon, color: AppColors.green, size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
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
                  detail,
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

class _PickOption extends StatelessWidget {
  final IconData icon;
  final String title;
  final String detail;
  final VoidCallback onTap;

  const _PickOption({
    required this.icon,
    required this.title,
    required this.detail,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.card.withAlpha(58),
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              _RoundIcon(icon: icon),
              const SizedBox(width: 13),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        color: AppColors.text,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      detail,
                      style: TextStyle(color: AppColors.muted, fontSize: 11),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded, color: AppColors.muted),
            ],
          ),
        ),
      ),
    );
  }
}

class _SendButton extends StatelessWidget {
  final bool enabled;
  final String label;
  final VoidCallback onPressed;

  const _SendButton({
    required this.enabled,
    required this.label,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(99),
        boxShadow: enabled
            ? [BoxShadow(color: AppColors.green.withAlpha(70), blurRadius: 28)]
            : null,
      ),
      child: FilledButton.icon(
        onPressed: enabled ? onPressed : null,
        style: FilledButton.styleFrom(
          minimumSize: const Size.fromHeight(54),
          shape: const StadiumBorder(),
        ),
        icon: const Icon(Icons.arrow_upward_rounded),
        label: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
    );
  }
}

class _RoundIcon extends StatelessWidget {
  final IconData icon;

  const _RoundIcon({required this.icon});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 48,
      height: 48,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: AppColors.card.withAlpha(72),
        border: Border.all(color: AppColors.green.withAlpha(40)),
      ),
      child: Icon(icon, color: AppColors.green, size: 23),
    );
  }
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
