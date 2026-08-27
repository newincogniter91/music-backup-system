import 'package:flutter/material.dart';
import '../services/settings_service.dart';

class SettingsScreen extends StatefulWidget {
  final ValueChanged<bool> onThemeChanged;
  const SettingsScreen({super.key, required this.onThemeChanged});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _ipController = TextEditingController();
  final _portController = TextEditingController();
  bool _isDarkMode = true;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final ip = await SettingsService.getServerIp();
    final port = await SettingsService.getServerPort();
    final dark = await SettingsService.getDarkMode();
    if (!mounted) return;
    setState(() {
      _ipController.text = ip;
      _portController.text = port;
      _isDarkMode = dark;
      _loaded = true;
    });
  }

  Future<void> _saveIp(String value) => SettingsService.setServerIp(value.trim());

  Future<void> _savePort(String value) => SettingsService.setServerPort(value.trim());

  Future<void> _saveTheme(bool isDark) async {
    setState(() => _isDarkMode = isDark);
    await SettingsService.setDarkMode(isDark);
    widget.onThemeChanged(isDark);
  }

  @override
  void dispose() {
    _ipController.dispose();
    _portController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Impostazioni')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text('Server', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          const SizedBox(height: 8),
          TextField(
            controller: _ipController,
            decoration: const InputDecoration(
              labelText: 'IP del server (es. IP Tailscale)',
              hintText: '100.x.x.x',
              border: OutlineInputBorder(),
            ),
            keyboardType: TextInputType.text,
            onChanged: _saveIp,
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _portController,
            decoration: InputDecoration(
              labelText: 'Porta',
              hintText: SettingsService.defaultPort,
              border: const OutlineInputBorder(),
            ),
            keyboardType: TextInputType.number,
            onChanged: _savePort,
          ),
          const SizedBox(height: 32),
          const Text('Aspetto', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          SwitchListTile(
            title: const Text('Tema scuro'),
            value: _isDarkMode,
            onChanged: _saveTheme,
            contentPadding: EdgeInsets.zero,
          ),
        ],
      ),
    );
  }
}
