import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../app/app_services.dart';
import '../../io/codec/codec_exception.dart';
import '../../io/import_format_summary.dart';
import '../../library/media_item.dart';
import '../../library/media_library.dart';
import '../../project/models/project.dart';
import '../../project/project_factory.dart';
import '../theme.dart';
import '../widgets/artwork_tile.dart';
import '../widgets/brand.dart';
import '../widgets/primitives.dart';
import 'onboarding_screen.dart';
import 'separation_screen.dart';
import 'settings_screen.dart';
import 'studio_screen.dart';

/// Home: the songs that have been imported and the projects made from them
/// (LIB-01, PROJ-04).
class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key});

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  List<ProjectSummary> _projects = const [];
  bool _importing = false;
  String? _importMessage;
  double _importProgress = 0;
  String _query = '';

  /// Above this many rows the list is worth filtering.
  static const int _searchThreshold = 6;

  StreamSubscription<List<String>>? _incoming;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _refreshProjects();
      _maybeShowOnboarding();
      _listenForSharedFiles();
    });
  }

  @override
  void dispose() {
    _incoming?.cancel();
    super.dispose();
  }

  /// Picks up songs sent from another app or opened from a file manager.
  ///
  /// Subscribing before [IncomingFiles.start] matters: start drains whatever
  /// the platform was holding from a cold launch into the same stream, and a
  /// listener attached afterwards would miss exactly the case that is hardest
  /// to get right.
  void _listenForSharedFiles() {
    final incoming = _services.incoming;
    _incoming = incoming.files.listen((paths) {
      if (mounted) _importPaths(paths);
    });
    incoming.start();
  }

  AppServices get _services => ServicesScope.of(context);

  Future<void> _maybeShowOnboarding() async {
    final settings = _services.settings;
    if (settings.hasSeenOnboarding) return;
    if (!mounted) return;
    await Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => const OnboardingScreen()));
    await settings.markOnboardingSeen();
  }

  Future<void> _refreshProjects() async {
    final projects = await _services.projects.list();
    if (mounted) setState(() => _projects = projects);
  }

  // ------------------------------------------------------------------ import

  Future<void> _import() async {
    // What this device can actually decode, not the full list from the
    // requirement: offering a format the picker will then refuse to import
    // wastes the user's time and looks like a bug (IMP-01).
    final extensions = _services.codecs.decodableExtensions;
    final files = await FilePicker.pickFiles(
      dialogTitle: 'Choose songs to import',
      // With no backend at all, filtering to nothing would leave every file
      // greyed out. Better to let the picker offer everything and report a
      // clear error on import (IMP-04) than to present an empty dialog.
      type: extensions.isEmpty ? FileType.audio : FileType.custom,
      allowedExtensions: extensions.isEmpty ? null : extensions,
    );
    final paths = [
      for (final file in files)
        if (file.path != null) file.path!,
    ];
    await _importPaths(paths);
  }

  /// Imports [paths], wherever they came from.
  ///
  /// Split out from [_import] so a song arriving from the share sheet gets the
  /// same progress, the same error reporting and the same duplicate handling
  /// as one chosen in the picker (IMP-05).
  Future<void> _importPaths(List<String> paths) async {
    if (paths.isEmpty || _importing) return;

    setState(() {
      _importing = true;
      _importProgress = 0;
      _importMessage = 'Preparing…';
    });

    final result = await _services.library.importAll(
      paths,
      onProgress: (progress) {
        if (!mounted) return;
        setState(() {
          _importMessage = progress.description;
          _importProgress = progress.fraction;
        });
      },
    );

    if (!mounted) return;
    setState(() => _importing = false);

    if (result.hasFailures) {
      _showImportFailures(result);
    } else if (result.imported.length == 1) {
      _showSnack('Imported ${result.imported.single.title}');
    } else if (result.imported.isNotEmpty) {
      _showSnack('Imported ${result.imported.length} songs');
    }
  }

  /// What this device can open, in words fit to show the user.
  ImportFormatSummary get _formats => ImportFormatSummary.of(_services.codecs);

  void _showImportFailures(BatchImportResult result) {
    // Only worth suggesting FFmpeg when a file failed because nothing on this
    // device could read it — not when it was simply corrupt or missing.
    final unreadable = result.failures.values.any(
      (error) =>
          error.kind == CodecErrorKind.noBackend ||
          error.kind == CodecErrorKind.unsupportedFormat,
    );
    final hint = unreadable ? _formats.missingSentence : null;

    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          result.imported.isEmpty
              ? 'Nothing could be imported'
              : 'Some files could not be imported',
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final entry in result.failures.entries)
              Padding(
                padding: const EdgeInsets.only(bottom: Space.md),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      entry.key.split('/').last,
                      style: Theme.of(context).textTheme.labelLarge,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      entry.value.message,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            if (hint != null)
              Padding(
                padding: const EdgeInsets.only(top: Space.xs),
                child: Text(
                  '${_formats.supportedSentence} $hint',
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: Palette.textTertiary),
                ),
              ),
          ],
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------- projects

  Future<void> _separate(MediaItem item) async {
    final stems = await Navigator.of(context).push<SeparationOutcome>(
      MaterialPageRoute(builder: (_) => SeparationScreen(item: item)),
    );
    if (stems == null || !mounted) return;

    final factory = ProjectFactory(
      repository: _services.projects,
      assets: _services.assets,
    );
    final project = await factory.fromStems(
      source: item,
      stems: stems.stems,
      config: _services.config,
    );
    await _refreshProjects();
    if (mounted) await _openProject(project.id);
  }

  Future<void> _openWithoutSeparating(MediaItem item) async {
    final factory = ProjectFactory(
      repository: _services.projects,
      assets: _services.assets,
    );
    final project = await factory.fromMedia(
      source: item,
      audioPath: _services.library.audioPathFor(item),
      config: _services.config,
    );
    await _refreshProjects();
    if (mounted) await _openProject(project.id);
  }

  Future<void> _openProject(String id) async {
    await _services.controller.open(id);
    if (!mounted) return;
    await Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => const StudioScreen()));
    await _services.controller.close();
    await _refreshProjects();
  }

  Future<void> _renameProject(ProjectSummary summary) async {
    final name = await _promptForName('Rename project', summary.name);
    if (name == null) return;
    await _services.projects.rename(summary.id, name);
    await _refreshProjects();
  }

  Future<void> _duplicateProject(ProjectSummary summary) async {
    await _services.projects.duplicate(summary.id);
    await _refreshProjects();
    if (mounted) _showSnack('Duplicated ${summary.name}');
  }

  Future<void> _deleteProject(ProjectSummary summary) async {
    final confirmed = await _confirm(
      title: 'Delete “${summary.name}”?',
      message:
          'The project and any takes recorded into it are deleted. Imported '
          'songs and separated stems are kept.',
      confirmLabel: 'Delete',
    );
    if (!confirmed) return;
    await _services.projects.delete(summary.id);
    await _refreshProjects();
  }

  Future<void> _deleteSong(MediaItem item) async {
    final confirmed = await _confirm(
      title: 'Remove “${item.title}”?',
      message:
          'Encore’s copy is deleted. Your original file is left exactly where '
          'it is.',
      confirmLabel: 'Remove',
    );
    if (!confirmed) return;
    await _services.library.delete(item.id);
  }

  // -------------------------------------------------------------------- view

  @override
  Widget build(BuildContext context) {
    final library = _services.library;
    return ListenableBuilder(
      listenable: library,
      builder: (context, _) => _buildScaffold(context, library.items),
    );
  }

  Widget _buildScaffold(BuildContext context, List<MediaItem> allSongs) {
    // With nothing in the library the empty state carries its own call to
    // action, so a floating button beside it would just be the same control
    // twice.
    final isEmpty = allSongs.isEmpty && _projects.isEmpty;
    final songs = [...allSongs]
      ..sort((a, b) => b.importedAt.compareTo(a.importedAt));
    final searchable = songs.length + _projects.length > _searchThreshold;
    final query = _query.trim().toLowerCase();
    final filteredSongs = query.isEmpty
        ? songs
        : [
            for (final song in songs)
              if (song.title.toLowerCase().contains(query)) song,
          ];
    final filteredProjects = query.isEmpty
        ? _projects
        : [
            for (final project in _projects)
              if (project.name.toLowerCase().contains(query) ||
                  (project.sourceTitle ?? '').toLowerCase().contains(query))
                project,
          ];

    return Scaffold(
      backgroundColor: Palette.surface,
      floatingActionButton: isEmpty
          ? null
          : Tooltip(
              // The formats live on the control that opens the picker, so the
              // answer to "will it take my file?" is available before the
              // dialog rather than after a failed import (IMP-01).
              message: _formats.fullSentence,
              child: FloatingActionButton.extended(
                onPressed: _importing ? null : _import,
                icon: const Icon(Icons.add_rounded, size: 20),
                label: const Text('Import songs'),
              ),
            ),
      body: AppGround(
        child: SafeArea(
          bottom: false,
          child: Column(
            children: [
              _header(context, searchable),
              Expanded(
                child: isEmpty
                    ? _EmptyLibrary(
                        onImport: _import,
                        formats: _formats.fullSentence,
                      )
                    : _content(context, filteredSongs, filteredProjects),
              ),
            ],
          ),
        ),
      ),
      bottomSheet: _importing
          ? _ImportProgress(
              message: _importMessage ?? '',
              progress: _importProgress,
            )
          : null,
    );
  }

  Widget _header(BuildContext context, bool searchable) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        Space.xl,
        Space.lg,
        Space.xl,
        Space.sm,
      ),
      child: Column(
        children: [
          Row(
            children: [
              const EncoreWordmark(markSize: 26),
              const SizedBox(width: Space.md),
              const OfflineBadge(),
              const Spacer(),
              _headerAction(
                icon: Icons.help_outline_rounded,
                tooltip: 'How it works',
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const OnboardingScreen(),
                  ),
                ),
              ),
              const SizedBox(width: Space.sm),
              _headerAction(
                icon: Icons.tune_rounded,
                tooltip: 'Settings',
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const SettingsScreen(),
                  ),
                ),
              ),
            ],
          ),
          if (searchable) ...[
            const SizedBox(height: Space.lg),
            SizedBox(
              height: 40,
              child: TextField(
                onChanged: (value) => setState(() => _query = value),
                textInputAction: TextInputAction.search,
                style: Theme.of(context).textTheme.bodyMedium,
                decoration: InputDecoration(
                  hintText: 'Search songs and projects',
                  prefixIcon: const Icon(Icons.search_rounded, size: 18),
                  prefixIconConstraints: const BoxConstraints(
                    minWidth: 38,
                    minHeight: 38,
                  ),
                  suffixIcon: _query.isEmpty
                      ? null
                      : IconButton(
                          tooltip: 'Clear',
                          iconSize: 16,
                          onPressed: () => setState(() => _query = ''),
                          icon: const Icon(Icons.close_rounded),
                        ),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _headerAction({
    required IconData icon,
    required String tooltip,
    required VoidCallback onPressed,
  }) {
    return Tooltip(
      message: tooltip,
      child: IconButton(
        onPressed: onPressed,
        icon: Icon(icon, size: 19),
        style: IconButton.styleFrom(
          backgroundColor: Palette.panel,
          foregroundColor: Palette.textSecondary,
          minimumSize: const Size(38, 38),
          shape: const RoundedRectangleBorder(
            borderRadius: Radii.allControl,
            side: BorderSide(color: Palette.lineFaint),
          ),
        ),
      ),
    );
  }

  Widget _content(
    BuildContext context,
    List<MediaItem> songs,
    List<ProjectSummary> projects,
  ) {
    final theme = Theme.of(context);
    if (songs.isEmpty && projects.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(Space.xxl),
          child: Text(
            'Nothing matches “$_query”.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: Palette.textTertiary,
            ),
          ),
        ),
      );
    }

    // The most recent project gets a card of its own: coming back to
    // yesterday's take is the commonest reason to open the app twice.
    final resume = projects.isNotEmpty ? projects.first : null;
    final rest = projects.length > 1 ? projects.sublist(1) : const [];
    var row = 0;

    return ListView(
      padding: const EdgeInsets.fromLTRB(
        Space.xl,
        Space.sm,
        Space.xl,
        Space.huge * 2.4,
      ),
      children: [
        if (resume != null) ...[
          const SectionHeader(
            title: 'Continue',
            padding: EdgeInsets.fromLTRB(
              Space.xs,
              Space.md,
              Space.xs,
              Space.md,
            ),
          ),
          EntranceFade(
            index: row++,
            child: _ResumeCard(
              summary: resume,
              onOpen: () => _openProject(resume.id),
              onRename: () => _renameProject(resume),
              onDuplicate: () => _duplicateProject(resume),
              onDelete: () => _deleteProject(resume),
            ),
          ),
        ],
        if (rest.isNotEmpty) ...[
          SectionHeader(title: 'Projects', count: rest.length),
          for (final summary in rest)
            EntranceFade(
              index: row++,
              child: Padding(
                padding: const EdgeInsets.only(bottom: Space.sm),
                child: _ProjectRow(
                  summary: summary,
                  onOpen: () => _openProject(summary.id),
                  onRename: () => _renameProject(summary),
                  onDuplicate: () => _duplicateProject(summary),
                  onDelete: () => _deleteProject(summary),
                ),
              ),
            ),
        ],
        SectionHeader(
          title: 'Songs',
          count: songs.isEmpty ? null : songs.length,
        ),
        if (songs.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: Space.lg),
            child: Text(
              'Import a song to get started.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: Palette.textTertiary,
              ),
            ),
          ),
        for (final item in songs)
          EntranceFade(
            index: row++,
            child: Padding(
              padding: const EdgeInsets.only(bottom: Space.sm),
              child: _SongRow(
                item: item,
                onSeparate: () => _separate(item),
                onOpen: () => _openWithoutSeparating(item),
                onDelete: () => _deleteSong(item),
              ),
            ),
          ),
      ],
    );
  }

  // ----------------------------------------------------------------- helpers

  void _showSnack(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<String?> _promptForName(String title, String initial) {
    final controller = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          onSubmitted: (value) => Navigator.of(context).pop(value.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    ).then((value) => (value == null || value.isEmpty) ? null : value);
  }

  Future<bool> _confirm({
    required String title,
    required String message,
    required String confirmLabel,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Palette.record,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(confirmLabel),
          ),
        ],
      ),
    );
    return result ?? false;
  }
}

