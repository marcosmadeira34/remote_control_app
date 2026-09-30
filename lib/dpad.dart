// dpad.dart
//
// Direcional circular com detecção por ângulo, e não quatro botões quadrados
// numa grade. O motivo é tátil: num controle físico o polegar encontra a
// direção pela borda do anel, sem mirar. Zonas em cunha de 90° reproduzem
// isso — a margem de erro é enorme perto da borda, que é justamente onde o
// polegar cai quando o usuário não está olhando.
//
// O acabamento é vidro preto com bisel cromado — a referência é uma lente ou
// um botão de equipamento de áudio premium, não o cinza chapado de um app
// comum. O acento do app em foco aparece só no glow por trás do OK e na
// cunha pressionada; o resto (o preto, o cromado, o brilho de vidro) é fixo
// e igual no modo de espera, porque é esse padrão bonito que não deve mudar.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'remote_theme.dart';

enum DpadZone { up, right, down, left, center }

class Dpad extends StatefulWidget {
  const Dpad({
    super.key,
    required this.onPress,
    this.diameter = RemoteTokens.dpadDiameter,
    this.enabled = true,
    this.accent = RemoteTokens.live,
  });

  /// Chamado a cada toque e a cada repetição do hold.
  final void Function(DpadZone zone) onPress;
  final double diameter;
  final bool enabled;

  /// Cor do anel do OK e do brilho por trás — normalmente a cor neutra da
  /// interface, mas o keypad "adapta" para a cor do app em foco na TV.
  final Color accent;

  @override
  State<Dpad> createState() => _DpadState();
}

class _DpadState extends State<Dpad> {
  DpadZone? _active;
  Timer? _holdDelay;
  Timer? _repeat;

  static const _holdThreshold = Duration(milliseconds: 420);
  static const _repeatInterval = Duration(milliseconds: 140);

  DpadZone? _zoneAt(Offset local) {
    final r = widget.diameter / 2;
    final v = local - Offset(r, r);
    final distance = v.distance;

    if (distance > r) return null;
    if (distance < r * RemoteTokens.dpadCenterRatio) return DpadZone.center;

    // atan2 devolve 0 apontando para a direita e cresce no sentido horário
    // (y cresce para baixo em coordenadas de tela).
    final angle = math.atan2(v.dy, v.dx);
    const quarter = math.pi / 4;
    if (angle >= -quarter && angle < quarter) return DpadZone.right;
    if (angle >= quarter && angle < 3 * quarter) return DpadZone.down;
    if (angle >= -3 * quarter && angle < -quarter) return DpadZone.up;
    return DpadZone.left;
  }

  void _fire(DpadZone zone) {
    widget.onPress(zone);
    HapticFeedback.selectionClick();
  }

  void _down(PointerDownEvent e) {
    if (!widget.enabled) return;
    final zone = _zoneAt(e.localPosition);
    if (zone == null) return;

    setState(() => _active = zone);
    _fire(zone);

    // OK não repete: segurar o OK numa TV abre menu de contexto, e repetir
    // "enter" dispara ações duplicadas.
    if (zone == DpadZone.center) return;

    _holdDelay = Timer(_holdThreshold, () {
      _repeat = Timer.periodic(_repeatInterval, (_) => _fire(zone));
    });
  }

  void _up([PointerEvent? _]) {
    _holdDelay?.cancel();
    _repeat?.cancel();
    _holdDelay = null;
    _repeat = null;
    if (_active != null) setState(() => _active = null);
  }

  @override
  void dispose() {
    _holdDelay?.cancel();
    _repeat?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Direcional',
      child: Listener(
        onPointerDown: _down,
        onPointerUp: _up,
        onPointerCancel: _up,
        // A sombra por baixo do disco é o que separa o anel do fundo — sem
        // ela o vidro preto vira só uma mancha achatada.
        child: DecoratedBox(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: widget.enabled ? 0.55 : 0.25),
                blurRadius: 20,
                offset: const Offset(0, 12),
              ),
            ],
          ),
          child: CustomPaint(
            size: Size.square(widget.diameter),
            painter: _DpadPainter(
              active: _active,
              enabled: widget.enabled,
              accent: widget.accent,
            ),
          ),
        ),
      ),
    );
  }
}

/// Poeira de brilho no vidro, em coordenadas unitárias (-1..1) relativas ao
/// raio — gerada uma vez com semente fixa, não a cada frame. Reescalar pelo
/// raio em cada pintura é barato; regenerar posições aleatórias não seria.
final List<({double dx, double dy, double r, double alpha})> _glassSparkle =
    _generateSparkle();

List<({double dx, double dy, double r, double alpha})> _generateSparkle() {
  final rnd = math.Random(7);
  return List.generate(60, (_) {
    final angle = rnd.nextDouble() * 2 * math.pi;
    // sqrt(uniforme) espalha os pontos igualmente pela área do anel, em vez
    // de amontoar perto do centro.
    final dist = 0.55 + math.sqrt(rnd.nextDouble()) * 0.4;
    return (
      dx: math.cos(angle) * dist,
      dy: math.sin(angle) * dist,
      r: 0.5 + rnd.nextDouble() * 1.0,
      alpha: 0.10 + rnd.nextDouble() * 0.45,
    );
  });
}

class _DpadPainter extends CustomPainter {
  _DpadPainter({required this.active, required this.enabled, required this.accent});

  final DpadZone? active;
  final bool enabled;
  final Color accent;

  static const _glassTop = Color(0xFF1E2024);
  static const _glassDeep = Color(0xFF06070A);
  static const _chromeBright = Color(0xFFEDEFF2);
  static const _chromeMid = Color(0xFF7C8087);
  static const _chromeDark = Color(0xFF212327);

