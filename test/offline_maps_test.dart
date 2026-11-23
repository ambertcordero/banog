import 'package:banog/services/offline_maps.dart';
import 'package:banog/services/trip_tracking.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

void main() {
  group('Eastern Samar offline tiles', () {
    test('covers the whole province bounding box', () {
      final tiles = OfflineMapsService.easternSamarTiles();
      expect(tiles, isNotEmpty);

      for (final tile in tiles) {
        expect(tile.z, inInclusiveRange(offlineMinZoom, offlineMaxZoom));
        final maxIndex = (1 << tile.z) - 1;
        expect(tile.x, inInclusiveRange(0, maxIndex));
        expect(tile.y, inInclusiveRange(0, maxIndex));
      }
    });

    test('matches the expected tile count for zoom 8 to 13', () {
      expect(OfflineMapsService.easternSamarTiles().length, 1117);
    });

    test('counts only bulk-downloadable layers', () {
      expect(
        OfflineMapsService.tileCountFor({
          OfflineMapLayer.street,
          OfflineMapLayer.terrain,
        }),
        2234,
      );
      expect(OfflineMapsService.tileCountFor({OfflineMapLayer.satellite}), 0);
    });

    test('builds tile URLs from the template', () {
      expect(
        OfflineMapLayer.street.tileUrl(10, 3, 4),
        'https://tile.openstreetmap.org/10/3/4.png',
      );
      expect(
        OfflineMapLayer.satellite.tileUrl(9, 2, 5),
        'https://server.arcgisonline.com/ArcGIS/rest/services/'
        'World_Imagery/MapServer/tile/9/5/2',
      );
    });
  });

  group('Trip recording', () {
    test('computes distance between recorded points', () {
      final trip = SavedTrip(
        id: 'test',
        startedAt: DateTime(2026),
        endedAt: DateTime(2026, 1, 1, 1),
        points: [
          TripPoint(
            location: const LatLng(11.0, 125.0),
            timestamp: DateTime(2026),
          ),
          TripPoint(
            location: const LatLng(11.0, 125.01),
            timestamp: DateTime(2026, 1, 1, 0, 1),
          ),
        ],
      );

      // 0.01 degrees of longitude at the equator-ish latitude is ~1.09 km.
      expect(trip.distanceMeters, closeTo(1090, 60));
      expect(trip.duration, const Duration(hours: 1));
    });

    test('serializes and restores a trip', () {
      final original = SavedTrip(
        id: 'trip-1',
        startedAt: DateTime(2026, 11, 8, 9, 30),
        endedAt: DateTime(2026, 11, 8, 10, 0),
        points: [
          TripPoint(
            location: const LatLng(11.2, 125.5),
            timestamp: DateTime(2026, 11, 8, 9, 30),
            speedMetersPerSecond: 3.5,
            accuracyMeters: 4.0,
            altitudeMeters: 12.0,
          ),
        ],
      );

      final restored = SavedTrip.fromJson(original.toJson());
      expect(restored.id, original.id);
      expect(restored.startedAt, original.startedAt);
      expect(restored.endedAt, original.endedAt);
      expect(restored.points.single.location, original.points.single.location);
      expect(
        restored.points.single.speedMetersPerSecond,
        original.points.single.speedMetersPerSecond,
      );
    });
  });
}
