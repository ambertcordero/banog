import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:banog/services/intel_services.dart';
import 'package:banog/services/storm_tracking.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ParBoundary', () {
    test('contains points inside the official polygon', () {
      expect(ParBoundary.contains(const LatLng(10, 125)), isTrue);
      expect(ParBoundary.contains(const LatLng(18, 118)), isTrue);
      expect(ParBoundary.contains(const LatLng(24.5, 134)), isTrue);
      expect(ParBoundary.contains(ParBoundary.labelLocation), isTrue);
    });

    test('rejects points outside the polygon', () {
      expect(ParBoundary.contains(const LatLng(26, 130)), isFalse);
      expect(ParBoundary.contains(const LatLng(4, 130)), isFalse);
      expect(ParBoundary.contains(const LatLng(10, 140)), isFalse);
      expect(ParBoundary.contains(const LatLng(23, 118)), isFalse);
      expect(ParBoundary.contains(const LatLng(0, 0)), isFalse);
    });

    test('monitoring box includes the PAR plus a small buffer', () {
      expect(ParBoundary.isMonitorable(const LatLng(10, 125)), isTrue);
      expect(ParBoundary.isMonitorable(const LatLng(0, 110)), isTrue);
      expect(ParBoundary.isMonitorable(const LatLng(27, 140)), isTrue);
      expect(ParBoundary.isMonitorable(const LatLng(0, 0)), isFalse);
      expect(ParBoundary.isMonitorable(const LatLng(28, 125)), isFalse);
    });
  });

  group('StormWindCategory', () {
    test('maps PAGASA wind ranges', () {
      expect(
        StormWindCategoryInfo.fromWind(50),
        StormWindCategory.tropicalDepression,
      );
      expect(
        StormWindCategoryInfo.fromWind(70),
        StormWindCategory.tropicalStorm,
      );
      expect(
        StormWindCategoryInfo.fromWind(100),
        StormWindCategory.severeTropicalStorm,
      );
      expect(StormWindCategoryInfo.fromWind(150), StormWindCategory.typhoon);
      expect(
        StormWindCategoryInfo.fromWind(200),
        StormWindCategory.superTyphoon,
      );
      expect(StormWindCategory.superTyphoon.shortLabel, 'STY');
    });
  });

  group('StormTrackService.fetchTrack', () {
    test('parses observed and forecast points from a GDACS timeline', () async {
      var requests = 0;
      final client = MockClient((request) async {
        requests++;
        if (request.url.path.endsWith('getepisodedata')) {
          return http.Response(
            jsonEncode({
              'properties': {
                'impacts': {
                  'resource': {
                    'timeline': 'https://www.gdacs.org/gdacsapi/api/export/gettimeline?id=42',
                  },
                },
              },
            }),
            200,
          );
        }
        return http.Response(jsonEncode(_timelinePayload()), 200);
      });
      addTearDown(client.close);

      final track = await StormTrackService.fetchTrack(
        client,
        const StormEvent(
          name: 'Test Cyclone',
          alertLevel: 'Red',
          country: 'PH',
          description: '',
          latitude: 10.5,
          longitude: 129,
          isCurrent: true,
          reportUrl: '',
          windKmh: 108,
          eventId: 100,
          episodeId: 200,
        ),
      );

      expect(requests, 2);
      expect(track, isNotNull);
      expect(track!.name, 'Test Cyclone');
      expect(track.observed.length, 2);
      expect(track.forecast.length, 2);
      expect(track.observed.first.time, DateTime.utc(2026, 10, 12));
      expect(track.currentLocation, const LatLng(10.5, 129));
      expect(track.currentWindKmh, closeTo(108, 0.01));
      expect(track.currentStatus, 'Tropical Storm');
      expect(track.currentPoint!.isCurrent, isTrue);
      expect(track.forecastLine.length, 3);
      expect(track.touchesPar, isTrue);
      expect(track.isMonitorable, isTrue);
      expect(track.forecast.first.time, DateTime.utc(2026, 10, 13, 12));
    });

    test('returns null when the episode has no timeline', () async {
      final client = MockClient((request) async {
        return http.Response(
          jsonEncode({
            'properties': {'impacts': <Object>[]},
          }),
          200,
        );
      });
      addTearDown(client.close);

      final track = await StormTrackService.fetchTrack(
        client,
        const StormEvent(
          name: 'No track',
          alertLevel: 'Green',
          country: '',
          description: '',
          latitude: 10,
          longitude: 125,
          isCurrent: true,
          reportUrl: '',
          eventId: 7,
          episodeId: 8,
        ),
      );

      expect(track, isNull);
    });
  });

  group('StormTrackService.fetchParTracks', () {
    test('keeps only active storms inside or near the PAR', () async {
      final client = MockClient((request) async {
        final path = request.url.path;
        if (path.contains('geteventlist')) {
          return http.Response(
            jsonEncode({
              'features': [
                _feature(eventId: 100, episodeId: 200, lat: 10, lon: 130),
                _feature(eventId: 101, episodeId: 201, lat: 0, lon: 0),
                _feature(
                  eventId: 102,
                  episodeId: 202,
                  lat: 12,
                  lon: 125,
                  isCurrent: false,
                ),
              ],
            }),
            200,
          );
        }
        if (path.contains('getepisodedata')) {
          final eventId = request.url.queryParameters['eventid'];
          return http.Response(
            jsonEncode({
              'properties': {
                'impacts': {
                  'resource': {
                    'timeline':
                        'https://www.gdacs.org/gdacsapi/api/export/gettimeline?id=$eventId',
                  },
                },
              },
            }),
            200,
          );
        }
        final id = request.url.queryParameters['id'];
        if (id == '100') {
          return http.Response(jsonEncode(_timelinePayload()), 200);
        }
        return http.Response(
          jsonEncode({
            'channel': {
              'item': [
                {
                  'latitude': '0',
                  'longitude': '0',
                  'actual': 'True',
                  'current': 'True',
                  'advisory_number': '1',
                  'advisory_datetime': '12 Oct 2026 00:00',
                  'wind_speed': '15',
                  'storm_status': ['Tropical Depression'],
                },
              ],
            },
          }),
          200,
        );
      });
      addTearDown(client.close);

      final tracks = await StormTrackService.fetchParTracks(client);

      expect(tracks, hasLength(1));
      expect(tracks.single.eventId, 100);
      expect(tracks.single.name, 'Near storm');
    });
    test('returns only successful tracks when another storm fails', () async {
      final client = MockClient((request) async {
        final path = request.url.path;
        if (path.contains('geteventlist')) {
          return http.Response(
            jsonEncode({
              'features': [
                _feature(eventId: 100, episodeId: 200, lat: 10, lon: 130),
                _feature(eventId: 101, episodeId: 201, lat: 12, lon: 126),
              ],
            }),
            200,
          );
        }
        if (request.url.path.contains('getepisodedata')) {
          if (request.url.queryParameters['eventid'] == '101') {
            return http.Response('unavailable', 503);
          }
          return http.Response(
            jsonEncode({
              'properties': {
                'impacts': {
                  'resource': {
                    'timeline': 'https://www.gdacs.org/gdacsapi/api/export/gettimeline?id=100',
                  },
                },
              },
            }),
            200,
          );
        }
        return http.Response(jsonEncode(_timelinePayload()), 200);
      });
      addTearDown(client.close);

      final tracks = await StormTrackService.fetchParTracks(client);

      expect(tracks, hasLength(1));
      expect(tracks.single.eventId, 100);
    });

    test('throws when every active storm track fails', () async {
      final client = MockClient((request) async {
        if (request.url.path.contains('geteventlist')) {
          return http.Response(
            jsonEncode({
              'features': [
                _feature(eventId: 100, episodeId: 200, lat: 10, lon: 130),
              ],
            }),
            200,
          );
        }
        return http.Response('unavailable', 503);
      });
      addTearDown(client.close);

      await expectLater(
        StormTrackService.fetchParTracks(client),
        throwsA(isA<StormTrackUnavailableException>()),
      );
    });
  });

  group('StormTrackService.fetchRecentParTrack', () {
    test('replays the newest completed track that crossed the PAR', () async {
      final client = MockClient((request) async {
        final path = request.url.path;
        if (path.contains('geteventlist')) {
          return http.Response(
            jsonEncode({
              'features': [
                _feature(
                  eventId: 100,
                  episodeId: 200,
                  lat: 31,
                  lon: 127,
                  isCurrent: false,
                  name: 'Older storm',
                  fromDate: '2026-10-14T12:00:00',
                  toDate: '2026-10-25T18:00:00',
                ),
                _feature(
                  eventId: 300,
                  episodeId: 400,
                  lat: 31,
                  lon: 127,
                  isCurrent: false,
                  name: 'Newer storm',
                  fromDate: '2026-11-01T00:00:00',
                  toDate: '2026-11-02T06:00:00',
                ),
              ],
            }),
            200,
          );
        }
        if (path.contains('getepisodedata')) {
          final id = request.url.queryParameters['eventid'];
          return http.Response(
            jsonEncode({
              'properties': {
                'impacts': {
                  'resource': {
                    'timeline':
                        'https://www.gdacs.org/gdacsapi/api/export/gettimeline?id=$id',
                  },
                },
              },
            }),
            200,
          );
        }
        return http.Response(jsonEncode(_timelinePayload()), 200);
      });
      addTearDown(client.close);

      final track = await StormTrackService.fetchRecentParTrack(client);

      expect(track, isNotNull);
      expect(track!.eventId, 300);
      expect(track.name, 'Newer storm');
      expect(track.passesPar, isTrue);
    });

    test('skips completed tracks that never crossed the PAR', () async {
      final client = MockClient((request) async {
        if (request.url.path.contains('geteventlist')) {
          return http.Response(
            jsonEncode({
              'features': [
                _feature(
                  eventId: 300,
                  episodeId: 400,
                  lat: 15,
                  lon: 80,
                  isCurrent: false,
                  fromDate: '2026-11-01T00:00:00',
                  toDate: '2026-11-02T06:00:00',
                ),
              ],
            }),
            200,
          );
        }
        if (request.url.path.contains('getepisodedata')) {
          return http.Response(
            jsonEncode({
              'properties': {
                'impacts': {
                  'resource': {
                    'timeline': 'https://www.gdacs.org/gdacsapi/api/export/gettimeline?id=300',
                  },
                },
              },
            }),
            200,
          );
        }
        return http.Response(
          jsonEncode({
            'channel': {
              'item': [
                {
                  'latitude': '15',
                  'longitude': '80',
                  'actual': 'True',
                  'current': 'True',
                  'advisory_number': '1',
                  'advisory_datetime': '01 Nov 2026 00:00',
                  'wind_speed': '30',
                  'storm_status': ['Tropical Storm'],
                },
              ],
            },
          }),
          200,
        );
      });
      addTearDown(client.close);

      final track = await StormTrackService.fetchRecentParTrack(client);

      expect(track, isNull);
    });
  });

  group('StormTrack cache', () {
    test('describes cache age and staleness', () {
      expect(StormTrackService.describeAge(null), '');
      expect(
        StormTrackService.describeAge(const Duration(seconds: 30)),
        'just now',
      );
      expect(
        StormTrackService.describeAge(const Duration(minutes: 12)),
        '12m ago',
      );
      expect(StormTrackService.describeAge(const Duration(hours: 3)), '3h ago');
      expect(StormTrackService.describeAge(const Duration(days: 2)), '2d ago');

      final fresh = StormTrackCache(
        tracks: const [],
        savedAt: DateTime.now().toUtc(),
      );
      final stale = StormTrackCache(
        tracks: const [],
        savedAt: DateTime.now().toUtc().subtract(const Duration(hours: 7)),
      );
      expect(fresh.isStale(), isFalse);
      expect(stale.isStale(), isTrue);
    });

    test('keeps only the three most recent tracks', () async {
      SharedPreferences.setMockInitialValues({});
      final tracks = List.generate(
        5,
        (index) => StormTrack(
          eventId: index,
          name: 'Storm $index',
          fetchedAt: DateTime.utc(2026, 10, 12, 12),
          observed: [
            StormTrackPoint(
              location: LatLng(10 + index.toDouble(), 125),
              time: DateTime.utc(2026, 10, 12, 12),
              isForecast: false,
              isCurrent: true,
              advisoryNumber: 1,
            ),
          ],
          forecast: const [],
        ),
      );

      await StormTrackService.saveCache(tracks);
      final cache = await StormTrackService.loadCache();

      expect(cache.tracks, hasLength(StormTrackService.maxCachedTracks));
      expect(cache.tracks.map((track) => track.eventId), [0, 1, 2]);
    });
    test('round-trips a track through JSON', () {
      final track = StormTrack(
        eventId: 100,
        name: 'Test Cyclone',
        fetchedAt: DateTime.utc(2026, 10, 12, 12),
        observed: [
          StormTrackPoint(
            location: const LatLng(10.5, 129),
            time: DateTime.utc(2026, 10, 12, 12),
            isForecast: false,
            isCurrent: true,
            advisoryNumber: 2,
            windKmh: 108,
            status: 'Tropical Storm',
          ),
        ],
        forecast: [
          StormTrackPoint(
            location: const LatLng(11, 128),
            time: DateTime.utc(2026, 10, 13, 12),
            isForecast: true,
            isCurrent: false,
            advisoryNumber: 2,
            windKmh: 144,
            status: 'Typhoon',
          ),
        ],
      );

      final decoded = StormTrack.fromJson(
        jsonDecode(jsonEncode(track.toJson())),
      );

      expect(decoded, isNotNull);
      expect(decoded!.eventId, 100);
      expect(decoded.currentLocation, const LatLng(10.5, 129));
      expect(decoded.observed.single.isCurrent, isTrue);
      expect(decoded.forecast.single.windKmh, 144);
    });

    test('saves and restores the last tracks', () async {
      SharedPreferences.setMockInitialValues({});
      final track = StormTrack(
        eventId: 100,
        name: 'Test Cyclone',
        fetchedAt: DateTime.utc(2026, 10, 12, 12),
        observed: [
          StormTrackPoint(
            location: const LatLng(10.5, 129),
            time: DateTime.utc(2026, 10, 12, 12),
            isForecast: false,
            isCurrent: true,
            advisoryNumber: 2,
            windKmh: 108,
          ),
        ],
        forecast: const [],
      );

      await StormTrackService.saveCache([track]);
      final cache = await StormTrackService.loadCache();

      expect(cache.tracks, hasLength(1));
      expect(cache.tracks.single.name, 'Test Cyclone');
      expect(cache.savedAt, isNotNull);
    });
  });

  group('TyphoonPlayback', () {
    test('merges observed and forecast points without duplicates', () {
      final playback = TyphoonPlayback(_playbackTrack());

      expect(playback.path, hasLength(4));
      expect(playback.path.first.location, const LatLng(10, 130));
      expect(playback.path.last.location, const LatLng(11.5, 127));
      expect(playback.canPlay, isTrue);
      expect(playback.currentFraction, closeTo(0.2, 1e-9));
    });

    test('interpolates the playhead between observed and forecast points', () {
      final playback = TyphoonPlayback(_playbackTrack());

      final start = playback.frameAt(0)!;
      expect(start.location, const LatLng(10, 130));
      expect(start.isForecast, isFalse);

      final current = playback.frameAt(playback.currentFraction)!;
      expect(current.location, const LatLng(10.5, 129));
      expect(current.isForecast, isFalse);
      expect(current.windKmh, closeTo(108, 1e-9));

      final midway = playback.frameAt(0.5)!;
      expect(midway.location.latitude, closeTo(10.875, 1e-9));
      expect(midway.location.longitude, closeTo(128.25, 1e-9));
      expect(midway.time, DateTime.utc(2026, 10, 13, 6));
      expect(midway.isForecast, isTrue);
      expect(midway.status, 'Typhoon');
      expect(midway.windKmh, closeTo(135, 1e-9));

      expect(playback.frameAt(1)!.location, const LatLng(11.5, 127));
    });

    test('advances by speed and stops at the end of the loop', () {
      final playback = TyphoonPlayback(_playbackTrack(), progress: 0, speed: 2);

      expect(playback.advance(const Duration(seconds: 1)), isFalse);
      expect(
        playback.progress,
        closeTo(2 / TyphoonPlayback.loopDuration.inSeconds, 1e-9),
      );

      expect(playback.advance(const Duration(seconds: 7)), isTrue);
      expect(playback.progress, 1);
    });

    test('cannot play a track with a single point', () {
      final track = StormTrack(
        eventId: 1,
        name: 'Stationary',
        fetchedAt: DateTime.utc(2026, 10, 12, 12),
        observed: [
          StormTrackPoint(
            location: const LatLng(10, 130),
            time: DateTime.utc(2026, 10, 12, 12),
            isForecast: false,
            isCurrent: true,
            advisoryNumber: 1,
          ),
        ],
        forecast: const [],
      );
      final playback = TyphoonPlayback(track);

      expect(playback.canPlay, isFalse);
      expect(playback.frameAt(0.5)!.location, const LatLng(10, 130));
    });
  });
}

