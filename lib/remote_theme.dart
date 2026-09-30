// remote_theme.dart
//
// Tokens da interface. A premissa de design aqui é específica: o app é usado
// no escuro, com uma mão, sem o usuário olhar muito para a tela — o olho está
// na TV. Daí as escolhas:
//
//   - superfície grafite (não preto puro: preto puro no OLED some e o usuário
//     perde a noção de onde estão os botões na periferia da visão);
//   - alvos de toque grandes (mínimo 56dp, direcional com 264dp);
//   - contraste alto nos ícones, nenhuma linha fina de 1px;
//   - uma única cor de destaque, reservada para "conectado" e para o OK.
//     Cor não decora nada aqui: ela só informa estado.

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

abstract final class RemoteTokens {
  // Base
  static const backdrop = Color(0xFF16181C);
  static const surface = Color(0xFF22252B);
  static const surfaceRaised = Color(0xFF2E323A);
  static const surfacePressed = Color(0xFF3D434E);

  // Tinta
  static const ink = Color(0xFFE8EAED);
  static const inkMuted = Color(0xFF7A8290);

  // Estado
  static const live = Color(0xFF3FB6A8);
  static const alert = Color(0xFFD9634B);

  // Métricas
  static const dpadDiameter = 264.0;
  static const dpadCenterRatio = 0.36;
  static const minTarget = 56.0;
  static const gutter = 20.0;
}

ThemeData buildRemoteTheme() {
  final base = ThemeData.dark(useMaterial3: true);
  return base.copyWith(
    scaffoldBackgroundColor: RemoteTokens.backdrop,
    colorScheme: base.colorScheme.copyWith(
      surface: RemoteTokens.surface,
      primary: RemoteTokens.live,
      onPrimary: RemoteTokens.backdrop,
      error: RemoteTokens.alert,
    ),
    textTheme: GoogleFonts.archivoTextTheme(base.textTheme).apply(
      bodyColor: RemoteTokens.ink,
      displayColor: RemoteTokens.ink,
    ),
    splashFactory: NoSplash.splashFactory,
  );
}
