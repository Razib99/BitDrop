import re

with open("lib/features/sources/sources_screen.dart", "r") as f:
    content = f.read()

replacement = """                onRescan: s.id == 'drive'
                    ? () {
                        final library = ref.read(cloudLibraryProvider);
                        if (library.currentFolders.isEmpty) {
                          unawaited(showDriveFolderPicker(context));
                        } else {
                          unawaited(library.scan());
                        }
                      }
                    : () => sendCommand(ref, Rescan(sourceId: s.id)),
                onCancelSync: s.id == 'drive'
                    ? () {
                        ref.read(cloudLibraryProvider).cancelScan();
                      }
                    : null,
"""

content = content.replace(
"""                onRescan: s.id == 'drive'
                    ? () {
                        final library = ref.read(cloudLibraryProvider);
                        if (library.currentFolders.isEmpty) {
                          unawaited(showDriveFolderPicker(context));
                        } else {
                          unawaited(library.scan());
                        }
                      }
                    : () => sendCommand(ref, Rescan(sourceId: s.id)),""", replacement)

# We also need to add Stop Sync button to the _ConnectDriveCard just in case.
# Let's see _ConnectDriveCard in sources_screen.dart.
replacement_connect_card = """                if (scan.total > 0)
                  Text(Fmt.percent(scan.progress),
                      style: context.t.monoReadout
                          .copyWith(color: c.textSecondary)),
                const SizedBox(width: Spacing.sm),
                TextButton(
                  onPressed: () => ref.read(cloudLibraryProvider).cancelScan(),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: const Size(0, 24),
                  ),
                  child: const Text('Stop Sync'),
                ),
              ],
            ),"""

content = content.replace(
"""                if (scan.total > 0)
                  Text(Fmt.percent(scan.progress),
                      style: context.t.monoReadout
                          .copyWith(color: c.textSecondary)),
              ],
            ),""", replacement_connect_card)

with open("lib/features/sources/sources_screen.dart", "w") as f:
    f.write(content)
