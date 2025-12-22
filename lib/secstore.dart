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
  final storage = FlutterSecureStorage();

  //Save Credentials
  Future saveCredentials(AccessToken token, String refreshToken) async {
    debugPrint(token.expiry.toIso8601String());
    await storage.write(key: "type", value: token.type);
    await storage.write(key: "data", value: token.data);
    await storage.write(key: "expiry", value: token.expiry.toString());
    await storage.write(key: "refreshToken", value: refreshToken);
  }

  //Get Saved Credentials
  Future<Map<String, dynamic>?> getCredentials() async {
    var result = await storage.readAll();
    if (result.isEmpty) return null;
    return result;
  }

  //Clear Saved Credentials
  Future clear() {
    return storage.deleteAll();
  }
}

class GoogleDrive {
  final storage = SecureStorage();
  final List<String> _scopes = ['https://www.googleapis.com/auth/drive.metadata','https://www.googleapis.com/auth/drive.file'];

  String _getClientID() {
      if (Platform.isWindows || Platform.isLinux) {
        return '200356226298-ikvdvavc6ohgpdoovlcrobt2b6mdp4bt.apps.googleusercontent.com';
      }
      else if (Platform.isAndroid) {
        return '';
      }
      else {
        return '200356226298-8hhkd2af08crjdsvibbctsacu13ahdgr.apps.googleusercontent.com';
      }
  }

  //Get Authenticated Http Client
  Future<http.Client> getHttpClient() async {
    //Get Credentials
    var credentials = null;//await storage.getCredentials();
    if (credentials == null) {
      //Needs user authentication
      var authClient = await clientViaUserConsent(
          ClientId(_getClientID(),'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'),_scopes, (url) {
        //Open Url in Browser
        launchUrl(Uri.parse(url));
      });
      //Save Credentials
      await storage.saveCredentials(authClient.credentials.accessToken,
          authClient.credentials.refreshToken!);
      return authClient;
    } else {
      debugPrint(credentials["expiry"]);
      //Already authenticated
      return authenticatedClient(
          http.Client(),
          AccessCredentials(
              AccessToken(credentials["type"], credentials["data"],
                  DateTime.tryParse(credentials["expiry"])!),
              credentials["refreshToken"],
              _scopes));
    }
  }

// check if the directory forlder is already available in drive , if available return its id
// if not available create a folder in drive and return id
//   if not able to create id then it means user authetication has failed
  Future<String?> _getFolderId(ga.DriveApi driveApi) async {
    final mimeType = "application/vnd.google-apps.folder";
    String folderName = "personalDiaryBackup";

    try {
      final found = await driveApi.files.list(
        q: "mimeType = '$mimeType' and name = '$folderName'",
        $fields: "files(id, name)",
      );
      final files = found.files;
      if (files == null) {
        debugPrint("Sign-in first Error");
        return null;
      }

      // The folder already exists
      if (files.isNotEmpty) {
        return files.first.id;
      }

      // Create a folder
      ga.File folder = ga.File();
      folder.name = folderName;
      folder.mimeType = mimeType;
      final folderCreation = await driveApi.files.create(folder);
      debugPrint("Folder ID: ${folderCreation.id}");

      return folderCreation.id;
    } catch (e) {
      debugPrint('$e');
      return null;
    }
  }

  uploadFileToGoogleDrive(File file) async {
    var client = await getHttpClient();
    var drive = ga.DriveApi(client);
    String? folderId =  await _getFolderId(drive);
    if(folderId == null){
      debugPrint("Sign-in first Error");
    }else {
      ga.File fileToUpload = ga.File();
      fileToUpload.parents = [folderId];
      fileToUpload.name = p.basename(file.absolute.path);
      var response = await drive.files.create(
        fileToUpload,
        uploadMedia: ga.Media(file.openRead(), file.lengthSync()),
      );
      debugPrint('$response');
    }

  }
}