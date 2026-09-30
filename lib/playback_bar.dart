// playback_bar.dart
//
// A barra só existe quando há um app em primeiro plano. Sem estado vazio, sem
// placeholder: uma barra que diz "nada tocando" é ruído permanente em troca de
// informação zero.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'playback_cubit.dart';
import 'radial_pad.dart' show RadialTokens;
import 'remote_control_bloc.dart';
import 'tv_repository.dart';

class PlaybackBar extends StatelessWidget {
  const PlaybackBar({super.key});

  void _key(BuildContext context, String key) {
    HapticFeedback.selectionClick();
    context.read<RemoteControlBloc>().add(RemoteKeyPressed(key));
  }

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<PlaybackCubit, KnownApp?>(
      builder: (context, app) => AnimatedSize(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
        alignment: Alignment.topCenter,
        child: app == null
            ? const SizedBox(width: double.infinity)
            : Container(
                margin: const EdgeInsets.only(bottom: 10),
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xFF17181B),
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Row(
                  children: [
                    // KEY_PLAY e KEY_PAUSE são teclas separadas no protocolo,
                    // e a TV não informa qual é o estado atual. KEY_PLAY_BACK
                    // alterna, que é o que o usuário espera de um botão só.
                    _Tap(
                      icon: Icons.play_arrow_rounded,
                      label: 'Reproduzir ou pausar',
                      size: 24,
                      onTap: () => _key(context, 'KEY_PLAY_BACK'),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        app.label,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: RadialTokens.ink,
                          fontSize: 13,
                        ),
                      ),
                    ),
                    _Tap(
                      icon: Icons.replay_10_rounded,
                      label: 'Voltar 10 segundos',
                      onTap: () => _key(context, TvKeys.rewind),
                    ),
                    const SizedBox(width: 6),
                    _Tap(
                      icon: Icons.forward_10_rounded,
                      label: 'Avançar 10 segundos',
                      onTap: () => _key(context, TvKeys.fastForward),
                    ),
                  ],
                ),
              ),
      ),
    );
  }
}

class _Tap extends StatelessWidget {
  const _Tap({
    required this.icon,
    required this.label,
    required this.onTap,
    this.size = 21,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final double size;

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        label: label,
        child: InkWell(
          borderRadius: BorderRadius.circular(22),
          onTap: onTap,
          child: SizedBox(
            width: 44,
            height: 44,
            child: Icon(
              icon,
              color: size > 22 ? RadialTokens.ink : RadialTokens.inkMuted,
              size: size,
            ),
          ),
        ),
      );
}
