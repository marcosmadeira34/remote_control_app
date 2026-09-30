// playback_cubit.dart
//
// Descobre qual app está em primeiro plano na TV consultando
// /api/v2/applications/<id>, onde `visible` significa "está na tela agora".
//
// O protocolo não permite listar o app em foco: só dá para perguntar sobre um
// ID por vez. Uma varredura ingênua do catálogo a cada ciclo seriam 6
// requisições a cada 3s, o que aquece o telefone e polui a rede. A estratégia
// aqui é assimétrica:
//
//   - se já sabemos qual app está visível, confirmamos só ele (1 requisição);
//   - a varredura completa roda ao perder o app conhecido, e no máximo a cada
//     `_sweepEvery` ciclos, em paralelo;
//   - o poll para quando o app vai para background ou a TV desconecta.
//
// Limite honesto: o protocolo não devolve o título do que está tocando, só o
// app. "Netflix" é tudo o que dá para afirmar sem uma integração à parte.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'remote_theme.dart';
import 'samsung_tv_client.dart';
import 'tv_repository.dart';

class KnownApp {
  const KnownApp(this.id, this.label, this.accent, this.icon,
      {this.hasPlayback = true});
  final String id;
  final String label;

  /// Cor da marca, usada com moderação: só no chip ativo e no acento do
  /// keypad, nunca espalhada pela interface (ver RemoteTokens.live).
  final Color accent;

  /// Fica no lugar do logotipo oficial: não temos os arquivos de marca
  /// licenciados para redistribuir, então o reconhecimento vem do par
  /// ícone+cor, não do logo pixel-perfect.
  final IconData icon;
  final bool hasPlayback;
}

/// IDs variam por região e firmware; estes são estáveis há anos. Confirme com
/// `SamsungTvClient.fetchInstalledApps()` antes de aumentar a lista — cada
/// entrada nova encarece a varredura.
const kKnownApps = <KnownApp>[
  KnownApp('3201907018807', 'Netflix', Color(0xFFE0483D), Icons.movie_rounded),
  KnownApp('111299001912', 'YouTube', Color(0xFFE0483D),
      Icons.play_circle_fill_rounded),
  KnownApp('3201910019365', 'Prime Video', Color(0xFF4FA8D8),
      Icons.local_movies_rounded),
  KnownApp('3201901017640', 'Disney+', Color(0xFF5C7FE0),
      Icons.auto_awesome_rounded),
  KnownApp('3201606009684', 'Spotify', Color(0xFF3FBF7F), Icons.music_note_rounded),
];

/// Acento do app em foco, ou a cor neutra padrão quando nenhum app está
/// visível (TV na home, trocando de fonte etc.).
Color appAccent(KnownApp? app) => app?.accent ?? RemoteTokens.live;

class PlaybackCubit extends Cubit<KnownApp?> {
  PlaybackCubit(this._repo) : super(null);

  final TvRepository _repo;

  static const _tick = Duration(seconds: 3);
  static const _sweepEvery = 4;

  Timer? _timer;
  int _sinceSweep = _sweepEvery;
  bool _busy = false;

  void start() {
    _timer ??= Timer.periodic(_tick, (_) => _poll());
    _poll();
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _poll() async {
    if (_busy) return;
    final host = _repo.device?.host;
    if (host == null || _repo.currentStatus != TvLinkStatus.online) {
      if (state != null) emit(null);
      return;
    }

    _busy = true;
    try {
      final known = state;
      if (known != null && _sinceSweep < _sweepEvery) {
        _sinceSweep++;
        final status = await SamsungTvClient.fetchAppStatus(host, known.id);
        // null = firmware recusou a consulta. Não é "parou de tocar": manter o
        // estado anterior evita a barra piscando a cada 403.
        if (status == null) return;
        if (status.visible) return;
        emit(null);
        _sinceSweep = _sweepEvery;
        return;
      }

      _sinceSweep = 0;
      final results = await Future.wait(
        kKnownApps.map(
          (app) async => (
            app: app,
            status: await SamsungTvClient.fetchAppStatus(host, app.id),
          ),
        ),
      );
      final visible = results
          .where((r) => r.status?.visible == true)
          .map((r) => r.app)
          .firstOrNull;
      if (visible?.id != state?.id) emit(visible);
    } finally {
      _busy = false;
    }
  }

  @override
  Future<void> close() {
    stop();
    return super.close();
  }
}
