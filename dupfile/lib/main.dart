import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:io';
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
  bool _isCheckingDuplicates = false;
  int _filesProcessed = 0;

  final Map<String, List<String>> _fileChecksums = {}; // Stores all file hashes
  final Map<String, List<String>> _duplicateFiles = {}; // Stores duplicates

  /// Computes SHA-256 checksum for a file
  Future<String> _calculateChecksum(File file) async {
    List<int> fileBytes = await file.readAsBytes();
    return sha256.convert(fileBytes).toString();
  }

  /// Checks for duplicate files in a selected directory
  Future<void> _findDuplicateFiles(String directoryPath) async {
    setState(() {
      _isProcessing = true;
      _filesProcessed = 0;
      _fileChecksums.clear();
      _duplicateFiles.clear();
    });

    Directory dir = Directory(directoryPath);
    try {
      List<FileSystemEntity> entities = dir.listSync(recursive: true);
      for (var entity in entities) {
        if (entity is File) {
          String checksum = await _calculateChecksum(entity);
          setState(() {
            _fileChecksums.putIfAbsent(checksum, () => []).add(entity.path);
            _filesProcessed++;
          });
        }
      }

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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Duplicate File Checker')),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // Select directory to check for duplicate files
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

            // Progress indicator for duplicate detection
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

            // Display duplicate files
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
                            ...entry.value.map((filePath) => Text(' - $filePath')),
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
