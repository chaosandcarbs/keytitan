import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:keytitan/autofill_session.dart';

void main() {
  testWidgets(
    'native cleanup waits for pending work and rejects late secrets',
    (tester) async {
      const channel = MethodChannel('app.keytitan/autofill_session');
      const codec = StandardMethodCodec();
      final context = Completer<Map<String, dynamic>>();
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        if (call.method == 'context') return context.future;
        return null;
      });
      await tester.pumpWidget(const KeyTitanAutofillApp());
      await tester.pump();

      final reply = Completer<ByteData?>();
      tester.binding.channelBuffers.push(
        channel.name,
        codec.encodeMethodCall(const MethodCall('cleanup')),
        reply.complete,
      );
      await tester.pump();
      expect(reply.isCompleted, isFalse);

      context.complete({
        'destination': 'example.com',
        'password': 'late-secret',
      });
      await tester.pump();
      await tester.pump();
      expect(codec.decodeEnvelope((await reply.future)!), isNull);
      expect(find.byType(TextField), findsNothing);
      expect(find.text('example.com'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
