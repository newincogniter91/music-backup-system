import 'dart:io';
import 'package:http/http.dart' as http;
import 'settings_service.dart';

enum BackupStatus { scanning, uploading, done, error }

/// Rappresenta lo stato di avanzamento del backup in un dato istante.
/// Viene emesso come stream da [BackupService.runBackup] così che la UI
/// possa aggiornarsi in tempo reale.
class BackupProgress {
  final int total;
  final int completed;
  final String currentFile;
  final BackupStatus status;
  final String? errorMessage;

  BackupProgress({
    required this.total,
    required this.completed,
    required this.currentFile,
    required this.status,
    this.errorMessage,
  });
}

class BackupService {
  static const List<String> _extensions = ['.mp3', '.m4a'];

  /// Cartelle monitorate. Percorsi standard della memoria condivisa
  /// Android; richiedono il permesso "Gestisci tutti i file" per
  /// essere letti direttamente (vedi HomeScreen._ensurePermissions).
  static const List<String> _folders = [
    '/storage/emulated/0/Download',
    '/storage/emulated/0/Music',
  ];

  /// Cerca ricorsivamente tutti i file .mp3/.m4a nelle cartelle
  /// monitorate. Non elimina né modifica nulla: solo lettura.
  static Future<List<File>> scanAudioFiles() async {
    final List<File> found = [];
    for (final folderPath in _folders) {
      final dir = Directory(folderPath);
      if (!await dir.exists()) continue;
      try {
        await for (final entity in dir.list(recursive: true, followLinks: false)) {
          if (entity is File) {
            final lower = entity.path.toLowerCase();
            if (_extensions.any((ext) => lower.endsWith(ext))) {
              found.add(entity);
            }
          }
        }
      } catch (_) {
        // Ignora sottocartelle non leggibili e prosegue con le altre.
        continue;
      }
    }
    return found;
  }

  /// Esegue lo scan e carica ogni file trovato con una richiesta
  /// POST multipart separata verso http://IP:PORTA/upload.
  /// Il campo del file nella richiesta si chiama "file" — il server
  /// dovrà aspettarsi lo stesso nome di campo.
  static Stream<BackupProgress> runBackup() async* {
    yield BackupProgress(
      total: 0,
      completed: 0,
      currentFile: '',
      status: BackupStatus.scanning,
    );

    final files = await scanAudioFiles();
    final total = files.length;

    if (total == 0) {
      yield BackupProgress(
        total: 0,
        completed: 0,
        currentFile: '',
        status: BackupStatus.done,
      );
      return;
    }

    final ip = await SettingsService.getServerIp();
    final port = await SettingsService.getServerPort();

    if (ip.isEmpty) {
      yield BackupProgress(
        total: total,
        completed: 0,
        currentFile: '',
        status: BackupStatus.error,
        errorMessage: 'IP del server non configurato. Vai nelle impostazioni.',
      );
      return;
    }

    final uri = Uri.parse('http://$ip:$port/upload');
    int completed = 0;

    for (final file in files) {
      final fileName = file.path.split('/').last;
      yield BackupProgress(
        total: total,
        completed: completed,
        currentFile: fileName,
        status: BackupStatus.uploading,
      );

      try {
        final request = http.MultipartRequest('POST', uri);
        request.files.add(await http.MultipartFile.fromPath('file', file.path));
        final response = await request.send().timeout(const Duration(seconds: 30));

        if (response.statusCode != 200) {
          yield BackupProgress(
            total: total,
            completed: completed,
            currentFile: fileName,
            status: BackupStatus.error,
            errorMessage: 'Errore su "$fileName": il server ha risposto ${response.statusCode}',
          );
          return;
        }
      } catch (e) {
        yield BackupProgress(
          total: total,
          completed: completed,
          currentFile: fileName,
          status: BackupStatus.error,
          errorMessage: 'Connessione fallita su "$fileName": impossibile raggiungere $ip:$port',
        );
        return;
      }

      completed++;
    }

    yield BackupProgress(
      total: total,
      completed: completed,
      currentFile: '',
      status: BackupStatus.done,
    );
  }
}
