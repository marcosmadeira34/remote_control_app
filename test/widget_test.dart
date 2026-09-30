// widget_test.dart
//
// Smoke test enxuto: só cobre o que não depende de platform channels
// (secure storage, shared_preferences, sockets). Testar RemoteApp inteiro
// aqui exigiria mockar todos esses canais — não vale o custo para o que este
// projeto precisa agora.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:remote_control/remote_theme.dart';

void main() {
  testWidgets('buildRemoteTheme aplica os tokens de cor esperados',
      (WidgetTester tester) async {
    final theme = buildRemoteTheme();

    expect(theme.scaffoldBackgroundColor, RemoteTokens.backdrop);
    expect(theme.colorScheme.primary, RemoteTokens.live);
    expect(theme.colorScheme.error, RemoteTokens.alert);

    await tester.pumpWidget(MaterialApp(
      theme: theme,
      home: const Scaffold(body: Text('ok')),
    ));
    expect(find.text('ok'), findsOneWidget);
  });
}
