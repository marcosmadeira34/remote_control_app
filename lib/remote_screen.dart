// remote_screen.dart

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'dpad.dart';
import 'playback_bar.dart';
import 'playback_cubit.dart';
import 'radial_pad.dart' show RadialTokens;
import 'remote_analytics.dart';
import 'remote_control_bloc.dart';
import 'remote_theme.dart';
import 'tv_connection_bloc.dart';
import 'tv_repository.dart';

class RemoteScreen extends StatefulWidget {
  const RemoteScreen({super.key});

  @override
  State<RemoteScreen> createState() => _RemoteScreenState();
}

class _RemoteScreenState extends State<RemoteScreen> {
  late final AppLifecycleListener _lifecycle;

  SessionTracker get _tracker => context.read<SessionTracker>();

  @override
  void initState() {
    super.initState();
    // O Android derruba o WebSocket em background; religue no resumed e
    // feche a sessão de analytics ao esconder.
    _lifecycle = AppLifecycleListener(
      onResume: () {
        context.read<TvConnectionBloc>().add(const TvResumed());
        if (context.read<TvConnectionBloc>().state is TvOnline) {
          context.read<PlaybackCubit>().start();
        }
      },
      onHide: () {
        context.read<PlaybackCubit>().stop();
        _tracker.end();
      },
    );
    context.read<TvConnectionBloc>().add(const TvStarted());
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  void _key(String key) =>
      context.read<RemoteControlBloc>().add(RemoteKeyPressed(key));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: MultiBlocListener(
          listeners: [
            BlocListener<RemoteControlBloc, RemoteState>(
              listenWhen: (a, b) => b is RemoteRejected,
              listener: (context, state) {
                if (state is! RemoteRejected) return;
                ScaffoldMessenger.of(context)
                  ..clearSnackBars()
                  ..showSnackBar(SnackBar(
                    content: Text(state.message),
                    backgroundColor: RemoteTokens.surfaceRaised,
                  ));
              },
            ),
            BlocListener<TvConnectionBloc, TvConnState>(
              listener: (context, state) {
                if (state is TvOnline) {
                  context.read<PlaybackCubit>().start();
                  _tracker.start(RemoteMode.dpad);
                } else {
                  context.read<PlaybackCubit>().stop();
                  _tracker.end();
                }
              },
            ),
          ],
          child: BlocBuilder<TvConnectionBloc, TvConnState>(
            builder: (context, state) => _mainScreen(context, state),
          ),
        ),
      ),
    );
  }

  // ------------------------------------------------------------ tela única

  // A tela principal — status, relógio, o controle inteiro — é sempre a
  // primeira coisa que aparece, conectada ou não: o direcional, volume,
  // canal e ações ficam sempre visíveis, só desabilitados (esmaecidos) sem
  // conexão, como um controle físico continua sendo um controle mesmo com a
  // TV desligada. Conectar é uma ação à parte, pelo ícone na barra de
  // status — como Wi-Fi, que fica lembrado mas nunca impede o aparelho de
  // abrir nem exige uma tela própria pra isso.
  Widget _mainScreen(BuildContext context, TvConnState state) {
    final device = switch (state) {
      TvOnline(:final device) => device,
      TvPairing(:final device) => device,
      TvFailed(:final device) => device,
      TvIdle(:final lastDevice) => lastDevice,
      _ => null,
    };
    final online = state is TvOnline;

    return BlocBuilder<PlaybackCubit, KnownApp?>(
      builder: (context, app) {
        final accent = appAccent(app);
        return _RemoteEntrance(
          accent: accent,
          child: Column(
            children: [
              _StatusBar(device: device, connected: online),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) => SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(
                      horizontal: RemoteTokens.gutter,
                      vertical: 4,
                    ),
                    // O conteúdo normalmente é bem mais baixo que o espaço
                    // disponível. Sem isto ele gruda no topo e sobra um vão
                    // morto até o keypad; centralizado, a respiração fica
                    // distribuída e o keypad ainda não perde o lugar fixo.
                    child: ConstrainedBox(
                      constraints:
                          BoxConstraints(minHeight: constraints.maxHeight),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const _Clock(),
                          // Barra de reprodução e atalhos de app precisam de
                          // TV online pra significar alguma coisa — sem
                          // conexão eles só some, o relógio continua.
                          if (online) ...[
                            const SizedBox(height: 28),
                            const PlaybackBar(),
                            _AppsButton(activeAppId: app?.id),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              _KeypadPanel(
                accent: accent,
                child: _keypadControls(accent: accent, enabled: online),
              ),
            ],
          ),
        );
      },
    );
  }

  // ----------------------------------------------------------------- remoto

  // Volume e canal flanqueiam o direcional em vez de ficarem empilhados
  // abaixo dele — num controle físico é assim que ficam, e é o motivo do
  // polegar não precisar descer até o fim da tela para trocar de volume.
  // O LayoutBuilder encolhe o direcional em telas estreitas para as duas
  // colunas de ícone caberem ao lado sem estourar a largura.
  Widget _keypadControls({required Color accent, required bool enabled}) =>
      LayoutBuilder(
        builder: (context, constraints) {
          const columnWidth = RemoteTokens.minTarget;
          const gap = 14.0;
          final maxDpad = constraints.maxWidth - 2 * (columnWidth + gap);
          final dpadSize =
              maxDpad.clamp(150.0, RemoteTokens.dpadDiameter).toDouble();

          return Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _IconRepeatButton(
                        icon: Icons.volume_up_rounded,
                        semanticLabel: 'Aumentar volume',
                        accent: accent,
                        enabled: enabled,
                        onFire: () => _key(TvKeys.volumeUp),
                      ),
                      const SizedBox(height: 10),
                      // O mudo fica entre o máximo e o mínimo: é o ponto de
                      // repouso natural do polegar entre os dois extremos do
                      // volume, não uma quarta ação solta lá embaixo.
                      _RoundIconButton(
                        icon: Icons.volume_off_rounded,
                        semanticLabel: 'Mudo',
                        accent: accent,
                        enabled: enabled,
                        onTap: () => _key(TvKeys.mute),
                      ),
                      const SizedBox(height: 10),
                      _IconRepeatButton(
                        icon: Icons.volume_down_rounded,
                        semanticLabel: 'Diminuir volume',
                        accent: accent,
                        enabled: enabled,
                        onFire: () => _key(TvKeys.volumeDown),
                      ),
                    ],
                  ),
                  const SizedBox(width: gap),
                  Dpad(
                    diameter: dpadSize,
                    accent: accent,
                    enabled: enabled,
                    onPress: (zone) => _key(switch (zone) {
                      DpadZone.up => TvKeys.up,
                      DpadZone.down => TvKeys.down,
                      DpadZone.left => TvKeys.left,
                      DpadZone.right => TvKeys.right,
                      DpadZone.center => TvKeys.enter,
                    }),
                  ),
                  const SizedBox(width: gap),
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _IconRepeatButton(
                        icon: Icons.keyboard_arrow_up_rounded,
                        semanticLabel: 'Canal seguinte',
                        accent: accent,
                        enabled: enabled,
                        onFire: () => _key(TvKeys.channelUp),
                      ),
                      const SizedBox(height: 10),
                      _IconRepeatButton(
                        icon: Icons.keyboard_arrow_down_rounded,
                        semanticLabel: 'Canal anterior',
                        accent: accent,
                        enabled: enabled,
                        onFire: () => _key(TvKeys.channelDown),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 22),
              _actionRow(accent: accent, enabled: enabled),
            ],
          );
        },
      );

  // Voltar e início ficam fixos aqui, sempre — é a única saída para o menu
  // da TV. A transição para streaming (avançar/retroceder/pausar) já mora na
  // PlaybackBar lá em cima quando um app está em foco; duplicar esses três
  // botões aqui só custava a navegação, sem ganhar nada.
  Widget _actionRow({required Color accent, required bool enabled}) => Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _PillButton(
            icon: Icons.arrow_back_rounded,
            label: 'Voltar',
            accent: accent,
            enabled: enabled,
            onTap: () => _key(TvKeys.back),
          ),
          _PillButton(
            icon: Icons.home_rounded,
            label: 'Início',
            accent: accent,
            enabled: enabled,
            onTap: () => _key(TvKeys.home),
          ),
          _PillButton(
            icon: Icons.input_rounded,
            label: 'Fonte',
            accent: accent,
            enabled: enabled,
            onTap: () => _key(TvKeys.source),
          ),
        ],
      );
}

