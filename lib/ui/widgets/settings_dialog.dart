import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_theme.dart';
import 'adaptive_panel.dart';

class SettingsDialog extends StatefulWidget {
  final String initialName;
  final bool initialEncryptOutgoing;
  final void Function(String, bool) onSave;

  const SettingsDialog({
    super.key,
    required this.initialName,
    required this.initialEncryptOutgoing,
    required this.onSave,
  });

  @override
  State<SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<SettingsDialog> {
  late final TextEditingController _nameInput;
  late bool _encryptOutgoing;

  @override
  void initState() {
    super.initState();
    _nameInput = TextEditingController(text: widget.initialName);
    _encryptOutgoing = widget.initialEncryptOutgoing;
  }

  @override
  void dispose() {
    _nameInput.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;
    return AdaptivePanel(
      maxWidth: 410,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Settings',
            style: TextStyle(
              color: AppColors.text,
              fontSize: 20,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'This name is shown to nearby QuickDrop users.',
            style: TextStyle(color: AppColors.muted, fontSize: 12),
          ),
          const SizedBox(height: 20),
          TextField(
            controller: _nameInput,
            autofocus: true,
            scrollPadding: EdgeInsets.only(bottom: keyboard + 120),
            maxLength: 15,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _save(),
            decoration: const InputDecoration(
              labelText: 'Device name',
              counterText: '',
            ),
          ),
          const SizedBox(height: 10),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            value: _encryptOutgoing,
            onChanged: (value) => setState(() => _encryptOutgoing = value),
            secondary: Icon(
              _encryptOutgoing
                  ? Icons.lock_outline_rounded
                  : Icons.lock_open_rounded,
              color: _encryptOutgoing ? AppColors.green : AppColors.muted,
            ),
            title: Text(
              'Encrypt files I send',
              style: TextStyle(
                color: AppColors.text,
                fontSize: 13,
                fontWeight: FontWeight.w700,
              ),
            ),
            subtitle: Text(
              'Protects file contents while sending.',
              style: TextStyle(color: AppColors.muted, fontSize: 10),
            ),
          ),
          const SizedBox(height: 22),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Cancel'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: _save,
                  child: const Text('Save'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Divider(color: AppColors.softLine),
          Align(
            alignment: Alignment.center,
            child: TextButton.icon(
              onPressed: _openGitHub,
              icon: const FaIcon(FontAwesomeIcons.github, size: 17),
              label: const Text('karnyadav'),
            ),
          ),
        ],
      ),
    );
  }

  void _save() {
    final name = _nameInput.text.trim();
    if (name.isEmpty) return;
    widget.onSave(name, _encryptOutgoing);
    Navigator.pop(context, true);
  }

  Future<void> _openGitHub() async {
    final opened = await launchUrl(
      Uri.parse('https://github.com/karnyadavdev'),
      mode: LaunchMode.externalApplication,
    );
    if (!opened && mounted) {
      final messages = ScaffoldMessenger.of(context);
      messages.showSnackBar(
        const SnackBar(content: Text('Could not open GitHub.')),
      );
    }
  }
}
