import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:crypto/crypto.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

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
      theme: ThemeData(primarySwatch: Colors.blue),
      home: const SplashScreenWrapper(),
    );
  }
}

class SplashScreenWrapper extends StatefulWidget {
  const SplashScreenWrapper({super.key});

  @override
  State<SplashScreenWrapper> createState() => _SplashScreenWrapperState();
}

class _SplashScreenWrapperState extends State<SplashScreenWrapper> {
  bool _showHome = false;

  @override
  void initState() {
    super.initState();
    Timer(const Duration(seconds: 3), () {
      if (!mounted) return;
      setState(() {
        _showHome = true;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    return _showHome ? const HomeScreen() : const SplashScreen();
  }
}

class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: const [
            Icon(Icons.find_in_page, size: 80, color: Colors.blue),
            SizedBox(height: 20),
            Text(
              'Duplicate File Checker',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Colors.blue),
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
              filePath TEXT
            )
          ''');
        },
      ),
    );
  }

  static Future<void> insertChecksumIfNotExists(String checksum, String filePath) async {
    final db = await database;
    final existing = await db.query('checksums', where: 'checksum = ? AND filePath = ?', whereArgs: [checksum, filePath]);
    if (existing.isEmpty) {
      await db.insert('checksums', {
        'checksum': checksum,
        'filePath': filePath,
      });
    }
  }

  static Future<List<Map<String, dynamic>>> getDuplicates() async {
    final db = await database;
    return await db.rawQuery('''
      SELECT checksum, GROUP_CONCAT(filePath, "||") as files, COUNT(*) as count 
      FROM checksums 
      GROUP BY checksum 
      HAVING count > 1
    ''');
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
    await launchUrl(uri);
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  List<Map<String, dynamic>> _duplicateFiles = [];
  bool _isScanning = false;
  int _processed = 0;
  int _total = 0;
  String _currentFile = '';
  int _duplicateCount = 0;

  Future<void> _scanForDuplicates() async {
    String? directoryPath = await FilePicker.platform.getDirectoryPath();
    if (directoryPath == null) return;

    setState(() {
      _isScanning = true;
      _duplicateFiles = [];
      _processed = 0;
      _total = 0;
      _currentFile = '';
      _duplicateCount = 0;
    });

    await DBHelper.clearDatabase();
    final dirQueue = <Directory>[Directory(directoryPath)];
    final allFiles = <File>[];

    while (dirQueue.isNotEmpty) {
      final currentDir = dirQueue.removeLast();
      try {
        final entities = currentDir.listSync(followLinks: false);
        for (final entity in entities) {
          if (entity is File) {
            allFiles.add(entity);
          } else if (entity is Directory) {
            dirQueue.add(entity);
          }
        }
      } catch (_) {}
    }

    _total = allFiles.length;
    for (final file in allFiles) {
      try {
        setState(() {
          _currentFile = file.path;
          _processed++;
        });
        final digest = await sha256.bind(file.openRead()).first;
        await DBHelper.insertChecksumIfNotExists(digest.toString(), file.path);
        final duplicates = await DBHelper.getDuplicates();
        setState(() {
          _duplicateCount = duplicates.fold(0, (acc, item) => acc + (item['count'] as int));
        });
      } catch (_) {}
    }

    final duplicates = await DBHelper.getDuplicates();
    setState(() {
      _isScanning = false;
      _duplicateFiles = duplicates;
      _currentFile = '';
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Duplicate File Checker')),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            ElevatedButton(
              onPressed: _isScanning ? null : _scanForDuplicates,
              child: const Text('Scan for Duplicates'),
            ),
            const SizedBox(height: 20),
            if (_isScanning) ...[
              const CircularProgressIndicator(),
              const SizedBox(height: 10),
              Text('Processing: $_processed / $_total'),
              Text('Current file: $_currentFile'),
              Text('Duplicate files found so far: $_duplicateCount'),
            ] else ...[
              Text('Total duplicate files: $_duplicateCount'),
              const SizedBox(height: 10),
              Expanded(
                child: ListView.builder(
                  itemCount: _duplicateFiles.length,
                  itemBuilder: (context, index) {
                    final item = _duplicateFiles[index];
                    final files = (item['files'] as String).split('||');
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Checksum: ${item['checksum']}',
                          style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.green),
                        ),
                        ...files.map(
                          (filePath) => GestureDetector(
                            onTap: () => openDirectoryInExplorer(filePath),
                            child: Text(
                              filePath,
                              style: const TextStyle(
                                color: Colors.blue,
                                decoration: TextDecoration.underline,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 10),
                      ],
                    );
                  },
                ),
              ),
            ]
          ],
        ),
      ),
    );
  }
}