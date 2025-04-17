import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' show log, pow;
import 'package:file_picker/file_picker.dart';
import 'package:crypto/crypto.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:lottie/lottie.dart';
import 'package:open_filex/open_filex.dart';

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
      title: 'DuplicateFinder Pro',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF6200EE),
          secondary: const Color(0xFF03DAC6),
          brightness: Brightness.light,
        ),
        useMaterial3: true,
        appBarTheme: const AppBarTheme(
          elevation: 2,
          centerTitle: true,
          titleTextStyle: TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
        ),
        cardTheme: CardTheme(
          elevation: 3,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            elevation: 3,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 24),
          ),
        ),
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF6200EE),
          secondary: const Color(0xFF03DAC6),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      themeMode: ThemeMode.system,
      home: BlocProvider(
        create: (context) => ScanBloc(FileCheckerRepository()),
        child: const SplashScreenWrapper(),
      ),
    );
  }
}

// Data models
class DuplicateGroup {
  final String checksum;
  final List<FileInfo> files;

  DuplicateGroup({required this.checksum, required this.files});

  int get totalSize => files.fold(0, (sum, file) => sum + file.size);
  int get count => files.length;
}

class FileInfo {
  final String path;
  final String name;
  final int size;
  final DateTime modified;

  FileInfo({
    required this.path,
    required this.name,
    required this.size,
    required this.modified,
  });

  factory FileInfo.fromFile(File file) {
    return FileInfo(
      path: file.path,
      name: file.path.split(Platform.pathSeparator).last,
      size: file.lengthSync(),
      modified: file.lastModifiedSync(),
    );
  }
}

// Isolate Worker for file scanning
class FileWorker {
  static Future<String> computeChecksum(Map<String, dynamic> data) async {
    final File file = File(data['path']);
    try {
      final digest = await sha256.bind(file.openRead()).first;
      return digest.toString();
    } catch (e) {
      return 'error:${e.toString()}';
    }
  }
}

// Repository
class FileCheckerRepository {
  static Database? _db;
  static const int _dbVersion = 3;

  Future<Database> get database async {
    if (_db != null) return _db!;
    _db = await _initDB('duplicate_finder.db');
    return _db!;
  }

