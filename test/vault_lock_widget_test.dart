import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:keytitan/passlist.dart';
import 'package:keytitan/passwords.dart';

class _UnsavableVault extends passFile {
  _UnsavableVault() : super('/unused.ktn', 'master');

  final saveResult = Completer<bool>();

  @override
  Future<bool> attemptEncrypt() => saveResult.future;

  @override
  Future<bool> suspendForRecovery() async => false; // Also exercise sealing failure.

  @override
  Future<List<Map<String, dynamic>>> getCategories() async {
    if (isAccessLocked) throw VaultLockedException();
    return [
      {'id': 1, 'category': 'Private category'},
    ];
  }

  @override
  Future<List<Map<String, dynamic>>> getPasswordsByCategory(
    dynamic category,
  ) async {
    if (isAccessLocked) throw VaultLockedException();
    return [
      {
        'id': 1,
        'title': 'Private account',
        'site': '',
        'username': 'alice',
        'password': 'ciphertext',
      },
    ];
  }
}

void main() {
  testWidgets(
    'failed save and failed sealing never reveal the vault without authentication',
    (tester) async {
      final vault = _UnsavableVault();
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          onGenerateRoute: (settings) => MaterialPageRoute<void>(
            settings: RouteSettings(name: '/', arguments: vault),
            builder: (_) =>
                KeyTitanList(title: 'Vault', navigatorKey: navigator),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Private account'), findsOneWidget);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      await tester.pump(const Duration(seconds: 31));
      expect(vault.isAccessLocked, isTrue);
      // Hidden applications do not render frames. Check the first resumed UI.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(find.text('Private account'), findsNothing);
      expect(find.text('Locking Vault'), findsOneWidget);
      vault.saveResult.complete(false);
      await tester.pumpAndSettle();
      expect(find.text('Vault Locked'), findsOneWidget);
      expect(find.text('Private account'), findsNothing);
      expect(await navigator.currentState!.maybePop(), isTrue);
      await tester.pumpAndSettle();
      expect(find.text('Vault Locked'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'wrong');
      await tester.tap(find.text('Unlock pending changes'));
      await tester.pumpAndSettle();
      expect(find.text('Vault Locked'), findsOneWidget);
      expect(find.text('Private account'), findsNothing);
      expect(vault.isAccessLocked, isTrue);

      await tester.enterText(find.byType(TextField), 'master');
      await tester.tap(find.text('Unlock pending changes'));
      await tester.pumpAndSettle();
      expect(vault.isAccessLocked, isFalse);
      expect(find.text('Private account'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await vault.dispose();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    },
  );
}
