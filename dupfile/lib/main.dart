import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:crypto/crypto.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:intl/intl.dart';
import 'dart:convert';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Duplicate File Checker',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF4A6BFF),
          brightness: Brightness.light,
        ),
        useMaterial3: true,
        appBarTheme: const AppBarTheme(
          elevation: 0,
          centerTitle: true,
          titleTextStyle: TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.w600,
          ),
        ),
        cardTheme: CardTheme(
          elevation: 2,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          margin: const EdgeInsets.symmetric(vertical: 8),
        ),
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF4A6BFF),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      themeMode: ThemeMode.system,
      home: const SplashScreenWrapper(),
    );
  }
}

class SplashScreenWrapper extends StatefulWidget {
  const SplashScreenWrapper({super.key});

  @override
  State<SplashScreenWrapper> createState() => _SplashScreenWrapperState();
}

class _SplashScreenWrapperState extends State<SplashScreenWrapper>
    with SingleTickerProviderStateMixin {
  bool _showHome = false;
  late AnimationController _controller;
  late Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 1200),
      vsync: this,
    );
    _animation = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeInOut,
    );
    _controller.forward();

    Timer(const Duration(seconds: 2), () {
      if (!mounted) return;
      setState(() => _showHome = true);
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _showHome
        ? const HomeScreen()
        : FadeTransition(
            opacity: _animation,
            child: const SplashScreen(),
          );
  }
}

class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.background,
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primary.withOpacity(0.1),
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.find_in_page,
                size: 60,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
            const SizedBox(height: 24),
            Text(
              'Duplicate File Checker',
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: Theme.of(context).colorScheme.onBackground,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Find and manage duplicate files',
              style: TextStyle(
                fontSize: 14,
                color: Theme.of(context)
                    .colorScheme
                    .onBackground
                    .withOpacity(0.7),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class DBHelper {
  static Database? _db;

  static Future<Database> get database async {
    if (_db != null) return _db!;
    _db = await _initDB('checksums.db');
    return _db!;
  }

  static Future<Database> _initDB(String fileName) async {
    final documentsDirectory = await getApplicationDocumentsDirectory();
    final path = join(documentsDirectory.path, fileName);
    return await databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (db, version) async {
          await db.execute('''
            CREATE TABLE checksums (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              checksum TEXT,
              filePath TEXT UNIQUE,
              fileName TEXT,
              fileSize INTEGER,
              fileModified TEXT,
              scanRoot TEXT
            )
          ''');
        },
      ),
    );
  }

  static Future<void> insertChecksumIfNotExists(
    String checksum,
    String filePath,
    String fileName,
    int fileSize,
    String fileModified,
    String scanRoot,
  ) async {
    final db = await database;
    final existing = await db.query(
      'checksums',
      where: 'filePath = ?',
      whereArgs: [filePath],
    );
    if (existing.isEmpty) {
      await db.insert('checksums', {
        'checksum': checksum,
        'filePath': filePath,
        'fileName': fileName,
        'fileSize': fileSize,
        'fileModified': fileModified,
        'scanRoot': scanRoot,
      });
    }
  }

  static Future<List<Map<String, dynamic>>> getDuplicates(String scanRoot) async {
    final db = await database;
    return await db.rawQuery('''
      SELECT checksum, GROUP_CONCAT(filePath, "||") as files, SUM(fileSize) as totalSize, COUNT(*) as count
      FROM checksums
      WHERE scanRoot = ?
      GROUP BY checksum
      HAVING count > 1
    ''', [scanRoot]);
  }

  static Future<void> deleteFileRecord(String filePath) async {
    final db = await database;
    await db.delete('checksums', where: 'filePath = ?', whereArgs: [filePath]);
  }

  static Future<void> clearDatabase() async {
    final db = await database;
    await db.delete('checksums');
  }
}

