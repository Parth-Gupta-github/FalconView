import 'package:flutter_test/flutter_test.dart';

import 'package:falconview/main.dart';

void main() {
  testWidgets('FalconView boots to map screen', (WidgetTester tester) async {
    await tester.pumpWidget(const FalconViewApp());
    await tester.pump();

    expect(find.text('Search any city or district…'), findsOneWidget);
    expect(find.text('MARK'), findsOneWidget);
    expect(find.text('TRACK'), findsOneWidget);
    expect(find.text('RULER'), findsOneWidget);
    expect(find.text('CLR'), findsOneWidget);
  });
}
