import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:path_provider/path_provider.dart';

/// A base map that Banog can pre-download for offline use.
enum OfflineMapLayer { street, terrain, satellite }

extension OfflineMapLayerInfo on OfflineMapLayer {
  String get title => switch (this) {
    OfflineMapLayer.street => 'Street map',
    OfflineMapLayer.terrain => 'Terrain map',
    OfflineMapLayer.satellite => 'Satellite map',
  };

  String get subtitle => switch (this) {
    OfflineMapLayer.street => 'OpenStreetMap roads, places, and boundaries',
    OfflineMapLayer.terrain => 'OpenTopoMap terrain and elevation details',
    OfflineMapLayer.satellite =>
      'Esri imagery (cached only for areas you view online)',
  };

  String get urlTemplate => switch (this) {
    OfflineMapLayer.street => 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
    OfflineMapLayer.terrain => 'https://tile.opentopomap.org/{z}/{x}/{y}.png',
    OfflineMapLayer.satellite =>
      'https://server.arcgisonline.com/ArcGIS/rest/services/'
          'World_Imagery/MapServer/tile/{z}/{y}/{x}',
  };

  /// Satellite imagery may be cached as it is viewed, but must not be
  /// bulk-downloaded because of the provider's usage terms.
  bool get supportsBulkDownload => this != OfflineMapLayer.satellite;

  String tileUrl(int z, int x, int y) => urlTemplate
      .replaceAll('{z}', '$z')
      .replaceAll('{x}', '$x')
      .replaceAll('{y}', '$y');
}

/// Bounding box of Eastern Samar, taken from the bundled province boundary.
const double easternSamarSouth = 10.687949282;
const double easternSamarWest = 125.125405412;
const double easternSamarNorth = 12.349578051;
const double easternSamarEast = 125.969094646;

const int offlineMinZoom = 8;
const int offlineMaxZoom = 13;

LatLngBounds get easternSamarBounds => LatLngBounds(
  LatLng(easternSamarSouth, easternSamarWest),
  LatLng(easternSamarNorth, easternSamarEast),
);

/// A single slippy-map tile.
class OfflineTileCoordinate {
  const OfflineTileCoordinate(this.z, this.x, this.y);

  final int z;
  final int x;
  final int y;

  @override
  String toString() => '$z/$x/$y';
}

/// Snapshot of an in-progress or completed offline download.
class OfflineDownloadProgress {
  const OfflineDownloadProgress({
    this.completed = 0,
    this.total = 0,
    this.downloaded = 0,
    this.skipped = 0,
    this.failed = 0,
    this.bytes = 0,
    this.cancelled = false,
    this.done = false,
  });

  final int completed;
  final int total;
  final int downloaded;
  final int skipped;
  final int failed;
  final int bytes;
  final bool cancelled;
  final bool done;

  double get fraction => total == 0 ? 0 : completed / total;

  OfflineDownloadProgress copyWith({
    int? completed,
    int? total,
    int? downloaded,
    int? skipped,
    int? failed,
    int? bytes,
    bool? cancelled,
    bool? done,
  }) => OfflineDownloadProgress(
    completed: completed ?? this.completed,
    total: total ?? this.total,
    downloaded: downloaded ?? this.downloaded,
    skipped: skipped ?? this.skipped,
    failed: failed ?? this.failed,
    bytes: bytes ?? this.bytes,
    cancelled: cancelled ?? this.cancelled,
    done: done ?? this.done,
  );
}

/// Handles the persistent tile cache used by Banog's FlutterMap layers and the
/// bulk downloader for Eastern Samar.
class OfflineMapsService {
  const OfflineMapsService._();

  static const _folderName = 'offline_maps';
  static const _tileAge = Duration(days: 3650);

  static bool _initialised = false;

  /// Create (or reuse) the persistent built-in cache used by every tile layer.
  ///
  /// Must be called before the first map renders so that the singleton is
  /// configured with a persistent directory instead of the OS cache.
  static Future<void> initialiseCache() async {
    if (_initialised || kIsWeb) return;
    try {
      await _provider();
      _initialised = true;
    } catch (_) {
      // Offline caching is a nice-to-have; never block app startup.
    }
  }

  static Future<BuiltInMapCachingProvider> _provider() async {
    final documents = await getApplicationDocumentsDirectory();
    final cacheDirectory =
        '${documents.path}${Platform.pathSeparator}$_folderName';
    return BuiltInMapCachingProvider.getOrCreateInstance(
      cacheDirectory: cacheDirectory,
      // Never evict tiles automatically: downloaded provinces must survive.
      maxCacheSize: null,
      // Keep cached tiles usable indefinitely while offline.
      overrideFreshAge: _tileAge,
    );
  }

  /// Directory that stores the cached tile files.
  static Future<Directory> _tileDirectory() async {
    final documents = await getApplicationDocumentsDirectory();
    return Directory(
      '${documents.path}${Platform.pathSeparator}$_folderName'
      '${Platform.pathSeparator}fm_cache',
    );
  }

  /// Total size of the cached tile data, in bytes.
  static Future<int> storageBytes() async {
    if (kIsWeb) return 0;
    try {
      final directory = await _tileDirectory();
      if (!await directory.exists()) return 0;
      var total = 0;
      await for (final entity in directory.list(recursive: true)) {
        if (entity is File) {
          total += await entity.length();
        }
      }
      return total;
    } catch (_) {
      return 0;
    }
  }