  Future<Database> _initDB(String fileName) async {
    final documentsDirectory = await getApplicationDocumentsDirectory();
    final path = join(documentsDirectory.path, fileName);
    return await databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: _dbVersion,
        onCreate: (db, version) async {
          await db.execute('''CREATE TABLE files (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            checksum TEXT NOT NULL,
            path TEXT NOT NULL,
            name TEXT NOT NULL,
            size INTEGER NOT NULL,
            modified INTEGER NOT NULL,
            UNIQUE(path)
          )''');

          await db.execute('CREATE INDEX idx_checksum ON files (checksum)');
        },
      ),
    );
  }

  Future<void> clearDatabase() async {
    final db = await database;
    await db.delete('files');
  }

  Future<void> insertFile(String checksum, FileInfo fileInfo) async {
    final db = await database;
    await db.insert('files', {
      'checksum': checksum,
      'path': fileInfo.path,
      'name': fileInfo.name,
      'size': fileInfo.size,
      'modified': fileInfo.modified.millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<DuplicateGroup>> getDuplicates() async {
    final db = await database;
    final results = await db.rawQuery('''
      SELECT checksum, COUNT(*) as count
      FROM files
      GROUP BY checksum
      HAVING count > 1
      ORDER BY count DESC, (
        SELECT SUM(size) FROM files AS f 
        WHERE f.checksum = files.checksum
      ) DESC
    ''');

    final duplicateGroups = <DuplicateGroup>[];

    for (final row in results) {
      final checksum = row['checksum'] as String;
      final fileRows = await db.query(
        'files',
        where: 'checksum = ?',
        whereArgs: [checksum],
        orderBy: 'size DESC',
      );

      final files =
          fileRows
              .map(
                (fileRow) => FileInfo(
                  path: fileRow['path'] as String,
                  name: fileRow['name'] as String,
                  size: fileRow['size'] as int,
                  modified: DateTime.fromMillisecondsSinceEpoch(
                    fileRow['modified'] as int,
                  ),
                ),
              )
              .toList();

      duplicateGroups.add(DuplicateGroup(checksum: checksum, files: files));
    }

    return duplicateGroups;
  }

  // New methods for optimized scanning
  Future<List<File>> collectFiles(
    Directory dir, {
    List<String> extensions = const [],
  }) async {
    final files = <File>[];

    try {
      await for (final entity in dir.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is File) {
          if (extensions.isEmpty ||
              extensions.contains(extension(entity.path).toLowerCase())) {
            files.add(entity);
          }
        }
      }
    } catch (e) {
      debugPrint('Error listing directory: $e');
    }

    return files;
  }

  Future<Map<String, List<FileInfo>>> findDuplicatesBySize(
    List<File> files,
  ) async {
    final sizeMap = <int, List<FileInfo>>{};

    for (final file in files) {
      try {
        final fileInfo = FileInfo.fromFile(file);
        sizeMap.putIfAbsent(fileInfo.size, () => []).add(fileInfo);
      } catch (e) {
        debugPrint('Error processing file size: $e');
      }
    }

    // Filter out unique files by size
    final potentialDuplicates = <int, List<FileInfo>>{};
    sizeMap.forEach((size, fileInfos) {
      if (fileInfos.length > 1 && size > 0) {
        potentialDuplicates[size] = fileInfos;
      }
    });

    return potentialDuplicates.map(
      (key, value) => MapEntry(key.toString(), value),
    );
  }
}

// Bloc for state management
enum ScanStatus { initial, scanning, completed, cancelled, error }

class ScanState {
  final ScanStatus status;
  final List<DuplicateGroup> duplicateGroups;
  final int processedFiles;
  final int totalFiles;
  final String currentFile;
  final int duplicateCount;
  final double progress;
  final String scanPath;
  final List<String> selectedExtensions;
  final String error;
  final bool useQuickScan;

  ScanState({
    this.status = ScanStatus.initial,
    this.duplicateGroups = const [],
    this.processedFiles = 0,
    this.totalFiles = 0,
    this.currentFile = '',
    this.duplicateCount = 0,
    this.progress = 0.0,
    this.scanPath = '',
    this.selectedExtensions = const [],
    this.error = '',
    this.useQuickScan = true,
  });

  ScanState copyWith({
    ScanStatus? status,
    List<DuplicateGroup>? duplicateGroups,
    int? processedFiles,
    int? totalFiles,
    String? currentFile,
    int? duplicateCount,
    double? progress,
    String? scanPath,
    List<String>? selectedExtensions,
    String? error,
    bool? useQuickScan,
  }) {
    return ScanState(
      status: status ?? this.status,
      duplicateGroups: duplicateGroups ?? this.duplicateGroups,
      processedFiles: processedFiles ?? this.processedFiles,
      totalFiles: totalFiles ?? this.totalFiles,
      currentFile: currentFile ?? this.currentFile,
      duplicateCount: duplicateCount ?? this.duplicateCount,
      progress: progress ?? this.progress,
      scanPath: scanPath ?? this.scanPath,
      selectedExtensions: selectedExtensions ?? this.selectedExtensions,
      error: error ?? this.error,
      useQuickScan: useQuickScan ?? this.useQuickScan,
    );
  }
}

abstract class ScanEvent {}

class CancelScanEvent extends ScanEvent {}


class SelectDirectoryEvent extends ScanEvent {
  final String? directory;
  final bool useQuickScan;
  final List<String> extensions;

  SelectDirectoryEvent({
    this.directory,
    this.useQuickScan = false,
    this.extensions = const [],
  });
}


class UpdateProgressEvent extends ScanEvent {
  final int processed;
  final String currentFile;
  final double progress;

  UpdateProgressEvent({
    required this.processed,
    required this.currentFile,
    required this.progress,
  });
}

class CompleteScanEvent extends ScanEvent {
  final List<DuplicateGroup> duplicateGroups;

  CompleteScanEvent(this.duplicateGroups);
}

class ToggleQuickScanEvent extends ScanEvent {
  final bool useQuickScan;

  ToggleQuickScanEvent(this.useQuickScan);
}

class UpdateExtensionsEvent extends ScanEvent {
  final List<String> extensions;

  UpdateExtensionsEvent(this.extensions);
}

class RescanDirectoryEvent extends ScanEvent {}

class RemoveDuplicateGroupEvent extends ScanEvent {
  final DuplicateGroup group;
  RemoveDuplicateGroupEvent(this.group);
}

class ScanBloc extends Bloc<ScanEvent, ScanState> {
  final FileCheckerRepository repository;
  bool _isCancelled = false;
  String? currentDirectory;

  ScanBloc(this.repository) : super(ScanState()) {
    on<SelectDirectoryEvent>(_onSelectDirectory);
    on<UpdateProgressEvent>(_onUpdateProgress);
    on<CompleteScanEvent>(_onCompleteScan);
    on<ToggleQuickScanEvent>(_onToggleQuickScan);
    on<UpdateExtensionsEvent>(_onUpdateExtensions);
    on<CancelScanEvent>(_onCancelScan);
    on<RescanDirectoryEvent>(_onRescanDirectory);
    on<RemoveDuplicateGroupEvent>(_onRemoveDuplicateGroup);

  }

  void _onCancelScan(CancelScanEvent event, Emitter<ScanState> emit) {
    _isCancelled = true;
    emit(state.copyWith(status: ScanStatus.initial));
  }

  void _onRemoveDuplicateGroup(
  RemoveDuplicateGroupEvent event,
  Emitter<ScanState> emit,
) {
  final updatedGroups = List<DuplicateGroup>.from(state.duplicateGroups)
    ..removeWhere((g) => g == event.group);

  emit(state.copyWith(duplicateGroups: updatedGroups));
}

  Future<void> _onSelectDirectory(
    SelectDirectoryEvent event,
    Emitter<ScanState> emit,
  ) async {
    _isCancelled = false;

    final directory = event.directory ?? await FilePicker.platform.getDirectoryPath();
    if (directory == null) return;

    currentDirectory = directory;

    emit(
      state.copyWith(
        status: ScanStatus.scanning,
        duplicateGroups: [],
        processedFiles: 0,
        totalFiles: 0,
        currentFile: '',
        duplicateCount: 0,
        progress: 0,
        scanPath: directory,
        useQuickScan: event.useQuickScan,
        selectedExtensions: event.extensions,
      ),
    );

    try {
      await repository.clearDatabase();

      final selectedDir = Directory(directory);
      final files = await repository.collectFiles(
        selectedDir,
        extensions: state.selectedExtensions,
      );

      emit(state.copyWith(totalFiles: files.length));

      if (state.useQuickScan && files.length > 100) {
        final sizeGroups = await repository.findDuplicatesBySize(files);

        int processed = 0;
        int duplicateCount = 0;

        for (final entry in sizeGroups.entries) {
          final sameSize = entry.value;

          for (int i = 0; i < sameSize.length; i++) {
            if (_isCancelled || isClosed) return;

            final fileInfo = sameSize[i];

            emit(
              state.copyWith(
                processedFiles: processed + 1,
                currentFile: fileInfo.name,
                progress: (processed + 1) / files.length,
              ),
            );

            final result = await Isolate.run(
              () => FileWorker.computeChecksum({'path': fileInfo.path}),
            );

            if (!result.startsWith('error:')) {
              await repository.insertFile(result, fileInfo);
            }

            processed++;
          }
        }

        final duplicates = await repository.getDuplicates();
        duplicateCount = duplicates.fold(
          0,
          (count, group) => count + group.count - 1,
        );

        if (!_isCancelled && !isClosed) {
          add(CompleteScanEvent(duplicates));
        }
      } else {
        int processed = 0;
        int duplicateCount = 0;

        for (final file in files) {
          if (_isCancelled || isClosed) return;

          final fileInfo = FileInfo.fromFile(file);

          add(
            UpdateProgressEvent(
              processed: processed + 1,
              currentFile: fileInfo.name,
              progress: (processed + 1) / files.length,
            ),
          );

          final result = await Isolate.run(
            () => FileWorker.computeChecksum({'path': fileInfo.path}),
          );

          if (!result.startsWith('error:')) {
            await repository.insertFile(result, fileInfo);

            if (processed % 10 == 0 || processed == files.length - 1) {
              final duplicates = await repository.getDuplicates();
              duplicateCount = duplicates.fold(
                0,
                (count, group) => count + group.count - 1,
              );

              emit(state.copyWith(duplicateCount: duplicateCount));
            }
          }

          processed++;
        }

        final duplicates = await repository.getDuplicates();
        if (!_isCancelled && !isClosed) {
          add(CompleteScanEvent(duplicates));
        }
      }
    } catch (e) {
      emit(state.copyWith(status: ScanStatus.error, error: e.toString()));
    }
  }

  void _onUpdateProgress(UpdateProgressEvent event, Emitter<ScanState> emit) {
    emit(
      state.copyWith(
        processedFiles: event.processed,
        currentFile: event.currentFile,
        progress: event.progress,
      ),
    );
  }

  void _onCompleteScan(CompleteScanEvent event, Emitter<ScanState> emit) {
    emit(
      state.copyWith(
        status: ScanStatus.completed,
        duplicateGroups: event.duplicateGroups,
        currentFile: '',
      ),
    );
  }

  void _onToggleQuickScan(ToggleQuickScanEvent event, Emitter<ScanState> emit) {
    emit(state.copyWith(useQuickScan: event.useQuickScan));
  }

  void _onUpdateExtensions(
    UpdateExtensionsEvent event,
    Emitter<ScanState> emit,
  ) {
    emit(state.copyWith(selectedExtensions: event.extensions));
  }

  Future<void> _onRescanDirectory(
    RescanDirectoryEvent event,
    Emitter<ScanState> emit,
  ) async {
    if (currentDirectory != null) {
      add(SelectDirectoryEvent(directory: currentDirectory!));
    }
  }
}

// Splash Screen
class SplashScreenWrapper extends StatefulWidget {
  const SplashScreenWrapper({super.key});

  @override
  State<SplashScreenWrapper> createState() => _SplashScreenWrapperState();
}

class _SplashScreenWrapperState extends State<SplashScreenWrapper>
    with SingleTickerProviderStateMixin {
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
        return AnimatedSwitcher(
          duration: const Duration(milliseconds: 500),
          child:
              snapshot.connectionState == ConnectionState.done
                  ? const HomeScreen()
                  : FadeTransition(
                    opacity: _controller,
                    child: const SplashScreen(),
                  ),
        );
      },
    );
  }
}

