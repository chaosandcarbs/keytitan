import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'globals.dart';
import 'secstore.dart';

class KeyTitanSync extends StatefulWidget {
  const KeyTitanSync({
    super.key,
    required this.title,
    required this.navigatorKey,
  });

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
  List<drive.File> _driveFiles = [];
  final _pathController = TextEditingController();
  final _googleDrive = GoogleDrive();

  @override
  void initState() {
    super.initState();
    _checkExistingAuth();
    // On Android, lock the sync folder to app-private storage immediately.
    // The system directory picker cannot navigate there, so we set it
    // programmatically and skip showing the picker entirely.
    if (Platform.isAndroid) {
      _initAppPrivateDirectory();
    }
  }

  Future<void> _initAppPrivateDirectory() async {
    final appDir = await getApplicationDocumentsDirectory();
    await _loadFilesFromDirectory(appDir.path);
  }

  @override
  void dispose() {
    _pathController.dispose();
    super.dispose();
  }

  // Silently restores an existing session if one is available.
  // On Android this checks whether google_sign_in has a cached account;
  // on desktop it checks whether credentials are stored in the keychain.
  Future<void> _checkExistingAuth() async {
    final signedIn = await _googleDrive.isSignedIn();
    if (signedIn) {
      setState(() => _isAuthenticated = true);
      _refreshDriveFiles();
    }
  }

