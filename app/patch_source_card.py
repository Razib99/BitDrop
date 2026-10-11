import re

with open("lib/widgets/cards.dart", "r") as f:
    content = f.read()

replacement1 = """  const SourceCard({
    super.key,
    required this.account,
    this.onRescan,
    this.onCancelSync,
    this.onEditFolders,
    this.onReconnect,
    this.onRemove,
    this.showAdvanced = false,
    this.onToggleAdvanced,
  });

  final SourceAccount account;
  final VoidCallback? onRescan;
  final VoidCallback? onCancelSync;"""

content = content.replace(
"""  const SourceCard({
    super.key,
    required this.account,
    this.onRescan,
    this.onEditFolders,
    this.onReconnect,
    this.onRemove,
    this.showAdvanced = false,
    this.onToggleAdvanced,
  });

  final SourceAccount account;
  final VoidCallback? onRescan;""", replacement1)

replacement2 = """                if (onRescan != null && account.status != SourceStatus.syncing)
                  _SmallButton(
                      label: 'Rescan', icon: Icons.sync, onTap: onRescan!),
                if (onCancelSync != null && account.status == SourceStatus.syncing)
                  _SmallButton(
                      label: 'Stop Sync', icon: Icons.cancel_outlined, onTap: onCancelSync!),
"""

content = content.replace(
"""                if (onRescan != null)
                  _SmallButton(
                      label: 'Rescan', icon: Icons.sync, onTap: onRescan!),""", replacement2)

with open("lib/widgets/cards.dart", "w") as f:
    f.write(content)
