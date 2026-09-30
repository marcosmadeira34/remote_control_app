// multicast_lock.dart
//
// O Android descarta pacotes multicast que não sejam para o próprio aparelho,
// a menos que alguém segure um MulticastLock. Sem isso o M-SEARCH do SSDP sai
// do celular, a TV responde, e a resposta é jogada fora antes de chegar ao
// app — que é o motivo mais comum de "a descoberta não acha nada" mesmo com
// tudo na mesma rede.
//
// Precisa do lado nativo: veja MainActivity.kt.

import 'package:flutter/services.dart';

abstract final class MulticastLock {
  static const _channel = MethodChannel('tv/multicast');

  /// Falhas são engolidas de propósito: em iOS ou se o canal não estiver
  /// registrado, a descoberta deve tentar mesmo assim e cair no plano B.
  static Future<void> acquire() async {
    try {
      await _channel.invokeMethod<void>('acquire');
    } catch (_) {}
  }

  static Future<void> release() async {
    try {
      await _channel.invokeMethod<void>('release');
    } catch (_) {}
  }
}
