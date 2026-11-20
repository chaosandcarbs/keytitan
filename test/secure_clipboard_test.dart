import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:keytitan/secure_clipboard.dart';

void main() {
  testWidgets('owned clipboard content expires', (tester) async {
    String? text;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          text = (call.arguments as Map)['text'];
        }
        if (call.method == 'Clipboard.getData') return {'text': text};
        return null;
      },
    );
    await SensitiveClipboard.copy(
      'synthetic-password',
      clearAfter: const Duration(seconds: 15),
    );
    await tester.pump(const Duration(seconds: 15));
    expect(text, '');
  });

  testWidgets('expiry preserves text copied by another application', (
    tester,
  ) async {
    String? text;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          text = (call.arguments as Map)['text'];
        }
        if (call.method == 'Clipboard.getData') return {'text': text};
        return null;
      },
    );
    await SensitiveClipboard.copy(
      'synthetic-password',
      clearAfter: const Duration(seconds: 15),
    );
    text = 'another application';
    await tester.pump(const Duration(seconds: 15));
    expect(text, 'another application');
  });

  testWidgets('a new copy replaces the old expiry', (tester) async {
    String? text;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          text = (call.arguments as Map)['text'];
        }
        if (call.method == 'Clipboard.getData') return {'text': text};
        return null;
      },
    );
    await SensitiveClipboard.copy(
      'first',
      clearAfter: const Duration(seconds: 15),
    );
    await tester.pump(const Duration(seconds: 10));
    await SensitiveClipboard.copy(
      'second',
      clearAfter: const Duration(seconds: 15),
    );
    await tester.pump(const Duration(seconds: 5));
    expect(text, 'second');
    await tester.pump(const Duration(seconds: 10));
    expect(text, '');
  });
}