// -------------------------------------------------------------- componentes

/// Sempre no ar, conectado ou não — só o ponto e o nome mudam. Sem TV
/// nenhuma lembrada, mostra "Controle Remoto" em vez de deixar a barra vazia.
/// O botão de conectar mora aqui, do lado do de ligar/desligar — mesma
/// linguagem visual, mesmo lugar de sempre num controle de verdade.
class _StatusBar extends StatelessWidget {
  const _StatusBar({required this.device, required this.connected});
  final SamsungTvDevice? device;
  final bool connected;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(RemoteTokens.gutter, 10, 4, 4),
        child: Row(
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 220),
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: connected ? RadialTokens.bloom : RemoteTokens.inkMuted,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                device?.name ?? 'Controle Remoto',
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 15),
              ),
            ),
            IconButton(
              icon: Icon(connected
                  ? Icons.cast_connected_rounded
                  : Icons.cast_rounded),
              color: connected ? RemoteTokens.live : RemoteTokens.inkMuted,
              tooltip: connected ? 'Gerenciar conexão' : 'Encontrar TVs',
              onPressed: () => showModalBottomSheet<void>(
                context: context,
                backgroundColor: RemoteTokens.surface,
                shape: const RoundedRectangleBorder(
                  borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
                ),
                builder: (_) => const _ConnectSheet(),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.power_settings_new_rounded),
              color: RemoteTokens.inkMuted,
              onPressed: connected
                  ? () => context
                      .read<RemoteControlBloc>()
                      .add(const RemoteKeyPressed(TvKeys.power))
                  : null,
            ),
          ],
        ),
      );
}

