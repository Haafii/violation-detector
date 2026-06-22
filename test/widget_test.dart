import 'package:flutter_test/flutter_test.dart';

import 'package:app_test/main.dart';

void main() {
  testWidgets('App loads', (WidgetTester tester) async {
    await tester.pumpWidget(const ViolationDetectorApp());
    expect(find.byType(ViolationDetectorApp), findsOneWidget);
  });
}