  @override
  void paint(Canvas canvas, Size size) {
    final r = size.width / 2;
    final center = Offset(r, r);
    final innerR = r * RemoteTokens.dpadCenterRatio;
    final opacity = enabled ? 1.0 : 0.35;
    final ringRect = Rect.fromCircle(center: center, radius: r);

    // Vidro preto: gradiente radial deslocado simula uma cúpula funda
    // recebendo pouca luz — a base escura da referência, não o cinza médio
    // de antes.
    canvas.drawCircle(
      center,
      r,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(-0.3, -0.45),
          radius: 1.15,
          colors: [_glassTop.withValues(alpha: opacity), _glassDeep.withValues(alpha: opacity)],
        ).createShader(ringRect),
    );

    // Bisel cromado: sweep gradient com faixas claras e escuras alternando,
    // como luz batendo de forma desigual num aro de metal polido.
    canvas.drawCircle(
      center,
      r - 2,
      Paint()
        ..shader = SweepGradient(
          startAngle: 0,
          endAngle: 2 * math.pi,
          colors: [
            _chromeDark,
            _chromeBright,
            _chromeMid,
            _chromeDark,
            _chromeBright,
            _chromeMid,
            _chromeDark,
          ],
          stops: const [0, 0.14, 0.30, 0.5, 0.66, 0.82, 1.0],
          transform: const GradientRotation(-math.pi / 3),
        ).createShader(ringRect)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3.2
        ..strokeCap = StrokeCap.round,
    );

    // Poeira de vidro: pontinhos claros espalhados na faixa entre o miolo e
    // a borda — é o que faz a superfície ler como vidro polido, não plástico.
    for (final s in _glassSparkle) {
      canvas.drawCircle(
        center + Offset(s.dx * r, s.dy * r),
        s.r * (r / RemoteTokens.dpadDiameter * 2).clamp(0.55, 1.0),
        Paint()..color = Colors.white.withValues(alpha: s.alpha * opacity * 0.7),
      );
    }

    // Cunha pressionada: o acento entra aqui com força, porque o vidro de
    // fundo agora é escuro o bastante para não lavar a cor.
    if (active != null && active != DpadZone.center) {
      final startAngle = switch (active!) {
        DpadZone.right => -math.pi / 4,
        DpadZone.down => math.pi / 4,
        DpadZone.left => 3 * math.pi / 4,
        DpadZone.up => -3 * math.pi / 4,
        DpadZone.center => 0.0,
      };
      canvas.drawPath(
        Path()
          ..moveTo(center.dx, center.dy)
          ..arcTo(Rect.fromCircle(center: center, radius: r - 4), startAngle,
              math.pi / 2, false)
          ..close(),
        Paint()..color = accent.withValues(alpha: 0.30),
      );
      // Redesenha o miolo por cima para a cunha não invadir o OK.
      canvas.drawCircle(center, innerR + 6, Paint()..color = _glassDeep);
    }

    // Brilho especular: um arco fino e claro perto da borda superior,
    // sugerindo a curvatura de vidro sem precisar de textura de imagem.
    canvas.drawArc(
      ringRect.deflate(6),
      -math.pi * 0.78,
      math.pi * 0.42,
      false,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.16 * opacity)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.4
        ..strokeCap = StrokeCap.round,
    );

    // Setas: quase brancas, com um traço do acento — no vidro escuro, ink
    // puro sumiria de contraste.
    final arrow = Paint()
      ..color = (enabled
              ? Color.lerp(Colors.white, accent, 0.3)!
              : RemoteTokens.inkMuted)
          .withValues(alpha: opacity)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.5
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final ringMid = (r + innerR) / 2;
    for (final zone in [
      DpadZone.up,
      DpadZone.right,
      DpadZone.down,
      DpadZone.left
    ]) {
      final angle = switch (zone) {
        DpadZone.up => -math.pi / 2,
        DpadZone.right => 0.0,
        DpadZone.down => math.pi / 2,
        DpadZone.left => math.pi,
        DpadZone.center => 0.0,
      };
      final at = center + Offset(math.cos(angle), math.sin(angle)) * ringMid;
      canvas.save();
      canvas.translate(at.dx, at.dy);
      canvas.rotate(angle);
      // Chevron apontando para +x, girado para a direção da zona.
      canvas.drawPath(
        Path()
          ..moveTo(-5, -9)
          ..lineTo(5, 0)
          ..lineTo(-5, 9),
        arrow,
      );
      canvas.restore();
    }

    // Miolo (OK): a mesma lente funda do anel, só que com o glow do acento
    // por trás — é o único lugar, junto da cunha, onde a cor do app aparece.
    canvas.drawCircle(
      center,
      innerR + 6,
      Paint()
        ..color = accent.withValues(alpha: enabled ? 0.30 : 0.08)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 12),
    );
    canvas.drawCircle(
      center,
      innerR,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(-0.3, -0.4),
          radius: 1.2,
          colors: [
            (active == DpadZone.center ? _glassDeep : _glassTop)
                .withValues(alpha: opacity),
            _glassDeep.withValues(alpha: opacity),
          ],
        ).createShader(Rect.fromCircle(center: center, radius: innerR)),
    );
    canvas.drawCircle(
      center,
      innerR,
      Paint()
        ..color = accent.withValues(alpha: enabled ? 0.7 : 0.2)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );

    final label = TextPainter(
      text: TextSpan(
        text: 'OK',
        style: TextStyle(
          color: (enabled ? Colors.white : RemoteTokens.inkMuted)
              .withValues(alpha: opacity),
          fontSize: 19,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.5,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    label.paint(canvas, center - Offset(label.width / 2, label.height / 2));
  }

  @override
  bool shouldRepaint(_DpadPainter old) =>
      old.active != active || old.enabled != enabled || old.accent != accent;
}