  Future<void> _handleAuthentication() async {
    setState(() => _isAuthenticating = true);
    try {
      final client = await _googleDrive.getHttpClient();
      if (client == null) {
        // User cancelled or auth failed — do not mark as authenticated.
        setState(() => _isAuthenticating = false);
        return;
      }
      setState(() {
        _isAuthenticated = true;
        _isAuthenticating = false;
      });
      _refreshDriveFiles();
    } catch (e) {
      setState(() => _isAuthenticating = false);
      final msg = e.toString().toLowerCase();
      if (msg.contains('401') || msg.contains('unauthorized')) {
        _showSessionExpiredDialog();
      } else if (mounted) {
        _showSnackBar('Authentication failed: $e');
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
      final msg = e.toString().toLowerCase();
      if (msg.contains('401') || msg.contains('unauthorized')) {
        _showSessionExpiredDialog();
      }
    }
  }

  void _showSessionExpiredDialog() {
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Constants.dialogColor,
        title: const Text('Session Expired',
            style: TextStyle(color: Colors.redAccent)),
        content: const Text(
          'Your Google Drive session has expired or was authorised on a '
          'different device.\n\nSign out and reconnect to refresh your credentials.',
          style: TextStyle(color: Colors.white),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK', style: TextStyle(color: Colors.blue)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () {
              Navigator.pop(context);
              _handleSignOut();
            },
            child:
                const Text('Sign Out', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  Future<void> _loadFilesFromDirectory(String dirPath) async {
    final entities = await Directory(dirPath).list().toList();
    if (mounted) {
      setState(() {
        _pathController.text = dirPath;
        _localFiles = entities.whereType<File>().where((f) {
          final ext = p.extension(f.path).toLowerCase();
          return ext == '.ktn' || ext == '.pass';
        }).toList();
      });
    }
  }

  Future<void> _pickDirectory() async {
    if (Platform.isAndroid) {
      // On Android the system picker cannot navigate to app-private storage.
      // Reload from the fixed app-private directory instead.
      final appDir = await getApplicationDocumentsDirectory();
      await _loadFilesFromDirectory(appDir.path);
      return;
    }

    final selected = await FilePicker.getDirectoryPath();
    if (selected == null) return;
    await _loadFilesFromDirectory(selected);
  }

  Future<void> _deleteLocalFile(File file) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Constants.dialogColor,
        title: const Text('Delete file?',
            style: TextStyle(color: Colors.redAccent)),
        content: Text(
          'Delete "${p.basename(file.path)}" from local storage?',
          style: const TextStyle(color: Colors.white),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel', style: TextStyle(color: Colors.blue)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await file.delete();
      setState(() => _localFiles.remove(file));
    } catch (e) {
      _showSnackBar('Could not delete file: $e');
    }
  }

  Future<void> _handleSignOut() async {
    await _googleDrive.signOut();
    setState(() {
      _isAuthenticated = false;
      _driveFiles = [];
    });
    _showSnackBar(
        'Signed out. You can now reconnect with a different account.');
  }

  Future<void> _handleUpload() async {
    setState(() => _isUploading = true);
    try {
      for (final file in _localFiles) {
        await _googleDrive.uploadFileToDrive(file);
      }
      _showSnackBar('Backup complete.');
      _refreshDriveFiles();
    } catch (e) {
      _showSnackBar('Upload failed: $e');
    } finally {
      setState(() => _isUploading = false);
    }
  }

  Future<void> _handleDownload(drive.File driveFile) async {
    if (driveFile.id == null || driveFile.name == null) return;

    // On Android use app-private storage unconditionally; on desktop require
    // the user to have selected a directory first.
    final String localDir;
    if (Platform.isAndroid) {
      final appDir = await getApplicationDocumentsDirectory();
      localDir = appDir.path;
    } else {
      if (_pathController.text.isEmpty) {
        _showSnackBar('Select a local folder first (Step 2).');
        return;
      }
      localDir = _pathController.text;
    }

    _showSnackBar('Downloading ${driveFile.name}…');
    final result = await _googleDrive.downloadFileFromDrive(
      driveFile.id!,
      driveFile.name!,
      localDir,
    );
    if (result != null) {
      _showSnackBar('Downloaded to local folder.');
      await _loadFilesFromDirectory(localDir); // refresh local file list
    }
  }

  void _showSnackBar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      backgroundColor: Colors.black,
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          children: [
            _buildStepCard(
              step: '1',
              title: 'Authenticate',
              child: _isAuthenticating
                  ? const CircularProgressIndicator()
                  : Row(
                      children: [
                        Expanded(
                          child: ElevatedButton.icon(
                            onPressed:
                                _isAuthenticated ? null : _handleAuthentication,
                            icon: Icon(
                              _isAuthenticated
                                  ? Icons.check_circle
                                  : Icons.login,
                              color: Constants.lightText,
                            ),
                            label: Text(
                              _isAuthenticated
                                  ? 'Logged into Drive'
                                  : 'Connect Google Drive',
                              style:
                                  const TextStyle(color: Constants.lightText),
                            ),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: _isAuthenticated
                                  ? Colors.green.withValues(alpha: 0.5)
                                  : Constants.dialogColor,
                              padding: const EdgeInsets.all(16),
                            ),
                          ),
                        ),
                        if (_isAuthenticated) ...[
                          const SizedBox(width: 8),
                          IconButton(
                            tooltip: 'Sign Out / Switch Account',
                            icon: const Icon(Icons.logout,
                                color: Colors.redAccent),
                            onPressed: _handleSignOut,
                            style: IconButton.styleFrom(
                              backgroundColor: Constants.dialogColor,
                              padding: const EdgeInsets.all(12),
                            ),
                          ),
                        ],
                      ],
                    ),
            ),
            const SizedBox(height: 15),
            _buildStepCard(
              step: '2',
              title: 'Local Sync Folder',
              child: Column(
                children: [
                  TextField(
                    controller: _pathController,
                    readOnly: true,
                    decoration: InputDecoration(
                      hintText: Platform.isAndroid
                          ? 'App private storage'
                          : 'Pick a directory',
                      // On Android the directory is fixed to app-private
                      // storage; the picker button is not shown.
                      suffixIcon: Platform.isAndroid
                          ? null
                          : IconButton(
                              icon: const Icon(Icons.folder),
                              onPressed: _pickDirectory,
                            ),
                    ),
                  ),
                  if (_localFiles.isNotEmpty)
                    ListView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: _localFiles.length,
                      itemBuilder: (_, i) => ListTile(
                        leading: const Icon(Icons.insert_drive_file,
                            color: Colors.blueAccent),
                        title: Text(
                          p.basename(_localFiles[i].path),
                          style: const TextStyle(fontSize: 12),
                        ),
                        trailing: IconButton(
                          icon: const Icon(Icons.delete,
                              color: Colors.redAccent, size: 20),
                          tooltip: 'Delete file',
                          onPressed: () => _deleteLocalFile(_localFiles[i]),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 15),
            _buildStepCard(
              step: '3',
              title: 'Cloud Backup & Restore',
              child: Column(
                children: [
                  ElevatedButton.icon(
                    onPressed: (_isAuthenticated && _localFiles.isNotEmpty)
                        ? _handleUpload
                        : null,
                    icon: _isUploading
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.cloud_upload),
                    label: const Text('Upload All to Cloud',
                        style: TextStyle(color: Constants.lightText)),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Constants.dialogColor,
                      padding: const EdgeInsets.all(16),
                      iconColor: Constants.lightText,
                    ),
                  ),
                  const Divider(height: 30),
                  const Text(
                    'FILES IN GOOGLE DRIVE',
                    style: TextStyle(fontSize: 12, color: Constants.lightText),
                  ),
                  if (_isLoadingDrive) const CircularProgressIndicator(),
                  if (!_isLoadingDrive && _driveFiles.isEmpty)
                    const Text('No backups found on Drive',
                        style: TextStyle(color: Constants.lightText)),
                  ..._driveFiles.map((df) => ListTile(
                        dense: true,
                        title: Text(df.name ?? 'Unknown',
                            style: const TextStyle(color: Colors.white)),
                        subtitle: Text('${df.size ?? 0} bytes'),
                        trailing: IconButton(
                          icon: const Icon(Icons.download,
                              color: Colors.greenAccent),
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

  Widget _buildStepCard({
    required String step,
    required String title,
    required Widget child,
  }) {
    return Card(
      color: const Color(0xFF1A1A1A),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'STEP $step: $title',
              style: const TextStyle(fontSize: 11, color: Colors.blue),
            ),
            const SizedBox(height: 10),
            child,
          ],
        ),
      ),
    );
  }
}
