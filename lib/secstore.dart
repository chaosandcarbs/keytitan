import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:keytitan/env.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:extension_google_sign_in_as_googleapis_auth/extension_google_sign_in_as_googleapis_auth.dart';
import 'package:googleapis_auth/auth_io.dart';
import 'package:googleapis/drive/v3.dart' as ga;
import 'package:path/path.dart' as p;
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';
import 'globals.dart';

// ---------------------------------------------------------------------------
// SecureStorage - persists desktop OAuth credentials across sessions.
// On mobile, google_sign_in manages its own token lifecycle via the platform
// SDK, so we only use this store for the desktop flow.
// ---------------------------------------------------------------------------
class SecureStorage {
  final _storage = const FlutterSecureStorage();
  static const _credentialsKey = 'google_drive_credentials';

  Future<void> saveCredentials(AccessCredentials creds) async {
    final data = {
      'accessToken': {
        'data': creds.accessToken.data,
        'expiry': creds.accessToken.expiry.toIso8601String(),
        'type': creds.accessToken.type,
      },
      'refreshToken': creds.refreshToken,
      'idToken': creds.idToken,
      'scopes': creds.scopes,
    };
    await _storage.write(key: _credentialsKey, value: jsonEncode(data));
  }

  Future<AccessCredentials?> getCredentials() async {
    final json = await _storage.read(key: _credentialsKey);
    if (json == null) return null;

    final data = jsonDecode(json) as Map<String, dynamic>;
    final tokenData = data['accessToken'] as Map<String, dynamic>;

    return AccessCredentials(
      AccessToken(
        tokenData['type'] ?? 'Bearer',
        tokenData['data'],
        DateTime.parse(tokenData['expiry']),
      ),
      data['refreshToken'],
      List<String>.from(data['scopes']),
      idToken: data['idToken'],
    );
  }

  Future<void> clearCredentials() async {
    await _storage.delete(key: _credentialsKey);
  }
}

// ---------------------------------------------------------------------------
// GoogleDrive - authentication, listing, uploading, and downloading
// .ktn backup files from the "KeyTitanBackup" Drive folder.
//
// Android/iOS: uses google_sign_in (Android Credential Manager / Google
//   Identity Services), which is Google's recommended approach for mobile.
//   The extension_google_sign_in_as_googleapis_auth bridge converts the
//   GoogleSignInClientAuthorization into a googleapis-compatible AuthClient.
//
// Desktop: uses googleapis_auth's clientViaUserConsent (localhost redirect
//   server), which works fine on Windows/Linux/macOS.
// ---------------------------------------------------------------------------
class GoogleDrive {
  final storage = SecureStorage();

  static final List<String> _scopes = [
    ga.DriveApi.driveFileScope,
    ga.DriveApi.driveMetadataReadonlyScope,
  ];

  // Whether google_sign_in has been initialised for this session.
  bool _gsiInitialized = false;

  // Cached authenticated client so repeated calls within a session do not
  // re-trigger the OAuth consent flow.
  http.Client? _cachedClient;
  String? _lastAuthError;

  String? get lastAuthError => _lastAuthError;

  // Initialises the google_sign_in singleton once.
  // On Android, Credential Manager requires serverClientId to be a Web
  // application type OAuth client (not Desktop). clientId is the Android
  // OAuth client so Credential Manager can match the registered app.
  // On desktop, serverClientId is the Desktop OAuth client used by the
  // localhost-redirect consent flow.
  Future<void> _ensureGsiInitialized() async {
    if (_gsiInitialized) return;
    await GoogleSignIn.instance.initialize(
      clientId: Platform.isAndroid ? Env.androidClientId : null,
      serverClientId:
          Platform.isAndroid ? Env.webClientId : Env.desktopClientId,
    );
    _gsiInitialized = true;
  }

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  // Returns an authenticated HTTP client for the current platform, or null
  // if the user cancelled or authentication failed.
  // The result is cached so subsequent calls within the same session reuse
  // the existing client and never re-trigger the OAuth consent flow.
  Future<http.Client?> getHttpClient() async {
    _lastAuthError = null;
    if (_cachedClient != null) return _cachedClient;
    if (Platform.isAndroid || Platform.isIOS) {
      _cachedClient = await _getMobileClient();
    } else {
      _cachedClient = await _getDesktopClient();
    }
    return _cachedClient;
  }

  // Signs the user out. On mobile this clears the google_sign_in session;
  // on desktop it removes the stored credentials.
  Future<void> signOut() async {
    _cachedClient?.close();
    _cachedClient = null;
    if (Platform.isAndroid || Platform.isIOS) {
      await _ensureGsiInitialized();
      await GoogleSignIn.instance.signOut();
    } else {
      await storage.clearCredentials();
    }
  }

