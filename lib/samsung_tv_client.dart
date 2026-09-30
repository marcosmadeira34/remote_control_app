// samsung_tv_client.dart
//
// Cliente Dart para o protocolo de controle remoto local das Samsung Smart TV
// (Tizen, modelos 2016+). Protocolo NAO documentado publicamente pela Samsung —
// obtido por engenharia reversa e usado por praticamente todos os apps de
// controle remoto do mercado.
//
// Dependencias (pubspec.yaml):
//   http: ^1.2.0
//
// Portas:
//   8001  -> REST (device info) e WebSocket sem TLS (modelos 2016/2017)
//   8002  -> WebSocket com TLS e certificado self-signed (2018+) — padrao aqui
//
// Fluxo:
//   1. discover()            -> acha IPs na rede local
//   2. fetchDeviceInfo(ip)   -> nome, modelo, MAC (para Wake-on-LAN)
//   3. connect()             -> TV exibe popup de permissao; ao aceitar retorna token
//   4. guardar o token       -> proximas conexoes ja entram autorizadas
//   5. sendKey/sendText/...

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// Estado da conexao com a TV.
enum TvConnectionState { disconnected, connecting, awaitingApproval, connected }

/// Erro de dominio do cliente.
class SamsungTvException implements Exception {
  SamsungTvException(this.message);
  final String message;
  @override
  String toString() => 'SamsungTvException: $message';
}

/// Dados basicos retornados pelo endpoint REST /api/v2/.
class SamsungTvDevice {
  const SamsungTvDevice({
    required this.host,
    required this.id,
    required this.name,
    required this.model,
    this.wifiMac,
    this.tokenAuthSupport = true,
  });

  final String host;
  final String id;
  final String name;
  final String model;

  /// MAC usado para ligar a TV via Wake-on-LAN.
  final String? wifiMac;

  /// Quando true, a TV usa a porta 8002 com token.
  final bool tokenAuthSupport;

  factory SamsungTvDevice.fromJson(String host, Map<String, dynamic> json) {
    final device = (json['device'] as Map?)?.cast<String, dynamic>() ?? {};
    return SamsungTvDevice(
      host: host,
      id: (json['id'] ?? device['id'] ?? '').toString(),
      name: (device['name'] ?? json['name'] ?? 'Samsung TV').toString(),
      model: (device['modelName'] ?? '').toString(),
      wifiMac: device['wifiMac']?.toString(),
      tokenAuthSupport: device['TokenAuthSupport']?.toString() == 'true',
    );
  }
}

class SamsungTvClient {
  SamsungTvClient({
    required this.host,
    this.appName = 'Controle Remoto',
    this.port = 8002,
    this.token,
  });

  final String host;

  /// Nome exibido no popup de permissao da TV e na lista de dispositivos
  /// autorizados (Configuracoes > Geral > Gerenciador de Dispositivos Externos).
  final String appName;

  final int port;

  /// Token devolvido pela TV no primeiro pareamento. Persista-o.
  String? token;

  WebSocket? _socket;
  StreamSubscription? _subscription;
  Completer<String?>? _handshake;

  final _stateController =
      StreamController<TvConnectionState>.broadcast();
  Stream<TvConnectionState> get stateStream => _stateController.stream;

  TvConnectionState _state = TvConnectionState.disconnected;
  TvConnectionState get state => _state;

  void _setState(TvConnectionState value) {
    _state = value;
    if (!_stateController.isClosed) _stateController.add(value);
  }

  bool get isConnected => _socket?.readyState == WebSocket.open;

  Uri get _uri => Uri(
        scheme: port == 8002 ? 'wss' : 'ws',
        host: host,
        port: port,
        path: '/api/v2/channels/samsung.remote.control',
        queryParameters: {
          'name': base64.encode(utf8.encode(appName)),
          if (token != null && token!.isNotEmpty) 'token': token!,
        },
      );

  // ---------------------------------------------------------------- conexao