StormTrack _playbackTrack() {
  return StormTrack(
    eventId: 100,
    name: 'Playback storm',
    fetchedAt: DateTime.utc(2026, 10, 12, 12),
    observed: [
      StormTrackPoint(
        location: const LatLng(10, 130),
        time: DateTime.utc(2026, 10, 12),
        isForecast: false,
        isCurrent: false,
        advisoryNumber: 1,
        windKmh: 72,
        status: 'Tropical Storm',
      ),
      StormTrackPoint(
        location: const LatLng(10.5, 129),
        time: DateTime.utc(2026, 10, 12, 12),
        isForecast: false,
        isCurrent: true,
        advisoryNumber: 2,
        windKmh: 108,
        status: 'Severe Tropical Storm',
      ),
      StormTrackPoint(
        location: const LatLng(10.5, 129),
        time: DateTime.utc(2026, 10, 12, 12),
        isForecast: false,
        isCurrent: false,
        advisoryNumber: 1,
        windKmh: 108,
        status: 'Severe Tropical Storm',
      ),
    ],
    forecast: [
      StormTrackPoint(
        location: const LatLng(11, 128),
        time: DateTime.utc(2026, 10, 13, 12),
        isForecast: true,
        isCurrent: false,
        advisoryNumber: 2,
        windKmh: 144,
        status: 'Typhoon',
      ),
      StormTrackPoint(
        location: const LatLng(11.5, 127),
        time: DateTime.utc(2026, 10, 14, 12),
        isForecast: true,
        isCurrent: false,
        advisoryNumber: 2,
        windKmh: 180,
        status: 'Typhoon',
      ),
    ],
  );
}

