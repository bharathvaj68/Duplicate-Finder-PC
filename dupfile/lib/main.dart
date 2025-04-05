import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:crypto/crypto.dart';

void main() {
  runApp(MyApp());
}

class MyApp extends StatelessWidget {
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
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (context) => HomeScreen()),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.blueAccent,
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.folder, size: 100, color: Colors.white),
            SizedBox(height: 20),
            Text(
              'Duplicate File Checker',
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class HomeScreen extends StatefulWidget {
  @override
  _HomeScreenState createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  Map<String, List<String>> _fileChecksums = {};
  Map<String, List<String>> _duplicateFiles = {};
  bool _isCheckingDuplicates = false;
  bool _isCollectingChecksums = false;
  int _filesProcessed = 0;
  int _directoriesProcessed = 0;

  Future<void> _selectDirectoryToCheckDuplicates() async {
    String? directory = await FilePicker.platform.getDirectoryPath();
    if (directory != null) {
      await _processDirectory(directory);
      _findDuplicateFiles();
    }
  }

  Future<void> _processDirectory(String directoryPath) async {
    setState(() {
      _isCollectingChecksums = true;
      _filesProcessed = 0;
      _directoriesProcessed = 0;
    });

    Directory dir = Directory(directoryPath);
    try {
      await for (var entity in dir.list(recursive: true, followLinks: false)) {
        if (entity is File) {
          try {
            String checksum = await _calculateChecksum(entity);
            _fileChecksums.putIfAbsent(checksum, () => []).add(entity.path);
            _filesProcessed++;
          } catch (e) {
            print("Error reading file: \${entity.path}");
          }
        } else if (entity is Directory) {
          _directoriesProcessed++;
        }
      }
    } catch (e) {
      print("Error processing directory: \$e");
    }

    setState(() {
      _isCollectingChecksums = false;
    });
  }

  Future<String> _calculateChecksum(File file) async {
    try {
      var input = await file.readAsBytes();
      return sha256.convert(input).toString();
    } catch (e) {
      return "";
    }
  }

  void _findDuplicateFiles() {
    setState(() {
      _duplicateFiles.clear();
      _fileChecksums.forEach((checksum, paths) {
        if (paths.length > 1) {
          _duplicateFiles[checksum] = paths;
        }
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Duplicate File Checker')),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            ElevatedButton(
              onPressed:
                  _isCheckingDuplicates || _isCollectingChecksums
                      ? null
                      : _selectDirectoryToCheckDuplicates,
              child: Text('Select Directory to Find Duplicates'),
            ),
            SizedBox(height: 20),
            _isCollectingChecksums
                ? Column(
                  children: [
                    CircularProgressIndicator(),
                    SizedBox(height: 10),
                    Text(
                      "Processing... Files: \$_filesProcessed | Directories: \$_directoriesProcessed",
                      style: TextStyle(color: Colors.blue),
                    ),
                  ],
                )
                : _duplicateFiles.isEmpty
                ? Text(
                  "No duplicates found.",
                  style: TextStyle(color: Colors.green),
                )
                : Expanded(
                  child: ListView(
                    children:
                        _duplicateFiles.entries.expand((entry) {
                          return entry.value.map(
                            (path) => ListTile(
                              title: Text(path),
                              subtitle: Text('Checksum: ${entry.key}'),
                            ),
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
