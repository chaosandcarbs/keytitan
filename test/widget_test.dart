import 'package:flutter_test/flutter_test.dart';

import 'package:keytitan/main.dart';

void main() {
  testWidgets('KeyTitan home screen renders primary actions',
      (WidgetTester tester) async {
    await tester.pumpWidget(const KeyTitanApp());

    expect(find.text('KeyTitan Password Manager'), findsOneWidget);
    expect(find.text('New Password File'), findsOneWidget);
    expect(find.text('Open Password File'), findsOneWidget);
    expect(find.text('Google Drive Sync'), findsOneWidget);
    expect(find.text('Settings'), findsOneWidget);
    expect(find.text('Exit KeyTitan'), findsOneWidget);
  });
}