Map<String, dynamic> _timelinePayload() {
  return {
    'channel': {
      'item': [
        {
          'latitude': '10.0',
          'longitude': '130.0',
          'actual': 'True',
          'current': 'False',
          'advisory_number': '1',
          'advisory_datetime': '12 Oct 2026 00:00',
          'wind_speed': '15',
          'storm_status': ['Tropical Depression'],
        },
        {
          'latitude': '10.5',
          'longitude': '129.0',
          'actual': 'True',
          'current': 'True',
          'advisory_number': '2',
          'advisory_datetime': '12 Oct 2026 12:00',
          'wind_speed': '30',
          'storm_status': ['Tropical Storm'],
        },
        {
          'latitude': '10.5',
          'longitude': '129.0',
          'actual': 'True',
          'current': 'False',
          'advisory_number': '1',
          'advisory_datetime': '12 Oct 2026 12:00',
          'wind_speed': '30',
          'storm_status': ['Tropical Storm'],
        },
        {
          'latitude': '11.0',
          'longitude': '128.0',
          'actual': 'False',
          'current': 'False',
          'advisory_number': '2',
          'advisory_datetime': '13 Oct 2026 12:00',
          'wind_speed': '40',
          'storm_status': ['Typhoon'],
        },
        {
          'latitude': '11.5',
          'longitude': '127.0',
          'actual': 'False',
          'current': 'False',
          'advisory_number': '2',
          'advisory_datetime': '14 Oct 2026 12:00',
          'wind_speed': '45',
          'storm_status': ['Typhoon'],
        },
      ],
    },
  };
}

Map<String, dynamic> _feature({
  required int eventId,
  required int episodeId,
  required double lat,
  required double lon,
  bool isCurrent = true,
  String? name,
  String? fromDate,
  String? toDate,
}) {
  return {
    'geometry': {
      'type': 'Point',
      'coordinates': [lon, lat],
    },
    'properties': {
      'eventid': eventId,
      'episodeid': episodeId,
      'eventname': name ?? (eventId == 100 ? 'Near storm' : 'Far storm'),
      'alertlevel': 'Green',
      'country': 'PH',
      'htmldescription': '',
      'iscurrent': isCurrent ? 'true' : 'false',
      'fromdate': fromDate,
      'todate': toDate,
      'severitydata': {'severity': 100, 'severityunit': 'km/h'},
    },
  };
}