/// Busca, pareamento e gerência da conexão — tudo o que costumava ser tela
/// própria agora é um bottom sheet sobre o controle, que nunca sai de trás
/// dele. Fecha sozinho ao conectar; abrir de novo já conectado vira tela de
/// gerência (desconectar, trocar de TV), não de busca.
class _ConnectSheet extends StatelessWidget {
  const _ConnectSheet();

  @override
  Widget build(BuildContext context) => SafeArea(
        top: false,
        // showModalBottomSheet não força largura total no conteúdo — sem
        // isto a folha encolhe pro tamanho do texto e flutua centralizada
        // em vez de ancorada na borda inferior como uma folha de verdade.
        child: SizedBox(
          width: double.infinity,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 28, 24, 24),
            child: BlocConsumer<TvConnectionBloc, TvConnState>(
              listenWhen: (a, b) => b is TvOnline,
              listener: (context, state) => Navigator.of(context).maybePop(),
              builder: (context, state) => switch (state) {
                TvOnline(:final device) => _connected(context, device),
                TvIdle(:final lastDevice) => _idle(context, lastDevice),
                TvScanning() => const _KeypadStatus(
                    title: 'Procurando TVs',
                    body: 'Mantenha o celular na mesma rede Wi-Fi da TV.',
                  ),
                TvPairing(:final device, :final awaitingApproval) =>
                  _KeypadStatus(
                    title: awaitingApproval ? 'Confirme na TV' : 'Conectando',
                    body: awaitingApproval
                        ? 'Apareceu um aviso na ${device.name} pedindo '
                            'permissão. Escolha Permitir no controle físico.'
                        : device.name,
                  ),
                TvDevicesFound(:final devices) => _picker(context, devices),
                TvFailed(:final message, :final device) =>
                  _failed(context, message, device),
              },
            ),
          ),
        ),
      );

  Widget _connected(BuildContext context, SamsungTvDevice device) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.cast_connected_rounded,
              color: RemoteTokens.live, size: 26),
          const SizedBox(height: 10),
          Text(device.name,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          const Text('Conectado',
              style: TextStyle(color: RemoteTokens.inkMuted)),
          const SizedBox(height: 18),
          OutlinedButton(
            onPressed: () {
              context.read<TvConnectionBloc>().add(const TvDisconnectRequested());
              Navigator.of(context).maybePop();
            },
            child: const Text('Desconectar'),
          ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: () =>
                context.read<TvConnectionBloc>().add(const TvScanRequested()),
            child: const Text('Procurar outra TV'),
          ),
        ],
      );

  // Conectar é ação do usuário: com uma TV lembrada, o toque já basta (o
  // token fica salvo, não repete o pareamento); sem nenhuma, o caminho é
  // procurar do zero.
  Widget _idle(BuildContext context, SamsungTvDevice? lastDevice) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            lastDevice?.name ?? 'Nenhuma TV conectada',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 6),
          Text(
            lastDevice != null
                ? 'Toque para conectar.'
                : 'A TV precisa estar ligada e na mesma rede Wi-Fi.',
            textAlign: TextAlign.center,
            style: const TextStyle(color: RemoteTokens.inkMuted),
          ),
          const SizedBox(height: 18),
          FilledButton(
            onPressed: () => lastDevice != null
                ? context.read<TvConnectionBloc>().add(TvDeviceChosen(lastDevice))
                : context.read<TvConnectionBloc>().add(const TvScanRequested()),
            child: Text(lastDevice != null ? 'Conectar' : 'Procurar TV'),
          ),
          if (lastDevice != null) ...[
            const SizedBox(height: 8),
            TextButton(
              onPressed: () =>
                  context.read<TvConnectionBloc>().add(const TvScanRequested()),
              child: const Text('Procurar outra TV'),
            ),
          ],
        ],
      );

  Widget _picker(BuildContext context, List<SamsungTvDevice> devices) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Escolha a TV',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          for (final d in devices)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.tv_rounded, color: RemoteTokens.ink),
              title: Text(d.name),
              subtitle: Text('${d.model} · ${d.host}',
                  style: const TextStyle(color: RemoteTokens.inkMuted)),
              onTap: () =>
                  context.read<TvConnectionBloc>().add(TvDeviceChosen(d)),
            ),
        ],
      );

  Widget _failed(
    BuildContext context,
    String message,
    SamsungTvDevice? device,
  ) =>
      Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(message,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium),
          const SizedBox(height: 18),
          FilledButton(
            onPressed: () =>
                context.read<TvConnectionBloc>().add(const TvScanRequested()),
            child: const Text('Procurar de novo'),
          ),
          if (device?.wifiMac != null) ...[
            const SizedBox(height: 10),
            OutlinedButton(
              onPressed: () =>
                  context.read<TvConnectionBloc>().add(const TvWakeRequested()),
              child: const Text('Ligar a TV'),
            ),
          ],
          const SizedBox(height: 10),
          TextButton(
            onPressed: () => _askForHost(context),
            child: const Text('Informar o IP manualmente'),
          ),
        ],
      );

  Future<void> _askForHost(BuildContext context) async {
    final controller = TextEditingController();
    final bloc = context.read<TvConnectionBloc>();
    final host = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: RemoteTokens.surface,
        title: const Text('IP da TV'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.text,
          decoration: const InputDecoration(hintText: '192.168.0.42'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('Conectar'),
          ),
        ],
      ),
    );
    if (host != null && host.trim().isNotEmpty) {
      bloc.add(TvHostSubmitted(host));
    }
  }
}

