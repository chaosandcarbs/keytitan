import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'autofill.dart';
import 'globals.dart';

enum PasswordOutputMode {
  clipboard(label: 'Clipboard', storageValue: 'clipboard'),
  autofill(label: 'Autofill', storageValue: 'autofill');

  final String label;
  final String storageValue;

  const PasswordOutputMode({
    required this.label,
    required this.storageValue,
  });

  static PasswordOutputMode fromStorage(String? value) {
    return PasswordOutputMode.values.firstWhere(
      (mode) => mode.storageValue == value,
      orElse: () => PasswordOutputMode.clipboard,
    );
  }
}

class KeyTitanSettingsData {
  static const List<int> clipboardDelayOptions = [15, 30, 45, 60];
  static const List<int> autofillAttemptWindowOptions = [15, 30, 60, 300];
  static const List<int> autoLockDelayOptions = [15, 30, 60, 300, 0];

  final PasswordOutputMode outputMode;
  final bool clearClipboardAfterCopy;
  final int clipboardClearDelaySeconds;
  final bool showPlaintextOnEdit;
  final bool showAutofillUriOverrides;
  final int autofillAttemptWindowSeconds;
  final int autoLockDelaySeconds;

  const KeyTitanSettingsData({
    this.outputMode = PasswordOutputMode.clipboard,
    this.clearClipboardAfterCopy = true,
    this.clipboardClearDelaySeconds = 15,
    this.showPlaintextOnEdit = false,
    this.showAutofillUriOverrides = false,
    this.autofillAttemptWindowSeconds = 30,
    this.autoLockDelaySeconds = 30,
  });

  KeyTitanSettingsData copyWith({
    PasswordOutputMode? outputMode,
    bool? clearClipboardAfterCopy,
    int? clipboardClearDelaySeconds,
    bool? showPlaintextOnEdit,
    bool? showAutofillUriOverrides,
    int? autofillAttemptWindowSeconds,
    int? autoLockDelaySeconds,
  }) {
    return KeyTitanSettingsData(
      outputMode: outputMode ?? this.outputMode,
      clearClipboardAfterCopy:
          clearClipboardAfterCopy ?? this.clearClipboardAfterCopy,
      clipboardClearDelaySeconds:
          clipboardClearDelaySeconds ?? this.clipboardClearDelaySeconds,
      showPlaintextOnEdit: showPlaintextOnEdit ?? this.showPlaintextOnEdit,
      showAutofillUriOverrides:
          showAutofillUriOverrides ?? this.showAutofillUriOverrides,
      autofillAttemptWindowSeconds:
          autofillAttemptWindowSeconds ?? this.autofillAttemptWindowSeconds,
      autoLockDelaySeconds:
          autoLockDelaySeconds ?? this.autoLockDelaySeconds,
    );
  }

  factory KeyTitanSettingsData.fromJson(Map<String, dynamic> json) {
    final parsedDelay = json['clipboardClearDelaySeconds'];
    final parsedDelayInt = parsedDelay is int
        ? parsedDelay
        : int.tryParse(parsedDelay?.toString() ?? '');
    final parsedOutputMode = PasswordOutputMode.fromStorage(
      json['outputMode']?.toString(),
    );
    final parsedAutofillWindow = json['autofillAttemptWindowSeconds'];
    final parsedAutofillWindowInt = parsedAutofillWindow is int
        ? parsedAutofillWindow
        : int.tryParse(parsedAutofillWindow?.toString() ?? '');
    final parsedAutoLockDelay = json['autoLockDelaySeconds'];
    final parsedAutoLockDelayInt = parsedAutoLockDelay is int
        ? parsedAutoLockDelay
        : int.tryParse(parsedAutoLockDelay?.toString() ?? '');
    final migratedAutoLockDelay =
        json.containsKey('autoLockOnBackground') &&
                !json.containsKey('autoLockDelaySeconds')
            ? (json['autoLockOnBackground'] == true ? 30 : 0)
            : 30;

    return KeyTitanSettingsData(
      outputMode: _supportsAutofillMode
          ? parsedOutputMode
          : PasswordOutputMode.clipboard,
      clearClipboardAfterCopy: json.containsKey('clearClipboardAfterCopy')
          ? json['clearClipboardAfterCopy'] == true
          : true,
      clipboardClearDelaySeconds:
          clipboardDelayOptions.contains(parsedDelayInt) ? parsedDelayInt! : 15,
      showPlaintextOnEdit: json['showPlaintextOnEdit'] == true,
      showAutofillUriOverrides: json['showAutofillUriOverrides'] == true,
      autofillAttemptWindowSeconds:
          autofillAttemptWindowOptions.contains(parsedAutofillWindowInt)
              ? parsedAutofillWindowInt!
              : 30,
      autoLockDelaySeconds:
          autoLockDelayOptions.contains(parsedAutoLockDelayInt)
              ? parsedAutoLockDelayInt!
              : migratedAutoLockDelay,
    );
  }

