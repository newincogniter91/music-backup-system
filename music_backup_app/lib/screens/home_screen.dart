import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import '../services/backup_service.dart';
import 'settings_screen.dart';

class HomeScreen extends StatefulWidget {
  final ValueChanged<bool> onThemeChanged;
  const HomeScreen({super.key, required this.onThemeChanged});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  BackupProgress? _progress;
  bool _isRunning = false;

  /// Su Android 11+ serve il permesso "Gestisci tutti i file" per
  /// leggere direttamente le cartelle Download/Music. Questo permesso
  /// speciale non si concede con un semplice popup: se non è già
  /// attivo, apre la pagina di sistema dedicata.
  Future<bool> _ensurePermissions() async {
    final status = await Permission.manageExternalStorage.status;
    if (status.isGranted) return true;
    final result = await Permission.manageExternalStorage.request();
    return result.isGranted;
  }

  Future<void> _startBackup() async {
    if (_isRunning) return;

    final granted = await _ensurePermissions();
    if (!granted) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Permesso di accesso ai file negato.'),
        ),
      );
      return;
    }

    setState(() {
      _isRunning = true;
      _progress = null;
    });

    await for (final progress in BackupService.runBackup()) {
      if (!mounted) return;
      setState(() {
        _progress = progress;
      });
    }

    if (!mounted) return;
    setState(() {
      _isRunning = false;
    });
  }

  double get _percent {
    if (_progress == null || _progress!.total == 0) return 0;
    return _progress!.completed / _progress!.total;
  }

  String get _statusText {
    final p = _progress;
    if (p == null) return 'Pronto per il backup';
    switch (p.status) {
      case BackupStatus.scanning:
        return 'Scansione file in corso...';
      case BackupStatus.uploading:
        return 'Caricamento: ${p.currentFile}\n${p.completed}/${p.total}';
      case BackupStatus.done:
        return p.total == 0
            ? 'Nessun file audio trovato'
            : 'Backup completato: ${p.completed}/${p.total} file';
      case BackupStatus.error:
        return p.errorMessage ?? 'Errore sconosciuto';
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Music Backup'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () async {
              await Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => SettingsScreen(onThemeChanged: widget.onThemeChanged),
                ),
              );
            },
          ),
        ],
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            GestureDetector(
              onTap: _isRunning ? null : _startBackup,
              child: Container(
                width: 180,
                height: 180,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _isRunning
                      ? theme.colorScheme.surfaceVariant
                      : theme.colorScheme.primary,
                  boxShadow: [
                    BoxShadow(
                      color: theme.colorScheme.primary.withOpacity(0.4),
                      blurRadius: 20,
                      spreadRadius: 2,
                    ),
                  ],
                ),
                child: Center(
                  child: _isRunning
                      ? SizedBox(
                          width: 48,
                          height: 48,
                          child: CircularProgressIndicator(
                            value: _percent > 0 ? _percent : null,
                            color: theme.colorScheme.onPrimary,
                            strokeWidth: 4,
                          ),
                        )
                      : Icon(
                          Icons.backup,
                          size: 64,
                          color: theme.colorScheme.onPrimary,
                        ),
                ),
              ),
            ),
            const SizedBox(height: 32),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: _percent,
                  minHeight: 8,
                ),
              ),
            ),
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Text(
                _statusText,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