/// Entrada em dois atos, como um salto pro hyperespaço que termina num
/// pouso: primeiro um túnel de estrelas explode do centro pra fora (o
/// direcional ainda nem existe); depois, de dentro pra fora — na direção de
/// quem olha — o controle nasce pequeno e desfocado no fundo desse túnel e
/// cresce até o tamanho real, com uma leve ultrapassagem antes de assentar.
/// A sensação é de vir voando na sua direção, não de aparecer no lugar.
///
/// Roda uma vez só: o AnimationController vive no State, que o Flutter
/// preserva entre rebuilds da mesma posição na árvore (troca de app, cor
/// mudando etc. não reiniciam a animação, só a reconstroem já no fim). Cai a
/// conexão e reconecta, a tela toda é desmontada e remontada — aí a entrada
/// toca de novo, o que é o comportamento certo: é uma religada, não um
/// rebuild qualquer.
class _RemoteEntrance extends StatefulWidget {
  const _RemoteEntrance({required this.child, required this.accent});

  final Widget child;
  final Color accent;

  @override
  State<_RemoteEntrance> createState() => _RemoteEntranceState();
}

class _RemoteEntranceState extends State<_RemoteEntrance>
    with SingleTickerProviderStateMixin {
  static const _burstFraction = 0.55;

  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 850),
  )..forward();

  late final List<_WarpStar> _stars = _generateWarpStars();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  /// Opacidade, escala e desfoque do conteúdo real em cada instante —
  /// tradução direta dos keyframes CSS do protótipo (0%/38%/72%/100%) pra
  /// interpolação linear por trecho sobre uma curva easeOutCubic.
  ({double opacity, double scale, double blur}) _emergeAt(double t) {
    final e = Curves.easeOutCubic.transform(t);
    double seg(double a, double b, double from, double to) {
      if (e <= from) return a;
      if (e >= to) return b;
      return a + (b - a) * (e - from) / (to - from);
    }

    return (
      opacity: seg(0, 1, 0.38, 0.72),
      scale: e <= 0.38
          ? 0.42
          : e <= 0.72
              ? seg(0.42, 1.035, 0.38, 0.72)
              : seg(1.035, 1.0, 0.72, 1.0),
      blur: seg(9, 0, 0.38, 0.72),
    );
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: _c,
        child: widget.child,
        builder: (context, child) {
          final t = _c.value;
          final e = _emergeAt(t);
          final content = Opacity(
            opacity: e.opacity,
            child: Transform.scale(
              scale: e.scale,
              child: e.blur > 0.05
                  ? ImageFiltered(
                      imageFilter:
                          ui.ImageFilter.blur(sigmaX: e.blur, sigmaY: e.blur),
                      child: child,
                    )
                  : child,
            ),
          );

          if (t >= _burstFraction) return content;

          return Stack(
            fit: StackFit.expand,
            children: [
              content,
              IgnorePointer(
                child: CustomPaint(
                  painter: _WarpPainter(
                    stars: _stars,
                    progress: t / _burstFraction,
                    accent: widget.accent,
                  ),
                ),
              ),
            ],
          );
        },
      );
}

