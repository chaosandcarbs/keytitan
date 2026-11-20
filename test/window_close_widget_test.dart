import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:keytitan/passlist.dart';
import 'package:keytitan/passwords.dart';
import 'package:window_manager/window_manager.dart';

class _CloseRequest extends EventRequest {
  _CloseRequest() : super.borrowed(0);

  bool cancelled = false;
  bool pending = true;

  @override
  bool cancel() => cancelled = true;
}

class _Window extends Window {
  _Window() : super.borrowed(0);

  FutureOr<void> Function(WindowEvent)? listener;
  final removedListeners = <ListenerId>[];
  int completedCloses = 0;
  int showCalls = 0;
  int focusCalls = 0;

  @override
  ListenerId addListener(FutureOr<void> Function(WindowEvent) callback) {
    listener = callback;
    return 1;
  }

  @override
  bool removeListener(ListenerId listenerId) {
    removedListeners.add(listenerId);
    listener = null;
    return true;
  }

  Future<void> requestClose(_CloseRequest request) async {
    await listener?.call(
      WindowCloseRequestedEvent(windowId: 1, request: request),
    );
    // The native backend holds the request until its async listener completes.
    request.pending = false;
    if (!request.cancelled) completedCloses++;
  }

  @override
  void show() => showCalls++;

  @override
  void focus() => focusCalls++;
}

class _Vault extends passFile {
  _Vault({this.disposalGate}) : super('/unused.ktn', 'master');

  Completer<bool> saveResult = Completer<bool>();
  final Completer<void>? disposalGate;
  int saveCalls = 0;
  int disposalCalls = 0;

  @override
  Future<bool> attemptEncrypt() {
    saveCalls++;
    return saveResult.future;
  }

  @override
  Future<List<Map<String, dynamic>>> getCategories() async => [];

  @override
  Future<void> dispose() async {
    disposalCalls++;
    await disposalGate?.future;
    await super.dispose();
  }
}

Future<void> _showVault(
  WidgetTester tester,
  _Vault vault,
  _Window window,
) async {
  final navigator = GlobalKey<NavigatorState>();
  await tester.pumpWidget(
    MaterialApp(
      navigatorKey: navigator,
      onGenerateRoute: (_) => MaterialPageRoute<void>(
        settings: RouteSettings(name: '/', arguments: vault),
        builder: (_) => KeyTitanList(
          title: 'Vault',
          navigatorKey: navigator,
          window: window,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('window close waits for saving and vault cleanup', (
    tester,
  ) async {
    final disposalGate = Completer<void>();
    final vault = _Vault(disposalGate: disposalGate);
    final window = _Window();
    await _showVault(tester, vault, window);

    final request = _CloseRequest();
    final closing = window.requestClose(request);
    expect(request.pending, isTrue);
    expect(vault.saveCalls, 1);
    expect(window.completedCloses, 0);

    final repeatedRequest = _CloseRequest();
    await window.requestClose(repeatedRequest);
    expect(repeatedRequest.cancelled, isTrue);
    expect(vault.saveCalls, 1);

    vault.saveResult.complete(true);
    await tester.pump();
    expect(vault.disposalCalls, 1);
    expect(request.pending, isTrue);
    expect(window.completedCloses, 0);

    disposalGate.complete();
    await closing;
    expect(window.completedCloses, 1);
    expect(request.pending, isFalse);
    expect(request.cancelled, isFalse);

    await tester.pumpWidget(const SizedBox.shrink());
    expect(window.removedListeners, [1]);
    expect(vault.disposalCalls, 1);
  });

  testWidgets('failed save keeps the window open and allows retry', (
    tester,
  ) async {
    final vault = _Vault();
    final window = _Window();
    await _showVault(tester, vault, window);

    final request = _CloseRequest();
    final closing = window.requestClose(request);
    vault.saveResult.complete(false);
    await closing;
    await tester.pump();
    expect(request.cancelled, isTrue);
    expect(window.completedCloses, 0);
    expect(vault.disposalCalls, 0);
    expect(window.showCalls, 1);
    expect(window.focusCalls, 1);
    expect(
      find.text('Window close cancelled because the vault could not be saved.'),
      findsOneWidget,
    );

    vault.saveResult = Completer<bool>();
    final retry = window.requestClose(_CloseRequest());
    vault.saveResult.complete(true);
    await retry;
    expect(vault.saveCalls, 2);
    expect(window.completedCloses, 1);
    expect(vault.disposalCalls, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
