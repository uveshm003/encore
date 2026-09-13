import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../ui/screens/library_screen.dart';
import '../ui/theme.dart';
import '../ui/widgets/brand.dart';
import '../ui/widgets/primitives.dart';
import 'app_services.dart';

/// The app once its services are up.
class EncoreApp extends StatelessWidget {
  const EncoreApp({required this.services, super.key});

  final AppServices services;

  @override
  Widget build(BuildContext context) {
    return ServicesScope(
      services: services,
      child: MaterialApp(
        title: 'Encore',
        debugShowCheckedModeBanner: false,
        theme: EncoreTheme.dark(),
        themeMode: ThemeMode.dark,
        scrollBehavior: const _EncoreScrollBehavior(),
        home: const LibraryScreen(),
      ),
    );
  }
}

/// Lets a mouse drag the timeline the way a finger does.
///
/// Flutter only allows touch to drag-scroll by default. The timeline is the
/// one view where dragging the surface is the natural gesture on a desktop
/// too, and there is no scroll wheel on a trackpad-less machine.
class _EncoreScrollBehavior extends MaterialScrollBehavior {
  const _EncoreScrollBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices => const {
    PointerDeviceKind.touch,
    PointerDeviceKind.mouse,
    PointerDeviceKind.trackpad,
    PointerDeviceKind.stylus,
  };
}

/// Shown while storage, codecs and the audio device are being set up, and in
/// place of the app if any of that fails.
///
/// Start-up touches the file system and opens an audio device, either of which
/// can fail on a real machine; failing to a readable screen with the actual
/// error beats a blank window.
class EncoreBootstrap extends StatefulWidget {
  const EncoreBootstrap({super.key});

  @override
  State<EncoreBootstrap> createState() => _EncoreBootstrapState();
}

class _EncoreBootstrapState extends State<EncoreBootstrap> {
  late Future<AppServices> _startup;

  @override
  void initState() {
    super.initState();
    _startup = AppServices.create();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<AppServices>(
      future: _startup,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return _shell(
            _StartupFailure(
              error: snapshot.error!,
              onRetry: () => setState(() => _startup = AppServices.create()),
            ),
          );
        }
        final services = snapshot.data;
        if (services == null) return _shell(const SplashScreen());
        return EncoreApp(services: services);
      },
    );
  }

  Widget _shell(Widget home) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: EncoreTheme.dark(),
    home: home,
  );
}

/// The first thing anyone sees.
///
/// Start-up is normally a few hundred milliseconds, so this is not a progress
/// screen — it is the mark, held still enough to be read, with the one claim
/// the app is built around underneath it.
class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: Palette.base,
      body: AppGround(
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const EncoreMark(size: 76, animate: true),
              const SizedBox(height: Space.xxl),
              Text(
                'Encore',
                style: EncoreType.wordmark.copyWith(
                  fontSize: 24,
                  letterSpacing: 1.2,
                ),
              ),
              const SizedBox(height: Space.sm),
              Text(
                'Offline vocal studio',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: Palette.textTertiary,
                  letterSpacing: 0.4,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StartupFailure extends StatelessWidget {
  const _StartupFailure({required this.error, required this.onRetry});

  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: Palette.base,
      body: AppGround(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Padding(
              padding: const EdgeInsets.all(Space.xxl),
              child: SurfacePanel(
                padding: const EdgeInsets.all(Space.xxl),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Container(
                      width: 44,
                      height: 44,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: Palette.record.withValues(alpha: 0.14),
                        borderRadius: Radii.allPanel,
                      ),
                      child: const Icon(
                        Icons.error_outline_rounded,
                        size: 22,
                        color: Palette.record,
                      ),
                    ),
                    const SizedBox(height: Space.lg),
                    Text(
                      'Encore could not start',
                      style: theme.textTheme.titleLarge,
                    ),
                    const SizedBox(height: Space.sm),
                    Text(
                      'The audio device or the folder Encore keeps its files '
                      'in could not be opened.',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: Palette.textSecondary,
                      ),
                    ),
                    const SizedBox(height: Space.lg),
                    Container(
                      padding: const EdgeInsets.all(Space.md),
                      decoration: BoxDecoration(
                        color: Palette.well,
                        borderRadius: Radii.allControl,
                        border: Border.all(color: Palette.lineFaint),
                      ),
                      child: SelectableText(
                        '$error',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: Palette.textTertiary,
                        ),
                      ),
                    ),
                    const SizedBox(height: Space.xl),
                    FilledButton.icon(
                      onPressed: onRetry,
                      icon: const Icon(Icons.refresh_rounded, size: 18),
                      label: const Text('Try again'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