class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: colorScheme.surface,
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            TweenAnimationBuilder<double>(
              tween: Tween<double>(begin: 0.0, end: 1.0),
              duration: const Duration(milliseconds: 800),
              curve: Curves.easeOutBack,
              builder: (context, value, child) {
                return Transform.scale(
                  scale: value,
                  child: Container(
                    width: 120,
                    height: 120,
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: colorScheme.primary.withOpacity(0.2),
                      shape: BoxShape.circle,
                    ),
                    child: Container(
                      decoration: BoxDecoration(
                        color: colorScheme.primary.withOpacity(0.4),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        Icons.insert_drive_file,
                        size: 60,
                        color: colorScheme.primary,
                      ),
                    ),
                  ),
                );
              },
            ),
            const SizedBox(height: 32),
            TweenAnimationBuilder<double>(
              tween: Tween<double>(begin: 0.0, end: 1.0),
              duration: const Duration(milliseconds: 800),
              curve: Curves.easeOut,
              builder: (context, value, child) {
                return Opacity(opacity: value, child: child);
              },
              child: Column(
                children: [
                  Text(
                    'DuplicateFinder Pro',
                    style: TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.bold,
                      color: colorScheme.primary,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Find & Manage Duplicate Files',
                    style: TextStyle(
                      fontSize: 16,
                      color: colorScheme.onSurface.withOpacity(0.7),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}


//Recycle Bin page

class RecycleBinPage extends StatefulWidget {
  const RecycleBinPage({super.key});

  @override
  State<RecycleBinPage> createState() => _RecycleBinPageState();
}

class _RecycleBinPageState extends State<RecycleBinPage> {
  Map<String, List<File>> _groupedFiles = {};

  @override
  void initState() {
    super.initState();
    _loadRecycledFiles();
  }


//Function to display common name
String getCommonPrefix(List<String> names) {
  if (names.isEmpty) return '';
  String prefix = names.first;
  for (final name in names.skip(1)) {
    while (!name.startsWith(prefix)) {
      if (prefix.isEmpty) return '';
      prefix = prefix.substring(0, prefix.length - 1);
    }
  }
  return prefix;
}

// to calc checksums to group duplicates
  Future<String> _calculateChecksum(File file) async {
    try {
      final bytes = await file.readAsBytes();
      return sha256.convert(bytes).toString();
    } catch (e) {
      return 'error';
    }
  }

//function to load files to recyclebin
  Future<void> _loadRecycledFiles() async {
    try {
      final docsDir = await getApplicationDocumentsDirectory();
      final recycleDir = Directory('${docsDir.path}${Platform.pathSeparator}dupbin');

      if (!await recycleDir.exists()) {
        await recycleDir.create(recursive: true);
      }

      final files = recycleDir.listSync().whereType<File>().toList();
      final Map<String, List<File>> grouped = {};

      for (var file in files) {
        final checksum = await _calculateChecksum(file);
        if (checksum != 'error') {
          grouped.putIfAbsent(checksum, () => []).add(file);
        }
      }

      setState(() {
        _groupedFiles = grouped;
      });

      for (var entry in grouped.entries) {
        debugPrint('🔁 Group [${entry.key.substring(0, 8)}]: ${entry.value.length} files');
      }
    } catch (e) {
      debugPrint('❌ Failed to load recycle bin: $e');
    }
  }

//to open recycle bin folder from page
  Future<void> _openRecycleBinFolder(BuildContext context) async {
    try {
      final docsDir = await getApplicationDocumentsDirectory();
      final recycleDirPath = '${docsDir.path}${Platform.pathSeparator}dupbin';
      final uri = Uri.file(recycleDirPath);

      if (!await Directory(recycleDirPath).exists()) {
        await Directory(recycleDirPath).create(recursive: true);
      }

      if (!await launchUrl(uri)) {
        throw 'Could not open folder: $recycleDirPath';
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not open folder: $e')),
      );
    }
  }


//to restore files individually
  Future<void> _restoreFile(BuildContext context, File file) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (localCtx) => AlertDialog(
        title: const Text('Restore File'),
        content: Text('Restore "${file.uri.pathSegments.last}" to Downloads?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(localCtx, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(localCtx, true), child: const Text('Restore')),
        ],
      ),
    );

    if (confirm != true) return;

    try {
      final String home = Platform.isWindows
          ? Platform.environment['USERPROFILE'] ?? ''
          : Platform.environment['HOME'] ?? '';
      final restoredDir = Directory('$home${Platform.pathSeparator}Downloads${Platform.pathSeparator}restored_dups');

      if (!await restoredDir.exists()) {
        await restoredDir.create(recursive: true);
      }

      final newPath = '${restoredDir.path}${Platform.pathSeparator}${file.uri.pathSegments.last}';
      await file.rename(newPath);

      _loadRecycledFiles(); // Refresh after restore

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Restored "${file.uri.pathSegments.last}"'),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to restore: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  @override
Widget build(BuildContext context) {
  return Scaffold(
    appBar: AppBar(
      title: const Text('Recycle Bin'),
      actions: [
        IconButton(
          icon: const Icon(Icons.folder_open),
          tooltip: 'Open Recycle Bin Folder',
          onPressed: () => _openRecycleBinFolder(context),
        ),
      ],
    ),
    body: _groupedFiles.isEmpty
        ? const Center(child: Text('Recycle bin is empty.'))
        : ListView.builder(
            itemCount: _groupedFiles.length,
            itemBuilder: (context, index) {
              final entry = _groupedFiles.entries.elementAt(index);
              final files = entry.value;
              final names = files.map((f) => f.uri.pathSegments.last).toList();
              final prefix = getCommonPrefix(names).trim();

              return Card(
                margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                elevation: 2,
                child: ExpansionTile(
                  title: Text(
                    prefix.isNotEmpty
                        ? '$prefix... (${files.length} files)'
                        : '${names.first} (${files.length} files)',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  children: files.map((file) {
                    final name = file.uri.pathSegments.last;
                    final size = file.lengthSync();
                    final modified = file.lastModifiedSync();

                    return ListTile(
                      title: Text(name),
                      subtitle: Text(
                        '${(size / 1024).toStringAsFixed(2)} KB • Modified: ${modified.toLocal()}',
                      ),
                      onTap: () => OpenFilex.open(file.path),
                      trailing: IconButton(
                        icon: const Icon(Icons.restore),
                        tooltip: 'Restore',
                        onPressed: () => _restoreFile(context, file),
                      ),
                    );
                  }).toList(),
                ),
              );
            },
          ),
  );
}
}



// Main app screens
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with TickerProviderStateMixin {
  final List<String> _commonExtensions = [
    '.jpg',
    '.jpeg',
    '.png',
    '.gif',
    '.mp4',
    '.mov',
    '.mkv',
    '.doc',
    '.docx',
    '.pdf',
    '.txt',
    '.mp3',
    '.zip',
  ];
  final List<String> _selectedExtensions = [];
  bool _showExtensionFilter = false;
  final Map<DuplicateGroup, bool> _groupVisibility = {};

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<ScanBloc, ScanState>(
      builder: (context, state) {
        return Scaffold(
  body: CustomScrollView(
    slivers: [
      _buildAppBar(context, state),
      SliverPadding(
        padding: const EdgeInsets.all(16.0),
        sliver: SliverToBoxAdapter(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildScanButton(context, state),
              const SizedBox(height: 16),
              ElevatedButton.icon(
  onPressed: () {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (context) => RecycleBinPage()),
    );
  },
  icon: const Icon(Icons.recycling_outlined),
  label: const Text('Open Recycle Bin'),
  style: ElevatedButton.styleFrom(
    backgroundColor: Theme.of(context).colorScheme.primaryContainer,
    foregroundColor: Theme.of(context).colorScheme.onPrimaryContainer,
  ),
),

              _buildScanOptions(context, state),
              if (_showExtensionFilter) ...[
                const SizedBox(height: 16),
                _buildExtensionFilter(context),
              ],
              const SizedBox(height: 24),
              if (state.status == ScanStatus.scanning)
                _buildScanProgress(context, state)
              else if (state.status == ScanStatus.completed &&
                  state.duplicateGroups.isNotEmpty)
                _buildResultsHeader(context, state),
                const SizedBox(height: 8),
                
            ],
          ),
        ),
      ),

      // Show this only if no duplicates found
      if (state.status == ScanStatus.completed &&
          state.duplicateGroups.isEmpty)
        _buildNoDuplicatesFoundMessage(context, state)

      // Show the results list if duplicates found
      else if (state.status == ScanStatus.completed &&
               state.duplicateGroups.isNotEmpty)
        _buildResultsList(context, state)

      // Show a message when app first loads
      else if (state.status == ScanStatus.initial)
        SliverFillRemaining(
          hasScrollBody: false,
          child: Center(
            child: Text("Start a scan to find duplicate files."),
          ),
        ),
    ],
  ),
);

      },
    );
  }


//_openDupBinFolder is used when open recycle bin button is pressed
/* Future<void> _openDupBinFolder() async {
  final docsDir = await getApplicationDocumentsDirectory();
  final dupBin = Directory('${docsDir.path}${Platform.pathSeparator}dupbin');

  if (!await dupBin.exists()) {
    await dupBin.create(recursive: true);
  }

  if (Platform.isWindows) {
    await Process.run('explorer', [dupBin.path]);
  } else if (Platform.isMacOS) {
    await Process.run('open', [dupBin.path]);
  } else if (Platform.isLinux) {
    await Process.run('xdg-open', [dupBin.path]);
  }
} */

  Widget _buildAppBar(BuildContext context, ScanState state) {
    return SliverAppBar(
      expandedHeight: 120,
      pinned: true,
      flexibleSpace: FlexibleSpaceBar(
        title: Text(
          'DuplicateFinder Pro',
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurface,
            fontWeight: FontWeight.bold,
          ),
        ),
        background: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Theme.of(context).colorScheme.primary.withOpacity(0.2),
                Theme.of(context).colorScheme.surface,
              ],
            ),
          ),
        ),
      ),
      actions: [
        if (state.duplicateCount > 0)
          Container(
            margin: const EdgeInsets.only(right: 16),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.file_copy_outlined,
                  size: 18,
                  color: Theme.of(context).colorScheme.onPrimaryContainer,
                ),
                const SizedBox(width: 4),
                Text(
                  '${state.duplicateCount}',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onPrimaryContainer,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildScanButton(BuildContext context, ScanState state) {
    return ElevatedButton.icon(
      onPressed: (state.status == ScanStatus.scanning)
    ? null
    : () => context.read<ScanBloc>().add(
          SelectDirectoryEvent(
            useQuickScan: state.useQuickScan,
            extensions: _selectedExtensions,
          ),
        ),

      icon: Icon(
        state.status == ScanStatus.scanning
            ? Icons.hourglass_top
            : Icons.search,
        size: 28,
      ),
      label: Text(
        state.status == ScanStatus.scanning
            ? 'Scanning...'
            : 'Scan for Duplicates',
        style: const TextStyle(fontSize: 18),
      ),
      style: ElevatedButton.styleFrom(
        minimumSize: const Size.fromHeight(56),
        backgroundColor: Theme.of(context).colorScheme.primary,
        foregroundColor: Theme.of(context).colorScheme.onPrimary,
      ),
    );
  }

  Widget _buildScanOptions(BuildContext context, ScanState state) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Scan Options',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            SwitchListTile(
              title: const Text('Quick Scan Mode'),
              subtitle: const Text(
                'Compares files with same size first (faster)',
              ),
              value: state.useQuickScan,
              onChanged: (value) {
                context.read<ScanBloc>().add(ToggleQuickScanEvent(value));
              },
              secondary: Icon(
                Icons.speed,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
            ListTile(
              title: const Text('File Extension Filter'),
              subtitle: Text(
                _selectedExtensions.isEmpty
                    ? 'All files'
                    : '${_selectedExtensions.length} extensions selected',
              ),
              leading: Icon(
                Icons.filter_list,
                color: Theme.of(context).colorScheme.primary,
              ),
              trailing: IconButton(
                icon: Icon(
                  _showExtensionFilter ? Icons.expand_less : Icons.expand_more,
                ),
                onPressed: () {
                  setState(() {
                    _showExtensionFilter = !_showExtensionFilter;
                  });
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildExtensionFilter(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'File Extensions',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                TextButton.icon(
                  icon: const Icon(Icons.clear_all),
                  label: Text(
                    _selectedExtensions.isEmpty ? 'Select All' : 'Clear All',
                  ),
                  onPressed: () {
                    setState(() {
                      if (_selectedExtensions.isEmpty) {
                        _selectedExtensions.addAll(_commonExtensions);
                      } else {
                        _selectedExtensions.clear();
                      }
                    });
                    context.read<ScanBloc>().add(
                      UpdateExtensionsEvent(_selectedExtensions),
                    );
                  },
                ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children:
                  _commonExtensions.map((ext) {
                    final selected = _selectedExtensions.contains(ext);
                    return FilterChip(
                      label: Text(ext),
                      selected: selected,
                      checkmarkColor: Theme.of(context).colorScheme.onPrimary,
                      selectedColor: Theme.of(context).colorScheme.primary,
                      labelStyle: TextStyle(
                        color:
                            selected
                                ? Theme.of(context).colorScheme.onPrimary
                                : null,
                      ),
                      onSelected: (value) {
                        setState(() {
                          if (value) {
                            _selectedExtensions.add(ext);
                          } else {
                            _selectedExtensions.remove(ext);
                          }
                        });
                        context.read<ScanBloc>().add(
                          UpdateExtensionsEvent(_selectedExtensions),
                        );
                      },
                    );
                  }).toList(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildScanProgress(BuildContext context, ScanState state) {
  return Card(
    child: Padding(
      padding: const EdgeInsets.all(24.0),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          LinearProgressIndicator(
            value: state.progress,
            minHeight: 10,
            borderRadius: BorderRadius.circular(8),
          ),
          const SizedBox(height: 24),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Column(
                children: [
                  Text(
                    '${state.processedFiles}/${state.totalFiles}',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                  ),
                  const Text('Files Scanned'),
                ],
              ),
              const SizedBox(width: 40),
              Column(
                children: [
                  Text(
                    '${state.duplicateCount}',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: Theme.of(context).colorScheme.error,
                        ),
                  ),
                  const Text('Duplicates Found'),
                ],
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            'Current file: ${state.currentFile}',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 24),
          TextButton.icon(
            icon: const Icon(Icons.cancel),
            label: const Text("Cancel Scan"),
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () {
              context.read<ScanBloc>().add(CancelScanEvent());
            },
          ),
        ],
      ),
    ),
  );
}


// it is the page shows after duplicates found
  Widget _buildResultsHeader(BuildContext context, ScanState state) {
  if (state.duplicateGroups.isEmpty) return const SizedBox.shrink();

  final totalSize = state.duplicateGroups.fold(0, (total, group) {
  if (group.files.length <= 1) return total;

  final sortedFiles = List.of(group.files);
  sortedFiles.sort((a, b) {
    final aModified = File(a.path).lastModifiedSync();
    final bModified = File(b.path).lastModifiedSync();
    return aModified.compareTo(bModified);
  });

  // Keep the oldest, sum the rest
  final duplicatesSize = sortedFiles.skip(1).fold<int>(0, (sum, file) {
    return sum + File(file.path).lengthSync();
  });

  return total + duplicatesSize;
});

  return Card(
    color: Theme.of(context).colorScheme.secondaryContainer,
    child: Padding(
      padding: const EdgeInsets.all(20.0),
      child: Column(
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.secondary.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  Icons.save_alt,
                  color: Theme.of(context).colorScheme.secondary,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Reclaim Space',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    Text(
                      'You can save up to ${_formatSize(totalSize)}',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.secondary,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
              ElevatedButton.icon(
                icon: const Icon(Icons.delete),
                label: const Text("Delete Duplicates"),
                onPressed: () => _deleteAllDuplicates(context, state), //func in ln 1164
                style: ElevatedButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.errorContainer,
                  foregroundColor: Theme.of(context).colorScheme.onErrorContainer,
                ),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}

// deleteAllDuplicates function to be used onPressed
Future<void> _deleteAllDuplicates(BuildContext context, ScanState state) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Delete All Duplicates'),
      content: const Text('Are you sure you want to delete all duplicate files except the oldest in each group?'),
      actions: [
        TextButton(
          child: const Text('Cancel'),
          onPressed: () => Navigator.of(context).pop(false),
        ),
        ElevatedButton(
          child: const Text('Yes, Delete'),
          onPressed: () => Navigator.of(context).pop(true),
        ),
      ],
    ),
  );

  if (confirmed != true) return;

  final dupBin = await _getDupBinDirectory();
  int totalSize = 0;

  for (final group in state.duplicateGroups) {
    if (group.files.length <= 1) continue;

    // Create a map of files with their lastModified date
    final fileDateMap = <FileInfo, DateTime>{};
    for (final f in group.files) {
      try {
        fileDateMap[f] = File(f.path).lastModifiedSync();
      } catch (e) {
        // Skip unreadable files
        continue;
      }
    }

    if (fileDateMap.isEmpty) continue;

    // Find the oldest file
    final oldest = fileDateMap.entries.reduce((a, b) => a.value.isBefore(b.value) ? a : b).key;

    for (final f in group.files) {
      if (f.path == oldest.path) continue; // Skip the oldest (original)

      final file = File(f.path);
      if (await file.exists()) {
        final fileName = file.path.split(Platform.pathSeparator).last;
        final newPath = '${dupBin.path}${Platform.pathSeparator}$fileName';

        try {
          totalSize += await file.length();
          await file.rename(newPath);
        } catch (e) {
          totalSize += await file.length();
          await file.copy(newPath);
          await file.delete();
        }
      }
    }
  }

  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Duplicates moved to dupbin. Space saved: ${_formatSize(totalSize)}'),
        backgroundColor: Colors.green,
      ),
    );
    context.read<ScanBloc>().add(RescanDirectoryEvent());
  }
}



Future<Directory> _getDupBinDirectory() async {
  final docsDir = await getApplicationDocumentsDirectory();
  final dupBinPath = '${docsDir.path}${Platform.pathSeparator}dupbin';
  final dupBinDir = Directory(dupBinPath);
  if (!await dupBinDir.exists()) {
    await dupBinDir.create(recursive: true);
  }
  return dupBinDir;
}


  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024)
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  Widget _buildResultsList(BuildContext context, ScanState state) {
  for (var group in state.duplicateGroups) {
    _groupVisibility.putIfAbsent(group, () => true);
  }

  return SliverList(
    delegate: SliverChildBuilderDelegate(
      (context, index) {
        final group = state.duplicateGroups[index];
        return _buildDuplicateGroupCard(
          context,
          group,
          index,
          _groupVisibility[group] ?? true,
          () async {
            final confirmed = await showDialog<bool>(
              context: context,
              builder: (context) => AlertDialog(
                title: const Text('Delete Duplicates?'),
                content: const Text('Are you sure you want to move all but the original file to dupbin?'),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(false),
                    child: const Text('Cancel'),
                  ),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(true),
                    child: const Text('OK'),
                  ),
                ],
              ),
            );

            if (confirmed != true) return;

            setState(() {
              _groupVisibility[group] = false;
            });

            await Future.delayed(const Duration(milliseconds: 400));

            await _deleteGroupDuplicates(
              context,
              group,
              () {
                context.read<ScanBloc>().add(RemoveDuplicateGroupEvent(group));
              },
            );
          },
        );
      },
      childCount: state.duplicateGroups.length,
    ),
  );
}



