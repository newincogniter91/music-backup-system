import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'settings_service.dart';

enum BackupStatus { scanning, uploading, downloading, done, error }

/// Rappresenta lo stato di avanzamento del backup in un dato istante.
/// Viene emesso come stream da [BackupService.runBackup] così che la UI
/// possa aggiornarsi in tempo reale.
class BackupProgress {
  final int total;
  final int completed;
  final String currentFile;
  final BackupStatus status;
  final String? errorMessage;
  final int uploaded;
  final int downloaded;

  BackupProgress({
    required this.total,
    required this.completed,
    required this.currentFile,
    required this.status,
    this.errorMessage,
    this.uploaded = 0,
    this.downloaded = 0,
  });
}

/// Un file presente sul server, come descritto da GET /list.
/// [name] è il nome sul disco del server, [originalName] quello con cui
/// il file era arrivato dal telefono (può differire se c'è stato un
/// conflitto di nome), [sha] l'hash SHA-256 del contenuto.
class ServerFile {
  final int id;
  final String name;
  final String originalName;
  final int size;
  final String sha;

  ServerFile({
    required this.id,
    required this.name,
    required this.originalName,
    required this.size,
    required this.sha,
  });

  factory ServerFile.fromJson(Map<String, dynamic> json) => ServerFile(
        id: json['id'] as int,
        name: json['name'] as String,
        originalName: json['original_name'] as String,
        size: json['size'] as int,
        sha: json['sha256'] as String,
      );
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

  /// Cartella in cui finiscono i file scaricati dal server.
  static const String _downloadFolder = '/storage/emulated/0/Music';

  static String _baseName(String path) => path.split('/').last;

  /// Solo il nome del file, senza percorso: il nome arriva dal server e
  /// non ci si fida ciecamente.
  static String _safeName(String name) =>
      name.replaceAll('\\', '/').split('/').last;

  static Future<String> _sha256Of(File file) async {
    final digest = await sha256.bind(file.openRead()).first;
    return digest.toString();
  }

