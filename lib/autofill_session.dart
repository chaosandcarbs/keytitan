import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'passwords.dart';

/// Owns only this request's vault. Never borrows the main UI's unlocked key.
class AutofillVaultSession {
  passFile? _vault;
  bool _closed = false;
  Future<void> _pendingUnlock = Future<void>.value();
  Future<void>? _closing;
  passFile get vault => _vault ?? (throw StateError('Unlock the vault first.'));

  Future<bool> unlock(String path, String password) {
    final pending = _pendingUnlock.then((_) => _unlock(path, password));
    _pendingUnlock = pending.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return pending;
  }

  Future<bool> _unlock(String path, String password) async {
    if (_closed) return false;
    final candidate = passFile(path, password);
    final ok = await candidate.attemptDecrypt();
    if (!ok || _closed) {
      await candidate.dispose();
      return false;
    }
    await _vault?.dispose();
    _vault = candidate;
    return true;
  }

  Future<List<Map<String, dynamic>>> entries() async {
    final rows = <Map<String, dynamic>>[];
    for (final category in await vault.getCategories()) {
      rows.addAll(await vault.getPasswordsByCategory(category['category']));
    }
    return rows;
  }

  Future<void> ensureCurrent() async {
    if (_closed || !await vault.isCurrentOnDisk) {
      throw StateError(
        'The vault changed in another session. Close and unlock it again.',
      );
    }
  }

  Future<String> password(Map<String, dynamic> entry) async {
    await ensureCurrent();
    final String result;
    try {
      result = await vault.decryptPassword(entry['password'].toString());
    } on PasswordDecryptionException {
      throw StateError('Unable to decrypt this login.');
    }
    await ensureCurrent();
    return result;
  }

  Future<int> save(keyTitanPass entry) async {
    await ensureCurrent();
    final id = await vault.savePassword(entry);
    if (!await vault.attemptEncrypt()) {
      await close();
      throw StateError(
        'The login was not saved. The vault changed or storage is unavailable. Close and retry.',
      );
    }
    return id;
  }

  Future<void> close() {
    _closed = true;
    return _closing ??= _close();
  }

  Future<void> _close() async {
    await _pendingUnlock;
    final file = _vault;
    _vault = null;
    await file?.dispose();
  }
}

class KeyTitanAutofillApp extends StatelessWidget {
  const KeyTitanAutofillApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData(colorSchemeSeed: Colors.blueGrey, useMaterial3: true),
    home: const _AutofillScreen(),
  );
}

class _AutofillScreen extends StatefulWidget {
  const _AutofillScreen();
  @override
  State<_AutofillScreen> createState() => _AutofillScreenState();
}

class _AutofillScreenState extends State<_AutofillScreen> {
  static const channel = MethodChannel('app.keytitan/autofill_session');
  final session = AutofillVaultSession();
  final master = TextEditingController();
  final username = TextEditingController();
  final secret = TextEditingController();
  final title = TextEditingController();
  final search = TextEditingController();
  Map<String, dynamic> request = {};
  List<String> files = [];
  String? path;
  List<Map<String, dynamic>> rows = [];
  Set<String> matches = {};
  bool busy = true;
  bool unlocked = false;
  bool browseAll = false;
  bool editing = false;
  bool saved = false;
  String? error;
  Map<String, dynamic>? updating;
  int attempts = 0;
  bool _closing = false;
  Future<void>? _cleanupFuture;
  Future<void> _pendingWork = Future<void>.value();

  bool get saving => request['save'] == true;
  bool get registration => request['registration'] == true && !saving;
  String get destination => request['destination']?.toString() ?? '';
  String get binding => request['binding']?.toString() ?? '';

  @override
  void initState() {
    super.initState();
    channel.setMethodCallHandler((call) async {
      if (call.method != 'cleanup') throw MissingPluginException();
      await _cleanup();
    });
    unawaited(channel.invokeMethod<void>('ready').catchError((Object _) {}));
    unawaited(_initialize());
  }