class _WarpStar {
  _WarpStar({
    required this.angle,
    required this.speed,
    required this.width,
    required this.teal,
  });
  final double angle;
  final double speed;
  final double width;
  final bool teal;
}

/// Semente fixa: o padrão de estrelas é sempre o mesmo, só a duração muda —
/// senão cada religada pareceria um efeito de hyperespaço diferente.
List<_WarpStar> _generateWarpStars() {
  final rnd = math.Random(11);
  return List.generate(
    90,
    (_) => _WarpStar(
      angle: rnd.nextDouble() * 2 * math.pi,
      speed: 0.65 + rnd.nextDouble() * 0.7,
      width: 1 + rnd.nextDouble() * 1.6,
      teal: rnd.nextDouble() < 0.22,
    ),
  );
}

class _WarpPainter extends CustomPainter {
  _WarpPainter({required this.stars, required this.progress, required this.accent});

  final List<_WarpStar> stars;

  /// 0..1 dentro só da fração de estouro (não do total da entrada).
  final double progress;
  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final maxR = size.shortestSide > 0
        ? math.sqrt(size.width * size.width + size.height * size.height) / 2 + 24
        : 0.0;
    final ease = progress * progress; // acelera pra fora, como saltar
    final alpha = (1 - progress).clamp(0.0, 1.0);
    if (alpha <= 0.01) return;

    for (final s in stars) {
      final dir = Offset(math.cos(s.angle), math.sin(s.angle));
      final r0 = ease * maxR * 0.12 * s.speed;
      final r1 = ease * maxR * s.speed;
      canvas.drawLine(
        center + dir * r0,
        center + dir * r1,
        Paint()
          ..color = (s.teal ? accent : Colors.white).withValues(alpha: alpha * 0.9)
          ..strokeWidth = s.width
          ..strokeCap = StrokeCap.round,
      );
    }
  }

  @override
  bool shouldRepaint(_WarpPainter old) => old.progress != progress;
}

/// Encolhe no toque — a mesma resposta imediata da cunha pressionada do
/// direcional, pra nenhum botão do keypad parecer "morto" enquanto o
/// direcional reage. Reage a um bool de fora em vez de gerir o próprio
/// gesto, porque os botões que a usam já tratam down/up de formas diferentes
/// (um toque simples aqui, pressionar-e-segurar ali).
class _PressFeedback extends StatelessWidget {
  const _PressFeedback({required this.pressed, required this.child});
  final bool pressed;
  final Widget child;

