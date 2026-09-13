import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../app/app_info.dart';
import '../theme.dart';
import '../widgets/primitives.dart';

/// The third-party copyright notices Encore is obliged to reproduce.
///
/// BSD-3-Clause, MIT and Apache-2.0 — which is everything in the dependency
/// tree, see `docs/licences.md` — all require the copyright notice to travel
/// with the binary. Without this screen the app satisfies none of them, which
/// is the one open item NFR-LEG-01 turned up in code rather than on paper.
///
/// It reads `LicenseRegistry`, Flutter's own collection of every `LICENSE`
/// file in the dependency graph, rather than a list checked in here: a
/// hand-written list is wrong the first time somebody edits `pubspec.yaml`.
/// The registry also carries the Flutter engine's vendored notices (Skia,
/// ICU, HarfBuzz and the rest), which we would otherwise have to gather by
/// hand.
///
/// Flutter ships `showLicensePage` for this. It is not used because it brings
/// its own Material scaffolding and would be the one screen in the app that
/// does not follow the design system.
class LicencesScreen extends StatefulWidget {
  const LicencesScreen({super.key});

  @override
  State<LicencesScreen> createState() => _LicencesScreenState();
}

class _LicencesScreenState extends State<LicencesScreen> {
  late final Future<List<_PackageLicences>> _licences = _collect();

  /// Groups the registry's entries by package.
  ///
  /// One licence can cover several packages and one package can carry several
  /// licences, so this is a many-to-many flattened into "what do I show under
  /// this name" — the same shape `showLicensePage` uses.
  static Future<List<_PackageLicences>> _collect() async {
    final byPackage = <String, List<LicenseEntry>>{};
    await for (final entry in LicenseRegistry.licenses) {
      for (final package in entry.packages) {
        byPackage.putIfAbsent(package, () => []).add(entry);
      }
    }
    final packages = byPackage.keys.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return [
      for (final package in packages)
        _PackageLicences(name: package, entries: byPackage[package]!),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: Palette.surface,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        title: const Text('Open-source licences'),
      ),
      body: AppGround(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 680),
            child: FutureBuilder<List<_PackageLicences>>(
              future: _licences,
              builder: (context, snapshot) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return const Center(
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  );
                }
                final packages = snapshot.data ?? const <_PackageLicences>[];
                return ListView(
                  padding: const EdgeInsets.fromLTRB(
                    Space.xl,
                    0,
                    Space.xl,
                    Space.huge,
                  ),
                  children: [
                    const SectionHeader(title: 'Encore'),
                    SurfacePanel(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(AppInfo.versionLabel, style: EncoreType.numeric),
                          const SizedBox(height: Space.sm),
                          Text(
                            'Encore is built on the work below. Each of these '
                            'is used under a licence that asks for its '
                            'copyright notice to be carried with the app, and '
                            'this screen is where Encore carries them.',
                            style: theme.textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                    SectionHeader(title: 'Packages', count: packages.length),
                    SurfacePanel(
                      padding: EdgeInsets.zero,
                      child: Column(
                        children: [
                          for (var i = 0; i < packages.length; i++) ...[
                            if (i > 0) const Divider(height: 1),
                            _PackageTile(package: packages[i]),
                          ],
                        ],
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _PackageTile extends StatelessWidget {
  const _PackageTile({required this.package});

  final _PackageLicences package;

  @override
  Widget build(BuildContext context) {
    final count = package.entries.length;
    return ListTile(
      title: Text(package.name),
      subtitle: Text(count == 1 ? '1 licence' : '$count licences'),
      trailing: const Icon(Icons.chevron_right_rounded, size: 18),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (context) => _LicenceTextScreen(package: package),
        ),
      ),
    );
  }
}

/// The licence text itself, verbatim.
///
/// Verbatim is the point — reproducing the notice is the obligation — so the
/// paragraphs are rendered as the registry supplies them, only laid out.
class _LicenceTextScreen extends StatelessWidget {
  const _LicenceTextScreen({required this.package});

  final _PackageLicences package;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: Palette.surface,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        title: Text(package.name),
      ),
      body: AppGround(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 680),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(
                Space.xl,
                Space.lg,
                Space.xl,
                Space.huge,
              ),
              children: [
                for (final entry in package.entries)
                  Padding(
                    padding: const EdgeInsets.only(bottom: Space.lg),
                    child: SurfacePanel(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          for (final paragraph in entry.paragraphs)
                            Padding(
                              padding: EdgeInsets.only(
                                left:
                                    paragraph.indent ==
                                        LicenseParagraph.centeredIndent
                                    ? 0
                                    : paragraph.indent * Space.md,
                                bottom: Space.md,
                              ),
                              child: Text(
                                paragraph.text,
                                textAlign:
                                    paragraph.indent ==
                                        LicenseParagraph.centeredIndent
                                    ? TextAlign.center
                                    : TextAlign.left,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: Palette.textSecondary,
                                  height: 1.5,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PackageLicences {
  const _PackageLicences({required this.name, required this.entries});

  final String name;
  final List<LicenseEntry> entries;
}