  /// Abre a conexao. Se ainda nao houver token, a TV mostra um popup pedindo
  /// autorizacao e o Future so completa quando o usuario aceitar (ou o timeout
  /// estourar). Retorna o token — persista-o para as proximas sessoes.
  Future<String?> connect({
    Duration timeout = const Duration(seconds: 40),
  }) async {
    if (isConnected) return token;
    _setState(TvConnectionState.connecting);

    // A TV usa certificado self-signed na 8002: a validacao precisa ser
    // relaxada apenas para esse host.
    final httpClient = HttpClient()
      ..badCertificateCallback = (cert, h, p) => h == host;

    try {
      _socket = await WebSocket.connect(
        _uri.toString(),
        customClient: httpClient,
      ).timeout(const Duration(seconds: 10));
    } on Exception catch (e) {
      _setState(TvConnectionState.disconnected);
      throw SamsungTvException('Falha ao abrir o WebSocket em $host:$port ($e)');
    }

    _handshake = Completer<String?>();
    if (token == null || token!.isEmpty) {
      _setState(TvConnectionState.awaitingApproval);
    }

    _subscription = _socket!.listen(
      _onMessage,
      onDone: () {
        _setState(TvConnectionState.disconnected);
        if (_handshake?.isCompleted == false) {
          _handshake!.completeError(
            SamsungTvException('Conexao encerrada antes do handshake'),
          );
        }
      },
      onError: (Object e) {
        _setState(TvConnectionState.disconnected);
        if (_handshake?.isCompleted == false) _handshake!.completeError(e);
      },
      cancelOnError: true,
    );

    return _handshake!.future.timeout(
      timeout,
      onTimeout: () {
        disconnect();
        throw SamsungTvException(
          'A TV nao respondeu ao pedido de pareamento a tempo.',
        );
      },
    );
  }

  void _onMessage(dynamic raw) {
    final Map<String, dynamic> msg;
    try {
      msg = jsonDecode(raw as String) as Map<String, dynamic>;
    } catch (_) {
      return;
    }

    switch (msg['event']) {
      case 'ms.channel.connect':
        final data = (msg['data'] as Map?)?.cast<String, dynamic>();
        final newToken = data?['token']?.toString();
        if (newToken != null && newToken.isNotEmpty) token = newToken;
        _setState(TvConnectionState.connected);
        if (_handshake?.isCompleted == false) _handshake!.complete(token);
        break;

      case 'ms.channel.unauthorized':
        // Usuario recusou o popup, ou o token expirou/foi revogado.
        token = null;
        if (_handshake?.isCompleted == false) {
          _handshake!.completeError(
            SamsungTvException('Pareamento recusado pela TV.'),
          );
        }
        disconnect();
        break;

      case 'ms.channel.timeOut':
        if (_handshake?.isCompleted == false) {
          _handshake!.completeError(
            SamsungTvException('Timeout no canal de controle.'),
          );
        }
        disconnect();
        break;
    }
  }

  void _send(Map<String, dynamic> payload) {
    if (!isConnected) {
      throw SamsungTvException('Nao conectado a TV.');
    }
    _socket!.add(jsonEncode(payload));
  }

  Future<void> disconnect() async {
    await _subscription?.cancel();
    _subscription = null;
    await _socket?.close();
    _socket = null;
    _setState(TvConnectionState.disconnected);
  }

  void dispose() {
    disconnect();
    _stateController.close();
  }

  // ---------------------------------------------------------------- comandos

  /// Toque simples numa tecla. Use as constantes de [TvKeys].
  void sendKey(String key) => _send({
        'method': 'ms.remote.control',
        'params': {
          'Cmd': 'Click',
          'DataOfCmd': key,
          'Option': 'false',
          'TypeOfRemote': 'SendRemoteKey',
        },
      });

  /// Pressiona e segura (ex.: volume continuo, avanco rapido).
  Future<void> holdKey(
    String key, {
    Duration duration = const Duration(seconds: 1),
  }) async {
    void raw(String cmd) => _send({
          'method': 'ms.remote.control',
          'params': {
            'Cmd': cmd,
            'DataOfCmd': key,
            'Option': 'false',
            'TypeOfRemote': 'SendRemoteKey',
          },
        });
    raw('Press');
    await Future<void>.delayed(duration);
    raw('Release');
  }

  /// Digita texto direto no campo em foco (busca da Netflix, YouTube, etc).
  /// So funciona quando ha um teclado virtual aberto na TV.
  void sendText(String text) => _send({
        'method': 'ms.remote.control',
        'params': {
          'Cmd': base64.encode(utf8.encode(text)),
          'DataOfCmd': 'base64',
          'TypeOfRemote': 'SendInputString',
        },
      });