  @override
  Widget build(BuildContext context) => AnimatedScale(
        scale: pressed ? 0.90 : 1.0,
        duration: const Duration(milliseconds: 110),
        curve: Curves.easeOut,
        child: child,
      );
}

/// HH:MM local do celular — o olho fica no controle, não convém ter que
/// checar a barra do sistema pra saber a hora. Centralizado na área de
/// conteúdo, não escondido de canto: é o primeiro elemento com peso visual
/// que a tela mostra sem TV nenhuma tocando nada. Atualiza a cada 15s: sobra
/// folga pra nunca atrasar um minuto inteiro, sem redesenhar por segundo à
/// toa.
class _Clock extends StatefulWidget {
  const _Clock();

  @override
  State<_Clock> createState() => _ClockState();
}

class _ClockState extends State<_Clock> {
  late final Timer _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 15), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final hh = now.hour.toString().padLeft(2, '0');
    final mm = now.minute.toString().padLeft(2, '0');
    return Text(
      '$hh:$mm',
      style: const TextStyle(
        color: RemoteTokens.ink,
        fontSize: 56,
        fontWeight: FontWeight.w300,
        letterSpacing: 1,
        fontFeatures: [FontFeature.tabularFigures()],
      ),
    );
  }
}

/// Acabamento "metal escovado" comum a pílulas, ícones e ao painel do
/// keypad: gradiente sutil de cima pra baixo simulando luz vinda de cima,
/// friso claro de 1px na borda e sombra rasa por baixo. É o que faz um botão
/// ler como uma peça com relevo, não como uma mancha de cor plana.
BoxDecoration _glassDecoration(BorderRadius radius) => BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          RemoteTokens.surfaceRaised,
          RemoteTokens.surface,
        ],
      ),
      borderRadius: radius,
      border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
      boxShadow: const [
        BoxShadow(color: Colors.black26, blurRadius: 6, offset: Offset(0, 3)),
      ],
    );

/// Zona fixa embaixo da tela, no lugar do Dynamic Keypad de vidro da AVA:
/// nunca rola, e o friso superior muda de cor com o acento do app em foco —
/// junto com o direcional, é onde essa cor mais aparece.
class _KeypadPanel extends StatelessWidget {
  const _KeypadPanel({required this.child, required this.accent});
  final Widget child;
  final Color accent;

  @override
  Widget build(BuildContext context) => AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(
            RemoteTokens.gutter, 22, RemoteTokens.gutter, 18),
        decoration: BoxDecoration(
          color: RemoteTokens.backdrop,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          border: Border(
            top: BorderSide(color: accent.withValues(alpha: 0.22)),
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.5),
              blurRadius: 24,
              offset: const Offset(0, -8),
            ),
          ],
        ),
        child: child,
      );
}

class _PillButton extends StatefulWidget {
  const _PillButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.accent,
    this.enabled = true,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  /// Mescla leve no ícone com a cor do app em foco — discreta aqui, porque o
  /// papel principal dessas ações é utilitário, não decorativo.
  final Color? accent;

  /// Sem TV conectada o botão continua visível — um controle físico não
  /// some com a TV desligada — só esmaece e para de responder ao toque.
  final bool enabled;

  @override
  State<_PillButton> createState() => _PillButtonState();
}

class _PillButtonState extends State<_PillButton> {
  bool _pressed = false;

