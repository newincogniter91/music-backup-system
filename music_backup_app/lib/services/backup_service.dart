import 'dart:convert';
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

  /// Chiede al server i nomi dei file che ha già (GET /list, dal suo
  /// database).
  static Future<Set<String>> _fetchServerNames(String ip, String port) async {
    final response = await http
        .get(Uri.parse('http://$ip:$port/list'))
        .timeout(const Duration(seconds: 30));
    if (response.statusCode != 200) {
      throw Exception(
          'il server ha risposto ${response.statusCode} su /list (server aggiornato?)');
    }
    // Si accettano tutti i formati sensati: {"files": [...]} oppure [...],
    // con elementi che sono nomi (stringhe) oppure oggetti con "name" /
    // "original_name", e anche un corpo JSON codificato due volte. Se non
    // si capisce, l'errore mostra l'inizio di ciò che ha risposto il server.
    final body = utf8.decode(response.bodyBytes);
    try {
      dynamic data = jsonDecode(body);
      if (data is String) data = jsonDecode(data);
      final dynamic items = data is Map ? data['files'] : data;
      if (items is! List) {
        throw const FormatException('manca la lista dei file');
      }
      final names = <String>{};
      for (final item in items) {
        if (item is String) {
          names.add(item);
        } else if (item is Map) {
          final original = item['original_name'];
          final stored = item['name'];
          if (original is String) names.add(original);
          if (stored is String) names.add(stored);
        }
      }
      return names;
    } catch (e) {
      final preview = body.length > 80 ? '${body.substring(0, 80)}...' : body;
      throw Exception('risposta di /list non valida ($e): $preview');
    }
  }

  /// Esegue lo scan e carica, con una richiesta POST multipart separata
  /// verso http://IP:PORTA/upload, solo i file il cui nome il server non
  /// ha già (elenco da GET /list). Il campo del file nella richiesta si
  /// chiama "file" — il server dovrà aspettarsi lo stesso nome di campo.
  static Stream<BackupProgress> runBackup() async* {
    yield BackupProgress(
      total: 0,
      completed: 0,
      currentFile: '',
      status: BackupStatus.scanning,
    );

    final allFiles = await scanAudioFiles();

    if (allFiles.isEmpty) {
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
        total: allFiles.length,
        completed: 0,
        currentFile: '',
        status: BackupStatus.error,
        errorMessage: 'IP del server non configurato. Vai nelle impostazioni.',
      );
      return;
    }

    // Quali file ha già il server: si confrontano i nomi.
    var serverNames = <String>{};
    try {
      serverNames = await _fetchServerNames(ip, port);
    } catch (e) {
      yield BackupProgress(
        total: allFiles.length,
        completed: 0,
        currentFile: '',
        status: BackupStatus.error,
        errorMessage: 'Impossibile leggere l\'elenco dal server $ip:$port: $e',
      );
      return;
    }

    // Da inviare: solo quelli con un nome che il server non ha (e un nome
    // presente in più cartelle si invia una volta sola).
    final seenNames = <String>{};
    final files = <File>[];
    for (final file in allFiles) {
      final name = file.path.split('/').last;
      if (serverNames.contains(name)) continue;
      if (seenNames.add(name)) files.add(file);
    }
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
