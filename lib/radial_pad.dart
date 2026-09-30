// radial_pad.dart
//
// O controle de gesto radial foi removido (o app agora tem uma única
// superfície de controle, o keypad de botões). RadialTokens sobrevive porque
// algumas cores dele — sobretudo `bloom`, o roxo do indicador de conexão —
// ainda são usadas fora daqui e nunca foram unificadas com RemoteTokens.

import 'package:flutter/material.dart';

abstract final class RadialTokens {
  static const surface = Color(0xFF111214);
  static const well = Color(0xFF1B1D22);
  static const rail = Color(0xFF1F2126);
  static const railFill = Color(0xFF3A3C41);
  static const ink = Color(0xFFEDEEF0);
  static const inkMuted = Color(0xFF6E7176);
  static const inkFaint = Color(0xFF4E5055);

  /// Única cor cromática da interface. Só aparece sob o dedo e no status de
  /// conexão — se vazar para outro lugar, para de funcionar como sinal.
  static const bloom = Color(0xFF9B8CFF);
}
