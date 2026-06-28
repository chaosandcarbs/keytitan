import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:window_manager/window_manager.dart';
import 'autofill.dart';
import 'globals.dart';
import 'passwords.dart';
import 'settings.dart';

class KeyTitanList extends StatefulWidget {
  const KeyTitanList(
      {super.key, required this.title, required this.navigatorKey});

  final String title;
  final GlobalKey<NavigatorState> navigatorKey;

  @override
  State<KeyTitanList> createState() => _KeyTitanListState();
}

class _KeyTitanListState extends State<KeyTitanList>
    with WindowListener, WidgetsBindingObserver {
  // Form controllers for the add/edit password dialog.
  final headCon = TextEditingController();
  final idCon = TextEditingController();
  final titleCon = TextEditingController();
  final siteCon = TextEditingController();
  final uriCon = TextEditingController();
  final catCon = TextEditingController();
  final userCon = TextEditingController();
  final passCon = TextEditingController();
  final complexityCon = TextEditingController();

  // Incrementing this value causes ValueListenableBuilder to rebuild the
  // category list without requiring a full setState on the outer widget.
  final ValueNotifier<int> _refreshTrigger = ValueNotifier<int>(0);

  passFile? pFile;
  bool _initialized = false;
  // Guards against saveAndClose and closeWithoutSaving running concurrently.
  // On Android, PopScope can fire while saveAndClose is in progress.
  bool _isClosing = false;
  // Set to true once pFile has been explicitly disposed so that the widget's
  // dispose() method does not double-dispose it.
  bool _pFileDisposed = false;
  KeyTitanSettingsData _settings = const KeyTitanSettingsData();
  Timer? _backgroundLockTimer;
  DateTime? _backgroundedAt;
  bool _isAutoLocking = false;

  List<TextEditingController> get _dialogControllers => [
        headCon,
        idCon,
        titleCon,
        siteCon,
        uriCon,
        catCon,
        userCon,
        passCon,
        complexityCon,
      ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Only desktop platforms support the window-close interception.
    if (!Constants.isMobile) {
      windowManager.addListener(this);
    }
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final settings = await KeyTitanSettingsStore.load();
    if (!mounted) return;
    setState(() => _settings = settings);
    unawaited(_syncAutofillCache());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _cancelBackgroundLock();
    if (!Constants.isMobile) {
      windowManager.removeListener(this);
    }
    KeyTitanAutofillBridge.setPasswordResolver(null);
    // Zero then dispose all text controllers so plaintext doesn't linger.
    _clearAllControllers();
    headCon.dispose();
    idCon.dispose();
    titleCon.dispose();
    siteCon.dispose();
    uriCon.dispose();
    catCon.dispose();
    userCon.dispose();
    passCon.dispose();
    complexityCon.dispose();
    _refreshTrigger.dispose();
    // State.dispose cannot await; save/close paths await disposal before leaving.
    if (!_pFileDisposed) {
      unawaited(pFile?.dispose());
    }
    unawaited(KeyTitanAutofillBridge.clearEntries());
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _scheduleBackgroundLock();
      return;
    }

    if (state == AppLifecycleState.resumed) {
      _lockIfBackgroundDelayElapsed();
    }
  }

  @override
  void onWindowBlur() {
    _scheduleBackgroundLock();
  }

  @override
  void onWindowMinimize() {
    _scheduleBackgroundLock();
  }

  @override
  void onWindowFocus() {
    _lockIfBackgroundDelayElapsed();
  }

  @override
  void onWindowRestore() {
    _lockIfBackgroundDelayElapsed();
  }

  void _scheduleBackgroundLock() {
    if (_settings.autoLockDelaySeconds <= 0 ||
        pFile == null ||
        _isClosing ||
        _pFileDisposed) {
      return;
    }

    _backgroundedAt ??= DateTime.now();
    _backgroundLockTimer?.cancel();
    _backgroundLockTimer = Timer(
      Duration(seconds: _settings.autoLockDelaySeconds),
      () => unawaited(_lockForBackground()),
    );
  }

  void _lockIfBackgroundDelayElapsed() {
    final backgroundedAt = _backgroundedAt;
    _cancelBackgroundLock();
    if (backgroundedAt == null ||
        _settings.autoLockDelaySeconds <= 0 ||
        pFile == null ||
        _isClosing ||
        _pFileDisposed) {
      return;
    }

    final elapsed = DateTime.now().difference(backgroundedAt);
    if (elapsed >= Duration(seconds: _settings.autoLockDelaySeconds)) {
      unawaited(_lockForBackground());
    }
  }

  void _cancelBackgroundLock() {
    _backgroundLockTimer?.cancel();
    _backgroundLockTimer = null;
    _backgroundedAt = null;
  }

  Future<void> _lockForBackground() async {
    if (_isClosing || _pFileDisposed || pFile == null) return;
    _isClosing = true;
    _cancelBackgroundLock();
    _hideSensitiveUiForLock();
    _clearAllControllers();
    KeyTitanAutofillBridge.setPasswordResolver(null);

    var saved = false;
    try {
      saved = await pFile!.attemptEncrypt();
    } catch (e) {
      debugPrint('Auto-lock save error: $e');
    }
    if (!saved) {
      debugPrint('Auto-lock closing without saving because save failed.');
    }

    try {
      await pFile?.dispose();
      _pFileDisposed = true;
      await KeyTitanAutofillBridge.clearEntries();
    } catch (e) {
      debugPrint('Auto-lock cleanup error: $e');
    }

    if (mounted) {
      widget.navigatorKey.currentState
          ?.pushNamedAndRemoveUntil(KeyTitan.home, (route) => false);
    }
  }

  void _hideSensitiveUiForLock() {
    final route = ModalRoute.of(context);
    if (mounted && route != null && !route.isCurrent) {
      Navigator.of(context, rootNavigator: true).pop();
    }
    if (mounted) {
      setState(() => _isAutoLocking = true);
    }
  }

  // Overwrites all sensitive dialog controllers with empty strings so
  // plaintext does not linger in memory any longer than necessary.
  void _clearAllControllers() {
    for (final controller in _dialogControllers) {
      controller.clear();
    }
  }

  // Called when the user clicks the native window close button on desktop.
  // Zeroes the master password and closes the in-memory DB without saving.
  @override
  void onWindowClose() async {
    if (_isClosing) {
      await windowManager.destroy();
      return;
    }
    _isClosing = true;
    _cancelBackgroundLock();
    _clearAllControllers();
    KeyTitanAutofillBridge.setPasswordResolver(null);
    try {
      await pFile?.dispose();
      _pFileDisposed = true;
      await KeyTitanAutofillBridge.clearEntries();
    } catch (e) {
      debugPrint('Window-close cleanup error: $e');
    }
    await windowManager.destroy();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_initialized) {
      final args = ModalRoute.of(context)!.settings.arguments;
      if (args is passFile) {
        pFile = args;
        _triggerRefresh();
      }
      _initialized = true;
    }
  }

  void _triggerRefresh() {
    _refreshTrigger.value++;
    unawaited(_syncAutofillCache());
  }

  Future<void> _syncAutofillCache() async {
    if (!Constants.isMobile) return;

    final file = pFile;
    if (file == null || _settings.outputMode != PasswordOutputMode.autofill) {
      KeyTitanAutofillBridge.setPasswordResolver(null);
      await KeyTitanAutofillBridge.clearEntries();
      return;
    }

    KeyTitanAutofillBridge.setPasswordResolver(_resolveAutofillPassword);
    final entries = <Map<String, Object?>>[];
    final categories = await file.getCategories();
    for (final category in categories) {
      final rows = await file.getPasswordsByCategory(category['category']);
      for (final row in rows) {
        final site = row['site']?.toString() ?? '';
        entries.add({
          'id': row['id']?.toString() ?? '',
          'title': row['title']?.toString() ?? '',
          'site': site,
          'username': row['username']?.toString() ?? '',
          'uris': _autofillUris(row['uris']?.toString() ?? '', site),
        });
      }
    }

    await KeyTitanAutofillBridge.updateEntries(
      entries: entries,
      attemptWindowSeconds: _settings.autofillAttemptWindowSeconds,
    );
  }

  Future<String?> _resolveAutofillPassword(String entryId) async {
    final file = pFile;
    if (file == null || _settings.outputMode != PasswordOutputMode.autofill) {
      return null;
    }

    final id = int.tryParse(entryId);
    if (id == null) return null;

    final row = await file.getPasswordById(id);
    final ciphertext = row?['password']?.toString();
    if (ciphertext == null || ciphertext.isEmpty) return null;

    final plaintext =
        await keyTitanPass.hdecrypt(file.passwordBytes, ciphertext);
    if (plaintext == keyTitanPass.decryptionError) return null;
    return plaintext;
  }

  List<String> _autofillUris(String storedUris, String site) {
    try {
      final decoded = jsonDecode(storedUris);
      if (decoded is List) {
        return decoded.map((value) => value.toString()).toList();
      }
    } catch (_) {}

    final derived = jsonDecode(keyTitanPass.deriveUris(site));
    if (derived is List) {
      return derived.map((value) => value.toString()).toList();
    }
    return [];
  }

  // ---------------------------------------------------------------------------
  // CRUD helpers
  // ---------------------------------------------------------------------------

  Future<void> _createPassword() async {
    await pFile!.savePassword(_passwordFromControllers(id: -1));
    // Zero the password field immediately after the encrypted copy is written.
    passCon.text = '';
    _triggerRefresh();
    if (mounted) Navigator.of(context, rootNavigator: true).pop();
  }

  Future<void> _updatePassword() async {
    await pFile!
        .savePassword(_passwordFromControllers(id: int.parse(idCon.text)));
    // Zero the password field immediately after the encrypted copy is written.
    passCon.text = '';
    _triggerRefresh();
    if (mounted) Navigator.of(context, rootNavigator: true).pop();
  }

  keyTitanPass _passwordFromControllers({required int id}) {
    return keyTitanPass(
      id: id,
      title: titleCon.text,
      site: siteCon.text,
      uris: uriCon.text,
      category: catCon.text,
      username: userCon.text,
      displayPassword: passCon.text,
    );
  }

  Future<void> _deletePassword(int id) async {
    await pFile!.deletePassword(id);
    _triggerRefresh();
    if (mounted) Navigator.of(context, rootNavigator: true).pop();
  }

  Future<void> saveAndClose() async {
    if (_isClosing) return;
    _isClosing = true;
    _cancelBackgroundLock();
    // Zero dialog fields before the encrypt+dispose steps.
    _clearAllControllers();
    KeyTitanAutofillBridge.setPasswordResolver(null);
    bool saved = false;
    try {
      saved = await pFile!.attemptEncrypt();
    } catch (e) {
      debugPrint('Save error: $e');
    }
    if (!saved) {
      _isClosing = false;
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Save failed. Your vault is still open.'),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
      unawaited(_syncAutofillCache());
      return;
    }
    // Dispose after encrypting - the in-memory DB and password bytes are no
    // longer needed. Mark the flag so the widget dispose() doesn't double-free.
    try {
      await pFile?.dispose();
      _pFileDisposed = true;
      await KeyTitanAutofillBridge.clearEntries();
    } catch (e) {
      debugPrint('Save cleanup error: $e');
    }
    if (mounted) {
      widget.navigatorKey.currentState!
          .pushNamedAndRemoveUntil(KeyTitan.home, (route) => false);
    }
  }

  Future<void> closeWithoutSaving() async {
    if (_isClosing) return;
    _isClosing = true;
    _cancelBackgroundLock();
    _clearAllControllers();
    KeyTitanAutofillBridge.setPasswordResolver(null);
    try {
      await pFile?.dispose();
      _pFileDisposed = true;
      await KeyTitanAutofillBridge.clearEntries();
    } catch (e) {
      debugPrint('Close cleanup error: $e');
    }
    if (mounted) {
      widget.navigatorKey.currentState!
          .pushNamedAndRemoveUntil(KeyTitan.home, (route) => false);
    }
  }

  // ---------------------------------------------------------------------------
  // Dialogs
  // ---------------------------------------------------------------------------

  void _showDeleteDialog(String title, int id) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Confirm Delete'),
        content: Text('Are you sure you want to delete "$title"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => _deletePassword(id),
            child: const Text('Delete', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  Future<void> _showChangeVaultPasswordDialog() async {
    final currentCon = TextEditingController();
    final newCon = TextEditingController();
    final verifyCon = TextEditingController();
    final formKey = GlobalKey<FormState>();
    final pageContext = context;
    var isSaving = false;

    try {
      await showDialog(
        context: pageContext,
        barrierDismissible: false,
        builder: (dialogContext) => StatefulBuilder(
          builder: (dialogContext, setDialogState) {
            return AlertDialog(
              scrollable: true,
              backgroundColor: Constants.dialogColor,
              title: const Text('Change Vault Password'),
              content: Form(
                key: formKey,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextFormField(
                      controller: currentCon,
                      autofocus: true,
                      obscureText: true,
                      decoration: const InputDecoration(
                        labelText: 'Current vault password',
                      ),
                      validator: (value) => value == null || value.isEmpty
                          ? 'Current password is required'
                          : null,
                    ),
                    const SizedBox(height: 14),
                    TextFormField(
                      controller: newCon,
                      obscureText: true,
                      decoration: const InputDecoration(
                        labelText: 'New vault password',
                      ),
                      validator: (value) => value == null || value.isEmpty
                          ? 'New password is required'
                          : null,
                    ),
                    const SizedBox(height: 14),
                    TextFormField(
                      controller: verifyCon,
                      obscureText: true,
                      decoration: const InputDecoration(
                        labelText: 'Confirm new password',
                      ),
                      validator: (value) {
                        if (value == null || value.isEmpty) {
                          return 'Confirm the new password';
                        }
                        if (value != newCon.text) {
                          return 'Passwords do not match';
                        }
                        return null;
                      },
                    ),
                    if (isSaving) ...[
                      const SizedBox(height: 20),
                      const CircularProgressIndicator(),
                    ],
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed:
                      isSaving ? null : () => Navigator.pop(dialogContext),
                  child: const Text('Cancel'),
                ),
                ElevatedButton.icon(
                  icon: const Icon(Icons.key),
                  label: const Text('Change'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.white,
                    foregroundColor: Constants.cardColor,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 18,
                      vertical: 14,
                    ),
                  ),
                  onPressed: isSaving
                      ? null
                      : () async {
                          if (!formKey.currentState!.validate()) return;
                          setDialogState(() => isSaving = true);
                          final navigator = Navigator.of(dialogContext);
                          final messenger = ScaffoldMessenger.of(pageContext);

                          final changed = await pFile!.changeMasterPassword(
                            currentPassword: currentCon.text,
                            newPassword: newCon.text,
                          );

                          if (!mounted) return;
                          if (changed) {
                            navigator.pop();
                            messenger.showSnackBar(
                              const SnackBar(
                                content:
                                    Text('Vault password changed and saved.'),
                              ),
                            );
                          } else {
                            setDialogState(() => isSaving = false);
                            messenger.showSnackBar(
                              const SnackBar(
                                content: Text(
                                  'Could not change vault password.',
                                ),
                                backgroundColor: Colors.redAccent,
                              ),
                            );
                          }
                        },
                ),
              ],
            );
          },
        ),
      );
    } finally {
      currentCon.clear();
      newCon.clear();
      verifyCon.clear();
      // Let the dialog reverse animation finish before disposing controllers.
      await Future<void>.delayed(const Duration(milliseconds: 250));
      currentCon.dispose();
      newCon.dispose();
      verifyCon.dispose();
    }
  }

  // Shows the add/edit dialog and zeros all sensitive controllers when it
  // closes, regardless of whether the user submitted or cancelled.
  Future<void> _showPasswordDialog({bool edit = false}) async {
    headCon.text = edit ? 'Edit Password Info' : 'Enter New Password Info';

    final formKey = GlobalKey<FormState>();
    final complexityOptions = Complexity.values
        .map((c) => DropdownMenuEntry(value: c.value, label: c.text))
        .toList();

    int passLength = Constants.defaultPassLength;

    // Pre-populate the category drop-down with existing categories.
    final List<DropdownMenuEntry<dynamic>> categoryOptions = [
      const DropdownMenuEntry<dynamic>(value: 0, label: ''),
    ];
    final existing = await pFile!.getCategories();
    for (final cat in existing) {
      categoryOptions.add(
        DropdownMenuEntry(value: cat['id'], label: cat['category']),
      );
    }

    if (!edit || idCon.text.isEmpty) {
      idCon.text = '0';
      titleCon.text = '';
      siteCon.text = '';
      catCon.text = '';
      userCon.text = '';
      passCon.text = '';
    }

    if (!mounted) return;

    try {
      await showDialog(
        context: context,
        builder: (context) => AlertDialog(
          contentPadding: const EdgeInsets.all(10),
          scrollable: true,
          backgroundColor: Constants.dialogColor,
          titlePadding: const EdgeInsets.all(10),
          insetPadding: const EdgeInsets.all(10),
          title: TextFormField(
            controller: headCon,
            enabled: false,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 20,
              color: Constants.lightText,
            ),
          ),
          content: StatefulBuilder(
            builder: (context, setDialogState) {
              final media = MediaQuery.of(context);
              final maxHeight =
                  media.size.height * (Constants.isMobile ? 0.66 : 0.74);
              final maxDialogWidth =
                  media.size.width * (Constants.isMobile ? 0.86 : 0.8);
              final dialogWidth = maxDialogWidth > 520 ? 520.0 : maxDialogWidth;
              const gap = SizedBox(height: 14);

              return Form(
                key: formKey,
                child: SizedBox(
                  width: dialogWidth,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxHeight: maxHeight),
                    child: SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          TextFormField(
                            controller: titleCon,
                            decoration: const InputDecoration(
                              hintText: 'Title For Entry',
                              label: Text('Title'),
                            ),
                            validator: (v) => (v == null || v.isEmpty)
                                ? 'Title is required'
                                : null,
                          ),
                          gap,
                          TextFormField(
                            controller: siteCon,
                            decoration: const InputDecoration(
                              hintText: 'Site or App Name',
                              label: Text('Site Name'),
                            ),
                            validator: (v) => (v == null || v.isEmpty)
                                ? 'Site is required'
                                : null,
                          ),
                          if (_settings.showAutofillUriOverrides) ...[
                            gap,
                            TextFormField(
                              controller: uriCon,
                              minLines: 1,
                              maxLines: 3,
                              decoration: const InputDecoration(
                                hintText:
                                    'Optional: extra autofill URIs, androidapp://...',
                                label: Text('Autofill URIs'),
                              ),
                            ),
                          ],
                          gap,
                          _buildCategoryInputs(categoryOptions, dialogWidth),
                          gap,
                          TextFormField(
                            controller: userCon,
                            decoration: const InputDecoration(
                              hintText: 'Username',
                              label: Text('Username'),
                            ),
                            validator: (v) => (v == null || v.isEmpty)
                                ? 'Username is required'
                                : null,
                          ),
                          gap,
                          TextFormField(
                            controller: passCon,
                            obscureText:
                                !(edit && _settings.showPlaintextOnEdit),
                            decoration: const InputDecoration(
                              hintText: 'Enter or generate a password',
                              label: Text('Password'),
                              suffixIcon: Tooltip(
                                message:
                                    'Use the slider and complexity selector below to generate a random password.',
                                triggerMode: TooltipTriggerMode.tap,
                                showDuration: Duration(seconds: 5),
                                child: Icon(Icons.info_outline),
                              ),
                            ),
                            validator: (v) => (v == null || v.isEmpty)
                                ? 'Password is required'
                                : null,
                          ),
                          gap,
                          _buildComplexityPicker(
                            complexityOptions,
                            dialogWidth,
                          ),
                          SliderTheme(
                            data: const SliderThemeData(
                              showValueIndicator:
                                  ShowValueIndicator.onlyForDiscrete,
                            ),
                            child: Slider(
                              value: passLength.toDouble(),
                              label: 'Length: $passLength',
                              min: Constants.minPassLength.toDouble(),
                              max: Constants.maxPassLength.toDouble(),
                              divisions: Constants.maxPassLength -
                                  Constants.minPassLength,
                              thumbColor: Colors.white,
                              activeColor: Constants.lightText,
                              onChanged: (value) {
                                setDialogState(() {
                                  passLength = value.toInt();
                                  passCon.text = keyTitanPass.genPassword(
                                    Complexity.getComplexity(
                                      complexityCon.text,
                                    ),
                                    passLength,
                                  );
                                });
                              },
                            ),
                          ),
                          const SizedBox(height: 10),
                          Align(
                            child: ElevatedButton(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.white,
                                foregroundColor: Constants.cardColor,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 20,
                                  vertical: 16,
                                ),
                              ),
                              onPressed: () {
                                if (formKey.currentState!.validate()) {
                                  edit ? _updatePassword() : _createPassword();
                                }
                              },
                              child: Text(edit ? 'Update!' : 'Create!'),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      );
    } finally {
      // Zero all sensitive fields when the dialog closes - whether via submit,
      // cancel, back gesture, or any other dismissal path.
      _clearAllControllers();
    }
  }

  Widget _buildCategoryInputs(
    List<DropdownMenuEntry<dynamic>> categoryOptions,
    double dialogWidth,
  ) {
    final categoryWidth =
        Constants.isMobile ? dialogWidth : (dialogWidth - 44) * 0.54;
    final categoryDropdown =
        _buildCategoryDropdown(categoryOptions, categoryWidth);
    final newCategoryField = TextFormField(
      controller: catCon,
      decoration: const InputDecoration(
        hintText: 'New Category',
        label: Text('New Category'),
      ),
    );

    if (Constants.isMobile) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          categoryDropdown,
          const SizedBox(height: 12),
          newCategoryField,
        ],
      );
    }

    // Category: pick an existing one or type a new one.
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(flex: 5, child: categoryDropdown),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 8),
          child: Text('OR'),
        ),
        Expanded(flex: 4, child: newCategoryField),
      ],
    );
  }

  Widget _buildCategoryDropdown(
    List<DropdownMenuEntry<dynamic>> categoryOptions,
    double width,
  ) {
    return DropdownMenu<dynamic>(
      dropdownMenuEntries: categoryOptions,
      hintText: 'Category',
      label: const Text('Select Category'),
      width: width,
      controller: catCon,
    );
  }

  Widget _buildComplexityPicker(
    List<DropdownMenuEntry<int>> complexityOptions,
    double dialogWidth,
  ) {
    final dropdownWidth = dialogWidth - 48;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: SizedBox(
            width: dropdownWidth,
            child: DropdownMenu<int>(
              dropdownMenuEntries: complexityOptions,
              initialSelection: Complexity.basic.value,
              label: const Text('Password Complexity'),
              width: dropdownWidth,
              controller: complexityCon,
            ),
          ),
        ),
        const SizedBox(width: 8),
        const Tooltip(
          message:
              'Use the highest complexity your site allows.\nLudicrous mode: all printable ASCII characters.',
          triggerMode: TooltipTriggerMode.tap,
          showDuration: Duration(seconds: 5),
          child: Icon(Icons.info_outline),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    if (_isAutoLocking) {
      return _buildLockingState();
    }

    if (pFile == null) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    // PopScope handles the back gesture / button on Android and iOS.
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (!didPop) await closeWithoutSaving();
      },
      child: ValueListenableBuilder(
        valueListenable: _refreshTrigger,
        builder: (context, _, __) {
          return FutureBuilder<List<Map<String, dynamic>>>(
            future: pFile!.getCategories(),
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Scaffold(
                    body: Center(child: CircularProgressIndicator()));
              }

              final categories = snapshot.data ?? [];
              if (categories.isEmpty) return _buildEmptyState();

              return DefaultTabController(
                length: categories.length,
                child: Scaffold(
                  resizeToAvoidBottomInset: false,
                  appBar: AppBar(
                    leading: Image.asset(
                      'assets/keytitan_nobkg.png',
                      fit: BoxFit.contain,
                      alignment: Alignment.centerRight,
                    ),
                    title: Text(
                      'Manage Passwords',
                      style: TextStyle(
                        fontSize: Constants.titleTextSize.toDouble(),
                        fontWeight: FontWeight.w300,
                        letterSpacing: 1.2,
                      ),
                    ),
                    centerTitle: true,
                    elevation: 4,
                    bottom: TabBar(
                      isScrollable: true,
                      tabAlignment: TabAlignment.center,
                      tabs: categories
                          .map((c) => Tab(text: c['category']))
                          .toList(),
                      unselectedLabelColor: Constants.lightText,
                      labelColor: Colors.white,
                      labelPadding: const EdgeInsets.symmetric(
                          horizontal: 15.0, vertical: 7.0),
                    ),
                  ),
                  bottomNavigationBar: _buildBottomNav(),
                  body: TabBarView(
                    children: categories.map((cat) {
                      return _CategoryListView(
                        category: cat['category'],
                        pFile: pFile!,
                        settings: _settings,
                        onEdit: (data) async {
                          final messenger = ScaffoldMessenger.of(context);
                          // Decrypt the password only at the moment the edit
                          // button is pressed, then populate the dialog.
                          final decryptedPass = await keyTitanPass.hdecrypt(
                            pFile!.passwordBytes,
                            data['password'] as String,
                          );
                          if (!mounted) return;
                          if (decryptedPass == keyTitanPass.decryptionError) {
                            messenger.showSnackBar(
                              const SnackBar(
                                content: Text('Could not decrypt password'),
                                backgroundColor: Colors.redAccent,
                              ),
                            );
                            return;
                          }
                          idCon.text = data['id'].toString();
                          titleCon.text = data['title'] as String;
                          siteCon.text = (data['site'] ?? '') as String;
                          uriCon.text = keyTitanPass
                              .displayUris((data['uris'] ?? '').toString());
                          catCon.text = cat['category'] as String;
                          userCon.text = (data['username'] ?? '') as String;
                          passCon.text = decryptedPass;
                          _showPasswordDialog(edit: true);
                        },
                        onDelete: (title, id) => _showDeleteDialog(title, id),
                      );
                    }).toList(),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }

  Widget _buildBottomNav() {
    return BottomAppBar(
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          IconButton(
            icon: const Icon(Icons.add),
            color: Colors.green,
            tooltip: 'Add New Password',
            iconSize: Constants.footerButtonSize,
            onPressed: () => _showPasswordDialog(),
          ),
          IconButton(
            icon: const Icon(Icons.key),
            color: Colors.amberAccent,
            tooltip: 'Change Vault Password',
            iconSize: Constants.footerButtonSize,
            onPressed: _showChangeVaultPasswordDialog,
          ),
          IconButton(
            icon: const Icon(Icons.save),
            color: Colors.blueAccent,
            tooltip: 'Save & Close',
            iconSize: Constants.footerButtonSize,
            onPressed: saveAndClose,
          ),
          IconButton(
            icon: const Icon(Icons.logout),
            color: Colors.redAccent,
            tooltip: 'Close without saving',
            iconSize: Constants.footerButtonSize,
            onPressed: closeWithoutSaving,
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    return Scaffold(
      resizeToAvoidBottomInset: false,
      appBar: AppBar(title: Text(widget.title)),
      bottomNavigationBar: _buildBottomNav(),
      body: Container(
        decoration: Constants.backgroundDecoration,
        child: const Center(
          child: Text(
            'Add Your First Password!\nTap the + button below.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w300),
          ),
        ),
      ),
    );
  }

  Widget _buildLockingState() {
    return Scaffold(
      appBar: genTitanAppBar('Locking Vault'),
      backgroundColor: Constants.backColor,
      body: Container(
        width: double.infinity,
        decoration: Constants.backgroundDecoration,
        child: const Center(child: CircularProgressIndicator()),
      ),
    );
  }
}

// Displays the password list for a single category tab.
// Passwords stored in the DB are always encrypted (ChaCha20-Poly1305 via hencrypt).
// Decryption happens only at the instant of user action (copy or edit) -
// never eagerly during list construction.
class _CategoryListView extends StatelessWidget {
  final String category;
  final passFile pFile;
  final KeyTitanSettingsData settings;

  /// Called when the user taps Edit. Receives the raw DB row (password field
  /// is still the encrypted ciphertext string).
  final Future<void> Function(Map<String, dynamic>) onEdit;
  final Function(String, int) onDelete;

  const _CategoryListView({
    required this.category,
    required this.pFile,
    required this.settings,
    required this.onEdit,
    required this.onDelete,
  });

  Future<void> _launchInBrowser(String rawUrl) async {
    final url = rawUrl.startsWith('http') ? rawUrl : 'https://$rawUrl';
    final uri = Uri.parse(url);
    if (uri.host.isEmpty || !uri.host.contains('.')) return;
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  Future<void> _clearClipboardLater(String copiedText) async {
    await Future.delayed(
      Duration(seconds: settings.clipboardClearDelaySeconds),
    );
    final current = await Clipboard.getData('text/plain');
    if (current?.text == copiedText) {
      await Clipboard.setData(const ClipboardData(text: ''));
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<Map<String, dynamic>>>(
      future: pFile.getPasswordsByCategory(category),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }

        final passwords = snapshot.data!;
        return Container(
          width: double.infinity,
          decoration: Constants.backgroundDecoration,
          child: ListView.builder(
            padding: const EdgeInsets.all(12.0),
            itemCount: passwords.length,
            itemBuilder: (context, index) {
              final item = passwords[index];

              // Only title and username are displayed in the card.
              // The password ciphertext (item['password']) is never decrypted
              // here - decryption happens inside the action callbacks below.
              return Card(
                margin: const EdgeInsets.only(bottom: 12),
                clipBehavior: Clip.antiAlias,
                child: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(16.0),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  item['title'],
                                  style: const TextStyle(
                                      fontSize: 18,
                                      fontWeight: FontWeight.bold),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  item['username'] ?? '',
                                  style: const TextStyle(
                                      color: Constants.lightText),
                                ),
                              ],
                            ),
                          ),
                          if (!Constants.isMobile)
                            _buildActionRow(context, item),
                        ],
                      ),
                    ),
                    if (Constants.isMobile)
                      Container(
                        color: Colors.black12,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: _buildActionRow(context, item, expanded: true),
                      ),
                  ],
                ),
              );
            },
          ),
        );
      },
    );
  }

  Widget _buildActionRow(
    BuildContext context,
    Map<String, dynamic> item, {
    bool expanded = false,
  }) {
    final hasSite = item['site']?.toString().isNotEmpty ?? false;

    final actions = [
      IconButton(
        tooltip: 'Open Site',
        icon: Icon(Icons.link, color: hasSite ? Colors.blue : Colors.grey),
        iconSize: Constants.cardIconSize,
        onPressed:
            hasSite ? () => _launchInBrowser(item['site'].toString()) : null,
      ),
      IconButton(
        tooltip: 'Copy Password',
        icon: const Icon(Icons.copy),
        iconSize: Constants.cardIconSize,
        onPressed: () async {
          final messenger = ScaffoldMessenger.of(context);
          // Decrypt only at the moment the copy button is pressed.
          // The plaintext exists only for the duration of this callback.
          final plaintext = await keyTitanPass.hdecrypt(
            pFile.passwordBytes,
            item['password'] as String,
          );
          if (plaintext == keyTitanPass.decryptionError) {
            messenger.showSnackBar(
              const SnackBar(
                content: Text('Could not decrypt password'),
                backgroundColor: Colors.redAccent,
              ),
            );
            return;
          }
          await Clipboard.setData(ClipboardData(text: plaintext));
          if (settings.clearClipboardAfterCopy) {
            unawaited(_clearClipboardLater(plaintext));
          }
          messenger.showSnackBar(
            const SnackBar(content: Text('Password copied to clipboard')),
          );
        },
      ),
      IconButton(
        tooltip: 'Edit Entry',
        icon: const Icon(Icons.edit, color: Colors.orangeAccent),
        iconSize: Constants.cardIconSize,
        onPressed: () async => await onEdit(item),
      ),
      IconButton(
        tooltip: 'Delete Entry',
        icon: const Icon(Icons.delete, color: Colors.red),
        iconSize: Constants.cardIconSize,
        onPressed: () => onDelete(item['title'], item['id']),
      ),
    ];

    return Row(
      mainAxisAlignment:
          expanded ? MainAxisAlignment.spaceAround : MainAxisAlignment.end,
      mainAxisSize: expanded ? MainAxisSize.max : MainAxisSize.min,
      children: actions,
    );
  }
}
