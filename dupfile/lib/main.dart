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
enum ScanStatus { initial, scanning, completed, error }

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

class SelectDirectoryEvent extends ScanEvent {
  final bool useQuickScan;
  final List<String> extensions;

  SelectDirectoryEvent({this.useQuickScan = true, this.extensions = const []});
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

class ScanBloc extends Bloc<ScanEvent, ScanState> {
  final FileCheckerRepository repository;

  ScanBloc(this.repository) : super(ScanState()) {
    on<SelectDirectoryEvent>(_onSelectDirectory);
    on<UpdateProgressEvent>(_onUpdateProgress);
    on<CompleteScanEvent>(_onCompleteScan);
    on<ToggleQuickScanEvent>(_onToggleQuickScan);
    on<UpdateExtensionsEvent>(_onUpdateExtensions);
  }

  Future<void> _onSelectDirectory(
    SelectDirectoryEvent event,
    Emitter<ScanState> emit,
  ) async {
    final directory = await FilePicker.platform.getDirectoryPath();
    if (directory == null) return;

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

      // Quick scan mode - first group by size
      if (state.useQuickScan && files.length > 100) {
        final sizeGroups = await repository.findDuplicatesBySize(files);

        int processed = 0;
        int duplicateCount = 0;

        // Process only potential duplicates (same size files)
        for (final entry in sizeGroups.entries) {
          final sameSize = entry.value;

          for (int i = 0; i < sameSize.length; i++) {
            if (!isClosed) {
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
        }

        final duplicates = await repository.getDuplicates();
        duplicateCount = duplicates.fold(
          0,
          (count, group) => count + group.count - 1,
        );

        add(CompleteScanEvent(duplicates));
      } else {
        // Standard full scan
        int processed = 0;
        int duplicateCount = 0;

        for (final file in files) {
          if (isClosed) break;

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

            // Check current duplicate count periodically
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
        add(CompleteScanEvent(duplicates));
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
    '.doc',
    '.docx',
    '.pdf',
    '.txt',
    '.mp3',
    '.zip',
  ];
  final List<String> _selectedExtensions = [];
  bool _showExtensionFilter = false;

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
                      _buildScanOptions(context, state),
                      if (_showExtensionFilter) ...[
                        const SizedBox(height: 16),
                        _buildExtensionFilter(context),
                      ],
                      const SizedBox(height: 24),
                      if (state.status == ScanStatus.scanning)
                        _buildScanProgress(context, state)
                      else if (state.status == ScanStatus.completed)
                        _buildResultsHeader(context, state),
                    ],
                  ),
                ),
              ),
              if (state.status == ScanStatus.completed)
                _buildResultsList(context, state)
              else if (state.status == ScanStatus.initial)
                _buildEmptyState(context),
            ],
          ),
        );
      },
    );
  }

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
                  Icons.copy_all,
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
      onPressed:
          state.status == ScanStatus.scanning
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
          ],
        ),
      ),
    );
  }

  Widget _buildResultsHeader(BuildContext context, ScanState state) {
    if (state.duplicateGroups.isEmpty) return const SizedBox.shrink();

    final totalSize = state.duplicateGroups.fold(0, (total, group) {
      // Count all files except one per group (as one needs to be kept)
      return total + group.totalSize ~/ group.count * (group.count - 1);
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
                    color: Theme.of(
                      context,
                    ).colorScheme.secondary.withOpacity(0.2),
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
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024)
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  Widget _buildResultsList(BuildContext context, ScanState state) {
    return SliverList(
      delegate: SliverChildBuilderDelegate((context, index) {
        final group = state.duplicateGroups[index];
        return _buildDuplicateGroupCard(context, group, index);
      }, childCount: state.duplicateGroups.length),
    );
  }

  Widget _buildDuplicateGroupCard(
    BuildContext context,
    DuplicateGroup group,
    int index,
  ) {
    return Padding(
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
          children:
              group.files
                  .map((file) => _buildFileListTile(context, file))
                  .toList(),
        ),
      ),
    );
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

  Widget _buildEmptyState(BuildContext context) {
    return const SliverFillRemaining(
      child: SizedBox.shrink(), // renders nothing
    );
  }
}
