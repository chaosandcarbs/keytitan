import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'globals.dart';
import 'passwords.dart';

class KeyTitanOpen extends StatefulWidget {
  const KeyTitanOpen({
    super.key,
    required this.title,
    required this.navigatorKey,
  });

  final String title;
  final GlobalKey<NavigatorState> navigatorKey;

  @override
  State<KeyTitanOpen> createState() => _KeyTitanOpenState();
}

class _KeyTitanOpenState extends State<KeyTitanOpen> {
  bool _isLoading = false;
  String? _errorMessage;

  final _passController = TextEditingController();

  @override
  void dispose() {
    _passController.dispose();
    super.dispose();
  }

  Future<void> _handleOpenFile() async {
    final appDir = await getApplicationDocumentsDirectory();

    // Android cannot browse app-private storage, so we list .ktn files there.
    final String? filePath;
    if (Platform.isAndroid) {
      filePath = await _pickFromAppStorage(appDir.path);
    } else {
      filePath = await _pickWithSystemPicker(appDir.path);
    }

    if (filePath == null) return;

    final masterPass = await _showPasswordDialog();
    _passController.clear();
    if (masterPass == null || masterPass.isEmpty) return;

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    passFile? pFile;
    try {
      pFile = passFile(filePath, masterPass);
      final ok = await pFile.attemptDecrypt();

      if (ok) {
        if (mounted) {
          Navigator.pushReplacementNamed(
            context,
            KeyTitan.passList,
            arguments: pFile,
          );
        } else {
          await pFile.dispose();
        }
      } else if (mounted) {
        await pFile.dispose();
        setState(() => _errorMessage = 'Incorrect password or corrupted file.');
      }
    } catch (e) {
      await pFile?.dispose();
      // if (mounted) setState(() => _errorMessage = 'Error: ${e.toString()}');
      if (mounted) setState(() => _errorMessage = 'Error: Unable to open file');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  /// Lists recognised password files inside app-private storage and shows a
  /// dialog so the user can pick one without needing the system file picker.
  Future<String?> _pickFromAppStorage(String dirPath) async {
    final entities = await Directory(dirPath).list().toList();
    final files = entities.whereType<File>().where((f) {
      return KeyTitanVaultFiles.hasVaultExtension(f.path);
    }).toList()
      ..sort((a, b) => p.basename(a.path).compareTo(p.basename(b.path)));

    if (!mounted) return null;

    if (files.isEmpty) {
      await showDialog(
        context: context,
        builder: (context) => AlertDialog(
          backgroundColor: Constants.dialogColor,
          title: const Text('No Files Found',
              style: TextStyle(color: Constants.lightText)),
          content: const Text(
            'No .ktn password files were found in app storage.\n\n'
            'Create a new file first, or use Drive Sync to download one.',
            style: TextStyle(color: Constants.lightText),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('OK',
                  style: TextStyle(color: Constants.lightText)),
            ),
          ],
        ),
      );
      return null;
    }

    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Constants.dialogColor,
        title: const Text('Select File',
            style: TextStyle(color: Constants.lightText)),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: files.length,
            itemBuilder: (context, index) {
              final name = p.basename(files[index].path);
              return ListTile(
                leading:
                    const Icon(Icons.lock_outline, color: Constants.lightText),
                title: Text(name,
                    style: const TextStyle(color: Constants.lightText)),
                onTap: () => Navigator.pop(context, files[index].path),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel',
                style: TextStyle(color: Constants.lightText)),
          ),
        ],
      ),
    );
  }

  /// Uses the system file picker (desktop). Returns the selected path or null.
  Future<String?> _pickWithSystemPicker(String initialDir) async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: [KeyTitanVaultFiles.pickerExtension],
      initialDirectory: initialDir,
    );
    return result?.files.single.path;
  }

  Future<String?> _showPasswordDialog() {
    _passController.clear();
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: const Text('Unlock File'),
        content: TextField(
          controller: _passController,
          autofocus: true,
          obscureText: true,
          decoration: const InputDecoration(hintText: 'Enter file password'),
          onSubmitted: (_) => Navigator.pop(context, _passController.text),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel',
                style: TextStyle(color: Constants.lightText)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, _passController.text),
            style: TextButton.styleFrom(
              foregroundColor: Constants.cardColor,
              padding: const EdgeInsets.all(16),
              backgroundColor: Colors.white,
            ),
            child: const Text('Unlock'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      resizeToAvoidBottomInset: false,
      appBar: genTitanAppBar(widget.title),
      backgroundColor: Constants.backColor,
      bottomSheet: bottomBar(context),
      body: Container(
        width: double.infinity,
        decoration: Constants.backgroundDecoration,
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            const Icon(Icons.file_open_outlined,
                size: 80, color: Constants.lightText),
            const SizedBox(height: 24),
            Text(
              'Open Existing Password File',
              style: TextStyle(
                fontSize: Constants.menuTextSize,
                color: Constants.lightText,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              'Select your .ktn KeyTitan file and enter your file password to unlock.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white54),
            ),
            const SizedBox(height: 40),
            if (_isLoading)
              const CircularProgressIndicator()
            else ...[
              TitanButton(
                label: 'Browse Files',
                icon: Icons.search,
                onPressed: _handleOpenFile,
                height: Constants.cardHeight * 0.6,
                color: Constants.cardColor,
              ),
              if (_errorMessage != null)
                Padding(
                  padding: const EdgeInsets.only(top: 20),
                  child: Text(
                    _errorMessage!,
                    textAlign: TextAlign.center,
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error),
                  ),
                ),
            ],
            const Spacer(),
            TextButton.icon(
              onPressed: () => Navigator.of(context).pop(),
              icon: const Icon(Icons.arrow_back, size: 16),
              label: const Text('Back to Home'),
              style: TextButton.styleFrom(foregroundColor: Colors.white38),
            ),
            const SizedBox(height: 60),
          ],
        ),
      ),
    );
  }
}