Future<void> openDirectoryInExplorer(String filePath) async {
  final directoryPath = File(filePath).parent.path;
  if (await Directory(directoryPath).exists()) {
    final uri = Uri.file(directoryPath);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri);
    }
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  bool _isScanning = false;
  double _progress = 0;
  int _total = 0;
  int _processed = 0;
  int _duplicateCount = 0;
  int _totalDuplicateSize = 0;
  String _currentFile = '';
  List<Map<String, dynamic>> _duplicateFiles = [];
  bool _cancelRequested = false;

  Future<void> _scanForDuplicates() async {
    setState(() {
      _isScanning = true;
      _progress = 0;
      _processed = 0;
      _duplicateCount = 0;
      _totalDuplicateSize = 0;
      _currentFile = '';
      _duplicateFiles = [];
      _cancelRequested = false;
    });

    String? selectedDirectory = await FilePicker.platform.getDirectoryPath();
    if (selectedDirectory == null) {
      setState(() => _isScanning = false);
      return;
    }

    final String scanRoot = selectedDirectory;
    List<FileSystemEntity> allFiles = Directory(selectedDirectory)
        .listSync(recursive: true, followLinks: false)
        .whereType<File>()
        .toList();

    _total = allFiles.length;

    for (var file in allFiles) {
      if (_cancelRequested) break;

      setState(() {
        _currentFile = file.path;
        _processed++;
        _progress = _processed / _total;
      });

      try {
        var bytes = await File(file.path).readAsBytes();
        var digest = sha256.convert(bytes);
        var stat = await file.stat();

        await DBHelper.insertChecksumIfNotExists(
          digest.toString(),
          file.path,
          file.uri.pathSegments.last,
          stat.size,
          DateFormat('yyyy-MM-dd HH:mm:ss').format(stat.modified),
          scanRoot,
        );
      } catch (_) {}
    }

    List<Map<String, dynamic>> duplicates = await DBHelper.getDuplicates(scanRoot);
    int totalSize = 0;
    for (var item in duplicates) {
      totalSize += item['totalSize'] as int;
    }

    setState(() {
      _isScanning = false;
      _duplicateFiles = duplicates;
      _duplicateCount = duplicates.length;
      _totalDuplicateSize = totalSize;
    });
  }

  void _cancelScan() {
    setState(() => _cancelRequested = true);
  }

  void _clearDuplicates() async {
    for (var group in _duplicateFiles) {
      final files = (group['files'] as String).split('||');
      for (var i = 1; i < files.length; i++) {
        try {
          await File(files[i]).delete();
          await DBHelper.deleteFileRecord(files[i]);
        } catch (_) {}
      }
    }

    List<Map<String, dynamic>> updated = await DBHelper.getDuplicates("");
    int totalSize = 0;
    for (var item in updated) {
      totalSize += item['totalSize'] as int;
    }

    setState(() {
      _duplicateFiles = updated;
      _duplicateCount = updated.length;
      _totalDuplicateSize = totalSize;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Duplicate File Checker'),
        actions: [
          if (_duplicateCount > 0)
            Padding(
              padding: const EdgeInsets.only(right: 16),
              child: Center(
                child: Text(
                  '$_duplicateCount duplicates',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onPrimaryContainer,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            ElevatedButton.icon(
              onPressed: _isScanning ? null : _scanForDuplicates,
              icon: const Icon(Icons.search),
              label: const Text('Scan for Duplicates'),
              style: ElevatedButton.styleFrom(
                minimumSize: const Size.fromHeight(50),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
            const SizedBox(height: 20),
            if (_isScanning) ...[
              LinearProgressIndicator(value: _progress),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('Processing files...'),
                  Text('$_processed/$_total'),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                _currentFile,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 16),
              Text('Found $_duplicateCount duplicate files'),
              const SizedBox(height: 16),
              ElevatedButton.icon(
                onPressed: _cancelScan,
                icon: const Icon(Icons.cancel),
                label: const Text('Cancel Scan'),
              ),
            ] else ...[
              if (_duplicateFiles.isEmpty)
                Expanded(
                  child: Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.folder_open, size: 60, color: Colors.grey),
                        const SizedBox(height: 16),
                        const Text('No duplicates found'),
                      ],
                    ),
                  ),
                )
              else
                Expanded(
                  child: Column(
                    children: [
                      Text(
                        'Total duplicate size: ${(_totalDuplicateSize / (1024 * 1024)).toStringAsFixed(2)} MB',
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 8),
                      ElevatedButton.icon(
                        onPressed: _clearDuplicates,
                        icon: const Icon(Icons.delete_forever),
                        label: const Text('Clear Duplicates'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.red,
                          foregroundColor: Colors.white,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Expanded(
                        child: ListView.builder(
                          itemCount: _duplicateFiles.length,
                          itemBuilder: (context, index) {
                            final item = _duplicateFiles[index];
                            final files =
                                (item['files'] as String).split('||');
                            return Card(
                              child: Padding(
                                padding: const EdgeInsets.all(16),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        CircleAvatar(
                                          child: Text('${item['count']}'),
                                        ),
                                        const SizedBox(width: 12),
                                        Expanded(
                                          child: Text(
                                            'Duplicate group ${index + 1}',
                                            style: const TextStyle(
                                              fontWeight: FontWeight.bold,
                                              fontSize: 16,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 12),
                                    ...files.map(
                                      (filePath) => ListTile(
                                        contentPadding: EdgeInsets.zero,
                                        leading:
                                            const Icon(Icons.insert_drive_file),
                                        title: Text(
                                          filePath.split('/').last,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                        subtitle: Text(
                                          filePath,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(fontSize: 12),
                                        ),
                                        trailing: IconButton(
                                          icon: const Icon(Icons.folder_open),
                                          onPressed: () =>
                                              openDirectoryInExplorer(filePath),
                                        ),
                                        onTap: () =>
                                            openDirectoryInExplorer(filePath),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}