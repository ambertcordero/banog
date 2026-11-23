import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:banog/services/intel_services.dart';

void main() {
  group('ForecastIntelService', () {
    test(
      'uses hourly precipitation probability and limits peaks to 24 hours',
      () async {
        final client = MockClient((request) async {
          expect(request.url.queryParameters['timezone'], 'Asia/Manila');
          expect(
            request.url.queryParameters['current'],
            isNot(contains('precipitation')),
          );
          return http.Response(
            jsonEncode({
              'current': {
                'temperature_2m': 28,
                'apparent_temperature': 31,
                'weather_code': 1,
                'wind_speed_10m': 12,
                'pressure_msl': 1012,
              },
              'hourly': {
                'precipitation_probability': [
                  5,
                  65,
                  ...List<int>.filled(23, 0),
                  99,
                  0,
                ],
                'weather_code': [1, ...List<int>.filled(23, 2), 99, 0],
                'wind_speed_10m': [12, 72, ...List<int>.filled(23, 0), 150, 0],
              },
            }),
            200,
          );
        });
        addTearDown(client.close);

        final conditions = await ForecastIntelService.fetchConditions(
          client,
          const LatLng(11.1, 125.6),
        );

        expect(conditions.rainChance, 5);
        expect(conditions.peakRainChance, 65);
        expect(conditions.peakWindKmh, 72);
        expect(conditions.peakWeatherCode, 2);
        expect(conditions.temperatureC, 28);
      },
    );

    test(
      'reports failed low-pressure requests instead of claiming no LPA',
      () async {
        final client = MockClient(
          (_) async => http.Response('unavailable', 503),
        );
        addTearDown(client.close);

        await expectLater(
          ForecastIntelService.detectLowPressure(
            client,
            const LatLng(11.1, 125.6),
          ),
          throwsA(isA<http.ClientException>()),
        );
      },
    );

    test('finds the lowest pressure in the requested grid', () async {
      final client = MockClient((_) async {
        return http.Response(
          jsonEncode(
            List.generate(
              9,
              (index) => {
                'current': {
                  'pressure_msl': index == 4 ? 998 : 1010 + index,
                  'wind_speed_10m': 25,
                },
              },
            ),
          ),
          200,
        );
      });
      addTearDown(client.close);

      final result = await ForecastIntelService.detectLowPressure(
        client,
        const LatLng(11, 125),
      );

      expect(result, isNotNull);
      expect(result!.pressureHpa, 998);
      expect(result.location, const LatLng(11, 125));
      expect(result.windKmh, 25);
    });
  });

  group('StormService', () {
    test('keeps nearby cyclones and prioritizes current advisories', () async {
      final client = MockClient((request) async {
        expect(request.url.queryParameters['eventlist'], 'TC');
        return http.Response(
          jsonEncode({
            'features': [
              _stormFeature(
                name: 'Nearby past storm',
                longitude: 0.1,
                latitude: 0,
                isCurrent: false,
              ),
              _stormFeature(
                name: 'Active storm',
                longitude: 1,
                latitude: 0,
                isCurrent: true,
                severity: 130,
              ),
              _stormFeature(
                name: 'Distant storm',
                longitude: 20,
                latitude: 0,
                isCurrent: true,
              ),
            ],
          }),
          200,
        );
      });
      addTearDown(client.close);

      final storms = await StormService.fetchNearbyStorms(
        client,
        center: const LatLng(0, 0),
        radiusKm: 300,
      );

      expect(storms.map((storm) => storm.name), [
        'Active storm',
        'Nearby past storm',
      ]);
      expect(storms.first.isCurrent, isTrue);
      expect(storms.first.windKmh, 130);
      expect(storms.first.distanceFrom(const LatLng(0, 0)), closeTo(111, 2));
    });
  });

  group('SafeTrackService', () {
    test('searches mapped evacuation centers by name online', () async {
      final client = MockClient((request) async {
        expect(request.url.host, 'overpass-api.de');
        final query = request.url.queryParameters['data']!;
        expect(query, contains('name'));
        expect(query, contains('General MacArthur'));
        expect(query, contains('assembly_point'));
        return http.Response(
          jsonEncode({
            'elements': [
              {
                'type': 'node',
                'id': 42,
                'lat': 11.1,
                'lon': 125.6,
                'tags': {
                  'emergency': 'assembly_point',
                  'name': 'General MacArthur Evacuation Center',
                },
              },
            ],
          }),
          200,
        );
      });
      addTearDown(client.close);

      final results = await SafeTrackService.searchNearbyEvacuationPoints(
        client,
        center: const LatLng(11.1, 125.6),
        query: 'General MacArthur',
      );

      expect(results, hasLength(1));
      expect(results.single.name, 'General MacArthur Evacuation Center');
    });

    test('searches evacuation points by name and ranks nearest first', () {
      const points = [
        EvacuationPoint(
          id: 'far-school',
          name: 'North School Evacuation Center',
          location: LatLng(11.3, 125.6),
        ),
        EvacuationPoint(
          id: 'near-school',
          name: 'Central School',
          location: LatLng(11.11, 125.6),
        ),
        EvacuationPoint(
          id: 'nearby-hall',
          name: 'Municipal Hall',
          location: LatLng(11.12, 125.6),
        ),
      ];

      final results = SafeTrackService.searchEvacuationPoints(
        points,
        query: 'school',
        origin: const LatLng(11.1, 125.6),
      );

      expect(results.map((point) => point.id), ['near-school', 'far-school']);
    });

    test('finds a Commons photo and retains its attribution', () async {
      final client = MockClient((request) async {
        expect(request.url.host, 'commons.wikimedia.org');
        expect(request.url.queryParameters['gsrsearch'], 'Pasig City Hall');
        expect(request.url.queryParameters['gsrnamespace'], '6');
        return http.Response(
          jsonEncode({
            'query': {
              'pages': {
                '1': {
                  'index': 1,
                  'title': 'File:City Hall Philippines.jpg',
                  'imageinfo': [
                    {
                      'thumburl':
                          'https://upload.wikimedia.org/thumb/generic-hall.jpg',
                      'descriptionurl': 'https://commons.wikimedia.org/wiki/File:City_Hall_Philippines.jpg',
                      'extmetadata': {
                        'Artist': {'value': 'Generic photographer'},
                        'LicenseShortName': {'value': 'CC BY-SA 4.0'},
                      },
                    },
                  ],
                },
                '2': {
                  'index': 2,
                  'title': 'File:Pasig City Hall, Feb 2024.jpg',
                  'imageinfo': [
                    {
                      'thumburl':
                          'https://upload.wikimedia.org/thumb/pasig-hall.jpg',
                      'descriptionurl': 'https://commons.wikimedia.org/wiki/File:Pasig_City_Hall.jpg',
                      'extmetadata': {
                        'Artist': {
                          'value': '<a href="https://commons.wikimedia.org/">Photographer</a>',
                        },
                        'LicenseShortName': {'value': 'CC BY-SA 4.0'},
                      },
                    },
                  ],
                },
              },
            },
          }),
          200,
        );
      });
      addTearDown(client.close);

      final photo = await SafeTrackService.findEvacuationPointPhoto(
        client,
        destinationName: 'Pasig City Hall',
      );

      expect(photo?.imageUrl.host, 'upload.wikimedia.org');
      expect(photo?.imageUrl.path, contains('pasig-hall'));
      expect(photo?.sourceUrl.path, contains('File:Pasig_City_Hall.jpg'));
      expect(photo?.attribution, 'Photographer · CC BY-SA 4.0');
      expect(photo?.title, 'Pasig City Hall, Feb 2024.jpg');
    });

    test('finds a nearby Commons photo for unnamed destinations', () async {
      final client = MockClient((request) async {
        expect(request.url.host, 'commons.wikimedia.org');
        expect(request.url.queryParameters['generator'], 'geosearch');
        expect(request.url.queryParameters['ggscoord'], '11.1|125.6');
        return http.Response(
          jsonEncode({
            'query': {
              'pages': {
                '1': {
                  'index': 1,
                  'title': 'File:Barangay Hall, Eastern Samar.jpg',
                  'imageinfo': [
                    {
                      'thumburl':
                          'https://upload.wikimedia.org/thumb/barangay.jpg',
                      'descriptionurl':
                          'https://commons.wikimedia.org/wiki/File:Barangay_Hall.jpg',
                      'extmetadata': {
                        'Artist': {'value': 'Local photographer'},
                        'LicenseShortName': {'value': 'CC BY-SA 4.0'},
                      },
                    },
                  ],
                },
              },
            },
          }),
          200,
        );
      });
      addTearDown(client.close);

      final photo = await SafeTrackService.findEvacuationPointPhoto(
        client,
        destinationName: 'Selected map destination',
        location: const LatLng(11.1, 125.6),
      );

      expect(photo?.imageUrl.path, contains('barangay'));
      expect(photo?.attribution, 'Local photographer · CC BY-SA 4.0');
    });

    test('finds and sorts community-mapped evacuation points', () async {
      final client = MockClient((request) async {
        expect(request.url.host, 'overpass-api.de');
        expect(request.url.queryParameters['data'], contains('assembly_point'));
        return http.Response(
          jsonEncode({
            'elements': [
              {
                'type': 'way',
                'id': 2,
                'center': {'lat': 11.2, 'lon': 125.6},
                'tags': {'evacuation_center': 'yes', 'name': 'Town Hall'},
              },
              {
                'type': 'node',
                'id': 1,
                'lat': 11.1,
                'lon': 125.6,
                'tags': {'emergency': 'assembly_point', 'name': 'School'},
              },
              {
                'type': 'node',
                'id': 3,
                'lat': 11.15,
                'lon': 125.6,
                'tags': {'name': 'Unrelated place'},
              },
            ],
          }),
          200,
        );
      });
      addTearDown(client.close);

      final points = await SafeTrackService.findNearbyEvacuationPoints(
        client,
        center: const LatLng(11.1, 125.6),
      );

      expect(points.map((point) => point.name), ['School', 'Town Hall']);
      expect(points.first.id, 'node:1');
      expect(points.first.distanceFrom(const LatLng(11.1, 125.6)), 0);
    });

    test('parses road route distance, duration and map geometry', () async {
      final client = MockClient((request) async {
        expect(request.url.host, 'router.project-osrm.org');
        expect(request.url.path, contains('/route/v1/driving/'));
        return http.Response(
          jsonEncode({
            'code': 'Ok',
            'routes': [
              {
                'distance': 3250,
                'duration': 540,
                'geometry': {
                  'coordinates': [
                    [125.6, 11.1],
                    [125.61, 11.11],
                  ],
                },
              },
            ],
          }),
          200,
        );
      });
      addTearDown(client.close);

      final route = await SafeTrackService.getDrivingRoute(
        client,
        origin: const LatLng(11.1, 125.6),
        destination: const LatLng(11.11, 125.61),
      );

      expect(route.distanceMeters, 3250);
      expect(route.drivingSeconds, 540);
      expect(route.points, [
        const LatLng(11.1, 125.6),
        const LatLng(11.11, 125.61),
      ]);
    });
  });

  test('caps combined hazard scores and recommends safety actions', () {
    const location = LatLng(11, 125);
    const conditions = WeatherConditions(
      temperatureC: 28,
      feelsLikeC: 32,
      rainChance: 80,
      windKmh: 90,
      pressureHpa: 1008,
      weatherCode: 95,
      peakRainChance: 80,
      peakWindKmh: 90,
      peakWeatherCode: 95,
    );
    const storm = StormEvent(
      name: 'Test cyclone',
      alertLevel: 'Red',
      country: 'PH',
      description: '',
      latitude: 11,
      longitude: 125,
      isCurrent: true,
      reportUrl: '',
      windKmh: 130,
    );
    const lowPressure = LowPressureArea(
      location: LatLng(11, 125),
      pressureHpa: 998,
      windKmh: 20,
    );

    final assessment = HazardAssessment.assess(
      conditions: conditions,
      storms: const [storm],
      lowPressure: lowPressure,
      location: location,
    );

    expect(assessment.score, 100);
    expect(assessment.level, 'Severe');
    expect(assessment.factors, contains('Thunderstorms in the forecast'));
    expect(
      assessment.actions,
      contains('Monitor PAGASA bulletins for Test cyclone.'),
    );
    expect(
      assessment.actions,
      contains('Prepare an emergency bag and check drainage around you.'),
    );
  });

  test('builds a prefilled SMS URI with cleaned recipients', () {
    final uri = EmergencySmsService.buildUri(
      recipients: [' 0917-000-0000 ', '', '+63918-000-0000'],
      message: 'Stay safe & check the forecast.',
    );

    expect(uri.scheme, 'sms');
    expect(uri.path, '0917-000-0000,+63918-000-0000');
    expect(uri.queryParameters['body'], 'Stay safe & check the forecast.');
  });
}

Map<String, Object?> _stormFeature({
  required String name,
  required double longitude,
  required double latitude,
  required bool isCurrent,
  double? severity,
}) {
  return {
    'geometry': {
      'type': 'Point',
      'coordinates': [longitude, latitude],
    },
    'properties': {
      'eventname': name,
      'alertlevel': 'Orange',
      'country': 'PH',
      'htmldescription': 'Cyclone advisory',
      'iscurrent': isCurrent.toString(),
      'url': {'report': 'https://example.test/report'},
      if (severity != null)
        'severitydata': {'severity': severity, 'severityunit': 'km/h'},
    },
  };
}
