import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'settings_service.dart';

enum BackupStatus { scanning, uploading, downloading, done, error }

/// Rappresenta lo stato di avanzamento del backup in un dato istante.
/// Viene emesso come stream da [BackupService.runUpload] e [BackupService.runDownload] così che la UI
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

/// Errore con un messaggio già pronto da mostrare all'utente.
class _BackupException implements Exception {
  final String message;
  _BackupException(this.message);
}

/// Stato condiviso da upload e download: impostazioni, file locali ed
/// elenco dei file del server.
class _Context {
  final String ip;
  final String port;
  final List<File> files;
  final List<ServerFile> serverFiles;

  _Context(this.ip, this.port, this.files, this.serverFiles);
}

class BackupService {
  static const List<String> _extensions = ['.mp3', '.m4a'];

  /// Sottocartelle monitorate per l'upload, in ogni memoria (interna e
  /// SD). Richiedono il permesso "Gestisci tutti i file" per essere lette
  /// direttamente (vedi HomeScreen._ensurePermissions).
  static const List<String> _folders = ['Download', 'Music'];

  /// Radici delle memorie: quella interna (/storage/emulated/0) e le
  /// eventuali SD/volumi rimovibili (/storage/XXXX-XXXX). Le SD si
  /// chiedono ad Android (vedi MainActivity) e, in mancanza, si cercano
  /// direttamente sotto /storage.
  static Future<List<String>> _storageRoots() async {
    final roots = <String>{'/storage/emulated/0'};
    try {
      final fromAndroid = await _media.invokeListMethod<String>('getStorageRoots');
      if (fromAndroid != null) roots.addAll(fromAndroid);
    } catch (_) {}
    try {
      final volume = RegExp(r'^[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}$');
      await for (final entity in Directory('/storage').list(followLinks: false)) {
        if (volume.hasMatch(_baseName(entity.path))) roots.add(entity.path);
      }
    } catch (_) {}
    return roots.toList();
  }

  static bool _isAudio(String path) {
    final lower = path.toLowerCase();
    return _extensions.any((ext) => lower.endsWith(ext));
  }

  /// Cerca i file .mp3/.m4a in QUALSIASI cartella della memoria interna e
  /// delle SD (esclusi Android/ e le cartelle nascoste, che iniziano con
  /// un punto). Serve al Download per sapere cosa il telefono ha già,
  /// ovunque sia. Solo lettura.
  static Future<List<File>> _scanEverywhere() async {
    final found = <File>[];
    for (final root in await _storageRoots()) {
      final pending = <Directory>[Directory(root)];
      while (pending.isNotEmpty) {
        final dir = pending.removeLast();
        try {
          await for (final entity in dir.list(followLinks: false)) {
            final name = _baseName(entity.path);
            if (entity is Directory) {
              if (name.startsWith('.')) continue;
              if (name == 'Android' && dir.path == root) continue;
              pending.add(entity);
            } else if (entity is File && _isAudio(name)) {
              found.add(entity);
            }
          }
        } catch (_) {
          continue; // cartella non leggibile: si salta e si prosegue
        }
      }
    }
    return found;
  }

