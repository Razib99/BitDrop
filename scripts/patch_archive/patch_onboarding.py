import re

with open("app/lib/features/onboarding/onboarding_screen.dart", "r") as f:
    content = f.read()

# Add imports
content = content.replace("import '../../core_api/commands.dart';", "import '../../core_api/commands.dart';\nimport '../storage/google_drive_service.dart';")

# Convert _ConnectSource to stateful or consumer, but it's easier to just inject service
provider_row = """class _ProviderRow extends StatelessWidget {
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
}"""
content = re.sub(r"class _ProviderRow extends StatelessWidget \{.*?\}\n\}", provider_row, content, flags=re.DOTALL)

connect_source = """class _ConnectSource extends StatefulWidget {
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
}"""
content = re.sub(r"class _ConnectSource extends StatelessWidget \{.*?\}\n\}", connect_source, content, flags=re.DOTALL)

with open("app/lib/features/onboarding/onboarding_screen.dart", "w") as f:
    f.write(content)
