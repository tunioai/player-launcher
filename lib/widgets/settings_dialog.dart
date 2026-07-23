import 'package:flutter/material.dart';

import '../services/autostart_service.dart';

typedef AutoStartGetter = Future<bool> Function();
typedef AutoStartSetter = Future<bool> Function(bool enabled);

class SettingsDialog extends StatefulWidget {
  const SettingsDialog({
    super.key,
    this.getAutoStartEnabled,
    this.setAutoStartEnabled,
  });

  final AutoStartGetter? getAutoStartEnabled;
  final AutoStartSetter? setAutoStartEnabled;

  @override
  State<SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<SettingsDialog> {
  bool _isLoading = true;
  bool _isUpdating = false;
  bool _autoStartEnabled = false;
  String? _error;

  AutoStartGetter get _getAutoStartEnabled =>
      widget.getAutoStartEnabled ?? AutoStartService.isLaunchAtStartupEnabled;

  AutoStartSetter get _setAutoStartEnabled =>
      widget.setAutoStartEnabled ?? AutoStartService.setLaunchAtStartupEnabled;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final enabled = await _getAutoStartEnabled();
      if (!mounted) return;
      setState(() {
        _autoStartEnabled = enabled;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = _friendlyError(e);
        _isLoading = false;
      });
    }
  }

  Future<void> _setEnabled(bool enabled) async {
    setState(() {
      _isUpdating = true;
      _error = null;
    });

    try {
      final actualValue = await _setAutoStartEnabled(enabled);
      if (!mounted) return;
      setState(() {
        _autoStartEnabled = actualValue;
        if (actualValue != enabled) {
          _error = 'The operating system did not apply this setting.';
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = _friendlyError(e);
      });
    } finally {
      if (mounted) {
        setState(() {
          _isUpdating = false;
        });
      }
    }
  }

  String _friendlyError(Object error) {
    final message = error.toString();
    final separator = message.indexOf(': ');
    return separator >= 0 ? message.substring(separator + 2) : message;
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.settings),
          SizedBox(width: 12),
          Text('Settings'),
        ],
      ),
      content: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: const Text('Start on system boot'),
              subtitle: const Text(
                'Launch in the system tray and start playback automatically.',
              ),
              value: _autoStartEnabled,
              onChanged: _isLoading || _isUpdating ? null : _setEnabled,
              secondary: _isLoading || _isUpdating
                  ? const SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.power_settings_new),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}
