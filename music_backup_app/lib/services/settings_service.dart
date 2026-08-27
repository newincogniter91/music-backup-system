import 'package:shared_preferences/shared_preferences.dart';

/// Gestisce la lettura/scrittura delle impostazioni configurabili
/// dall'utente: IP del server, porta e tema. Tutto è salvato con
/// SharedPreferences, quindi persiste tra un avvio e l'altro
/// dell'app e può essere cambiato in qualsiasi momento dalle
/// Impostazioni, senza bisogno di ricompilare l'app.
class SettingsService {
  static const _keyIp = 'server_ip';
  static const _keyPort = 'server_port';
  static const _keyDarkMode = 'dark_mode';

  /// Porta di default: scelta volutamente in un range poco comune,
  /// per non entrare in conflitto con altri servizi già in uso sulla
  /// rete (es. Jellyfin, Minecraft, Samba). Cambiabile in Impostazioni.
  static const String defaultPort = '47811';

  static Future<String> getServerIp() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyIp) ?? '';
  }

  static Future<void> setServerIp(String ip) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyIp, ip);
  }

  static Future<String> getServerPort() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyPort) ?? defaultPort;
  }

  static Future<void> setServerPort(String port) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyPort, port);
  }

  static Future<bool> getDarkMode() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyDarkMode) ?? true;
  }

  static Future<void> setDarkMode(bool isDark) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyDarkMode, isDark);
  }
}
