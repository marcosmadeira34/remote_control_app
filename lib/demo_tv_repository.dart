// demo_tv_repository.dart
//
// TvRepository falso para desenvolver a UI sem uma TV por perto. Simula uma
// conexão bem-sucedida com uma TV inventada e ignora todo comando enviado.
//
// Só entra em jogo com --dart-define=DEMO_MODE=true (ver main.dart) — nunca
// silenciosamente num build de release.

import 'dart:async';

import 'tv_repository.dart';

class DemoTvRepository implements TvRepository {
  static const _fakeDevice = SamsungTvDevice(
    host: '192.168.0.42',
    id: 'demo-device',
    name: 'TV da Sala (demo)',
    model: 'QN90A',
    wifiMac: 'AA:BB:CC:DD:EE:FF',
  );

  final _status = StreamController<TvLinkStatus>.broadcast();
  TvLinkStatus _current = TvLinkStatus.offline;
  SamsungTvDevice? _device;

  @override
  Stream<TvLinkStatus> get status => _status.stream;

  @override
  TvLinkStatus get currentStatus => _current;

  @override
  SamsungTvDevice? get device => _device;

  @override
  bool get isDemo => true;

  void _emit(TvLinkStatus value) {
    if (_current == value) return;
    _current = value;
    if (!_status.isClosed) _status.add(value);
  }

  @override
  Future<List<SamsungTvDevice>> discover() async {
    await Future<void>.delayed(const Duration(milliseconds: 400));
    return const [_fakeDevice];
  }

  @override
  Future<SamsungTvDevice?> probe(String host) async => _fakeDevice;

  @override
  Future<SamsungTvDevice?> lastDevice() async => _fakeDevice;

  @override
  Future<void> connect(SamsungTvDevice target) async {
    _device = target;
    _emit(TvLinkStatus.connecting);
    await Future<void>.delayed(const Duration(milliseconds: 600));
    _emit(TvLinkStatus.online);
  }

  @override
  Future<void> disconnect() async {
    _emit(TvLinkStatus.offline);
  }

  @override
  Future<void> forget(SamsungTvDevice d) async {
    _device = null;
    _emit(TvLinkStatus.offline);
  }

  @override
  Future<void> wake(SamsungTvDevice d) async {}

  @override
  void press(String key) {}

  @override
  Future<void> hold(String key, Duration duration) async {}

  @override
  void type(String text) {}

  @override
  void movePointer(int dx, int dy) {}

  @override
  void launchApp(String appId) {}

  void dispose() => _status.close();
}