  Future<void> _initialize() => _work(() async {
    final received = Map<String, dynamic>.from(
      await channel.invokeMapMethod('context') ?? {},
    );
    if (_closing) return;
    request = received;
    final dir = await getApplicationDocumentsDirectory();
    if (_closing) return;
    final entities = await Directory(dir.path).list().toList();
    if (_closing) return;
    files =
        entities
            .whereType<File>()
            .where((f) => f.path.toLowerCase().endsWith('.ktn'))
            .map((f) => f.path)
            .toList()
          ..sort();
    final preferred = request['vault']?.toString();
    path = files.contains(preferred) ? preferred : files.firstOrNull;
    username.text = request.remove('username')?.toString() ?? '';
    secret.text = request.remove('password')?.toString() ?? '';
    if (files.isEmpty) {
      error = 'Create or download a vault in KeyTitan first, then tap the login field again.';
    }
  });

  Future<void> _work(Future<void> Function() action) async {
    if (_closing) return;
    final completed = Completer<void>();
    _pendingWork = Future.wait<void>([_pendingWork, completed.future])
        .then((_) {});
    if (mounted) {
      setState(() {
        busy = true;
        error = null;
      });
    }
    try {
      await action();
    } on PlatformException catch (e) {
      if (mounted) {
        error = e.message ?? 'Request unavailable. Tap the field again.';
      }
    } on StateError catch (e) {
      if (mounted) error = e.message;
    } catch (_) {
      if (mounted) {
        error = 'Unable to complete this request. Close and try again.';
      }
    } finally {
      if (mounted) setState(() => busy = false);
      completed.complete();
    }
  }

  Future<void> _unlock() => _work(() async {
    final password = master.text;
    master.clear();
    if (path == null || password.isEmpty) {
      error = 'Select a vault and enter its master password.';
      return;
    }
    await channel.invokeMethod('validate');
    // Limit password guesses within the bounded request without suppressing suggestions.
    if (attempts++ > 0) {
      await Future<void>.delayed(const Duration(seconds: 2));
    }
    if (!await session.unlock(path!, password)) {
      error = 'Incorrect password or unreadable vault.';
      return;
    }
    if (!mounted) {
      await session.close();
      return;
    }
    await channel.invokeMethod('validate');
    await channel.invokeMethod('remember', {'path': path});
    await _refresh();
    unlocked = true;
    if (registration) _create();
  });

  Future<void> _refresh() async {
    rows = await session.entries();
    if (_closing) {
      rows = [];
      return;
    }
    final ids = await channel.invokeListMethod<String>('matches', {
      'entries': rows
          .map(
            (row) => {
              'id': row['id'].toString(),
              'site': row['site'],
              'uris': _uris(row),
            },
          )
          .toList(),
    });
    if (!_closing) matches = ids?.toSet() ?? {};
  }

  List<String> _uris(Map<String, dynamic> row) {
    try {
      return (jsonDecode(row['uris']?.toString() ?? '[]') as List)
          .map((e) => e.toString())
          .toList();
    } catch (_) {
      return [row['site']?.toString() ?? ''];
    }
  }

