// tv_repository.dart
//
// Camada que isola o protocolo do resto do app. Os BLoCs só conhecem esta
// interface — trocar o transporte (WebSocket local por SmartThings, por
// exemplo) não toca em UI nem em BLoC.

import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'multicast_lock.dart';
import 'network_scan.dart';
import 'samsung_tv_client.dart';

// Reexporta só o que a camada de cima precisa — o enum interno do cliente
// fica escondido para não colidir com os estados do BLoC.
export 'samsung_tv_client.dart' show SamsungTvDevice, TvKeys, SamsungTvException;

enum TvLinkStatus { offline, connecting, awaitingApproval, online }

abstract interface class TvRepository {
  Stream<TvLinkStatus> get status;
  TvLinkStatus get currentStatus;
  SamsungTvDevice? get device;

  /// true quando não há TV de verdade do outro lado. Quem faz rede precisa
  /// checar isto antes de sair batendo em endereços que não existem.
  bool get isDemo;

  Future<List<SamsungTvDevice>> discover();
  Future<SamsungTvDevice?> probe(String host);
  Future<SamsungTvDevice?> lastDevice();

  Future<void> connect(SamsungTvDevice device);
  Future<void> disconnect();
  Future<void> forget(SamsungTvDevice device);
  Future<void> wake(SamsungTvDevice device);

  void press(String key);
  Future<void> hold(String key, Duration duration);
  void type(String text);
  void movePointer(int dx, int dy);
  void launchApp(String appId);
}

class TvRepositoryImpl implements TvRepository {
  TvRepositoryImpl({
    FlutterSecureStorage? storage,
    this.appName = 'Controle Remoto',
  }) : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  /// Precisa ser estável entre versões: a TV vincula o token a este nome.
  /// Mudou o nome, o usuário pareia de novo.
  final String appName;

  SamsungTvClient? _client;
  SamsungTvDevice? _device;
  StreamSubscription<TvConnectionState>? _clientSub;

  final _status = StreamController<TvLinkStatus>.broadcast();
  TvLinkStatus _current = TvLinkStatus.offline;

  @override
  Stream<TvLinkStatus> get status => _status.stream;

  @override
  TvLinkStatus get currentStatus => _current;

  @override
  SamsungTvDevice? get device => _device;

  @override
  bool get isDemo => false;

  void _emit(TvLinkStatus value) {
    if (_current == value) return;
    _current = value;
    if (!_status.isClosed) _status.add(value);
  }

  // ------------------------------------------------------------- descoberta

  @override
  Future<List<SamsungTvDevice>> discover() async {
    // SSDP primeiro: quando funciona, responde em ~2s contra ~6s da varredura.
    // O lock é obrigatório no Android, senão a resposta da TV é descartada
    // antes de chegar aqui.
    await MulticastLock.acquire();
    try {
      final viaSsdp = await SamsungTvClient.discover();
      if (viaSsdp.isNotEmpty) return viaSsdp;
    } finally {
      await MulticastLock.release();
    }

    // Plano B: varredura unicast. Cobre roteador que bloqueia multicast, rede
    // mesh e o caso do lock nativo não estar registrado.
    for (final prefix in await localIpv4Prefixes()) {
      final found = await scanSubnet(prefix);
      if (found.isNotEmpty) return found;
    }
    return const [];
  }

  @override
  Future<SamsungTvDevice?> probe(String host) =>
      SamsungTvClient.fetchDeviceInfo(host);

  @override
  Future<SamsungTvDevice?> lastDevice() async {
    final raw = await _storage.read(key: 'tv_last_device');
    if (raw == null) return null;
    final map = jsonDecode(raw) as Map<String, dynamic>;
    return SamsungTvDevice(
      host: map['host'] as String,
      id: map['id'] as String,
      name: map['name'] as String,
      model: map['model'] as String,
      wifiMac: map['wifiMac'] as String?,
    );
  }

  Future<void> _remember(SamsungTvDevice d) => _storage.write(
        key: 'tv_last_device',
        value: jsonEncode({
          'host': d.host,
          'id': d.id,
          'name': d.name,
          'model': d.model,
          'wifiMac': d.wifiMac,
        }),
      );

  // ---------------------------------------------------------------- conexão

  @override
  Future<void> connect(SamsungTvDevice target) async {
    await disconnect();

    // O IP pode ter mudado desde a última sessão (DHCP). Revalida antes.
    final fresh = await probe(target.host) ?? target;
    _device = fresh;

    final saved = await _storage.read(key: 'tv_token_${fresh.id}');
    final client = SamsungTvClient(
      host: fresh.host,
      appName: appName,
      token: saved,
    );
    _client = client;

    _clientSub = client.stateStream.listen((s) {
      _emit(switch (s) {
        TvConnectionState.disconnected => TvLinkStatus.offline,
        TvConnectionState.connecting => TvLinkStatus.connecting,
        TvConnectionState.awaitingApproval => TvLinkStatus.awaitingApproval,
        TvConnectionState.connected => TvLinkStatus.online,
      });
    });

    final token = await client.connect();
    if (token != null && token.isNotEmpty) {
      await _storage.write(key: 'tv_token_${fresh.id}', value: token);
    }
    await _remember(fresh);
  }

  @override
  Future<void> disconnect() async {
    await _clientSub?.cancel();
    _clientSub = null;
    await _client?.disconnect();
    _client = null;
    _emit(TvLinkStatus.offline);
  }

  @override
  Future<void> forget(SamsungTvDevice d) async {
    await disconnect();
    await _storage.delete(key: 'tv_token_${d.id}');
    await _storage.delete(key: 'tv_last_device');
    _device = null;
  }

  @override
  Future<void> wake(SamsungTvDevice d) async {
    final mac = d.wifiMac;
    if (mac == null) {
      throw SamsungTvException(
        'Esta TV não informou o endereço MAC, então não dá para ligá-la pelo app.',
      );
    }
    await SamsungTvClient.wakeOnLan(mac);
  }

  // --------------------------------------------------------------- comandos

  SamsungTvClient get _live {
    final c = _client;
    if (c == null || !c.isConnected) {
      throw SamsungTvException('Sem conexão com a TV.');
    }
    return c;
  }

  @override
  void press(String key) => _live.sendKey(key);

  @override
  Future<void> hold(String key, Duration duration) =>
      _live.holdKey(key, duration: duration);

  @override
  void type(String text) => _live.sendText(text);

  @override
  void movePointer(int dx, int dy) => _live.sendMouseMove(dx, dy);

  @override
  void launchApp(String appId) => _live.launchApp(appId);

  void dispose() {
    _clientSub?.cancel();
    _client?.dispose();
    _status.close();
  }
}
