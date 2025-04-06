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
                color: Theme.of(context).colorScheme.onBackground.withOpacity(0.7),
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
  List<Map<String, dynamic>> _duplicateFiles = [];
  bool _isScanning = false;
  int _processed = 0;
  int _total = 0;
  String _currentFile = '';
  int _duplicateCount = 0;
  double _progress = 0;

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
      _progress = 0;
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
          _currentFile = file.path.split('/').last;
          _processed++;
          _progress = _processed / _total;
        });
        final digest = await sha256.bind(file.openRead()).first;
        await DBHelper.insertChecksumIfNotExists(digest.toString(), file.path);
        final duplicates = await DBHelper.getDuplicates();
        setState(() {
          _duplicateCount = duplicates.fold(0, (acc, item) => acc + (item['count'] as int) - 1);
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
              LinearProgressIndicator(
                value: _progress,
                backgroundColor: Theme.of(context).colorScheme.surfaceVariant,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Processing files...',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onBackground.withOpacity(0.8),
                    ),
                  ),
                  Text(
                    '$_processed/$_total',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                _currentFile,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onBackground.withOpacity(0.6),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'Found $_duplicateCount duplicate files',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.primary,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ] else ...[
              if (_duplicateFiles.isEmpty)
                Expanded(
                  child: Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.folder_open,
                          size: 60,
                          color: Theme.of(context).colorScheme.onBackground.withOpacity(0.3),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          'No duplicates found',
                          style: TextStyle(
                            fontSize: 18,
                            color: Theme.of(context).colorScheme.onBackground.withOpacity(0.6),
                          ),
                        ),
                      ],
                    ),
                  ),
                )
              else
                Expanded(
                  child: ListView.builder(
                    itemCount: _duplicateFiles.length,
                    itemBuilder: (context, index) {
                      final item = _duplicateFiles[index];
                      final files = (item['files'] as String).split('||');
                      return Card(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Container(
                                    padding: const EdgeInsets.all(8),
                                    decoration: BoxDecoration(
                                      color: Theme.of(context).colorScheme.primary.withOpacity(0.1),
                                      shape: BoxShape.circle,
                                    ),
                                    child: Text(
                                      '${item['count']}',
                                      style: TextStyle(
                                        fontWeight: FontWeight.bold,
                                        color: Theme.of(context).colorScheme.primary,
                                      ),
                                    ),
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
                                  leading: const Icon(Icons.insert_drive_file),
                                  title: Text(
                                    filePath.split('/').last,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  subtitle: Text(
                                    filePath,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: Theme.of(context).colorScheme.onBackground.withOpacity(0.6),
                                    ),
                                  ),
                                  trailing: IconButton(
                                    icon: const Icon(Icons.folder_open),
                                    onPressed: () => openDirectoryInExplorer(filePath),
                                  ),
                                  onTap: () => openDirectoryInExplorer(filePath),
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
          ],
        ),
      ),
    );
  }
}