  Future<bool> _confirm(String heading, String message, String action) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(heading),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(action),
            ),
          ],
        ),
      ) ??
      false;

  Future<void> _pick(Map<String, dynamic> row) async {
    if (saving) {
      if (!matches.contains(row['id'].toString())) return;
      setState(() {
        updating = row;
        title.text = row['title']?.toString() ?? '';
        editing = true;
      });
      return;
    }
    if (!matches.contains(row['id'].toString())) {
      final confirmed = await _confirm(
        'Associate this login?',
        'Allow ${row['username']} from ${row['site']} to be filled into $destination? This adds only this exact destination.',
        'Associate and fill',
      );
      if (!confirmed || !mounted) return;
      await _work(() async {
        await channel.invokeMethod('validate');
        final password = await session.password(row);
        final entry = keyTitanPass(
          id: row['id'] as int,
          title: row['title'].toString(),
          site: row['site'].toString(),
          category: row['category'].toString(),
          username: row['username'].toString(),
          displayPassword: password,
          uris: jsonEncode({..._uris(row), binding}.toList()),
        );
        await session.save(entry);
        await _refresh();
        await _release(rows.firstWhere((r) => r['id'] == row['id']));
      });
    } else {
      await _work(() => _release(row));
    }
  }

  Future<void> _release(Map<String, dynamic> row) async {
    await channel.invokeMethod('validate');
    final password = request['needsPassword'] == true
        ? await session.password(row)
        : null;
    await channel.invokeMethod('validate');
    await session.ensureCurrent();
    final release = {
      'id': row['id'].toString(),
      'username': row['username'],
      'password': password,
      'vaultPath': session.vault.fileName,
      'vaultDigest': session.vault.diskFingerprint,
      'cleaned': true,
    };
    await _cleanup(waitForWork: false);
    await channel.invokeMethod('finish', release);
  }

  void _create() {
    setState(() {
      updating = null;
      title.text = destination;
      if (!saving) {
        username.clear();
        secret.clear();
      }
      editing = true;
    });
  }

  Future<void> _save() async {
    if (username.text.trim().isEmpty || secret.text.isEmpty) {
      setState(() => error = 'Enter a username and password.');
      return;
    }
    final ok = await _confirm(
      updating == null ? 'Save login?' : 'Update password?',
      '${username.text}\n$destination\n\n${updating == null ? 'Create a new encrypted login.' : 'Replace the selected login’s password and username.'}',
      saving ? 'Save' : 'Save and fill',
    );
    if (!ok || !mounted) return;
    await _work(() async {
      await channel.invokeMethod('validate');
      final old = updating;
      final id = await session.save(
        keyTitanPass(
          id: old?['id'] as int? ?? -1,
          title: title.text.trim().isEmpty ? destination : title.text.trim(),
          site: old?['site']?.toString() ?? binding,
          category: old?['category']?.toString() ?? 'Autofill',
          username: username.text.trim(),
          displayPassword: secret.text,
          uris: jsonEncode(
            old == null ? [binding] : {..._uris(old), binding}.toList(),
          ),
        ),
      );
      secret.clear();
      if (saving) {
        await session.close();
        saved = true;
        editing = false;
      } else {
        await _refresh();
        await _release(rows.firstWhere((row) => row['id'] == id));
      }
    });
  }

  Future<void> _cancel() async {
    final cancellation = channel.invokeMethod<void>('cancel');
    final closing = _cleanup();
    // Revoke native commit/release authority immediately, not after a pending
    // database operation finishes disposing the private vault.
    try {
      await cancellation;
    } catch (_) {}
    await closing;
  }

  Future<void> _cleanup({bool updateUi = true, bool waitForWork = true}) {
    if (!_closing) {
      _closing = true;
      for (final controller in [master, username, secret, title, search]) {
        controller.clear();
      }
      rows = [];
      matches = {};
      updating = null;
      request.clear();
      if (updateUi && mounted) setState(() => busy = true);
    }
    final closed = _cleanupFuture ??= session.close();
    return waitForWork
        ? Future.wait<void>([closed, _pendingWork]).then((_) {})
        : closed;
  }

  @override
  void dispose() {
    unawaited(_cleanup(updateUi: false));
    channel.setMethodCallHandler(null);
    for (final controller in [master, username, secret, title, search]) {
      controller.clear();
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_closing) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final filtered = rows
        .where(
          (row) =>
              !registration &&
              (browseAll || matches.contains(row['id'].toString())) &&
              '${row['title']} ${row['username']} ${row['site']}'
                  .toLowerCase()
                  .contains(search.text.toLowerCase()),
        )
        .toList();
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) unawaited(_cancel());
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('KeyTitan'),
          leading: IconButton(
            tooltip: 'Cancel',
            onPressed: busy ? null : _cancel,
            icon: const Icon(Icons.close),
          ),
        ),
        body: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Text(destination, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            if (error != null)
              Semantics(
                liveRegion: true,
                child: Text(error!, style: const TextStyle(color: Colors.red)),
              ),
            if (busy) const LinearProgressIndicator(),
            if (saved) ...[
              const Text('Login saved to your encrypted vault.'),
              FilledButton(
                onPressed: busy
                    ? null
                    : () => channel.invokeMethod('finish', {'cleaned': true}),
                child: const Text('Done'),
              ),
            ] else if (!unlocked) ...[
              const Text(
                'Unlock to choose or save a login. The vault locks when you leave. A username-only fill can continue to the password step once within 60 seconds, for this same login.',
              ),
              DropdownButtonFormField<String>(
                initialValue: path,
                items: files
                    .map(
                      (file) => DropdownMenuItem(
                        value: file,
                        child: Text(p.basename(file)),
                      ),
                    )
                    .toList(),
                onChanged: busy
                    ? null
                    : (value) => setState(() => path = value),
                decoration: const InputDecoration(labelText: 'Vault'),
              ),
              TextField(
                controller: master,
                obscureText: true,
                enableSuggestions: false,
                enableIMEPersonalizedLearning: false,
                autocorrect: false,
                autofillHints: null,
                enabled: !busy,
                decoration: const InputDecoration(labelText: 'Master password'),
                onSubmitted: (_) {
                  if (!busy) _unlock();
                },
              ),
              FilledButton(
                onPressed: busy || path == null ? null : _unlock,
                child: const Text('Unlock'),
              ),
            ] else if (editing) ...[
              Text(
                updating == null ? 'New login' : 'Update ${updating!['title']}',
              ),
              TextField(
                controller: title,
                enabled: !busy,
                decoration: const InputDecoration(labelText: 'Title'),
              ),
              TextField(
                controller: username,
                enabled: !busy,
                autocorrect: false,
                decoration: const InputDecoration(
                  labelText: 'Username / email',
                ),
              ),
              TextField(
                controller: secret,
                enabled: !busy,
                obscureText: true,
                autocorrect: false,
                enableIMEPersonalizedLearning: false,
                enableSuggestions: false,
                decoration: const InputDecoration(labelText: 'Password'),
              ),
              if (!saving)
                TextButton(
                  onPressed: busy
                      ? null
                      : () {
                          const alphabet =
                              'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!@#%+-_';
                          final random = Random.secure();
                          secret.text = List.generate(
                            24,
                            (_) => alphabet[random.nextInt(alphabet.length)],
                          ).join();
                        },
                  child: const Text('Generate password'),
                ),
              FilledButton(
                onPressed: busy ? null : _save,
                child: Text(
                  saving ? 'Review and save' : 'Review, save and fill',
                ),
              ),
              TextButton(
                onPressed: busy ? null : () => setState(() => editing = false),
                child: const Text('Back'),
              ),
            ] else ...[
              Text(
                saving
                    ? 'Save a new login or select one to update.'
                    : 'Select a login to fill into the destination above.',
              ),
              if (filtered.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 16),
                  child: Text('No login saved for this destination.'),
                ),
              if (browseAll)
                TextField(
                  controller: search,
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(
                    labelText: 'Search saved logins',
                  ),
                ),
              for (final row in filtered)
                ListTile(
                  title: Text(row['title']?.toString() ?? ''),
                  subtitle: Text('${row['username']}\n${row['site']}'),
                  isThreeLine: true,
                  enabled: !busy,
                  trailing: Icon(saving ? Icons.edit : Icons.login),
                  onTap: () => _pick(row),
                ),
              FilledButton.tonal(
                onPressed: busy ? null : _create,
                child: const Text('Create login'),
              ),
              if (!saving && !registration)
                TextButton(
                  onPressed: busy
                      ? null
                      : () => setState(() => browseAll = !browseAll),
                  child: Text(
                    browseAll
                        ? 'Show matching logins'
                        : 'Choose an existing login for this site',
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}
