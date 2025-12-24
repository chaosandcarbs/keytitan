import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
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

  /// Handles picking the .ktn file and attempting decryption
  Future<void> _handleOpenFile() async {
    // 1. Pick the file
    FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['ktn','pass','hydra'],
    );

    if (result == null || result.files.single.path == null) return;

    final String filePath = result.files.single.path!;

    // 2. Prompt for password before attempting to open
    final String? masterPass = await _showPasswordDialog();
    if (masterPass == null || masterPass.isEmpty) return;

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      // 3. Initialize the passFile object
      final pFile = passFile(filePath, masterPass);
      
      // 4. Attempt Decryption (Salsa20)
      bool success = await pFile.attemptDecrypt();

      if (success) {
        // Navigate to the password list, passing the decrypted file object
        if (mounted) {
          Navigator.pushReplacementNamed(
            context, 
            KeyTitan.passList, 
            arguments: pFile
          );
        }
      } else {
        setState(() => _errorMessage = "Incorrect password or corrupted password file.");
      }
    } catch (e) {
      setState(() => _errorMessage = "Error: ${e.toString()}");
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  /// Dialog to collect the master password
  Future<String?> _showPasswordDialog() {
    _passController.clear();
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Unlock File'),
        content: TextField(
          controller: _passController,
          autofocus: true,
          obscureText: true,
          decoration: const InputDecoration(hintText: "Enter File Password"),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(context, _passController.text),
            style: TextButton.styleFrom(
              foregroundColor: Constants.lightText,
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
            const Icon(
              Icons.file_open_outlined,
              size: 80,
              color: Constants.lightText,
            ),
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
              'Select your .ktn KeyTitan file and enter your password to unlock.',
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
                    style: TextStyle(color: Theme.of(context).colorScheme.error),
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