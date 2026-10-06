import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core_api/commands.dart';
import '../storage/google_drive_service.dart';
import '../../l10n/l10n.dart';
import '../../providers/core_providers.dart';
import '../../routing/routes.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../sources/sources_screen.dart';

/// First run. The privacy promise comes before the sign-in, not after it,
/// because "why does this app want my whole Drive?" is the first question an
/// audiophile asks.
class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key});

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  final _controller = PageController();
  int _page = 0;

  static const _pageCount = 5;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _next() {
    if (_page < _pageCount - 1) {
      _controller.nextPage(duration: Motion.standard, curve: Motion.enter);
    } else {
      sendCommand(ref, const Rescan());
      context.go(Routes.home);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: PageView(
                controller: _controller,
                onPageChanged: (i) => setState(() => _page = i),
                children: const [
                  _Welcome(),
                  _PrivacyPromise(),
                  _ConnectSource(),
                  _ChooseFolders(),
                  _ScanStarts(),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(Spacing.md),
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      for (var i = 0; i < _pageCount; i++)
                        AnimatedContainer(
                          duration: Motion.micro,
                          margin: const EdgeInsets.symmetric(horizontal: 3),
                          width: i == _page ? 18 : 6,
                          height: 6,
                          decoration: BoxDecoration(
                            color: i == _page ? c.accent : c.outline,
                            borderRadius: BorderRadius.circular(3),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: Spacing.md),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: _next,
                      child: Text(switch (_page) {
                        0 => context.l10n.actionGetStarted,
                        2 => 'Continue with Google',
                        4 => 'Go to my library',
                        _ => context.l10n.actionContinue,
                      }),
                    ),
                  ),
                  if (_page > 0 && _page < _pageCount - 1)
                    TextButton(
                      onPressed: () => context.go(Routes.home),
                      child: Text(context.l10n.actionSkip),
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

class _Page extends StatelessWidget {
  const _Page({
    required this.icon,
    required this.title,
    required this.body,
    this.children = const [],
  });

  final IconData icon;
  final String title;
  final String body;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return ListView(
      padding: const EdgeInsets.fromLTRB(
          Spacing.xl, Spacing.xxl, Spacing.xl, Spacing.md),
      children: [
        Container(
          width: 88,
          height: 88,
          decoration: BoxDecoration(
            color: c.accent.withOpacity(0.12),
            shape: BoxShape.circle,
          ),
          child: Icon(icon, size: 40, color: c.accent),
        ),
        const SizedBox(height: Spacing.xl),
        Text(title, style: context.t.display),
        const SizedBox(height: Spacing.sm),
        Text(body, style: context.t.body.copyWith(color: c.textSecondary)),
        const SizedBox(height: Spacing.lg),
        ...children,
      ],
    );
  }
}

class _Welcome extends StatelessWidget {
  const _Welcome();

  @override
  Widget build(BuildContext context) => _Page(
        icon: Icons.graphic_eq,
        title: 'BitDrop',
        body: context.l10n.tagline,
        children: const [
          _Point(
            icon: Icons.cloud_queue,
            title: 'Your cloud, your files',
            body: 'Streams straight from Google Drive to your phone.',
          ),
          _Point(
            icon: Icons.usb,
            title: 'Straight to your DAC',
            body: 'The best path your phone allows, and the truth about it.',
          ),
          _Point(
            icon: Icons.storage,
            title: 'No storage anxiety',
            body: 'A smart disk cache keeps playback steady on bad networks.',
          ),
        ],
      );
}

class _PrivacyPromise extends StatelessWidget {
  const _PrivacyPromise();

  @override
  Widget build(BuildContext context) => const _Page(
        icon: Icons.lock_outline,
        title: 'No servers. Ever.',
        body: 'Your music and your account stay between your phone and your '
            'cloud. There is no BitDrop server in the middle.',
        children: [
          _Point(
            icon: Icons.phone_android,
            title: 'Indexing happens on this device',
            body: 'Your library is built and searched here, not in a cloud.',
          ),
          _Point(
            icon: Icons.cloud_off_outlined,
            title: 'Nothing is uploaded',
            body: 'BitDrop only reads. It never writes to your Drive.',
          ),
          _Point(
            icon: Icons.visibility_off_outlined,
            title: 'No tracking of what you own',
            body: 'File names, tags and listening history never leave the '
                'phone. Diagnostic reports have them stripped out.',
          ),
        ],
      );
}

class _ConnectSource extends StatefulWidget {
  const _ConnectSource();
  @override
  State<_ConnectSource> createState() => _ConnectSourceState();
}

class _ConnectSourceState extends State<_ConnectSource> {
  final _driveService = GoogleDriveService();
  bool _isSigningIn = false;

  @override
  void dispose() {
    _driveService.dispose();
    super.dispose();
  }

  Future<void> _handleDriveLogin() async {
    setState(() => _isSigningIn = true);
    await _driveService.signIn();
    setState(() => _isSigningIn = false);
    // Move to next page or show success if they successfully logged in
    if (_driveService.currentUser != null) {
      debugPrint("Successfully signed in as ${_driveService.currentUser?.email}");
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return _Page(
      icon: Icons.add_to_drive,
      title: 'Connect a source',
      body: 'BitDrop needs read-only access so it can list your folders and '
          'fetch the parts of a track it is about to play.',
      children: [
        Container(
          padding: const EdgeInsets.all(Spacing.sm),
          decoration: BoxDecoration(
            color: c.tierResampled.withOpacity(0.10),
            borderRadius: Radii.cardR,
            border: Border.all(color: c.tierResampled.withOpacity(0.4)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.info_outline, size: 18, color: c.tierResampled),
              const SizedBox(width: Spacing.xs),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('You may see an "unverified app" warning',
                        style: context.t.titleSmall),
                    const SizedBox(height: 2),
                    Text(
                      'BitDrop is still in Google testing mode, so Google '
                      'shows a warning screen. Choose Advanced, then '
                      'continue. You may also be asked to sign in again '
                      'about once a week.',
                      style:
                          context.t.bodySmall.copyWith(color: c.textSecondary),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: Spacing.md),
        if (_isSigningIn) const Center(child: CircularProgressIndicator()),
        if (!_isSigningIn) ...[
          _ProviderRow(
            icon: Icons.add_to_drive, 
            name: _driveService.currentUser != null 
                ? 'Google Drive (${_driveService.currentUser!.email})' 
                : 'Google Drive', 
            ready: true,
            onTap: _handleDriveLogin,
          ),
          const _ProviderRow(
              icon: Icons.cloud_outlined, name: 'S3-compatible', ready: false),
          const _ProviderRow(
              icon: Icons.dns_outlined, name: 'WebDAV', ready: false),
          const _ProviderRow(
            icon: Icons.library_music_outlined,
            name: 'OpenSubsonic / Navidrome',
            ready: false,
          ),
        ]
      ],
    );
  }
}

class _ChooseFolders extends ConsumerWidget {
  const _ChooseFolders();

  @override
  Widget build(BuildContext context, WidgetRef ref) => _Page(
        icon: Icons.folder_open,
        title: 'Choose music folders',
        body: 'Pick the folders to index. Fewer folders means a faster scan '
            'and less of your daily Drive request budget.',
        children: [
          OutlinedButton.icon(
            onPressed: () => showModalBottomSheet<void>(
              context: context,
              isScrollControlled: true,
              builder: (_) => const FolderPickerSheet(),
            ),
            icon: const Icon(Icons.checklist),
            label: const Text('Choose folders'),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size(double.infinity, Sizes.touchTarget),
            ),
          ),
        ],
      );
}

class _ScanStarts extends StatelessWidget {
  const _ScanStarts();

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return _Page(
      icon: Icons.bolt,
      title: 'Your library is ready',
      body: 'BitDrop builds a browsable library from folder and file names '
          'within seconds. Tags and artwork fill in afterwards, over Wi-Fi by '
          'default — you can start playing right away.',
      children: [
        Container(
          padding: const EdgeInsets.all(Spacing.sm),
          decoration: BoxDecoration(
            color: c.surface2,
            borderRadius: Radii.cardR,
            border: Border.all(color: c.outline),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.sync, size: 16, color: c.accent),
                  const SizedBox(width: Spacing.xs),
                  Text('Reading tags', style: context.t.titleSmall),
                  const Spacer(),
                  Text('240 / 12,480', style: context.t.monoReadout),
                ],
              ),
              const SizedBox(height: Spacing.xs),
              ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: SizedBox(
                  height: 4,
                  child: LinearProgressIndicator(
                    value: 0.02,
                    backgroundColor: c.surface3,
                    color: c.accent,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: Spacing.md),
        const _Point(
          icon: Icons.usb,
          title: 'Have a USB DAC?',
          body: 'Plug it in any time. BitDrop detects it and tells you '
              'exactly what it can do.',
        ),
        const _Point(
          icon: Icons.notifications_none,
          title: 'Notifications',
          body: 'Needed for playback controls on your lock screen. BitDrop '
              'asks the first time you play something.',
        ),
      ],
    );
  }
}

class _Point extends StatelessWidget {
  const _Point({
    required this.icon,
    required this.title,
    required this.body,
  });

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Padding(
      padding: const EdgeInsets.only(bottom: Spacing.md),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: c.textSecondary),
          const SizedBox(width: Spacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: context.t.titleSmall),
                const SizedBox(height: 2),
                Text(body,
                    style:
                        context.t.bodySmall.copyWith(color: c.textSecondary)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ProviderRow extends StatelessWidget {
  const _ProviderRow({
    required this.icon,
    required this.name,
    required this.ready,
    this.onTap,
  });

  final IconData icon;
  final String name;
  final bool ready;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Opacity(
      opacity: ready ? 1 : 0.5,
      child: InkWell(
        onTap: ready ? onTap : null,
        borderRadius: Radii.cardR,
        child: Container(
          margin: const EdgeInsets.only(bottom: Spacing.xs),
          padding: const EdgeInsets.all(Spacing.sm),
          decoration: BoxDecoration(
            color: c.surface1,
            borderRadius: Radii.cardR,
            border: Border.all(color: ready ? c.accent : c.outline),
          ),
          child: Row(
            children: [
              Icon(icon, color: ready ? c.accent : c.textTertiary),
              const SizedBox(width: Spacing.sm),
              Expanded(child: Text(name, style: context.t.titleSmall)),
              if (!ready)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: c.surface3,
                    borderRadius: Radii.badgeR,
                  ),
                  child: Text('Coming soon',
                      style:
                          context.t.monoLabel.copyWith(color: c.textSecondary)),
                )
              else
                Icon(Icons.chevron_right, color: c.textTertiary),
            ],
          ),
        ),
      ),
    );
  }
}
