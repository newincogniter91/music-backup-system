import 'package:flutter/material.dart';
import 'screens/home_screen.dart';
import 'services/settings_service.dart';
import 'theme/app_theme.dart';

void main() {
  runApp(const MusicBackupApp());
}

class MusicBackupApp extends StatefulWidget {
  const MusicBackupApp({super.key});

  @override
  State<MusicBackupApp> createState() => _MusicBackupAppState();
}

class _MusicBackupAppState extends State<MusicBackupApp> {
  bool _isDarkMode = true;

  @override
  void initState() {
    super.initState();
    _loadTheme();
  }

  Future<void> _loadTheme() async {
    final isDark = await SettingsService.getDarkMode();
    if (!mounted) return;
    setState(() {
      _isDarkMode = isDark;
    });
  }

  void _onThemeChanged(bool isDark) {
    setState(() {
      _isDarkMode = isDark;
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Music Backup',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightTheme,
      darkTheme: AppTheme.darkTheme,
      themeMode: _isDarkMode ? ThemeMode.dark : ThemeMode.light,
      home: HomeScreen(onThemeChanged: _onThemeChanged),
    );
  }
}