  // Returns true if there is already a signed-in session that can be resumed
  // silently, without showing any UI.
  Future<bool> isSignedIn() async {
    if (Platform.isAndroid || Platform.isIOS) {
      await _ensureGsiInitialized();
      // attemptLightweightAuthentication returns non-null when a cached
      // session exists and never shows any UI.
      try {
        final account =
            await GoogleSignIn.instance.attemptLightweightAuthentication();
        return account != null;
      } on GoogleSignInException catch (e) {
        debugPrint('OAuth mobile lightweight auth check failed: $e');
        return false;
      }
    }
    return (await storage.getCredentials()) != null;
  }

  // ---------------------------------------------------------------------------
  // Mobile authentication - Google Identity Services via google_sign_in
  // ---------------------------------------------------------------------------

  Future<http.Client?> _getMobileClient() async {
    try {
      await _ensureGsiInitialized();
      final gsi = GoogleSignIn.instance;

      final account = await _authenticateMobileAccount(gsi);

      if (account == null) {
        _lastAuthError = 'Google sign-in was cancelled or unavailable.';
        debugPrint('OAuth mobile: user cancelled or platform unsupported');
        return null;
      }

      final authorization =
          await account.authorizationClient.authorizationForScopes(_scopes) ??
              await account.authorizationClient.authorizeScopes(_scopes);

      // The extension bridge produces a googleapis_auth-compatible AuthClient.
      return authorization.authClient(scopes: _scopes);
    } on GoogleSignInException catch (e) {
      _lastAuthError = _googleSignInErrorMessage(e);
      debugPrint('OAuth mobile error: $e');
      return null;
    } catch (e) {
      _lastAuthError = 'Google Drive authentication failed.';
      debugPrint('OAuth mobile error: $e');
      return null;
    }
  }

  Future<GoogleSignInAccount?> _authenticateMobileAccount(
    GoogleSignIn gsi,
  ) async {
    try {
      return await _authenticateMobileAccountOnce(gsi, tryLightweight: true);
    } on GoogleSignInException catch (e) {
      if (!_looksLikeCredentialReauthFailure(e)) rethrow;

      // Android Credential Manager can retain stale credential state across
      // reinstalls/signature changes. Clear it once and retry the button flow.
      debugPrint('OAuth mobile reauth failed; clearing credential state.');
      await gsi.signOut();
      return _authenticateMobileAccountOnce(gsi, tryLightweight: false);
    }
  }

  Future<GoogleSignInAccount?> _authenticateMobileAccountOnce(
    GoogleSignIn gsi, {
    required bool tryLightweight,
  }) async {
    GoogleSignInAccount? account;
    if (tryLightweight) {
      account = await gsi.attemptLightweightAuthentication(
        reportAllExceptions: true,
      );
    }

    if (account == null && gsi.supportsAuthenticate()) {
      account = await gsi.authenticate(scopeHint: _scopes);
    }

    return account;
  }

  bool _looksLikeCredentialReauthFailure(GoogleSignInException e) {
    final description = e.description?.toLowerCase() ?? '';
    return e.code == GoogleSignInExceptionCode.canceled &&
        (description.contains('reauth') || description.contains('[16]'));
  }

  String _googleSignInErrorMessage(GoogleSignInException e) {
    if (_looksLikeCredentialReauthFailure(e)) {
      return 'Google sign-in reauth failed. Verify the Android OAuth client '
          'uses package app.keytitan and the SHA-1 for this signing key.';
    }
    if (e.code == GoogleSignInExceptionCode.canceled) {
      return 'Google sign-in was cancelled. If this happened after choosing '
          'an account, check the Android OAuth package name, SHA-1, and web '
          'server client ID.';
    }
    if (e.code == GoogleSignInExceptionCode.clientConfigurationError ||
        e.code == GoogleSignInExceptionCode.providerConfigurationError) {
      return 'Google sign-in is not configured correctly. Check the Android '
          'OAuth package name, signing SHA-1, and web server client ID.';
    }
    return 'Google sign-in failed: ${e.code.name}.';
  }

  // ---------------------------------------------------------------------------
  // Desktop authentication - googleapis_auth localhost redirect server
  // ---------------------------------------------------------------------------

