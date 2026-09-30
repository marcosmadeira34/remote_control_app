// tv_connection_bloc.dart

import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';

import 'tv_repository.dart';

// ------------------------------------------------------------------ eventos

sealed class TvConnectionEvent {
  const TvConnectionEvent();
}

/// Dispare no início do app: só carrega a última TV lembrada, não conecta
/// sozinho. Conectar é ação do usuário — como Wi-Fi, que lembra a rede mas
/// não impede o aparelho de abrir sem estar conectado a nada.
final class TvStarted extends TvConnectionEvent {
  const TvStarted();
}

final class TvScanRequested extends TvConnectionEvent {
  const TvScanRequested();
}

final class TvDeviceChosen extends TvConnectionEvent {
  const TvDeviceChosen(this.device);
  final SamsungTvDevice device;
}

/// Fallback para redes com isolamento de cliente, onde a descoberta não passa.
final class TvHostSubmitted extends TvConnectionEvent {
  const TvHostSubmitted(this.host);
  final String host;
}

final class TvWakeRequested extends TvConnectionEvent {
  const TvWakeRequested();
}

final class TvDisconnectRequested extends TvConnectionEvent {
  const TvDisconnectRequested();
}

final class TvForgetRequested extends TvConnectionEvent {
  const TvForgetRequested();
}

/// O Android derruba o socket em background; religue no `resumed`.
final class TvResumed extends TvConnectionEvent {
  const TvResumed();
}

final class _TvStatusChanged extends TvConnectionEvent {
  const _TvStatusChanged(this.status);
  final TvLinkStatus status;
}

// ------------------------------------------------------------------ estados

sealed class TvConnState {
  const TvConnState();
}

final class TvIdle extends TvConnState {
  const TvIdle({this.lastDevice});

  /// A última TV pareada, se houver — a tela usa isto pra oferecer um
  /// "Conectar" de um toque em vez de mandar procurar do zero.
  final SamsungTvDevice? lastDevice;
}

final class TvScanning extends TvConnState {
  const TvScanning();
}

final class TvDevicesFound extends TvConnState {
  const TvDevicesFound(this.devices);
  final List<SamsungTvDevice> devices;
}

final class TvPairing extends TvConnState {
  const TvPairing(this.device, {this.awaitingApproval = false});
  final SamsungTvDevice device;

  /// true = popup aberto na TV, esperando o usuário aceitar.
  final bool awaitingApproval;
}

final class TvOnline extends TvConnState {
  const TvOnline(this.device);
  final SamsungTvDevice device;
}

final class TvFailed extends TvConnState {
  const TvFailed(this.message, {this.device, this.devices = const []});
  final String message;
  final SamsungTvDevice? device;
  final List<SamsungTvDevice> devices;
}

// --------------------------------------------------------------------- bloc

class TvConnectionBloc extends Bloc<TvConnectionEvent, TvConnState> {
  TvConnectionBloc(this._repo) : super(const TvIdle()) {
    _sub = _repo.status.listen((s) => add(_TvStatusChanged(s)));

    on<TvStarted>(_onStarted);
    on<TvScanRequested>(_onScan);
    on<TvDeviceChosen>((e, emit) => _pair(e.device, emit));
    on<TvHostSubmitted>(_onHost);
    on<TvWakeRequested>(_onWake);
    on<TvDisconnectRequested>(_onDisconnect);
    on<TvForgetRequested>(_onForget);
    on<TvResumed>(_onResumed);
    on<_TvStatusChanged>(_onStatusChanged);
  }

  final TvRepository _repo;
  late final StreamSubscription<TvLinkStatus> _sub;

  SamsungTvDevice? _pairingTarget;

  Future<void> _onStarted(TvStarted e, Emitter<TvConnState> emit) async {
    emit(TvIdle(lastDevice: await _repo.lastDevice()));
  }

  Future<void> _onScan(TvScanRequested e, Emitter<TvConnState> emit) async {
    emit(const TvScanning());
    final found = await _repo.discover();
    if (found.isEmpty) {
      emit(const TvFailed(
        'Nenhuma TV encontrada. Confira se o celular está na mesma rede Wi-Fi '
        'da TV, ou informe o IP manualmente.',
      ));
      return;
    }
    // Achar não é decidir: mesmo com uma TV só, quem escolhe conectar é o
    // usuário, tocando nela — o app nunca conecta em nome de ninguém.
    emit(TvDevicesFound(found));
  }

  Future<void> _onHost(TvHostSubmitted e, Emitter<TvConnState> emit) async {
    emit(const TvScanning());
    final device = await _repo.probe(e.host.trim());
    if (device == null) {
      emit(TvFailed('Nada respondeu em ${e.host}. Confira o IP nas '
          'configurações de rede da TV.'));
      return;
    }
    await _pair(device, emit);
  }

  Future<void> _pair(SamsungTvDevice device, Emitter<TvConnState> emit) async {
    _pairingTarget = device;
    emit(TvPairing(device));
    try {
      await _repo.connect(device);
      emit(TvOnline(device));
    } on SamsungTvException catch (e) {
      emit(TvFailed(e.message, device: device));
    } catch (_) {
      emit(TvFailed(
        'Não foi possível conectar em ${device.name}. Verifique se a TV está '
        'ligada e na mesma rede.',
        device: device,
      ));
    }
  }

  Future<void> _onWake(TvWakeRequested e, Emitter<TvConnState> emit) async {
    final target = _pairingTarget ?? _repo.device ?? await _repo.lastDevice();
    if (target == null) return;
    try {
      await _repo.wake(target);
      // A TV leva alguns segundos para subir a pilha de rede.
      await Future<void>.delayed(const Duration(seconds: 6));
      await _pair(target, emit);
    } on SamsungTvException catch (e) {
      emit(TvFailed(e.message, device: target));
    }
  }

  Future<void> _onDisconnect(
      TvDisconnectRequested e, Emitter<TvConnState> emit) async {
    // Desconectar não é esquecer: a TV continua lembrada, só não conectada
    // agora — a tela de espera oferece religar com um toque.
    final last = _repo.device ?? await _repo.lastDevice();
    await _repo.disconnect();
    emit(TvIdle(lastDevice: last));
  }

  Future<void> _onForget(
      TvForgetRequested e, Emitter<TvConnState> emit) async {
    final target = _repo.device ?? await _repo.lastDevice();
    if (target != null) await _repo.forget(target);
    emit(const TvIdle());
  }

  Future<void> _onResumed(TvResumed e, Emitter<TvConnState> emit) async {
    if (_repo.currentStatus == TvLinkStatus.online) return;
    final target = _repo.device ?? await _repo.lastDevice();
    if (target != null) await _pair(target, emit);
  }

  void _onStatusChanged(_TvStatusChanged e, Emitter<TvConnState> emit) {
    final target = _pairingTarget;
    switch (e.status) {
      case TvLinkStatus.awaitingApproval:
        if (target != null) {
          emit(TvPairing(target, awaitingApproval: true));
        }
      case TvLinkStatus.online:
        if (target != null) emit(TvOnline(target));
      case TvLinkStatus.offline:
        // Queda depois de já estar online: sinaliza sem apagar o alvo,
        // para o TvResumed conseguir religar.
        if (state is TvOnline && target != null) {
          emit(TvFailed('A conexão com ${target.name} caiu.', device: target));
        }
      case TvLinkStatus.connecting:
        break;
    }
  }

  @override
  Future<void> close() {
    _sub.cancel();
    return super.close();
  }
}