  /// Remove every cached tile, including tiles cached while browsing online.
  static Future<void> clearCache() async {
    if (kIsWeb) return;
    try {
      final provider = await _provider();
      await provider.destroy(deleteCache: true);
      _initialised = false;
      await initialiseCache();
    } catch (_) {
      // Ignore: a failed clear simply leaves the existing cache in place.
    }
  }

  /// All tiles covering Eastern Samar for the supported zoom range.
  static List<OfflineTileCoordinate> easternSamarTiles({
    int minZoom = offlineMinZoom,
    int maxZoom = offlineMaxZoom,
  }) {
    final tiles = <OfflineTileCoordinate>[];
    for (var z = minZoom; z <= maxZoom; z++) {
      final scale = 1 << z;
      final minX = _tileX(easternSamarWest, scale);
      final maxX = _tileX(easternSamarEast, scale);
      // Y increases southwards, so north gives the smaller index.
      final minY = _tileY(easternSamarNorth, scale);
      final maxY = _tileY(easternSamarSouth, scale);
      for (var x = minX; x <= maxX; x++) {
        for (var y = minY; y <= maxY; y++) {
          tiles.add(OfflineTileCoordinate(z, x, y));
        }
      }
    }
    return tiles;
  }

  static int _tileX(double longitude, int scale) {
    final x = ((longitude + 180) / 360 * scale).floor();
    return x.clamp(0, scale - 1);
  }

  static int _tileY(double latitude, int scale) {
    final radians = latitude * math.pi / 180;
    final y =
        ((1 - math.log(math.tan(radians) + 1 / math.cos(radians)) / math.pi) /
                2 *
                scale)
            .floor();
    return y.clamp(0, scale - 1);
  }

  /// Estimate of how many tiles a download will fetch.
  static int tileCountFor(Set<OfflineMapLayer> layers) {
    final perLayer = easternSamarTiles().length;
    return layers.where((layer) => layer.supportsBulkDownload).length *
        perLayer;
  }

  /// Download the selected base maps for Eastern Samar into the tile cache.
  ///
  /// Tiles that are already cached are skipped. [onProgress] is throttled so it
  /// does not rebuild the UI for every single tile.
  static Future<OfflineDownloadProgress> download({
    required Set<OfflineMapLayer> layers,
    required void Function(OfflineDownloadProgress progress) onProgress,
    bool Function()? isCancelled,
    http.Client? client,
  }) async {
    final provider = await _provider();
    final httpClient = client ?? http.Client();
    final tasks = <({OfflineMapLayer layer, String url})>[];
    for (final layer in layers) {
      if (!layer.supportsBulkDownload) continue;
      for (final tile in easternSamarTiles()) {
        tasks.add((layer: layer, url: layer.tileUrl(tile.z, tile.x, tile.y)));
      }
    }

    var completed = 0;
    var downloaded = 0;
    var skipped = 0;
    var failed = 0;
    var bytes = 0;
    var cancelled = false;
    var nextIndex = 0;
    var lastReport = DateTime.now();

    var progress = OfflineDownloadProgress(total: tasks.length);
    onProgress(progress);

    void emit({bool force = false}) {
      progress = OfflineDownloadProgress(
        completed: completed,
        total: tasks.length,
        downloaded: downloaded,
        skipped: skipped,
        failed: failed,
        bytes: bytes,
        cancelled: cancelled,
      );
      final now = DateTime.now();
      if (force ||
          completed == tasks.length ||
          now.difference(lastReport) > const Duration(milliseconds: 120)) {
        lastReport = now;
        onProgress(progress);
      }
    }

    Future<void> worker() async {
      while (true) {
        if (cancelled || (isCancelled?.call() ?? false)) {
          cancelled = true;
          return;
        }
        final index = nextIndex++;
        if (index >= tasks.length) return;
        final task = tasks[index];

        try {
          CachedMapTile? existing;
          try {
            existing = await provider.getTile(task.url);
          } on CachedMapTileReadFailure {
            // Treat a corrupt tile as missing so it gets downloaded again.
            existing = null;
          }
          if (existing != null) {
            skipped++;
          } else {
            final response = await httpClient
                .get(
                  Uri.parse(task.url),
                  headers: const {
                    'User-Agent': 'BanogWeatherApp/1.0 (offline map download)',
                  },
                )
                .timeout(const Duration(seconds: 25));
            if (response.statusCode == 200 && response.bodyBytes.isNotEmpty) {
              await provider.putTile(
                url: task.url,
                metadata: CachedMapTileMetadata(
                  staleAt: DateTime.now().toUtc().add(_tileAge),
                  lastModified: null,
                  etag: null,
                ),
                bytes: response.bodyBytes,
              );
              downloaded++;
              bytes += response.bodyBytes.length;
            } else {
              failed++;
            }
          }
        } catch (_) {
          failed++;
        }

        completed++;
        emit();
      }
    }

    try {
      await Future.wait(List.generate(6, (_) => worker()));
    } finally {
      if (client == null) httpClient.close();
    }

    final result = progress.copyWith(
      completed: completed,
      total: tasks.length,
      downloaded: downloaded,
      skipped: skipped,
      failed: failed,
      bytes: bytes,
      cancelled: cancelled,
      done: true,
    );
    onProgress(result);
    return result;
  }
}