  /// Cerca ricorsivamente tutti i file .mp3/.m4a nelle cartelle
  /// monitorate (Download e Music, della memoria interna e delle SD).
  /// Non elimina né modifica nulla: solo lettura.
  static Future<List<File>> scanAudioFiles() async {
    final List<File> found = [];
    final folderPaths = [
      for (final root in await _storageRoots())
        for (final folder in _folders) '$root/$folder',
    ];
    for (final folderPath in folderPaths) {
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

  static const MethodChannel _media =
      MethodChannel('com.newincogniter91.musicbackup/media');

  /// Avvisa Android che in Music c'è un file nuovo, così i lettori musicali
  /// lo vedono subito (senza, resta fuori dall'indice finché il sistema
  /// non riscansiona). Il file non viene modificato in nessun modo.
  static Future<void> _scanMedia(String path) async {
    try {
      await _media.invokeMethod('scanFile', {'path': path});
    } catch (_) {}
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
  /// diventa il file definitivo solo se dimensione e SHA-256 coincidono
  /// con quelli dell'originale sul server. I byte vengono scritti così
  /// come arrivano (nessuna ricodifica): un download interrotto o
  /// alterato non lascia mai un file rotto in Music.
  static Future<void> _downloadTo(
      Uri uri, File dest, int expectedSize, String expectedSha) async {
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
      if (await _sha256Of(tmp) != expectedSha) {
        throw const HttpException(
            'la copia non coincide con l\'originale (hash diverso)');
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

  /// Parte comune a upload e download: impostazioni, scansione locale ed
  /// elenco dei file del server (GET /list). Con [everywhere] la
  /// scansione locale copre tutta la memoria (interna e SD), altrimenti
  /// solo Download e Music. Lancia [_BackupException] con il messaggio da
  /// mostrare se qualcosa non va.
  static Future<_Context> _prepare({required bool everywhere}) async {
    final ip = await SettingsService.getServerIp();
    final port = await SettingsService.getServerPort();

    if (ip.isEmpty) {
      throw _BackupException(
          'IP del server non configurato. Vai nelle impostazioni.');
    }

    final files = everywhere ? await _scanEverywhere() : await scanAudioFiles();
    try {
      final serverFiles = await _fetchServerFiles(ip, port);
      return _Context(ip, port, files, serverFiles);
    } catch (e) {
      throw _BackupException(
          'Impossibile leggere l\'elenco dal server $ip:$port: $e');
    }
  }

  /// File locali che il server non ha. Il confronto usa nome+dimensione
  /// e, se non basta, l'hash SHA-256 del contenuto.
  static Future<List<File>> _planUpload(_Context ctx) async {
    final serverKnown = <String>{
      for (final f in ctx.serverFiles) '${f.name}|${f.size}',
      for (final f in ctx.serverFiles) '${f.originalName}|${f.size}',
    };
    final serverHashes = <String>{for (final f in ctx.serverFiles) f.sha};
    final queuedHashes = <String>{};
    final toUpload = <File>[];

    for (final file in ctx.files) {
      try {
        final name = _baseName(file.path);
        final size = await file.length();
        if (serverKnown.contains('$name|$size')) continue;

        final hash = await _sha256Of(file);
        if (!serverHashes.contains(hash) && queuedHashes.add(hash)) {
          toUpload.add(file);
        }
      } catch (_) {
        continue; // file sparito o illeggibile: si salta
      }
    }
    return toUpload;
  }

  /// File del server che il telefono non ha in nessuna cartella, né
  /// nella memoria interna né nelle SD (stesso criterio di sopra).
  static Future<List<ServerFile>> _planDownload(_Context ctx) async {
    final localBySize = <int, List<File>>{};
    for (final file in ctx.files) {
      try {
        localBySize.putIfAbsent(await file.length(), () => <File>[]).add(file);
      } catch (_) {
        continue;
      }
    }

    final localHashes = <String, String>{}; // percorso -> hash già calcolati
    final toDownload = <ServerFile>[];
    final queuedDownloads = <String>{};

    for (final sf in ctx.serverFiles) {
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
    return toDownload;
  }

  /// Upload: invia al server (POST /upload, campo "file") solo i file del
  /// telefono che il server non ha. Non elimina né modifica nulla.
  static Stream<BackupProgress> runUpload() async* {
    yield BackupProgress(
      total: 0,
      completed: 0,
      currentFile: '',
      status: BackupStatus.scanning,
    );

    _Context? ctx;
    String? prepareError;
    try {
      ctx = await _prepare(everywhere: false);
    } on _BackupException catch (e) {
      prepareError = e.message;
    }
    if (ctx == null) {
      yield BackupProgress(
        total: 0,
        completed: 0,
        currentFile: '',
        status: BackupStatus.error,
        errorMessage: prepareError,
      );
      return;
    }

    final toUpload = await _planUpload(ctx);
    final total = toUpload.length;
    if (total == 0) {
      yield BackupProgress(
        total: 0,
        completed: 0,
        currentFile: '',
        status: BackupStatus.done,
      );
      return;
    }

    final uploadUri = Uri.parse('http://${ctx.ip}:${ctx.port}/upload');
    int completed = 0;

    for (final file in toUpload) {
      final fileName = _baseName(file.path);
      yield BackupProgress(
        total: total,
        completed: completed,
        currentFile: fileName,
        status: BackupStatus.uploading,
        uploaded: completed,
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
            uploaded: completed,
          );
          return;
        }
      } catch (e) {
        yield BackupProgress(
          total: total,
          completed: completed,
          currentFile: fileName,
          status: BackupStatus.error,
          errorMessage: 'Connessione fallita su "$fileName": impossibile raggiungere ${ctx.ip}:${ctx.port}',
          uploaded: completed,
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
      uploaded: completed,
    );
  }

  /// Download: scarica in Music (GET /download/<id>) solo i file del
  /// server che il telefono non ha, come copia identica byte per byte
  /// (verificata con SHA-256), poi avvisa Android perché i lettori la
  /// vedano. Non elimina né sovrascrive nulla.
  static Stream<BackupProgress> runDownload() async* {
    yield BackupProgress(
      total: 0,
      completed: 0,
      currentFile: '',
      status: BackupStatus.scanning,
    );

    _Context? ctx;
    String? prepareError;
    try {
      ctx = await _prepare(everywhere: true);
    } on _BackupException catch (e) {
      prepareError = e.message;
    }
    if (ctx == null) {
      yield BackupProgress(
        total: 0,
        completed: 0,
        currentFile: '',
        status: BackupStatus.error,
        errorMessage: prepareError,
      );
      return;
    }

    final toDownload = await _planDownload(ctx);
    final total = toDownload.length;
    if (total == 0) {
      yield BackupProgress(
        total: 0,
        completed: 0,
        currentFile: '',
        status: BackupStatus.done,
      );
      return;
    }

    try {
      await Directory(_downloadFolder).create(recursive: true);
    } catch (e) {
      yield BackupProgress(
        total: total,
        completed: 0,
        currentFile: '',
        status: BackupStatus.error,
        errorMessage: 'Impossibile accedere alla cartella Music: $e',
      );
      return;
    }

    int completed = 0;

    for (final sf in toDownload) {
      final fileName = _safeName(sf.name);
      yield BackupProgress(
        total: total,
        completed: completed,
        currentFile: fileName,
        status: BackupStatus.downloading,
        downloaded: completed,
      );

      try {
        final dest = await _destinationFor(sf);
        if (dest != null) {
          await _downloadTo(
            Uri.parse('http://${ctx.ip}:${ctx.port}/download/${sf.id}'),
            dest,
            sf.size,
            sf.sha,
          );
          await _scanMedia(dest.path);
        }
      } catch (e) {
        yield BackupProgress(
          total: total,
          completed: completed,
          currentFile: fileName,
          status: BackupStatus.error,
          errorMessage: 'Download fallito su "$fileName": $e',
          downloaded: completed,
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
      downloaded: completed,
    );
  }
}