  Map<String, dynamic> toJson() {
    final persistedOutputMode =
        _supportsAutofillMode ? outputMode : PasswordOutputMode.clipboard;
    return {
      'outputMode': persistedOutputMode.storageValue,
      'clearClipboardAfterCopy': clearClipboardAfterCopy,
      'clipboardClearDelaySeconds': clipboardClearDelaySeconds,
      'showPlaintextOnEdit': showPlaintextOnEdit,
      'showAutofillUriOverrides': showAutofillUriOverrides,
      'autofillAttemptWindowSeconds': autofillAttemptWindowSeconds,
      'autoLockDelaySeconds': autoLockDelaySeconds,
    };
  }

  static String autofillAttemptWindowLabel(int seconds) {
    switch (seconds) {
      case 15:
        return 'Once per 15s';
      case 30:
        return 'Once per 30s';
      case 60:
        return 'Once per 1m';
      case 300:
        return 'Once per 5m';
      default:
        return 'Once per ${seconds}s';
    }
  }

  static String autoLockDelayLabel(int seconds) {
    switch (seconds) {
      case 0:
        return 'Never';
      case 15:
        return '15s';
      case 30:
        return '30s';
      case 60:
        return '1m';
      case 300:
        return '5m';
      default:
        return '${seconds}s';
    }
  }
}

bool get _supportsAutofillMode => Constants.isMobile;

class KeyTitanSettingsStore {
  static const _settingsFileName = 'keytitan_settings.json';

  static Future<KeyTitanSettingsData> load() async {
    try {
      final file = await _settingsFile();
      if (!await file.exists()) return const KeyTitanSettingsData();

      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic>) {
        return const KeyTitanSettingsData();
      }
      return KeyTitanSettingsData.fromJson(decoded);
    } catch (_) {
      return const KeyTitanSettingsData();
    }
  }

  static Future<void> save(KeyTitanSettingsData settings) async {
    final file = await _settingsFile();
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode(settings.toJson()), flush: true);
  }

  static Future<File> _settingsFile() async {
    final dir = await _settingsDirectory();
    return File(p.join(dir.path, _settingsFileName));
  }

  static Future<Directory> _settingsDirectory() async {
    // Desktop settings live in config/support storage, away from vault files.
    if (Platform.isWindows) {
      final appData = Platform.environment['APPDATA'];
      if (_hasPath(appData)) return Directory(p.join(appData!, 'keytitan'));
      return _applicationSupportDirectory();
    }

    if (Platform.isLinux) {
      final xdgConfigHome = Platform.environment['XDG_CONFIG_HOME'];
      if (_hasPath(xdgConfigHome)) {
        return Directory(p.join(xdgConfigHome!, 'keytitan'));
      }

      final home = Platform.environment['HOME'];
      if (_hasPath(home)) {
        return Directory(p.join(home!, '.config', 'keytitan'));
      }
      return _applicationSupportDirectory();
    }

    // Android vaults already live in app-private documents storage.
    if (Platform.isAndroid) {
      return getApplicationDocumentsDirectory();
    }

    if (Platform.isMacOS || Platform.isIOS) {
      return _applicationSupportDirectory();
    }

    return _applicationSupportDirectory();
  }

  static Future<Directory> _applicationSupportDirectory() {
    return getApplicationSupportDirectory();
  }

  static bool _hasPath(String? value) {
    return value != null && value.trim().isNotEmpty;
  }
}

class KeyTitanSettings extends StatefulWidget {
  const KeyTitanSettings({
    super.key,
    required this.title,
    required this.navigatorKey,
  });

  final String title;
  final GlobalKey<NavigatorState> navigatorKey;

  @override
  State<KeyTitanSettings> createState() => _KeyTitanSettingsState();
}

