import 'package:flutter/material.dart';
import '../../core/platform/file_picker_channel.dart';
import '../../core/session/trusted_device.dart';
import '../../core/storage/device_repository.dart';

const projectGitHubUrl = 'https://github.com/1061700625/YiChuan';

class SettingsPage extends StatefulWidget {
  const SettingsPage({required this.deviceRepo, this.openUrl, super.key});

  final DeviceRepository deviceRepo;
  final Future<bool> Function(String url)? openUrl;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  List<TrustedDevice> _trustedDevices = [];

  @override
  void initState() {
    super.initState();
    widget.deviceRepo.addListener(_loadDevices);
    _loadDevices();
  }

  @override
  void dispose() {
    widget.deviceRepo.removeListener(_loadDevices);
    super.dispose();
  }

  Future<void> _loadDevices() async {
    final devices = await widget.deviceRepo.findAll();
    if (mounted) setState(() => _trustedDevices = devices);
  }

  Future<void> _openProjectPage() async {
    final opened = await (widget.openUrl ?? openExternalUrl)(projectGitHubUrl);
    if (!opened && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('无法打开项目链接')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(title: const Text('设置'), centerTitle: true),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('接收目录', style: textTheme.titleSmall),
          const SizedBox(height: 8),
          Card(
            child: ListTile(
              leading: Icon(Icons.folder_open, color: scheme.primary),
              title: const Text('Download/驿传'),
            ),
          ),
          const SizedBox(height: 24),
          Text('可信设备', style: textTheme.titleSmall),
          const SizedBox(height: 8),
          if (_trustedDevices.isEmpty)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Center(
                  child: Text(
                    '暂无可信设备',
                    style: textTheme.bodyMedium?.copyWith(
                      color: scheme.outline,
                    ),
                  ),
                ),
              ),
            )
          else
            ..._trustedDevices.map(
              (device) => Card(
                child: ListTile(
                  leading: Icon(
                    device.platform == DevicePlatform.macos
                        ? Icons.desktop_mac
                        : device.platform == DevicePlatform.windows
                        ? Icons.desktop_windows
                        : Icons.phone_android,
                    color: scheme.primary,
                  ),
                  title: Text(device.name),
                  subtitle: const Text('已信任'),
                  trailing: IconButton(
                    icon: Icon(Icons.delete_outline, color: scheme.error),
                    onPressed: () async {
                      await widget.deviceRepo.delete(device.id);
                    },
                  ),
                ),
              ),
            ),
          const SizedBox(height: 24),
          Text('关于', style: textTheme.titleSmall),
          const SizedBox(height: 8),
          Card(
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: _openProjectPage,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '驿传 v1.0.1',
                            style: textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Android ↔ Windows / macOS 局域网高速传输',
                            style: textTheme.bodySmall?.copyWith(
                              color: scheme.outline,
                              height: 1.5,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            '作者：小锋学长生活大爆炸',
                            style: textTheme.labelSmall?.copyWith(
                              color: scheme.outlineVariant,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            projectGitHubUrl,
                            style: textTheme.labelSmall?.copyWith(
                              color: scheme.primary,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    Icon(Icons.open_in_new, size: 20, color: scheme.primary),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
