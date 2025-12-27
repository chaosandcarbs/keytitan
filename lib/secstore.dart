import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:keytitan/env.dart';
import 'package:keytitan/globals.dart';
import 'passwords.dart' show keyTitanPass;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:googleapis_auth/auth_io.dart';
import 'package:googleapis/drive/v3.dart' as ga;
import 'package:path/path.dart' as p;
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

// --- SECURE STORAGE WRAPPER ---
class SecureStorage {
  final _storage = const FlutterSecureStorage();
  final _key = "google_drive_credentials";

  Future<void> saveCredentials(AccessCredentials credentials) async { 
    final data = {
      'accessToken': {
        'data': credentials.accessToken.data,
        'expiry': credentials.accessToken.expiry.toIso8601String(),
        'type': credentials.accessToken.type,
      },
      'refreshToken': credentials.refreshToken,
      'idToken': credentials.idToken,
      'scopes': credentials.scopes,
    };
    await _storage.write(key: _key, value: jsonEncode(data));
  }

  Future<AccessCredentials?> getCredentials() async {
    final jsonString = await _storage.read(key: _key);
    if (jsonString == null) return null;

    final Map<String, dynamic> data = jsonDecode(jsonString);
    final Map<String, dynamic> tokenData = data['accessToken'];
    
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

  Future<void> clear() async {
    await _storage.delete(key: _key);
  }
}

// --- GOOGLE DRIVE LOGIC ---
class GoogleDrive {
  final storage = SecureStorage();
  
  static String kt = 'KeyTitan${Complexity.luda.getAlphabet()}';
  static final _clientId = keyTitanPass.hdecrypt(kt, Env.clientId);
  static final _clientSecret = keyTitanPass.hdecrypt(kt, Env.clientSecret);
  final _scopes = [ga.DriveApi.driveFileScope, ga.DriveApi.driveMetadataReadonlyScope];

  /// Returns an authenticated client. Refreshes token automatically if possible.
  Future<http.Client?> getHttpClient() async {
    final credentials = await storage.getCredentials();
    if (credentials == null) return await _authenticateUser();

    final id = ClientId(_clientId, _clientSecret);
    
    // autoRefreshingClient handles the "1-hour expiry" problem for you
    final client = autoRefreshingClient(id, credentials, http.Client());
    
    // Listen for credential updates and save them back to storage
    client.credentialUpdates.listen((newCredentials) {
      storage.saveCredentials(newCredentials);
    });
    
    return client;
  }

  Future<http.Client?> _authenticateUser() async {
    final id = ClientId(_clientId, _clientSecret);
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
      debugPrint("Authentication Error: $e");
      return null;
    }
  }

  /// 1. LIST: Finds .pass and .ktn files in the 'KeyTitanBackup' folder
  Future<List<ga.File>> listDriveFiles() async {
    final client = await getHttpClient();
    if (client == null) return [];

    var driveApi = ga.DriveApi(client);
    String? folderId = await _getOrCreateFolderId(driveApi);
    if (folderId == null) return [];

    // Query filters for: parent folder, not trashed, and specific extensions
    final query = "'$folderId' in parents and trashed = false and (name contains '.pass' or name contains '.ktn')";
    
    var response = await driveApi.files.list(q: query, $fields: "files(id, name, size, modifiedTime)");
    return response.files ?? [];
  }

  /// 2. UPLOAD: Local file -> Google Drive
  Future<void> uploadFileToGoogleDrive(File file) async {
    final client = await getHttpClient();
    if (client == null) return;

    final ext = p.extension(file.path).toLowerCase();
    if (ext != '.pass' && ext != '.ktn') {
      debugPrint("Upload rejected: $ext is not a valid KeyTitan extension.");
      return;
    }

    var driveApi = ga.DriveApi(client);
    String? folderId = await _getOrCreateFolderId(driveApi);

    if (folderId != null) {
      ga.File fileMetadata = ga.File()
        ..parents = [folderId]
        ..name = p.basename(file.path);

      await driveApi.files.create(
        fileMetadata,
        uploadMedia: ga.Media(file.openRead(), file.lengthSync()),
      );
      debugPrint("Successfully uploaded ${fileMetadata.name} to Drive.");
    }
  }

  /// 3. DOWNLOAD: Google Drive -> Local storage path
  Future<File?> downloadFileFromDrive(String fileId, String fileName, String localDirPath) async {
    final client = await getHttpClient();
    if (client == null) return null;

    var driveApi = ga.DriveApi(client);
    
    // Retrieve the file content as a stream
    ga.Media media = await driveApi.files.get(
      fileId, 
      downloadOptions: ga.DownloadOptions.fullMedia
    ) as ga.Media;
    
    final savePath = p.join(localDirPath, fileName);
    final file = File(savePath);

    // Write stream to file (efficient for memory)
    final IOSink sink = file.openWrite();
    await sink.addStream(media.stream);
    await sink.close();

    debugPrint("File downloaded locally to: $savePath");
    return file;
  }

  Future<String?> _getOrCreateFolderId(ga.DriveApi driveApi) async {
    const folderName = "KeyTitanBackup";
    const mimeType = "application/vnd.google-apps.folder";

    try {
      final found = await driveApi.files.list(
        q: "name = '$folderName' and mimeType = '$mimeType' and trashed = false",
        $fields: "files(id, name)",
      );

      if (found.files != null && found.files!.isNotEmpty) {
        return found.files!.first.id;
      }

      ga.File folder = ga.File()
        ..name = folderName
        ..mimeType = mimeType;

      final folderCreation = await driveApi.files.create(folder);
      return folderCreation.id;
    } catch (e) {
      debugPrint("Folder Error: $e");
      return null;
    }
  }
}