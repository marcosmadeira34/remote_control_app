// remote_analytics.dart
//
// Instrumentação para decidir qual modo vira o padrão. A pergunta não é
// "quantos toques cada modo recebe" — o modo radial vai perder no volume por
// construção, já que um arrasto substitui vários toques. As perguntas que
// importam:
//
//   1. Quem começou no modo X ainda usa o app no dia 7?
//   2. Quem começou no modo X trocou de modo na primeira sessão? (abandono)
//   3. Quanto tempo passa entre conectar e o primeiro comando? (a tela vazia
//      trava alguém?)
//   4. Onde o pareamento falha, e quanto ele demora?
//
// Nada aqui grava por comando: em sessão de TV isso são centenas de eventos
// por minuto e a conta do analytics explode sem responder nada. A sessão
// inteira vira um evento agregado no fim.

import 'dart:async';

enum RemoteMode { radial, dpad, touchpad }

enum ModeSwitchSource { manual, firstRun, restored }

abstract interface class RemoteAnalytics {
  Future<void> pairingCompleted({
    required Duration elapsed,
    required bool neededApproval,
    required bool wasReconnect,
  });

  Future<void> pairingFailed({required String reason});

  Future<void> modeSelected({
    required RemoteMode mode,
    required ModeSwitchSource source,
    required RemoteMode? previous,
  });

  Future<void> sessionEnded({
    required RemoteMode mode,
    required Duration duration,
    required int commands,
    required Duration? timeToFirstCommand,
    required int modeSwitches,
    required int rejections,
    required bool sawCoach,
  });
}

class NoopRemoteAnalytics implements RemoteAnalytics {
  const NoopRemoteAnalytics();

  @override
  Future<void> pairingCompleted({
    required Duration elapsed,
    required bool neededApproval,
    required bool wasReconnect,
  }) async {}

  @override
  Future<void> pairingFailed({required String reason}) async {}

  @override
  Future<void> modeSelected({
    required RemoteMode mode,
    required ModeSwitchSource source,
    required RemoteMode? previous,
  }) async {}

  @override
  Future<void> sessionEnded({
    required RemoteMode mode,
    required Duration duration,
    required int commands,
    required Duration? timeToFirstCommand,
    required int modeSwitches,
    required int rejections,
    required bool sawCoach,
  }) async {}
}

/// Acumula uma sessão de uso e emite um evento só no fim.
///
/// Uma "sessão" vai do momento em que a TV fica online até o app ir para
/// background ou a conexão cair. Sessões abaixo de `_minDuration` são
/// descartadas: abrir e fechar por engano não é sinal de nada e distorce a
/// média de todo mundo.
class SessionTracker {
  SessionTracker(this._analytics);

  final RemoteAnalytics _analytics;

  static const _minDuration = Duration(seconds: 3);

  DateTime? _startedAt;
  DateTime? _firstCommandAt;
  RemoteMode? _mode;
  int _commands = 0;
  int _switches = 0;
  int _rejections = 0;
  bool _sawCoach = false;

  bool get isRunning => _startedAt != null;

  void start(RemoteMode mode, {bool sawCoach = false}) {
    if (isRunning) return;
    _startedAt = DateTime.now();
    _firstCommandAt = null;
    _mode = mode;
    _commands = 0;
    _switches = 0;
    _rejections = 0;
    _sawCoach = sawCoach;
  }

  void recordCommand() {
    if (!isRunning) return;
    _commands++;
    _firstCommandAt ??= DateTime.now();
  }

  /// Uma recusa é comando enviado com o socket caído. Taxa alta aqui aponta
  /// problema de reconexão, não de interface — vale separar antes de culpar
  /// o modo.
  void recordRejection() {
    if (isRunning) _rejections++;
  }

  /// Troca de modo dentro da sessão. É o sinal mais forte de abandono: quem
  /// entrou no radial e foi para o direcional no meio do uso não gostou.
  void recordModeSwitch(RemoteMode to) {
    if (!isRunning) return;
    _switches++;
    _mode = to;
  }

  Future<void> end() async {
    final started = _startedAt;
    final mode = _mode;
    _startedAt = null;
    if (started == null || mode == null) return;

    final duration = DateTime.now().difference(started);
    if (duration < _minDuration) return;

    await _analytics.sessionEnded(
      mode: mode,
      duration: duration,
      commands: _commands,
      timeToFirstCommand: _firstCommandAt?.difference(started),
      modeSwitches: _switches,
      rejections: _rejections,
      sawCoach: _sawCoach,
    );
  }
}
