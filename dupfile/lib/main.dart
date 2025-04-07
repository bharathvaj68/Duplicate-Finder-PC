import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:io';
import 'dart:math' show log, pow;
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
      ),
      home: const SplashScreenWrapper(),
    );
  }
}

class SplashScreenWrapper extends StatefulWidget {
  const SplashScreenWrapper({super.key});

  @override
  State<SplashScreenWrapper> createState() => _SplashScreenWrapperState();
}

class _SplashScreenWrapperState extends State<SplashScreenWrapper> with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 1500),
      vsync: this,
    )..forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder(
      future: Future.delayed(const Duration(seconds: 2)),
      builder: (context, snapshot) {
        return snapshot.connectionState == ConnectionState.done
            ? const HomeScreen()
            : FadeTransition(
                opacity: _controller,
                child: const SplashScreen(),
              );
      },
    );
  }
}

class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.surface,
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
                color: Theme.of(context).colorScheme.onSurface,
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
  static const int _dbVersion = 2;

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
        version: _dbVersion,
        onCreate: (db, version) async {
          await _createTables(db);
        },
        onUpgrade: (db, oldVersion, newVersion) async {
          if (oldVersion < 2) {
            await _migrateV1ToV2(db);
          }
        },
      ),
    );
  }

  static Future<void> _createTables(Database db) async {
    await db.execute('''CREATE TABLE checksums (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        checksum TEXT,
        filePath TEXT,
        fileName TEXT,
        fileSize INTEGER,
        lastModified INTEGER
      )''');
  }

  static Future<void> _migrateV1ToV2(Database db) async {
    try {
      await db.execute('ALTER TABLE checksums ADD COLUMN fileName TEXT');
      await db.execute('ALTER TABLE checksums ADD COLUMN fileSize INTEGER DEFAULT 0');
      await db.execute('ALTER TABLE checksums ADD COLUMN lastModified INTEGER DEFAULT 0');
    } catch (e) {
      debugPrint('Migration error: $e');
      await db.execute('DROP TABLE IF EXISTS checksums');
      await _createTables(db);
    }
  }

  static Future<void> insertChecksum(String checksum, File file) async {
    final db = await database;
    await db.insert('checksums', {
      'checksum': checksum,
      'filePath': file.path,
      'fileName': file.path.split(Platform.pathSeparator).last,
      'fileSize': await file.length(),
      'lastModified': (await file.lastModified()).millisecondsSinceEpoch,
    });
  }

  static Future<List<Map<String, dynamic>>> getDuplicates() async {
    final db = await database;
    return await db.rawQuery('''SELECT checksum, 
                                        GROUP_CONCAT(filePath, "||") as files,
                                        GROUP_CONCAT(fileName, "||") as fileNames,
                                        GROUP_CONCAT(fileSize, "||") as fileSizes,
                                        GROUP_CONCAT(lastModified, "||") as lastModifieds,
                                        COUNT(*) as count
                                FROM checksums
                                GROUP BY checksum
                                HAVING count > 1
                                ORDER BY fileSize DESC''');
  }

  static Future<void> clearDatabase() async {
    final db = await database;
    await db.delete('checksums');
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with TickerProviderStateMixin {
  List<Map<String, dynamic>> _duplicateFiles = [];
  bool _isScanning = false;
  int _processed = 0;
  int _total = 0;
  String _currentFile = '';
  int _duplicateCount = 0;
  double _progress = 0;
  late AnimationController _scanController;

  @override
  void initState() {
    super.initState();
    _scanController = AnimationController(
      duration: const Duration(milliseconds: 1000),
      vsync: this,
    );
  }

  @override
  void dispose() {
    _scanController.dispose();
    super.dispose();
  }

  Future<void> _scanForDuplicates() async {
    final directory = await FilePicker.platform.getDirectoryPath();
    if (directory == null) return;

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
    final files = await _collectFiles(Directory(directory));
    _total = files.length;

    for (final file in files) {
      if (!mounted) return;

      setState(() {
        _currentFile = file.path.split(Platform.pathSeparator).last;
        _processed++;
        _progress = _processed / _total;
      });

      try {
        final digest = await sha256.bind(file.openRead()).first;
        await DBHelper.insertChecksum(digest.toString(), file);
        final duplicates = await DBHelper.getDuplicates();
        setState(() {
          _duplicateCount = duplicates.fold(0, (acc, item) => acc + (item['count'] as int) - 1);
        });
      } catch (e) {
        debugPrint('Error processing file ${file.path}: $e');
      }
    }

    final duplicates = await DBHelper.getDuplicates();
    if (mounted) {
      setState(() {
        _isScanning = false;
        _duplicateFiles = duplicates;
        _currentFile = '';
      });
      _scanController.forward();
    }
  }

  Future<List<File>> _collectFiles(Directory dir) async {
    final files = <File>[];
    try {
      await for (final entity in dir.list(recursive: true)) {
        if (entity is File) {
          files.add(entity);
        }
      }
    } catch (e) {
      debugPrint('Error listing directory: $e');
    }
    return files;
  }

  Future<void> _openFileLocation(String path) async {
    final uri = Uri.file(File(path).parent.path);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri);
    }
  }

  String _formatBytes(int bytes) {
    if (bytes <= 0) return '0 B';
    const suffixes = ['B', 'KB', 'MB', 'GB', 'TB'];
    final i = (log(bytes) / log(1024)).floor();
    return '${(bytes / pow(1024, i)).toStringAsFixed(1)} ${suffixes[i]}';
  }

  String _formatDate(int timestamp) {
    return DateTime.fromMillisecondsSinceEpoch(timestamp).toString().split(' ')[0];
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
              ),
            ),
            const SizedBox(height: 20),
            if (_isScanning) _buildScanProgress(context),
            if (!_isScanning) _buildResults(context),
          ],
        ),
      ),
    );
  }

  Widget _buildScanProgress(BuildContext context) {
    return Expanded(
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(
              value: _progress,
              strokeWidth: 8,
            ),
            const SizedBox(height: 20),
            Text(
              'Scanning... $_processed/$_total',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 10),
            Text(
              _currentFile,
              style: Theme.of(context).textTheme.bodySmall,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildResults(BuildContext context) {
    if (_duplicateFiles.isEmpty) {
      return Expanded(
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.folder_open,
                size: 60,
                color: Theme.of(context).disabledColor,
              ),
              const SizedBox(height: 16),
              const Text('No duplicates found'),
            ],
          ),
        ),
      );
    }

    return Expanded(
      child: ListView.builder(
        itemCount: _duplicateFiles.length,
        itemBuilder: (context, index) {
          final group = _duplicateFiles[index];
          final files = (group['files'] as String).split('||');
          final names = (group['fileNames'] as String).split('||');
          final sizes = (group['fileSizes'] as String).split('||').map(int.parse).toList();
          final modified = (group['lastModifieds'] as String).split('||').map(int.parse).toList();

          return Card(
            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            color: Colors.red.shade50, // Highlight duplicates with red
            child: ExpansionTile(
              title: Text(
                '${group['count']} duplicates (${_formatBytes(sizes.reduce((a, b) => a + b))})',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              children: List.generate(files.length, (i) => ListTile(
                leading: const Icon(Icons.insert_drive_file),
                title: Text(names[i]),
                subtitle: Text(
                  '${_formatBytes(sizes[i])} • ${_formatDate(modified[i])}',
                ),
                trailing: IconButton(
                  icon: const Icon(Icons.folder_open),
                  onPressed: () => _openFileLocation(files[i]),
                ),
                onTap: () => _openFileLocation(files[i]),
              )),
            ),
          );
        },
      ),
    );
  }
}
