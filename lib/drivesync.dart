import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'globals.dart';
import 'secstore.dart';

class KeyTitanSync extends StatefulWidget {
  const KeyTitanSync({Key? key, required this.title, required this.navigatorKey})
      : super(key: key);

  final String title;
  final GlobalKey<NavigatorState> navigatorKey;

  @override
  State<KeyTitanSync> createState() => _KeyTitanSyncState();
}

class _KeyTitanSyncState extends State<KeyTitanSync> {
  bool _isAuthenticating = false;
  bool _isAuthenticated = false;
  bool _isUploading = false;
  
  List<File> _localFiles = [];
  final _pathController = TextEditingController();
  final _googleDrive = GoogleDrive();

  @override
  void dispose() {
    _pathController.dispose();
    super.dispose();
  }

  /// Handles Google OAuth2 Authentication via secstore logic
  Future<void> _handleAuthentication() async {
    setState(() => _isAuthenticating = true);
    try {
      // Logic from secstore.dart to get an authenticated client
      final client = await _googleDrive.getHttpClient();
      if (client != null) {
        setState(() {
          _isAuthenticated = true;
          _isAuthenticating = false;
        });
      }
    } catch (e) {
      debugPrint('Auth Error: $e');
      setState(() => _isAuthenticating = false);
      _showSnackBar('Authentication failed. Please try again.');
    }
  }

  /// Scans the selected directory for .ktn (KeyTitan) files
  Future<void> _pickDirectory() async {
    String? selectedPath = await FilePicker.platform.getDirectoryPath();
    
    if (selectedPath != null) {
      final dir = Directory(selectedPath);
      final List<FileSystemEntity> entities = await dir.list().toList();
      
      setState(() {
        _pathController.text = selectedPath;
        _localFiles = entities
            .whereType<File>()
            .where((file) => p.extension(file.path) == '.ktn')
            .toList();
      });
    }
  }

  /// Uploads the discovered files to the 'KeyTitanBackup' folder in Drive
  Future<void> _handleUpload() async {
    if (_localFiles.isEmpty) {
      _showSnackBar('No vault files found to upload.');
      return;
    }

    setState(() => _isUploading = true);
    try {
      for (var file in _localFiles) {
        await _googleDrive.uploadFileToGoogleDrive(file);
      }
      _showSnackBar('Successfully backed up ${_localFiles.length} files!');
    } catch (e) {
      debugPrint('Upload Error: $e');
      _showSnackBar('Upload failed. Check your connection.');
    } finally {
      setState(() => _isUploading = false);
    }
  }

  void _showSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: genTitanAppBar(widget.title),
      backgroundColor: Constants.backColor,
      bottomSheet: bottomBar(context),
      body: Container(
        padding: const EdgeInsets.all(24.0),
        decoration: Constants.backgroundDecoration,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildStepCard(
              step: "1",
              title: "Authenticate",
              child: _isAuthenticating 
                ? const Center(child: CircularProgressIndicator())
                : ElevatedButton.icon(
                    onPressed: _isAuthenticated ? null : _handleAuthentication,
                    icon: Icon(_isAuthenticated ? Icons.check_circle : Icons.login),
                    label: Text(_isAuthenticated ? "Authenticated" : "Sign in to Google"),
                  ),
            ),
            const SizedBox(height: 20),
            _buildStepCard(
              step: "2",
              title: "Select Local Vaults",
              child: Column(
                children: [
                  TextField(
                    controller: _pathController,
                    readOnly: true,
                    style: const TextStyle(color: Colors.white70, fontSize: 12),
                    decoration: InputDecoration(
                      hintText: "No directory selected",
                      suffixIcon: IconButton(
                        icon: const Icon(Icons.folder_open),
                        onPressed: _pickDirectory,
                      ),
                    ),
                  ),
                  if (_localFiles.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: Text("${_localFiles.length} vault(s) found", 
                        style: const TextStyle(color: Colors.greenAccent)),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            _buildStepCard(
              step: "3",
              title: "Cloud Backup",
              child: _isUploading
                ? const Center(child: CircularProgressIndicator())
                : ElevatedButton.icon(
                    onPressed: (_isAuthenticated && _localFiles.isNotEmpty) ? _handleUpload : null,
                    icon: const Icon(Icons.cloud_upload),
                    label: const Text("Upload to Drive"),
                    style: ElevatedButton.styleFrom(backgroundColor: Colors.blueGrey.shade800),
                  ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStepCard({required String step, required String title, required Widget child}) {
    return Card(
      color: Constants.cardColor,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text("STEP $step: $title", 
              style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white54, fontSize: 12)),
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }
}