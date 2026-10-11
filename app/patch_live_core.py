import re

with open("lib/core_live/live_core.dart", "r") as f:
    content = f.read()

replacement = """  @override Future<FolderListing> folder(String? folderId) async => const FolderListing(folderId: null, breadcrumb: [], entries: []);
  @override Future<List<Playlist>> playlists() async => const [];
  @override Future<List<String>> genres() async => const [];"""

content = content.replace(
"""  @override Future<FolderListing> folder(String? folderId) => _mockCore.folder(folderId);
  @override Future<List<Playlist>> playlists() => _mockCore.playlists();
  @override Future<List<String>> genres() => _mockCore.genres();""", replacement)

with open("lib/core_live/live_core.dart", "w") as f:
    f.write(content)