/// The strip that appears along the bottom while files are being decoded.
class _ImportProgress extends StatelessWidget {
  const _ImportProgress({required this.message, required this.progress});

  final String message;
  final double progress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(
        Space.xl,
        Space.md,
        Space.xl,
        Space.lg,
      ),
      decoration: const BoxDecoration(
        color: Palette.overlay,
        border: Border(top: BorderSide(color: Palette.line)),
      ),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: Space.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    message,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: Palette.textPrimary,
                    ),
                  ),
                  const SizedBox(height: Space.sm),
                  ProgressTrack(
                    value: progress <= 0 ? null : progress,
                    height: 4,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyLibrary extends StatelessWidget {
  const _EmptyLibrary({required this.onImport, required this.formats});

  final VoidCallback onImport;

  /// Which formats this device can open — the first screen a new user sees is
  /// the right place to answer it, rather than leaving them to find out by
  /// picking a file that fails.
  final String formats;

  @override
  Widget build(BuildContext context) {
    return EmptyState(
      art: const EncoreMark(size: 72, animate: true),
      title: 'Nothing here yet',
      message:
          'Import a song from this device. Encore removes the vocals right '
          'here, then you can sing over the backing and record it.\n\n'
          '$formats',
      action: FilledButton.icon(
        onPressed: onImport,
        icon: const Icon(Icons.add_rounded, size: 20),
        label: const Text('Import songs'),
      ),
      footnote: const OfflineBadge(label: 'Nothing leaves this device'),
    );
  }
}

/// The large card for the project that was open most recently.
class _ResumeCard extends StatelessWidget {
  const _ResumeCard({
    required this.summary,
    required this.onOpen,
    required this.onRename,
    required this.onDuplicate,
    required this.onDelete,
  });

  final ProjectSummary summary;
  final VoidCallback onOpen;
  final VoidCallback onRename;
  final VoidCallback onDuplicate;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tint = ArtworkTile.colourFor(summary.sourceTitle ?? summary.name);

    return PressableSurface(
      onTap: onOpen,
      accent: tint,
      borderRadius: Radii.allPanel,
      semanticLabel: 'Open ${summary.name}',
      child: Stack(
        children: [
          // The project's colour as a stripe down the leading edge — a strip
          // of tape on the spine. It used to be a wash fading across the whole
          // card, which tinted the text it sat behind and made every row look
          // like a different shade of the same idea.
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            width: 2,
            child: IgnorePointer(child: ColoredBox(color: tint)),
          ),
          Padding(
            padding: const EdgeInsets.all(Space.lg),
            child: Row(
              children: [
                ArtworkTile(
                  seed: summary.sourceTitle ?? summary.name,
                  size: 60,
                  icon: Icons.graphic_eq_rounded,
                ),
                const SizedBox(width: Space.lg),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        summary.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleLarge,
                      ),
                      const SizedBox(height: Space.xs),
                      Text(
                        'Edited ${relativeTime(summary.modifiedAt)}',
                        style: theme.textTheme.bodySmall,
                      ),
                      const SizedBox(height: Space.md),
                      Wrap(
                        spacing: Space.sm,
                        runSpacing: Space.xs,
                        children: [
                          MetaChip(
                            label:
                                '${summary.trackCount} '
                                '${summary.trackCount == 1 ? 'track' : 'tracks'}',
                            icon: Icons.layers_rounded,
                          ),
                          MetaChip(
                            label: formatDuration(summary.duration),
                            icon: Icons.schedule_rounded,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: Space.md),
                Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    _ProjectMenu(
                      onRename: onRename,
                      onDuplicate: onDuplicate,
                      onDelete: onDelete,
                    ),
                    const SizedBox(height: Space.sm),
                    FilledButton.icon(
                      onPressed: onOpen,
                      icon: const Icon(Icons.play_arrow_rounded, size: 18),
                      label: const Text('Continue'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ProjectRow extends StatelessWidget {
  const _ProjectRow({
    required this.summary,
    required this.onOpen,
    required this.onRename,
    required this.onDuplicate,
    required this.onDelete,
  });

  final ProjectSummary summary;
  final VoidCallback onOpen;
  final VoidCallback onRename;
  final VoidCallback onDuplicate;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PressableSurface(
      onTap: onOpen,
      padding: const EdgeInsets.all(Space.md),
      semanticLabel: 'Open ${summary.name}',
      child: Row(
        children: [
          ArtworkTile(
            seed: summary.sourceTitle ?? summary.name,
            size: 44,
            icon: Icons.graphic_eq_rounded,
          ),
          const SizedBox(width: Space.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  summary.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall,
                ),
                const SizedBox(height: 3),
                Text(
                  '${summary.trackCount} '
                  '${summary.trackCount == 1 ? 'track' : 'tracks'} · '
                  '${formatDuration(summary.duration)} · '
                  'edited ${relativeTime(summary.modifiedAt)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
          _ProjectMenu(
            onRename: onRename,
            onDuplicate: onDuplicate,
            onDelete: onDelete,
          ),
        ],
      ),
    );
  }
}

class _ProjectMenu extends StatelessWidget {
  const _ProjectMenu({
    required this.onRename,
    required this.onDuplicate,
    required this.onDelete,
  });

  final VoidCallback onRename;
  final VoidCallback onDuplicate;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: 'Project options',
      iconSize: 18,
      icon: const Icon(Icons.more_horiz_rounded, color: Palette.textTertiary),
      onSelected: (value) {
        if (value == 'rename') onRename();
        if (value == 'duplicate') onDuplicate();
        if (value == 'delete') onDelete();
      },
      itemBuilder: (context) => [
        const PopupMenuItem(value: 'rename', child: Text('Rename')),
        const PopupMenuItem(value: 'duplicate', child: Text('Duplicate')),
        PopupMenuItem(
          value: 'delete',
          child: Text('Delete', style: TextStyle(color: Palette.record)),
        ),
      ],
    );
  }
}

class _SongRow extends StatelessWidget {
  const _SongRow({
    required this.item,
    required this.onSeparate,
    required this.onOpen,
    required this.onDelete,
  });

  final MediaItem item;
  final VoidCallback onSeparate;
  final VoidCallback onOpen;
  final VoidCallback onDelete;

  /// Below this width the action moves onto its own line: a labelled button
  /// beside the title leaves a phone-width row with almost no room for the
  /// song's name.
  static const double _inlineActionWidth = 460;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PressableSurface(
      onTap: onSeparate,
      padding: const EdgeInsets.all(Space.md),
      semanticLabel: 'Remove vocals from ${item.title}',
      child: LayoutBuilder(
        builder: (context, constraints) {
          final inline = constraints.maxWidth >= _inlineActionWidth;
          final action = FilledButton.tonal(
            onPressed: onSeparate,
            style: FilledButton.styleFrom(
              backgroundColor: Palette.ember.withValues(alpha: 0.14),
              foregroundColor: Palette.emberBright,
              minimumSize: const Size(0, 38),
              padding: const EdgeInsets.symmetric(horizontal: Space.lg),
              textStyle: theme.textTheme.labelMedium,
              shape: const RoundedRectangleBorder(borderRadius: Radii.allControl),
            ),
            child: const Text('Remove vocals'),
          );

          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  ArtworkTile(seed: item.title, size: 44),
                  const SizedBox(width: Space.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          item.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall,
                        ),
                        const SizedBox(height: 5),
                        Wrap(
                          spacing: Space.xs,
                          runSpacing: Space.xs,
                          children: [
                            MetaChip(
                              label: formatDuration(item.duration),
                              icon: Icons.schedule_rounded,
                            ),
                            MetaChip(label: item.sourceFormat.displayName),
                            if (item.wasConverted)
                              MetaChip(label: '${item.sampleRate ~/ 1000} kHz'),
                          ],
                        ),
                      ],
                    ),
                  ),
                  if (inline) ...[const SizedBox(width: Space.md), action],
                  const SizedBox(width: Space.xs),
                  _menu(),
                ],
              ),
              if (!inline) ...[
                const SizedBox(height: Space.md),
                SizedBox(width: double.infinity, child: action),
              ],
            ],
          );
        },
      ),
    );
  }

  Widget _menu() {
    return PopupMenuButton<String>(
      tooltip: 'Song options',
      iconSize: 18,
      icon: const Icon(Icons.more_horiz_rounded, color: Palette.textTertiary),
      onSelected: (value) {
        if (value == 'open') onOpen();
        if (value == 'delete') onDelete();
      },
      itemBuilder: (context) => [
        const PopupMenuItem(
          value: 'open',
          child: Text('Open without separating'),
        ),
        const PopupMenuItem(
          value: 'delete',
          child: Text(
            'Remove from library',
            style: TextStyle(color: Palette.record),
          ),
        ),
      ],
    );
  }
}

/// "just now", "12 min ago", "3 d ago", then a date.
String relativeTime(DateTime time) {
  final difference = DateTime.now().difference(time);
  if (difference.inMinutes < 1) return 'just now';
  if (difference.inHours < 1) return '${difference.inMinutes} min ago';
  if (difference.inDays < 1) return '${difference.inHours} h ago';
  if (difference.inDays < 7) return '${difference.inDays} d ago';
  return '${time.day}/${time.month}/${time.year}';
}
