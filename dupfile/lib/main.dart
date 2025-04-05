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
      home: HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  _HomeScreenState createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  String? _checkDuplicatesDirectory; // Directory to check for duplicates

  bool _isProcessing = false;
  int _filesProcessed = 0;

  final Map<String, List<String>> _fileChecksums = {}; // Stores all file hashes
  final Map<String, List<String>> _duplicateFiles = {}; // Stores duplicates

  /// Computes SHA-256 checksum for a file
  Future<String> _calculateChecksum(File file) async {
    final input = file.openRead();
    final digest = await sha256.bind(input).first;
    return digest.toString();
  }

  /// Saves checksums to a JSON file in a structured, readable format
  Future<void> _saveChecksumsToJson() async {
    final file = File('checksums.json');
    final encoder = JsonEncoder.withIndent('  ');
    final jsonContent = encoder.convert(_fileChecksums);
    await file.writeAsString(jsonContent);
  }

  /// Checks for duplicate files in a selected directory
  Future<void> _findDuplicateFiles(String directoryPath) async {
    setState(() {
      _isProcessing = true;
      _filesProcessed = 0;
      _fileChecksums.clear();
      _duplicateFiles.clear();
    });

    final dir = Directory(directoryPath);
    try {
      await for (var entity in dir.list(recursive: true, followLinks: false)) {
        if (entity is File) {
          try {
            String checksum = await _calculateChecksum(entity);
            _fileChecksums.putIfAbsent(checksum, () => []).add(entity.path);
            _filesProcessed++;

            // To reduce memory usage, offload data periodically
            if (_filesProcessed % 100 == 0) {
              await _saveChecksumsToJson();
            }
          } catch (_) {
            continue; // Skip unreadable files
          }
        }
      }

      // Save final snapshot
      await _saveChecksumsToJson();

      // Identify duplicates
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

  /// Selects a directory to check for duplicate files
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