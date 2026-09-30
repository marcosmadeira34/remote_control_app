// remote_control_bloc.dart
//
// Deliberadamente burro: comandos são fire-and-forget. O único estado que
// importa é a recusa, quando o socket caiu entre o toque e o envio — nesse
// caso a UI mostra o aviso e o TvConnectionBloc cuida de religar.

import 'package:flutter_bloc/flutter_bloc.dart';

import 'remote_analytics.dart';
import 'tv_repository.dart';

sealed class RemoteEvent {
  const RemoteEvent();
}

final class RemoteKeyPressed extends RemoteEvent {
  const RemoteKeyPressed(this.key);
  final String key;
}

final class RemoteKeyHeld extends RemoteEvent {
  const RemoteKeyHeld(this.key, this.duration);
  final String key;
  final Duration duration;
}

final class RemoteTextTyped extends RemoteEvent {
  const RemoteTextTyped(this.text);
  final String text;
}

final class RemotePointerMoved extends RemoteEvent {
  const RemotePointerMoved(this.dx, this.dy);
  final int dx;
  final int dy;
}

final class RemoteAppLaunched extends RemoteEvent {
  const RemoteAppLaunched(this.appId);
  final String appId;
}

sealed class RemoteState {
  const RemoteState();
}

final class RemoteReady extends RemoteState {
  const RemoteReady();
}

final class RemoteRejected extends RemoteState {
  const RemoteRejected(this.message, this.at);
  final String message;

  /// Timestamp para o BlocListener reagir a falhas repetidas iguais.
  final DateTime at;
}

class RemoteControlBloc extends Bloc<RemoteEvent, RemoteState> {
  RemoteControlBloc(this._repo, {SessionTracker? tracker})
      : _tracker = tracker,
        super(const RemoteReady()) {
    on<RemoteKeyPressed>((e, emit) => _guard(emit, () => _repo.press(e.key)));
    on<RemoteKeyHeld>(
      (e, emit) => _guardAsync(emit, () => _repo.hold(e.key, e.duration)),
    );
    on<RemoteTextTyped>((e, emit) => _guard(emit, () => _repo.type(e.text)));
    on<RemoteAppLaunched>(
      (e, emit) => _guard(emit, () => _repo.launchApp(e.appId)),
    );
    // Sem restrição de concorrência: o throttle acontece no widget do
    // touchpad, onde os deltas são acumulados antes de virar evento.
    on<RemotePointerMoved>(
      (e, emit) => _guard(emit, () => _repo.movePointer(e.dx, e.dy)),
    );
  }

  final TvRepository _repo;

  /// Opcional: conta comandos e recusas na sessão. Fica aqui, e não na tela,
  /// porque cada modo despacha comandos por um caminho diferente.
  final SessionTracker? _tracker;

  void _guard(Emitter<RemoteState> emit, void Function() action) {
    try {
      action();
      _tracker?.recordCommand();
      if (state is! RemoteReady) emit(const RemoteReady());
    } on SamsungTvException catch (e) {
      _tracker?.recordRejection();
      emit(RemoteRejected(e.message, DateTime.now()));
    }
  }

  Future<void> _guardAsync(
    Emitter<RemoteState> emit,
    Future<void> Function() action,
  ) async {
    try {
      await action();
      _tracker?.recordCommand();
      if (state is! RemoteReady) emit(const RemoteReady());
    } on SamsungTvException catch (e) {
      _tracker?.recordRejection();
      emit(RemoteRejected(e.message, DateTime.now()));
    }
  }
}
