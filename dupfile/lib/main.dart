import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:file_picker/file_picker.dart';
import 'package:crypto/crypto.dart';

void main() {
  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Duplicate File Checker',
      theme: ThemeData(primarySwatch: Colors.blue),
      home: SplashScreen(),
    );
  }
}

class SplashScreen extends StatefulWidget {
  @override
  _SplashScreenState createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  @override
  void initState() {
    super.initState();
    Timer(Duration(seconds: 3), () {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => HomeScreen()),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
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

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  _HomeScreenState createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  String? _checkDuplicatesDirectory;
  bool _isProcessing = false;
  bool _shouldStop = false;
  int _filesProcessed = 0;
  final List<String> _directoriesBeingScanned = [];

  final Map<String, List<String>> _fileChecksums = {};
  final Map<String, List<String>> _duplicateFiles = {};

  Future<String> _calculateChecksum(File file) async {
    final input = file.openRead();
    final digest = await sha256.bind(input).first;
    return digest.toString();
  }

  Future<void> _saveChecksumsToJson() async {
    final file = File('checksums.json');
    final encoder = JsonEncoder.withIndent('  ');
    final jsonContent = encoder.convert(_fileChecksums);
    await file.writeAsString(jsonContent);
  }

  Future<void> _findDuplicateFiles(String directoryPath) async {
    setState(() {
      _isProcessing = true;
      _shouldStop = false;
      _filesProcessed = 0;
      _fileChecksums.clear();
      _duplicateFiles.clear();
      _directoriesBeingScanned.clear();
    });

    final dir = Directory(directoryPath);
    int localFileCount = 0;
    try {
      await for (var entity in dir.list(recursive: true, followLinks: false)) {
        if (_shouldStop) break;

        if (entity is File) {
          try {
            String parentDir = entity.parent.path;
            setState(() {
              _directoriesBeingScanned.insert(0, parentDir);
              if (_directoriesBeingScanned.length > 5) {
                _directoriesBeingScanned.removeLast();
              }
            });

            String checksum = await _calculateChecksum(entity);
            _fileChecksums.putIfAbsent(checksum, () => []).add(entity.path);
            localFileCount++;

            if (localFileCount % 10 == 0) {
              setState(() {
                _filesProcessed = localFileCount;
              });
            }

            if (localFileCount % 100 == 0) {
              await _saveChecksumsToJson();
            }
          } catch (_) {
            continue;
          }
        }
      }

      await _saveChecksumsToJson();
      setState(() {
        _filesProcessed = localFileCount;
      });

      _fileChecksums.forEach((checksum, paths) {
        if (paths.length > 1) {
          _duplicateFiles[checksum] = paths;
        }
      });
    } catch (e) {
      print("Error finding duplicates: $e");
    } finally {
      setState(() {
        _isProcessing = false;
      });
    }
  }

  Future<void> _selectCheckDuplicatesDirectory() async {
    String? directory = await FilePicker.platform.getDirectoryPath();
    if (directory != null) {
      setState(() {
        _checkDuplicatesDirectory = directory;
      });
      await _findDuplicateFiles(directory);
    }
  }

  Future<void> _openFileExplorer(String filePath) async {
    final directory = File(filePath).parent.path;

    if (Platform.isWindows) {
      await Process.run('explorer', [directory]);
    } else if (Platform.isMacOS) {
      await Process.run('open', [directory]);
    } else if (Platform.isLinux) {
      await Process.run('xdg-open', [directory]);
    } else {
      print('Unsupported platform');
    }
  }

  void _stopProcessing() {
    setState(() {
      _shouldStop = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    int totalDuplicates = _duplicateFiles.values.fold(0, (sum, list) => sum + list.length);

    return Scaffold(
      appBar: AppBar(title: Text('Duplicate File Checker')),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            ElevatedButton(
              onPressed: _isProcessing ? null : _selectCheckDuplicatesDirectory,
              child: Text('Select Directory to Find Duplicates'),
            ),
            SizedBox(height: 10),
            Text(
              _checkDuplicatesDirectory != null
                  ? 'Checking in: $_checkDuplicatesDirectory'
                  : 'No directory selected',
              textAlign: TextAlign.center,
            ),
            SizedBox(height: 20),
            if (_isProcessing)
              Column(
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 10),
                  Text(
                    'Processing... (Files processed: $_filesProcessed)',
                    style: TextStyle(fontWeight: FontWeight.bold, color: Colors.blue),
                  ),
                  SizedBox(height: 10),
                  ElevatedButton(
                    onPressed: _stopProcessing,
                    child: Text('Stop'),
                  ),
                  SizedBox(height: 10),
                  Text(
                    'Recently Scanned Directories:',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  Container(
                    height: 100,
                    child: ListView(
                      children: _directoriesBeingScanned.map((dir) => Text(dir)).toList(),
                    ),
                  ),
                ],
              ),
            SizedBox(height: 20),
            if (!_isProcessing && _duplicateFiles.isNotEmpty)
              Text(
                'Total Duplicates Found: $totalDuplicates',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Colors.red),
              ),
            Expanded(
              child: _duplicateFiles.isEmpty && !_isProcessing && _checkDuplicatesDirectory != null
                  ? Center(
                      child: Text(
                        'No duplicate files found in the selected directory.',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.green),
                      ),
                    )
                  : ListView(
                      children: _duplicateFiles.entries.map((entry) {
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Checksum: ${entry.key}',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                color: Colors.green,
                              ),
                            ),
                            ...entry.value.map(
                              (filePath) => InkWell(
                                onTap: () => _openFileExplorer(filePath),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(vertical: 2.0),
                                  child: Text(
                                    ' - $filePath',
                                    style: TextStyle(
                                      color: Colors.blue,
                                      decoration: TextDecoration.underline,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            SizedBox(height: 10),
                          ],
                        );
                      }).toList(),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}