//separate group duplicate cards
 Widget _buildDuplicateGroupCard(
  BuildContext context,
  DuplicateGroup group,
  int index,
  bool isVisible,
  VoidCallback onDelete,
) {
  return AnimatedOpacity(
    opacity: isVisible ? 1.0 : 0.0,
    duration: const Duration(milliseconds: 400),
    curve: Curves.easeOut,
    child: AnimatedSize(
      duration: const Duration(milliseconds: 400),
      curve: Curves.easeOut,
      child: isVisible
          ? Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Card(
                child: ExpansionTile(
                  title: Row(
                    children: [
                      Text(
                        '${group.count} duplicates',
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '(${_formatSize(group.totalSize)})',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.primary.withOpacity(0.7),
                        ),
                      ),
                      const Spacer(),
                      IconButton(
                        icon: const Icon(Icons.delete_outline),
                        tooltip: 'Delete group duplicates',
                        onPressed: onDelete,
                      ),
                    ],
                  ),
                  subtitle: Text(
                    'First found: ${group.files.first.name}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  leading: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.error.withOpacity(0.1),
                      shape: BoxShape.circle,
                    ),
                    child: Text(
                      '${index + 1}',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  children: group.files
                      .map((file) => _buildFileListTile(context, file))
                      .toList(),
                ),
              ),
            )
          : const SizedBox.shrink(),
    ),
  );
}