  /// Legge dal server l'elenco dei file che ha (GET /list).
  static Future<List<ServerFile>> _fetchServerFiles(String ip, String port) async {
    final response = await http
        .get(Uri.parse('http://$ip:$port/list'))
        .timeout(const Duration(seconds: 120));
    if (response.statusCode != 200) {
      throw Exception(
          'il server ha risposto ${response.statusCode} su /list (server aggiornato?)');
    }
    final data =
        jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
    return (data['files'] as List)
        .map((e) => ServerFile.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Dove salvare un file scaricato. Se in Music esiste già un file con
  /// lo stesso nome (ma contenuto diverso) usa il nome con suffisso hash,
  /// come fa il server: non sovrascrive mai. Restituisce null se anche
  /// quel nome esiste già.
  static Future<File?> _destinationFor(ServerFile sf) async {
    final name = _safeName(sf.name);
    final plain = File('$_downloadFolder/$name');
    if (!await plain.exists()) return plain;

    final dot = name.lastIndexOf('.');
    final stem = dot > 0 ? name.substring(0, dot) : name;
    final ext = dot > 0 ? name.substring(dot) : '';
    final suffixed =
        File('$_downloadFolder/${stem}__${sf.sha.substring(0, 8)}$ext');
    if (await suffixed.exists()) return null;
    return suffixed;
  }

  /// Scarica [uri] in [dest] passando da un file temporaneo .part, che
  /// diventa il file definitivo solo a download completo e della
  /// dimensione attesa: un download interrotto non lascia mai un mp3
  /// tronco in Music.
  static Future<void> _downloadTo(Uri uri, File dest, int expectedSize) async {
    final client = http.Client();
    final tmp = File('${dest.path}.part');
    try {
      final response = await client
          .send(http.Request('GET', uri))
          .timeout(const Duration(seconds: 30));
      if (response.statusCode != 200) {
        throw HttpException('il server ha risposto ${response.statusCode}');
      }
      await response.stream.pipe(tmp.openWrite());
      if (await tmp.length() != expectedSize) {
        throw const HttpException('download incompleto');
      }
      await tmp.rename(dest.path);
    } catch (_) {
      try {
        if (await tmp.exists()) await tmp.delete();
      } catch (_) {}
      rethrow;
    } finally {
      client.close();
    }
  }

  /// Sincronizzazione in due sensi, trasferendo solo ciò che manca:
  ///  1. chiede al server l'elenco dei suoi file (database del server);
  ///  2. carica (POST /upload, campo "file") i file del telefono che il
  ///     server non ha;
  ///  3. scarica (GET /download/<id>) in Music i file del server che il
  ///     telefono non ha.
  /// Il confronto usa nome+dimensione e, se non basta, l'hash SHA-256 del
  /// contenuto. Non elimina né modifica nulla.
  static Stream<BackupProgress> runBackup() async* {
    yield BackupProgress(
      total: 0,
      completed: 0,
      currentFile: '',
      status: BackupStatus.scanning,
    );

    final ip = await SettingsService.getServerIp();
    final port = await SettingsService.getServerPort();

    if (ip.isEmpty) {
      yield BackupProgress(
        total: 0,
        completed: 0,
        currentFile: '',
        status: BackupStatus.error,
        errorMessage: 'IP del server non configurato. Vai nelle impostazioni.',
      );
      return;
    }

    final files = await scanAudioFiles();

    // 1) Cosa ha già il server.
    var serverFiles = <ServerFile>[];
    try {
      serverFiles = await _fetchServerFiles(ip, port);
    } catch (e) {
      yield BackupProgress(
        total: 0,
        completed: 0,
        currentFile: '',
        status: BackupStatus.error,
        errorMessage: 'Impossibile leggere l\'elenco dal server $ip:$port: $e',
      );
      return;
    }

    // 2) Cosa manca al server: file locali che non ha.
    final serverKnown = <String>{
      for (final f in serverFiles) '${f.name}|${f.size}',
      for (final f in serverFiles) '${f.originalName}|${f.size}',
    };
    final serverHashes = <String>{for (final f in serverFiles) f.sha};
    final localHashes = <String, String>{}; // percorso -> hash (già calcolati)
    final queuedHashes = <String>{};
    final toUpload = <File>[];

    for (final file in files) {
      try {
        final name = _baseName(file.path);
        final size = await file.length();
        if (serverKnown.contains('$name|$size')) continue;

        final hash = await _sha256Of(file);
        localHashes[file.path] = hash;
        if (!serverHashes.contains(hash) && queuedHashes.add(hash)) {
          toUpload.add(file);
        }
      } catch (_) {
        continue; // file sparito o illeggibile: si salta
      }
    }

    // 3) Cosa manca al telefono: file del server che non ha in locale.
    final localBySize = <int, List<File>>{};
    for (final file in files) {
      try {
        localBySize.putIfAbsent(await file.length(), () => <File>[]).add(file);
      } catch (_) {
        continue;
      }
    }

    final toDownload = <ServerFile>[];
    final queuedDownloads = <String>{};
    for (final sf in serverFiles) {
      if (queuedDownloads.contains(sf.sha)) continue;
      var present = false;
      for (final local in localBySize[sf.size] ?? const <File>[]) {
        final localName = _baseName(local.path);
        if (localName == sf.name || localName == sf.originalName) {
          present = true;
          break;
        }
        try {
          var hash = localHashes[local.path];
          if (hash == null) {
            hash = await _sha256Of(local);
            localHashes[local.path] = hash;
          }
          if (hash == sf.sha) {
            present = true;
            break;
          }
        } catch (_) {}
      }
      if (!present) {
        toDownload.add(sf);
        queuedDownloads.add(sf.sha);
      }
    }

    final total = toUpload.length + toDownload.length;
    if (total == 0) {
      yield BackupProgress(
        total: 0,
        completed: 0,
        currentFile: '',
        status: BackupStatus.done,
      );
      return;
    }

    int completed = 0;
    int uploaded = 0;
    int downloaded = 0;

    // Upload: solo i file che il server non ha.
    final uploadUri = Uri.parse('http://$ip:$port/upload');
    for (final file in toUpload) {
      final fileName = _baseName(file.path);
      yield BackupProgress(
        total: total,
        completed: completed,
        currentFile: fileName,
        status: BackupStatus.uploading,
        uploaded: uploaded,
        downloaded: downloaded,
      );

      try {
        final request = http.MultipartRequest('POST', uploadUri);
        request.files.add(await http.MultipartFile.fromPath('file', file.path));
        final response = await request.send().timeout(const Duration(seconds: 30));

        if (response.statusCode != 200) {
          yield BackupProgress(
            total: total,
            completed: completed,
            currentFile: fileName,
            status: BackupStatus.error,
            errorMessage: 'Errore su "$fileName": il server ha risposto ${response.statusCode}',
            uploaded: uploaded,
            downloaded: downloaded,
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
          uploaded: uploaded,
          downloaded: downloaded,
        );
        return;
      }

      completed++;
      uploaded++;
    }

    // Download: solo i file del server che il telefono non ha.
    if (toDownload.isNotEmpty) {
      try {
        await Directory(_downloadFolder).create(recursive: true);
      } catch (e) {
        yield BackupProgress(
          total: total,
          completed: completed,
          currentFile: '',
          status: BackupStatus.error,
          errorMessage: 'Impossibile accedere alla cartella Music: $e',
          uploaded: uploaded,
          downloaded: downloaded,
        );
        return;
      }
    }

    for (final sf in toDownload) {
      final fileName = _safeName(sf.name);
      yield BackupProgress(
        total: total,
        completed: completed,
        currentFile: fileName,
        status: BackupStatus.downloading,
        uploaded: uploaded,
        downloaded: downloaded,
      );

      try {
        final dest = await _destinationFor(sf);
        if (dest != null) {
          await _downloadTo(
            Uri.parse('http://$ip:$port/download/${sf.id}'),
            dest,
            sf.size,
          );
        }
      } catch (e) {
        yield BackupProgress(
          total: total,
          completed: completed,
          currentFile: fileName,
          status: BackupStatus.error,
          errorMessage: 'Download fallito su "$fileName": $e',
          uploaded: uploaded,
          downloaded: downloaded,
        );
        return;
      }

      completed++;
      downloaded++;
    }

    yield BackupProgress(
      total: total,
      completed: completed,
      currentFile: '',
      status: BackupStatus.done,
      uploaded: uploaded,
      downloaded: downloaded,
    );
  }
}
