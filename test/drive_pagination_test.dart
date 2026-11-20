import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:keytitan/secstore.dart';

void main() {
  test(
    'Drive listing follows pages, including empty intermediate pages',
    () async {
      final tokens = <String?>[];
      final client = MockClient((request) async {
        expect(request.headers['authorization'], isNull);
        final query = request.url.queryParameters;
        if (query['q']!.contains('mimeType')) {
          return http.Response(
            jsonEncode({
              'files': [
                {'id': 'folder'},
              ],
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        expect(query['fields'], contains('nextPageToken'));
        final token = query['pageToken'];
        tokens.add(token);
        final Object response;
        if (token == null) {
          response = {
            'nextPageToken': 'page-two',
            'files': [
              {'id': 'one', 'name': 'first.ktn'},
              {'id': 'skip', 'name': 'notes.txt'},
            ],
          };
        } else if (token == 'page-two') {
          response = {'nextPageToken': 'page-three', 'files': []};
        } else {
          expect(token, 'page-three');
          response = {
            'files': [
              {'id': 'two', 'name': 'SECOND.KTN'},
            ],
          };
        }
        return http.Response(
          jsonEncode(response),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      try {
        final files = await GoogleDrive(client: client).listDriveFiles();
        expect(tokens, [null, 'page-two', 'page-three']);
        expect(files.map((file) => file.id), ['one', 'two']);
      } finally {
        client.close();
      }
    },
  );
}
