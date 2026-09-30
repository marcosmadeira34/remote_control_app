// network_scan.dart
//
// Plano B da descoberta: varre a faixa /24 do celular batendo na porta 8001.
//
// Existe porque o SSDP falha com frequência no mundo real — Android descarta
// multicast sem MulticastLock, muitos roteadores domésticos não repassam
// multicast entre Wi-Fi e cabo, e redes mesh costumam bloquear de vez. A
// varredura é mais lenta (~6s numa /24) mas usa só HTTP unicast, que passa em
// qualquer rede onde o celular consiga falar com a TV — que é exatamente a
// condição mínima para o app funcionar.

import 'dart:io';

import 'samsung_tv_client.dart';

/// Prefixos /24 das interfaces IPv4 do aparelho, ex.: ['192.168.0'].
///
/// Usa `NetworkInterface` do dart:io em vez de um plugin: no Android isso
/// devolve a wlan0 sem dependência extra nem permissão adicional.
Future<List<String>> localIpv4Prefixes() async {
  final prefixes = <String>{};
  try {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
      includeLinkLocal: false,
    );
    for (final iface in interfaces) {
      for (final addr in iface.addresses) {
        final parts = addr.address.split('.');
        if (parts.length != 4) continue;
        if (parts[0] == '127') continue;
        prefixes.add('${parts[0]}.${parts[1]}.${parts[2]}');
      }
    }
  } catch (_) {
    // Sem interfaces legíveis não há o que varrer.
  }
  return prefixes.toList();
}

/// Varre `prefixo.1` até `prefixo.254`.
///
/// Em lotes de [concurrency]: disparar 254 requisições de uma vez estoura o
/// limite de sockets do Android e o resultado é pior que o de lotes menores.
Future<List<SamsungTvDevice>> scanSubnet(
  String prefix, {
  int concurrency = 32,
  Duration timeout = const Duration(milliseconds: 700),
  void Function(double progress)? onProgress,
}) async {
  final hosts = List.generate(254, (i) => '$prefix.${i + 1}');
  final found = <SamsungTvDevice>[];

  for (var i = 0; i < hosts.length; i += concurrency) {
    final batch = hosts.skip(i).take(concurrency);
    final results = await Future.wait(
      batch.map((h) => SamsungTvClient.fetchDeviceInfo(h, timeout: timeout)),
    );
    found.addAll(results.whereType<SamsungTvDevice>());
    onProgress?.call((i + concurrency) / hosts.length);
  }
  return found;
}