  void _setPressed(bool value) {
    if (_pressed != value) setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    final accent = widget.enabled ? widget.accent : null;
    return Semantics(
      button: true,
      label: widget.label,
      child: GestureDetector(
        onTapDown: widget.enabled ? (_) => _setPressed(true) : null,
        onTapUp: widget.enabled ? (_) => _setPressed(false) : null,
        onTapCancel: widget.enabled ? () => _setPressed(false) : null,
        onTap: widget.enabled
            ? () {
                HapticFeedback.selectionClick();
                widget.onTap();
              }
            : null,
        child: _PressFeedback(
          pressed: _pressed,
          child: Opacity(
            opacity: widget.enabled ? 1 : 0.4,
            child: Container(
              width: 92,
              height: RemoteTokens.minTarget,
              decoration: _glassDecoration(BorderRadius.circular(30)).copyWith(
                border: Border.all(
                  color: _pressed
                      ? (accent ?? RemoteTokens.live).withValues(alpha: 0.55)
                      : Colors.white.withValues(alpha: 0.05),
                ),
              ),
              child: Icon(
                widget.icon,
                color: accent == null
                    ? RemoteTokens.ink
                    : Color.lerp(RemoteTokens.ink, accent, 0.3),
                size: 24,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Botão redondo com pressionar-e-segurar repetindo — substitui os rockers
/// alongados de antes por um par de círculos com ícone, sem a "barra".
class _IconRepeatButton extends StatefulWidget {
  const _IconRepeatButton({
    required this.icon,
    required this.onFire,
    required this.semanticLabel,
    this.accent,
    this.enabled = true,
  });

  final IconData icon;
  final VoidCallback onFire;
  final String semanticLabel;
  final Color? accent;
  final bool enabled;

  @override
  State<_IconRepeatButton> createState() => _IconRepeatButtonState();
}

class _IconRepeatButtonState extends State<_IconRepeatButton> {
  Timer? _delay;
  Timer? _repeat;
  bool _pressed = false;

  void _start() {
    if (!widget.enabled) return;
    HapticFeedback.selectionClick();
    setState(() => _pressed = true);
    widget.onFire();
    _delay = Timer(const Duration(milliseconds: 420), () {
      _repeat = Timer.periodic(
        const Duration(milliseconds: 130),
        (_) => widget.onFire(),
      );
    });
  }

  void _stop() {
    _delay?.cancel();
    _repeat?.cancel();
    _delay = null;
    _repeat = null;
    if (_pressed) setState(() => _pressed = false);
  }

  @override
  void dispose() {
    _stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final accent = widget.enabled ? widget.accent : null;
    return Semantics(
      button: true,
      label: widget.semanticLabel,
      child: Listener(
        onPointerDown: (_) => _start(),
        onPointerUp: (_) => _stop(),
        onPointerCancel: (_) => _stop(),
        child: _PressFeedback(
          pressed: _pressed,
          child: Opacity(
            opacity: widget.enabled ? 1 : 0.4,
            child: Container(
              width: RemoteTokens.minTarget,
              height: RemoteTokens.minTarget,
              decoration: _glassDecoration(
                      BorderRadius.circular(RemoteTokens.minTarget / 2))
                  .copyWith(
                border: Border.all(
                  color: _pressed
                      ? (accent ?? RemoteTokens.live).withValues(alpha: 0.55)
                      : Colors.white.withValues(alpha: 0.05),
                ),
              ),
              child: Icon(
                widget.icon,
                color: accent == null
                    ? RemoteTokens.ink
                    : Color.lerp(RemoteTokens.ink, accent, 0.5),
                size: 24,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Mesmo círculo do `_IconRepeatButton`, mas para uma ação que não repete —
/// o mudo é liga/desliga, segurar não deveria fazer nada de diferente.
class _RoundIconButton extends StatefulWidget {
  const _RoundIconButton({
    required this.icon,
    required this.onTap,
    required this.semanticLabel,
    this.accent,
    this.enabled = true,
  });

  final IconData icon;
  final VoidCallback onTap;
  final String semanticLabel;
  final Color? accent;
  final bool enabled;

  @override
  State<_RoundIconButton> createState() => _RoundIconButtonState();
}

class _RoundIconButtonState extends State<_RoundIconButton> {
  bool _pressed = false;

  void _setPressed(bool value) {
    if (_pressed != value) setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    final accent = widget.enabled ? widget.accent : null;
    return Semantics(
      button: true,
      label: widget.semanticLabel,
      child: GestureDetector(
        onTapDown: widget.enabled ? (_) => _setPressed(true) : null,
        onTapUp: widget.enabled ? (_) => _setPressed(false) : null,
        onTapCancel: widget.enabled ? () => _setPressed(false) : null,
        onTap: widget.enabled
            ? () {
                HapticFeedback.selectionClick();
                widget.onTap();
              }
            : null,
        child: _PressFeedback(
          pressed: _pressed,
          child: Opacity(
            opacity: widget.enabled ? 1 : 0.4,
            child: Container(
              width: RemoteTokens.minTarget,
              height: RemoteTokens.minTarget,
              decoration: _glassDecoration(
                      BorderRadius.circular(RemoteTokens.minTarget / 2))
                  .copyWith(
                border: Border.all(
                  color: _pressed
                      ? (accent ?? RemoteTokens.live).withValues(alpha: 0.55)
                      : Colors.white.withValues(alpha: 0.05),
                ),
              ),
              child: Icon(
                widget.icon,
                color: accent == null
                    ? RemoteTokens.ink
                    : Color.lerp(RemoteTokens.ink, accent, 0.5),
                size: 22,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Um botão só, não uma fileira que rola — a fileira horizontal escondia
/// metade dos apps fora da tela sem nenhum sinal de que havia mais. Abre uma
/// grade num bottom sheet, onde todos os apps cabem visíveis de uma vez.
class _AppsButton extends StatelessWidget {
  const _AppsButton({this.activeAppId});

  /// ID do app que a PlaybackCubit vê em primeiro plano na TV agora, se
  /// houver — usado para destacar o ladrilho correspondente na grade.
  final String? activeAppId;

  @override
  Widget build(BuildContext context) {
    final active = kKnownApps.where((a) => a.id == activeAppId).firstOrNull;
    return OutlinedButton.icon(
      onPressed: () => _openGrid(context),
      icon: Icon(
        active?.icon ?? Icons.apps_rounded,
        size: 20,
        color: active?.accent,
      ),
      label: Text(active?.label ?? 'Apps'),
      style: OutlinedButton.styleFrom(
        foregroundColor: RemoteTokens.ink,
        side: BorderSide(
          color: active != null
              ? active.accent.withValues(alpha: 0.6)
              : RemoteTokens.surface,
          width: 1.5,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
      ),
    );
  }

  Future<void> _openGrid(BuildContext context) async {
    final bloc = context.read<RemoteControlBloc>();
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: RemoteTokens.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
          child: GridView.count(
            crossAxisCount: 3,
            shrinkWrap: true,
            mainAxisSpacing: 20,
            crossAxisSpacing: 8,
            childAspectRatio: 0.85,
            children: [
              for (final app in kKnownApps)
                _AppTile(
                  app: app,
                  active: app.id == activeAppId,
                  onTap: () {
                    bloc.add(RemoteAppLaunched(app.id));
                    Navigator.pop(ctx);
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AppTile extends StatefulWidget {
  const _AppTile({required this.app, required this.active, required this.onTap});

  final KnownApp app;
  final bool active;
  final VoidCallback onTap;

  @override
  State<_AppTile> createState() => _AppTileState();
}

class _AppTileState extends State<_AppTile> {
  bool _pressed = false;

  void _setPressed(bool value) {
    if (_pressed != value) setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTapDown: (_) => _setPressed(true),
        onTapUp: (_) => _setPressed(false),
        onTapCancel: () => _setPressed(false),
        onTap: () {
          HapticFeedback.selectionClick();
          widget.onTap();
        },
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _PressFeedback(
              pressed: _pressed,
              child: Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: widget.app.accent,
                  shape: BoxShape.circle,
                  border:
                      widget.active ? Border.all(color: RemoteTokens.ink, width: 2) : null,
                ),
                child: Icon(widget.app.icon, color: Colors.white, size: 26),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              widget.app.label,
              textAlign: TextAlign.center,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                color: widget.active ? RemoteTokens.ink : RemoteTokens.inkMuted,
              ),
            ),
          ],
        ),
      );
}

/// Progresso (procurando, pareando) dentro do keypad — compacto, porque
/// mora no mesmo painel que depois vira o direcional, não numa tela cheia.
class _KeypadStatus extends StatelessWidget {
  const _KeypadStatus({required this.title, required this.body});

  final String title;
  final String body;

  @override
  Widget build(BuildContext context) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: RadialTokens.bloom,
            ),
          ),
          const SizedBox(height: 16),
          Text(title,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(
            body,
            textAlign: TextAlign.center,
            style: const TextStyle(color: RemoteTokens.inkMuted, height: 1.5),
          ),
        ],
      );
}
