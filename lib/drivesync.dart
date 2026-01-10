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
  bool _isLoadingDrive = false;
  bool _isUploading = false;
  
  List<File> _localFiles = [];
  List<drive.File> _driveFiles = []; // For remote files
  final _pathController = TextEditingController();
  final _googleDrive = GoogleDrive();

  @override
  void initState() {
    super.initState();
    _checkExistingAuth();
  }

  /// Silently check if we already have credentials stored
  Future<void> _checkExistingAuth() async {
    final creds = await _googleDrive.storage.getCredentials();
    if (creds != null) {
      setState(() => _isAuthenticated = true);
      _refreshDriveFiles();
    }
  }

/*
  /// Fetches the current file list from the 'KeyTitanBackup' folder
  Future<void> _refreshDriveFiles() async {
    if (!_isAuthenticated) return;
    setState(() => _isLoadingDrive = true);
    try {
      final files = await _googleDrive.listDriveFiles();
      setState(() {
        _driveFiles = files;
        _isLoadingDrive = false;
      });
    } catch (e) {
      debugPrint('List Error: $e');
      setState(() => _isLoadingDrive = false);
    }
  }
  Future<void> _handleAuthentication() async {
    setState(() => _isAuthenticating = true);
    final client = await _googleDrive.getHttpClient();
    if (client != null) {
      setState(() {
        _isAuthenticated = true;
        _isAuthenticating = false;
      });
      _refreshDriveFiles();
    } else {
      setState(() => _isAuthenticating = false);
      _showSnackBar('Authentication failed.');
    }
  }
*/
  Future<void> _handleAuthentication() async {
    setState(() => _isAuthenticating = true);
    try {
      await _googleDrive.getHttpClient();
      setState(() {
        _isAuthenticated = true;
        _isAuthenticating = false;
      });
      _refreshDriveFiles();
    } catch (e) {
      setState(() => _isAuthenticating = false);
      
      final errorStr = e.toString().toLowerCase();
      
      // Check for 401 or Unauthorized
      if (errorStr.contains("401") || errorStr.contains("unauthorized")) {
        _showUnauthorizedError();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Authentication Failed: $e")),
        );
      }
    }
  }

  Future<void> _refreshDriveFiles() async {
    setState(() => _isLoadingDrive = true);
    try {
      final files = await _googleDrive.listDriveFiles();
      setState(() {
        _driveFiles = files;
        _isLoadingDrive = false;
      });
    } catch (e) {
      setState(() => _isLoadingDrive = false);
      if (e.toString().contains("401") || e.toString().contains("unauthorized")) {
        _showUnauthorizedError();
      }
    }
  }

  void _showUnauthorizedError() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Constants.dialogColor,
        title: const Text("Session Expired", style: TextStyle(color: Colors.redAccent)),
        content: const Text(
          "Your Google Drive session is no longer valid or was authorized on a different device.\n\n"
          "Please click 'Sign Out' and then reconnect to refresh your credentials.",
          style: TextStyle(color: Colors.white),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("OK", style: TextStyle(color: Colors.blue)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () {
              Navigator.pop(context);
              _handleSignOut(); // This is the method we added in the last step
            },
            child: const Text("Sign Out Now", style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  Future<void> _pickDirectory() async {
    String? selectedPath = await FilePicker.platform.getDirectoryPath();
    if (selectedPath != null) {
      final dir = Directory(selectedPath);
      final List<FileSystemEntity> entities = await dir.list().toList();
      setState(() {
        _pathController.text = selectedPath;
        _localFiles = entities.whereType<File>().where((file) {
          final ext = p.extension(file.path).toLowerCase();
          return ext == '.ktn' || ext == '.pass';
        }).toList();
      });
    }
  }

  Future<void> _handleSignOut() async {
    // 1. Delete the credentials from Secure Storage
    await _googleDrive.storage.clearCredentials(); 
    
    // 2. Reset UI State
    setState(() {
      _isAuthenticated = false;
      _driveFiles = [];
    });

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text("Signed out of Google Drive. You can now reconnect.")),
    );
  }

  Future<void> _handleUpload() async {
    setState(() => _isUploading = true);
    try {
      for (var file in _localFiles) {
        await _googleDrive.uploadFileToDrive(file);
      }
      _showSnackBar('Backup complete!');
      _refreshDriveFiles(); // Refresh cloud list after upload
    } catch (e) {
      _showSnackBar('Upload failed.');
    } finally {
      setState(() => _isUploading = false);
    }
  }

  Future<void> _handleDownload(drive.File driveFile) async {
    if (driveFile.id == null || driveFile.name == null) return;
    if (_pathController.text.isEmpty) {
      _showSnackBar('Please select a local directory first (Step 2).');
      return;
    }
    
    _showSnackBar('Downloading ${driveFile.name}...');
    final result = await _googleDrive.downloadFileFromDrive(
      driveFile.id!, 
      driveFile.name!, 
      _pathController.text
    );

    if (result != null) {
      _showSnackBar('Downloaded to local folder.');
      _pickDirectory(); // Refresh local list to show the new file
    }
  }

  void _showSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      backgroundColor: Colors.black, // Matching your KeyTitan theme
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          children: [
            _buildStepCard(
              step: "1",
              title: "Authenticate",
              child: _isAuthenticating 
                ? const CircularProgressIndicator()
                : Row(
                    children: [
                      Expanded(
                        child: ElevatedButton.icon(
                          // If authenticated, we disable the "Connect" action 
                          onPressed: _isAuthenticated ? null : _handleAuthentication,
                          icon: Icon(_isAuthenticated ? Icons.check_circle : Icons.login, color: Constants.lightText,),
                          label: Text(_isAuthenticated ? "Logged into Drive" : "Connect Google Drive", 
                            style: TextStyle(color: Constants.lightText,),
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: _isAuthenticated ? Colors.green.withOpacity(0.5) : Constants.dialogColor, 
                            padding: const EdgeInsets.all(16),
                          ),
                        ),
                      ),
                      if (_isAuthenticated) ...[
                        const SizedBox(width: 8),
                        IconButton(
                          tooltip: "Sign Out / Switch Account",
                          icon: const Icon(Icons.logout, color: Colors.redAccent),
                          onPressed: _handleSignOut,
                          style: IconButton.styleFrom(
                            backgroundColor: Constants.dialogColor,
                            padding: const EdgeInsets.all(12),
                          ),
                        ),
                      ]
                    ],
                  ),
            ),
            const SizedBox(height: 15),
            _buildStepCard(
              step: "2",
              title: "Local Sync Folder",
              child: Column(
                children: [
                  TextField(
                    controller: _pathController,
                    readOnly: true,
                    decoration: InputDecoration(
                      hintText: "Pick directory",
                      suffixIcon: IconButton(icon: const Icon(Icons.folder), onPressed: _pickDirectory),
                    ),
                  ),
                  if (_localFiles.isNotEmpty)
                    ListView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: _localFiles.length,
                      itemBuilder: (ctx, i) => ListTile(
                        leading: const Icon(Icons.insert_drive_file, color: Colors.blueAccent),
                        title: Text(p.basename(_localFiles[i].path), style: const TextStyle(fontSize: 12)),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 15),
            _buildStepCard(
              step: "3",
              title: "Cloud Backup & Restore",
              child: Column(
                children: [
                  ElevatedButton.icon(
                    onPressed: (_isAuthenticated && _localFiles.isNotEmpty) ? _handleUpload : null,
                    icon: _isUploading ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.cloud_upload),
                    label: const Text("Upload All to Cloud", style: TextStyle(color: Constants.lightText),),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Constants.dialogColor,
                      padding: EdgeInsets.all(16),
                      iconColor: Constants.lightText  
                    ),
                  ),
                  const Divider(height: 30),
                  const Text("FILES IN GOOGLE DRIVE", style: TextStyle(fontSize: 12 , color: Constants.lightText)),
                  if (_isLoadingDrive) const CircularProgressIndicator(),
                  if (!_isLoadingDrive && _driveFiles.isEmpty) const Text("No backups found on Drive", style: TextStyle(color: Constants.lightText)),
                  ..._driveFiles.map((df) => ListTile(
                    dense: true,
                    title: Text(df.name ?? "Unknown", style: const TextStyle(color: Colors.white)),
                    subtitle: Text("${df.size ?? '0'} bytes"),
                    trailing: IconButton(
                      icon: const Icon(Icons.download, color: Colors.greenAccent),
                      onPressed: () => _handleDownload(df),
                    ),
                  )),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStepCard({required String step, required String title, required Widget child}) {
    return Card(
      color: const Color(0xFF1A1A1A),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text("STEP $step: $title", style: const TextStyle(fontSize: 11, color: Colors.blue)),
            const SizedBox(height: 10),
            child,
          ],
        ),
      ),
    );
  }
}