class _KeyTitanSettingsState extends State<KeyTitanSettings> {
  KeyTitanSettingsData _settings = const KeyTitanSettingsData();
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final settings = await KeyTitanSettingsStore.load();
    await KeyTitanAutofillBridge.configure(
      enabled: settings.outputMode == PasswordOutputMode.autofill,
      attemptWindowSeconds: settings.autofillAttemptWindowSeconds,
    );
    if (!mounted) return;
    setState(() {
      _settings = settings;
      _isLoading = false;
    });
  }

  Future<void> _updateSettings(KeyTitanSettingsData settings) async {
    setState(() => _settings = settings);
    await KeyTitanSettingsStore.save(settings);
    await KeyTitanAutofillBridge.configure(
      enabled: settings.outputMode == PasswordOutputMode.autofill,
      attemptWindowSeconds: settings.autofillAttemptWindowSeconds,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: genTitanAppBar(widget.title),
      bottomSheet: bottomBar(context),
      backgroundColor: Constants.backColor,
      body: Container(
        width: double.infinity,
        decoration: Constants.backgroundDecoration,
        child: _isLoading
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.fromLTRB(20, 24, 20, 70),
                children: [
                  _buildPanel(
                    title: 'Password Output',
                    children: [
                      SegmentedButton<PasswordOutputMode>(
                        segments: PasswordOutputMode.values
                            .map(
                              (mode) => ButtonSegment(
                                value: mode,
                                enabled: _supportsAutofillMode ||
                                    mode == PasswordOutputMode.clipboard,
                                label: _buildOutputModeLabel(mode),
                                icon: Icon(
                                  mode == PasswordOutputMode.clipboard
                                      ? Icons.copy
                                      : Icons.password,
                                ),
                              ),
                            )
                            .toList(),
                        selected: {_settings.outputMode},
                        onSelectionChanged: (selection) {
                          _updateSettings(
                            _settings.copyWith(outputMode: selection.first),
                          );
                        },
                      ),
                      if (_settings.outputMode == PasswordOutputMode.autofill &&
                          _supportsAutofillMode) ...[
                        const SizedBox(height: 12),
                        DropdownButtonFormField<int>(
                          initialValue: _settings.autofillAttemptWindowSeconds,
                          decoration: const InputDecoration(
                            labelText: 'Maximum OS autofill attempts',
                          ),
                          items: KeyTitanSettingsData
                              .autofillAttemptWindowOptions
                              .map(
                                (seconds) => DropdownMenuItem(
                                  value: seconds,
                                  child: Text(
                                    KeyTitanSettingsData
                                        .autofillAttemptWindowLabel(seconds),
                                  ),
                                ),
                              )
                              .toList(),
                          onChanged: (value) {
                            if (value == null) return;
                            _updateSettings(
                              _settings.copyWith(
                                autofillAttemptWindowSeconds: value,
                              ),
                            );
                          },
                        ),
                      ],
                      if (_settings.outputMode ==
                          PasswordOutputMode.clipboard) ...[
                        SwitchListTile(
                          value: _settings.clearClipboardAfterCopy,
                          title: const Text('Clear clipboard after copy'),
                          contentPadding: EdgeInsets.zero,
                          onChanged: (value) {
                            _updateSettings(
                              _settings.copyWith(
                                clearClipboardAfterCopy: value,
                              ),
                            );
                          },
                        ),
                        DropdownButtonFormField<int>(
                          initialValue: _settings.clipboardClearDelaySeconds,
                          decoration: const InputDecoration(
                            labelText: 'Clipboard clear delay',
                          ),
                          items: KeyTitanSettingsData.clipboardDelayOptions
                              .map(
                                (seconds) => DropdownMenuItem(
                                  value: seconds,
                                  child: Text('${seconds}s'),
                                ),
                              )
                              .toList(),
                          onChanged: _settings.clearClipboardAfterCopy
                              ? (value) {
                                  if (value == null) return;
                                  _updateSettings(
                                    _settings.copyWith(
                                      clipboardClearDelaySeconds: value,
                                    ),
                                  );
                                }
                              : null,
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 16),
                  _buildPanel(
                    title: 'Security',
                    children: [
                      DropdownButtonFormField<int>(
                        initialValue: _settings.autoLockDelaySeconds,
                        decoration: const InputDecoration(
                          labelText: 'Auto-lock after background',
                        ),
                        items: KeyTitanSettingsData.autoLockDelayOptions
                            .map(
                              (seconds) => DropdownMenuItem(
                                value: seconds,
                                child: Text(
                                  KeyTitanSettingsData
                                      .autoLockDelayLabel(seconds),
                                ),
                              ),
                            )
                            .toList(),
                        onChanged: (value) {
                          if (value == null) return;
                          _updateSettings(
                            _settings.copyWith(
                              autoLockDelaySeconds: value,
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  _buildPanel(
                    title: 'Editing',
                    children: [
                      SwitchListTile(
                        value: _settings.showPlaintextOnEdit,
                        title: const Text('Show password plaintext on edit'),
                        contentPadding: EdgeInsets.zero,
                        onChanged: (value) {
                          _updateSettings(
                            _settings.copyWith(showPlaintextOnEdit: value),
                          );
                        },
                      ),
                      SwitchListTile(
                        value: _settings.showAutofillUriOverrides,
                        title: const Text('Show additional autofill URIs'),
                        contentPadding: EdgeInsets.zero,
                        onChanged: (value) {
                          _updateSettings(
                            _settings.copyWith(
                              showAutofillUriOverrides: value,
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  TextButton.icon(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.arrow_back, size: 16),
                    label: const Text('Back to Home'),
                    style:
                        TextButton.styleFrom(foregroundColor: Colors.white38),
                  ),
                ],
              ),
      ),
    );
  }

  Widget _buildPanel({
    required String title,
    required List<Widget> children,
  }) {
    return Card(
      color: Constants.dialogColor,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              title,
              style: TextStyle(
                color: Constants.lightText,
                fontSize: Constants.menuTextSize + 2,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),
            ...children,
          ],
        ),
      ),
    );
  }

  Widget _buildOutputModeLabel(PasswordOutputMode mode) {
    if (mode != PasswordOutputMode.autofill || _supportsAutofillMode) {
      return Text(mode.label);
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(mode.label),
        const Text(
          'Desktop - coming soon',
          style: TextStyle(fontSize: 10),
        ),
      ],
    );
  }
}
