import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:googleapis_auth/auth_io.dart';
import 'package:googleapis/drive/v3.dart' as ga;
import 'package:path/path.dart' as p;
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

class SecureStorage {
  final storage = const FlutterSecureStorage();

  /// Saves both Access and Refresh tokens
  Future<void> saveCredentials(AccessCredentials credentials) async {
    await storage.write(key: "type", value: credentials.accessToken.type);
    await storage.write(key: "data", value: credentials.accessToken.data);
    await storage.write(key: "expiry", value: credentials.accessToken.expiry.toIso8601String());
    if (credentials.refreshToken != null) {
      await storage.write(key: "refreshToken", value: credentials.refreshToken);
    }
  }

  /// Retrieves credentials and reconstructs the AccessCredentials object
  Future<AccessCredentials?> getCredentials() async {
    var data = await storage.readAll();
    if (data.isEmpty || !data.containsKey("data")) return null;

    final token = AccessToken(
      data["type"]!,
      data["data"]!,
      DateTime.parse(data["expiry"]!),
    );

    return AccessCredentials(token, data["refreshToken"], ['https://www.googleapis.com/auth/drive.file']);
  }

  Future<void> clear() => storage.deleteAll();
}

class GoogleDrive {
  final storage = SecureStorage();
  
  // Replace these with your actual Google Cloud Console credentials
  static const _clientId = "YOUR_CLIENT_ID.apps.googleusercontent.com";
  static const _clientSecret = "YOUR_CLIENT_SECRET";
  final _scopes = [ga.DriveApi.driveFileScope, ga.DriveApi.driveMetadataReadonlyScope];

  /// Returns an authenticated HTTP client, refreshing tokens if necessary
  Future<http.Client?> getHttpClient() async {
    final credentials = await storage.getCredentials();

    if (credentials == null) {
      // Start initial Auth flow
      return await _authenticateUser();
    }

    // Wrap the client to handle automatic refreshes
    return authenticatedClient(
      http.Client(),
      credentials,
    );
  }

  Future<http.Client?> _authenticateUser() async {
    final id = ClientId(_clientId, _clientSecret);
    
    try {
      final client = await clientViaUserConsent(id, _scopes, (url) async {
        final uri = Uri.parse(url);
        if (await canLaunchUrl(uri)) {
          await launchUrl(uri, mode: LaunchMode.externalApplication);
        } else {
          throw 'Could not launch $url';
        }
      });

      // Save for future use
      await storage.saveCredentials(client.credentials);
      return client;
    } catch (e) {
      debugPrint("Authentication Error: $e");
      return null;
    }
  }

  /// Uploads a file to a specific "KeyTitanBackup" folder
  Future<void> uploadFileToGoogleDrive(File file) async {
    final client = await getHttpClient();
    if (client == null) return;

    var driveApi = ga.DriveApi(client);
    String? folderId = await _getOrCreateFolderId(driveApi);

    if (folderId != null) {
      ga.File fileToUpload = ga.File();
      fileToUpload.parents = [folderId];
      fileToUpload.name = p.basename(file.path);

      var response = await driveApi.files.create(
        fileToUpload,
        uploadMedia: ga.Media(file.openRead(), file.lengthSync()),
      );
      debugPrint("File uploaded successfully: ${response.id}");
    }
  }

  /// Finds or creates the backup folder
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

      // If not found, create it
      ga.File folder = ga.File()
        ..name = folderName
        ..mimeType = mimeType;

      final folderCreation = await driveApi.files.create(folder);
      return folderCreation.id;
    } catch (e) {
      debugPrint("Error finding/creating folder: $e");
      return null;
    }
  }
}