  /// Move o cursor do "touchpad" virtual.
  void sendMouseMove(int x, int y) => _send({
        'method': 'ms.remote.control',
        'params': {
          'Cmd': jsonEncode({'x': x, 'y': y, 'Time': '0'}),
          'TypeOfRemote': 'ProcessMouseDevice',
        },
      });

  /// Abre um app pelo ID. Ex.: Netflix `3201907018807`,
  /// YouTube `111299001912`, Prime Video `3201910019365`.
  ///
  /// [deepLink] = true manda `DEEP_LINK`, pensado para abrir um conteúdo
  /// específico dentro do app (precisa de um payload de link de verdade, que
  /// não temos aqui). Sem isso, várias TVs simplesmente ignoram o comando.
  /// Os atalhos deste app só querem trocar de app — `NATIVE_LAUNCH` é o
  /// action_type certo para isso, e o padrão.
  void launchApp(String appId, {bool deepLink = false}) => _send({
        'method': 'ms.channel.emit',
        'params': {
          'event': 'ed.apps.launch',
          'to': 'host',
          'data': {
            'appId': appId,
            'action_type': deepLink ? 'DEEP_LINK' : 'NATIVE_LAUNCH',
          },
        },
      });

  // ------------------------------------------------------------------- REST

  /// Consulta o endpoint REST publico da TV. Nao exige pareamento — util para
  /// validar um IP e descobrir o MAC antes de conectar.
  static Future<SamsungTvDevice?> fetchDeviceInfo(
    String host, {
    Duration timeout = const Duration(seconds: 2),
  }) async {
    try {
      final res = await http
          .get(Uri.parse('http://$host:8001/api/v2/'))
          .timeout(timeout);
      if (res.statusCode != 200) return null;
      return SamsungTvDevice.fromJson(
        host,
        jsonDecode(res.body) as Map<String, dynamic>,
      );
    } catch (_) {
      return null;
    }
  }

  /// Lista os apps instalados (algumas versoes de firmware bloqueiam).
  static Future<List<Map<String, dynamic>>> fetchInstalledApps(
      String host) async {
    try {
      final res = await http
          .get(Uri.parse('http://$host:8001/api/v2/applications'))
          .timeout(const Duration(seconds: 3));
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      return (body['applications'] as List? ?? [])
          .cast<Map<String, dynamic>>();
    } catch (_) {
      return [];
    }
  }

  /// Estado de um app específico. É o que permite saber o que está em primeiro
  /// plano na TV: `visible` true significa que ele está na tela agora.
  /// Não exige pareamento. Alguns firmwares 2022+ devolvem 403 aqui — trate
  /// null como "não sei", nunca como "não está rodando".
  static Future<({bool running, bool visible})?> fetchAppStatus(
    String host,
    String appId, {
    Duration timeout = const Duration(milliseconds: 1500),
  }) async {
    try {
      final res = await http
          .get(Uri.parse('http://$host:8001/api/v2/applications/$appId'))
          .timeout(timeout);
      if (res.statusCode != 200) return null;
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      return (
        running: body['running'] == true,
        visible: body['visible'] == true,
      );
    } catch (_) {
      return null;
    }
  }

  // -------------------------------------------------------------- descoberta

  /// Procura TVs Samsung na rede local via SSDP e valida cada resposta
  /// no endpoint REST. No Android e preciso segurar um MulticastLock
  /// (ver README) antes de chamar.
  static Future<List<SamsungTvDevice>> discover({
    Duration timeout = const Duration(seconds: 4),
  }) async {
    final found = <String>{};
    final socket =
        await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0, reuseAddress: true);
    socket.broadcastEnabled = true;

    // Firmwares diferentes respondem a alvos diferentes: o ST específico da
    // Samsung falha em vários modelos 2020+, que só aparecem no DIAL ou no
    // ssdp:all. Perguntar pelos três custa 3 datagramas e evita falso
    // negativo.
    const targets = [
      'urn:samsung.com:device:RemoteControlReceiver:1',
      'urn:dial-multiscreen-org:service:dial:1',
      'ssdp:all',
    ];
    String request(String st) => 'M-SEARCH * HTTP/1.1\r\n'
        'HOST: 239.255.255.250:1900\r\n'
        'MAN: "ssdp:discover"\r\n'
        'MX: 2\r\n'
        'ST: $st\r\n\r\n';

    socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      final dg = socket.receive();
      if (dg != null) found.add(dg.address.address);
    });

    // Duas rajadas por alvo: UDP é lossy.
    for (var i = 0; i < 2; i++) {
      for (final st in targets) {
        socket.send(
          utf8.encode(request(st)),
          InternetAddress('239.255.255.250'),
          1900,
        );
        await Future<void>.delayed(const Duration(milliseconds: 120));
      }
    }

    await Future<void>.delayed(timeout);
    socket.close();

    final devices = await Future.wait(found.map(fetchDeviceInfo));
    return devices.whereType<SamsungTvDevice>().toList();
  }

  /// Fallback: varre a faixa /24 do [subnet] (ex.: '192.168.0') batendo na
  /// porta 8001. Mais lento que o SSDP, porem mais confiavel em redes que
  /// bloqueiam multicast.
  static Future<List<SamsungTvDevice>> scanSubnet(String subnet) async {
    final futures = List.generate(
      254,
      (i) => fetchDeviceInfo('$subnet.${i + 1}',
          timeout: const Duration(milliseconds: 700)),
    );
    final results = await Future.wait(futures);
    return results.whereType<SamsungTvDevice>().toList();
  }

  // ------------------------------------------------------------ Wake-on-LAN

  /// Liga a TV enviando o magic packet para o MAC (campo `wifiMac` do
  /// device info). Exige que "Ligar com dispositivo movel" esteja habilitado
  /// nas configuracoes de rede da TV.
  static Future<void> wakeOnLan(
    String mac, {
    String broadcast = '255.255.255.255',
    int port = 9,
  }) async {
    final clean = mac.replaceAll(RegExp('[^0-9a-fA-F]'), '');
    if (clean.length != 12) {
      throw SamsungTvException('MAC invalido: $mac');
    }
    final macBytes = List<int>.generate(
      6,
      (i) => int.parse(clean.substring(i * 2, i * 2 + 2), radix: 16),
    );
    final packet = Uint8List.fromList([
      ...List.filled(6, 0xFF),
      for (var i = 0; i < 16; i++) ...macBytes,
    ]);

    final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    socket.broadcastEnabled = true;
    for (var i = 0; i < 3; i++) {
      socket.send(packet, InternetAddress(broadcast), port);
      await Future<void>.delayed(const Duration(milliseconds: 120));
    }
    socket.close();
  }
}

/// Codigos aceitos pelo comando `SendRemoteKey`.
abstract final class TvKeys {
  static const power = 'KEY_POWER';
  static const home = 'KEY_HOME';
  static const menu = 'KEY_MENU';
  static const source = 'KEY_SOURCE';
  static const guide = 'KEY_GUIDE';
  static const tools = 'KEY_TOOLS';
  static const info = 'KEY_INFO';
  static const exit = 'KEY_EXIT';
  static const back = 'KEY_RETURN';

  static const up = 'KEY_UP';
  static const down = 'KEY_DOWN';
  static const left = 'KEY_LEFT';
  static const right = 'KEY_RIGHT';
  static const enter = 'KEY_ENTER';

  static const volumeUp = 'KEY_VOLUP';
  static const volumeDown = 'KEY_VOLDOWN';
  static const mute = 'KEY_MUTE';

  static const channelUp = 'KEY_CHUP';
  static const channelDown = 'KEY_CHDOWN';
  static const channelList = 'KEY_CH_LIST';
  static const previousChannel = 'KEY_PRECH';

  static const play = 'KEY_PLAY';
  static const pause = 'KEY_PAUSE';
  static const stop = 'KEY_STOP';
  static const rewind = 'KEY_REWIND';
  static const fastForward = 'KEY_FF';
  static const record = 'KEY_REC';

  static const red = 'KEY_RED';
  static const green = 'KEY_GREEN';
  static const yellow = 'KEY_YELLOW';
  static const blue = 'KEY_BLUE';

  static const hdmi = 'KEY_HDMI';
  static const tv = 'KEY_TV';

  static const digits = <String>[
    'KEY_0', 'KEY_1', 'KEY_2', 'KEY_3', 'KEY_4',
    'KEY_5', 'KEY_6', 'KEY_7', 'KEY_8', 'KEY_9',
  ];
}
