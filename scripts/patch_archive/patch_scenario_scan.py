import re

with open("app/lib/features/dev/scenario_sheet.dart", "r") as f:
    content = f.read()

# Add imports for our mock catalog injection if they don't exist
imports = """import '../../core_mock/catalog.dart';
import '../../core_api/models.dart';
import '../../core_api/enums.dart';
"""
if "import '../../core_mock/catalog.dart';" not in content:
    content = content.replace("import 'package:flutter/material.dart';", imports + "import 'package:flutter/material.dart';")

dev_section = """const SectionHeader(title: 'Developer'),"""
if dev_section in content and "Scan Real Library" not in content:
    new_tile = """const SectionHeader(title: 'Developer'),
          ListTile(
            leading: const Icon(Icons.folder_special),
            title: const Text('Scan Real Library (Music folder)'),
            subtitle: const Text('Scans /home/razib/Desktop/BitDrop/Music & replaces mock data'),
            trailing: const Icon(Icons.refresh),
            onTap: () async {
              Navigator.of(context).pop();
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Scanning Music folder...')),
              );
              try {
                final results = rust_api.scanDirectory(path: '/home/razib/Desktop/BitDrop/Music');
                
                final newAlbums = <Album>[];
                final newTracks = <Track>[];
                
                final albumsMap = <String, List<rust_api.TrackMetadata>>{};
                for (final meta in results) {
                  albumsMap.putIfAbsent(meta.album, () => []).add(meta);
                }
                
                for (final albumTitle in albumsMap.keys) {
                  final tracks = albumsMap[albumTitle]!;
                  final first = tracks.first;
                  final albumId = 'real_album_${albumTitle.hashCode}';
                  final artistId = 'real_artist_${first.artist.hashCode}';
                  
                  final duration = tracks.fold<int>(0, (p, c) => p + c.durationMs);
                  final size = tracks.length * 30000000;
                  
                  newAlbums.add(Album(
                    id: albumId,
                    title: albumTitle,
                    artist: first.artist,
                    artistId: artistId,
                    trackCount: tracks.length,
                    durationMs: duration,
                    sizeBytes: size,
                    format: AudioFormat(codec: Codec.flac, bitDepth: 16, sampleRate: first.sampleRate),
                    availability: Availability.cached,
                    artwork: Artwork(seed: albumId, dominantColor: 0xFF556677),
                  ));
                  
                  for (final meta in tracks) {
                    newTracks.add(Track(
                      id: meta.path,
                      title: meta.title,
                      artist: meta.artist,
                      albumTitle: albumTitle,
                      albumId: albumId,
                      durationMs: meta.durationMs,
                      format: AudioFormat(codec: Codec.flac, bitDepth: 16, sampleRate: meta.sampleRate),
                      availability: Availability.cached,
                      sizeBytes: 30000000,
                      artwork: Artwork(seed: albumId, dominantColor: 0xFF556677),
                    ));
                  }
                }
                
                MockCatalog.albums.clear();
                MockCatalog.albums.addAll(newAlbums);
                MockCatalog.tracks.clear();
                MockCatalog.tracks.addAll(newTracks);
                
                // Force a reload in the UI
                ref.read(scenarioRevisionProvider.notifier).state++;
                
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('✅ Loaded ${newAlbums.length} albums, ${newTracks.length} tracks from disk!')),
                );
              } catch (e) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('❌ Error scanning: $e')),
                );
              }
            },
          ),"""
    content = content.replace(dev_section, new_tile)

with open("app/lib/features/dev/scenario_sheet.dart", "w") as f:
    f.write(content)