  Future<http.Client?> _getDesktopClient() async {
    final creds = await storage.getCredentials();
    if (creds != null) {
      final id = ClientId(Env.desktopClientId, Env.desktopClientSecret);
      final client = autoRefreshingClient(id, creds, http.Client());
      client.credentialUpdates.listen(storage.saveCredentials);
      return client;
    }
    return _authenticateDesktop();
  }

  Future<http.Client?> _authenticateDesktop() async {
    final id = ClientId(Env.desktopClientId, Env.desktopClientSecret);
    try {
      final client = await clientViaUserConsent(id, _scopes, (url) async {
        final uri = Uri.parse(url);
        if (await canLaunchUrl(uri)) {
          await launchUrl(uri, mode: LaunchMode.externalApplication);
        }
      });
      await storage.saveCredentials(client.credentials);
      return client;
    } catch (e) {
      debugPrint('OAuth desktop error: $e');
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // Drive operations
  // ---------------------------------------------------------------------------

  // Returns .ktn files in the KeyTitanBackup Drive folder.
  Future<List<ga.File>> listDriveFiles() async {
    final client = await getHttpClient();
    if (client == null) return [];

    final api = ga.DriveApi(client);
    final folderId = await _getOrCreateFolderId(api);
    if (folderId == null) return [];

    final query = "'$folderId' in parents and trashed = false "
        "and name contains '${KeyTitanVaultFiles.extension}'";

    final response = await api.files.list(
      q: query,
      $fields: 'files(id, name, size, modifiedTime)',
    );
    return (response.files ?? [])
        .where(
          (file) =>
              file.name != null &&
              KeyTitanVaultFiles.hasVaultExtension(file.name!),
        )
        .toList();
  }

  // Uploads a local file to the KeyTitanBackup folder. If a file with the
  // same name already exists in Drive it is overwritten; otherwise a new
  // entry is created.
  Future<void> uploadFileToDrive(File localFile) async {
    final client = await getHttpClient();
    if (client == null) return;

    final api = ga.DriveApi(client);
    final folderId = await _getOrCreateFolderId(api);
    if (folderId == null) return;

    final fileName = p.basename(localFile.path);
    final existing = await api.files.list(
      q: "name = '$fileName' and '$folderId' in parents and trashed = false",
      $fields: 'files(id)',
    );

    final media = ga.Media(localFile.openRead(), localFile.lengthSync());
    final driveFile = ga.File()..name = fileName;

    if (existing.files != null && existing.files!.isNotEmpty) {
      await api.files
          .update(driveFile, existing.files!.first.id!, uploadMedia: media);
    } else {
      driveFile.parents = [folderId];
      await api.files.create(driveFile, uploadMedia: media);
    }
  }

  // Downloads a Drive file to a local directory, replacing any existing local
  // copy with the same name.
  Future<File?> downloadFileFromDrive(
      String fileId, String fileName, String localDirPath) async {
    final client = await getHttpClient();
    if (client == null) return null;

    final safeFileName = _safeDriveFileName(fileName);
    if (safeFileName == null) return null;

    final api = ga.DriveApi(client);
    final media = await api.files.get(
      fileId,
      downloadOptions: ga.DownloadOptions.fullMedia,
    ) as ga.Media;

    final localRoot = p.normalize(p.absolute(localDirPath));
    final savePath = p.normalize(p.absolute(p.join(localRoot, safeFileName)));
    if (!p.isWithin(localRoot, savePath)) return null;

    final localFile = File(savePath);

    if (await localFile.exists()) {
      try {
        await localFile.delete();
      } catch (e) {
        debugPrint('Could not remove existing local file: $e');
      }
    }

    final sink = localFile.openWrite();
    try {
      await sink.addStream(media.stream);
    } catch (e) {
      debugPrint('Download stream error: $e');
      return null;
    } finally {
      await sink.close();
    }
    return localFile;
  }

  String? _safeDriveFileName(String fileName) {
    return KeyTitanVaultFiles.safeFileName(fileName);
  }

  // Finds the KeyTitanBackup folder in Drive, creating it if it doesn't exist.
  Future<String?> _getOrCreateFolderId(ga.DriveApi api) async {
    const name = 'KeyTitanBackup';
    const mimeType = 'application/vnd.google-apps.folder';
    try {
      final found = await api.files.list(
        q: "name = '$name' and mimeType = '$mimeType' and trashed = false",
        $fields: 'files(id)',
      );
      if (found.files != null && found.files!.isNotEmpty) {
        return found.files!.first.id;
      }
      final folder = ga.File()
        ..name = name
        ..mimeType = mimeType;
      final created = await api.files.create(folder);
      return created.id;
    } catch (e) {
      debugPrint('Drive folder error: $e');
      return null;
    }
  }
}