// function for deleteGroupDuplicates is used onPressed
Future<void> _deleteGroupDuplicates(
  BuildContext context,
  DuplicateGroup group,
  void Function() onGroupRemoved,
) async {
  final dupBin = await _getDupBinDirectory();

  if (group.files.length <= 1) return;

  // Map each file to its last modified date (safely)
  final fileDateMap = <FileInfo, DateTime>{};
  for (final f in group.files) {
    try {
      final file = File(f.path);
      if (await file.exists()) {
        fileDateMap[f] = await file.lastModified();
      }
    } catch (e) {
      continue; // Skip unreadable or missing files
    }
  }

  if (fileDateMap.isEmpty) return;

  // Identify the oldest file to keep
  final oldest = fileDateMap.entries.reduce((a, b) => a.value.isBefore(b.value) ? a : b).key;

  for (final f in group.files) {
    if (f.path == oldest.path) continue;

    final file = File(f.path);
    if (await file.exists()) {
      final fileName = file.path.split(Platform.pathSeparator).last;
      final newPath = '${dupBin.path}${Platform.pathSeparator}$fileName';

      try {
        await file.rename(newPath);
      } catch (e) {
        // fallback to copy + delete if rename fails
        await file.copy(newPath);
        await file.delete();
      }
    }
  }

  // Trigger vanish animation callback
  onGroupRemoved();

  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Group duplicates moved to Documents/dupbin')),
    );

    // Do not rescan here! Just remove from UI:
    context.read<ScanBloc>().add(RemoveDuplicateGroupEvent(group));
  }
}



  Widget _buildFileListTile(BuildContext context, FileInfo file) {
    return ListTile(
      onTap: () async {
        // Open the actual file
        final uri = Uri.file(file.path);
        try {
          await launchUrl(uri);
        } catch (e) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('Could not open file: $e')));
        }
      },
      title: Text(file.name),
      subtitle: Text(
        '${_formatSize(file.size)} • ${file.modified.toString().split('.').first}',
      ),
      leading: const Icon(Icons.insert_drive_file), // File icon
      trailing: IconButton(
        icon: const Icon(Icons.folder_open), // Folder icon
        onPressed: () async {
          // Open folder where file is located
          final directoryUri = Uri.file(
            file.path.replaceAll(RegExp(r'[^/\\]+$'), ''), // Remove file name
          );
          try {
            await launchUrl(directoryUri);
          } catch (e) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Could not open folder: $e')),
            );
          }
        },
      ),
    );
  }


// page lastly shows when no duplicate is found
  Widget _buildNoDuplicatesFoundMessage(BuildContext context, ScanState state) {
  if (state.status == ScanStatus.completed && state.duplicateGroups.isEmpty) {
    return SliverFillRemaining(
      hasScrollBody: false,
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.check_circle_outline, size: 64, color: Colors.green),
            const SizedBox(height: 16),
            Text(
              'No duplicate files found!',
              style: Theme.of(context).textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  return const SliverToBoxAdapter(child: SizedBox.shrink()); // Renders nothing
}
}