// main.dart

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'demo_tv_repository.dart';
import 'playback_cubit.dart';
import 'remote_analytics.dart';
import 'remote_control_bloc.dart';
import 'remote_screen.dart';
import 'remote_theme.dart';
import 'tv_connection_bloc.dart';
import 'tv_repository.dart';

/// flutter run --dart-define=DEMO_MODE=true
///
/// Liga uma TV falsa que "conecta" sozinha, para desenvolver a UI num
/// emulador sem precisar de uma Smart TV por perto. Nunca ativa sozinho num
/// build de release: precisa ser passado explicitamente na linha de comando.
const _demoMode = bool.fromEnvironment('DEMO_MODE');

void main() => runApp(const RemoteApp());

class RemoteApp extends StatelessWidget {
  const RemoteApp({super.key});

  @override
  Widget build(BuildContext context) {
    // Troque por FirebaseRemoteAnalytics depois de configurar o Firebase.
    // Até lá o Noop deixa o app rodar sem google-services.json.
    final tracker = SessionTracker(const NoopRemoteAnalytics());

    return MultiRepositoryProvider(
      providers: [
        RepositoryProvider<TvRepository>(
          // ATENÇÃO: este nome é a chave do pareamento. A TV guarda o token
          // vinculado a ele — mudar depois de publicar força todos os
          // usuários a parear de novo. Congele agora.
          create: (_) => _demoMode
              ? DemoTvRepository()
              : TvRepositoryImpl(appName: 'Controle Remoto'),
        ),
        RepositoryProvider<SessionTracker>.value(value: tracker),
      ],
      child: MultiBlocProvider(
        providers: [
          BlocProvider(
            create: (ctx) => TvConnectionBloc(ctx.read<TvRepository>()),
          ),
          BlocProvider(
            create: (ctx) => RemoteControlBloc(
              ctx.read<TvRepository>(),
              tracker: tracker,
            ),
          ),
          BlocProvider(
            create: (ctx) => PlaybackCubit(ctx.read<TvRepository>()),
          ),
        ],
        child: MaterialApp(
          title: 'Controle Remoto',
          debugShowCheckedModeBanner: false,
          theme: buildRemoteTheme(),
          home: const RemoteScreen(),
        ),
      ),
    );
  }
}
