import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';

/// Result of a live device-location request.
class DeviceLocationResult {
  const DeviceLocationResult({this.position, this.error});

  final LatLng? position;
  final String? error;

  bool get isSuccess => position != null;
}

/// Requests the device GPS position, handling runtime permission prompts.
class DeviceLocationService {
  const DeviceLocationService._();

  static Future<DeviceLocationResult> getCurrentPosition() async {
    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        return const DeviceLocationResult(
          error: 'Location services are turned off. Turn on GPS and try again.',
        );
      }

      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied) {
        return const DeviceLocationResult(
          error: 'Location permission was denied.',
        );
      }
      if (permission == LocationPermission.deniedForever) {
        return const DeviceLocationResult(
          error: 'Location permission is permanently denied. Allow it in app settings.',
        );
      }

      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 20),
        ),
      );
      return DeviceLocationResult(
        position: LatLng(position.latitude, position.longitude),
      );
    } on TimeoutException {
      return const DeviceLocationResult(
        error: 'Getting your location timed out. Please try again.',
      );
    } catch (error) {
      return DeviceLocationResult(error: 'Could not get your location: $error');
    }
  }

  static Future<bool> openAppSettings() => Geolocator.openAppSettings();

  static Future<bool> openLocationSettings() =>
      Geolocator.openLocationSettings();
}

/// Builds and launches a pre-filled SMS through the device messaging app.
class EmergencySmsService {
  const EmergencySmsService._();

  static Uri buildUri({
    required List<String> recipients,
    required String message,
  }) {
    final numbers = recipients
        .map((number) => number.trim())
        .where((number) => number.isNotEmpty)
        .join(',');
    return Uri(
      scheme: 'sms',
      path: numbers,
      queryParameters: message.isEmpty ? null : {'body': message},
    );
  }

  static Future<bool> send({
    required List<String> recipients,
    required String message,
  }) async {
    final uri = buildUri(recipients: recipients, message: message);
    if (!await canLaunchUrl(uri)) return false;
    return launchUrl(uri, mode: LaunchMode.externalApplication);
  }
}

/// An evacuation-related point mapped in OpenStreetMap.
class EvacuationPoint {
  const EvacuationPoint({
    required this.id,
    required this.name,
    required this.location,
  });

  final String id;
  final String name;
  final LatLng location;

  double distanceFrom(LatLng point) =>
      const Distance().as(LengthUnit.Meter, point, location);
}

class EvacuationPointPhoto {
  const EvacuationPointPhoto({
    required this.imageUrl,
    required this.sourceUrl,
    required this.attribution,
    required this.title,
  });

  final Uri imageUrl;
  final Uri sourceUrl;
  final String attribution;
  final String title;
}

/// A road route returned by the OSRM public routing service.
class SafeTrackRoute {
  const SafeTrackRoute({
    required this.points,
    required this.distanceMeters,
    required this.drivingSeconds,
  });

  final List<LatLng> points;
  final double distanceMeters;
  final double drivingSeconds;
}

/// Finds community-mapped evacuation points and a road route to one.
class SafeTrackService {
  const SafeTrackService._();

  static Future<EvacuationPointPhoto?> findEvacuationPointPhoto(
    http.Client client, {
    required String destinationName,
    LatLng? location,
  }) async {
    if (location != null) {
      final nearby = await _findNearbyCommonsPhoto(
        client,
        destinationName: destinationName,
        location: location,
      );
      if (nearby != null) return nearby;
    }
    return _findCommonsPhotoByName(client, destinationName);
  }

  static Future<EvacuationPointPhoto?> _findNearbyCommonsPhoto(
    http.Client client, {
    required String destinationName,
    required LatLng location,
  }) async {
    final query = Uri.https('commons.wikimedia.org', '/w/api.php', {
      'action': 'query',
      'generator': 'geosearch',
      'ggscoord': '${location.latitude}|${location.longitude}',
      'ggsradius': '10000',
      'ggsnamespace': '6',
      'ggslimit': '10',
      'prop': 'imageinfo',
      'iiprop': 'url|extmetadata',
      'iiurlwidth': '640',
      'format': 'json',
    });
    final payload = await _getCommonsPayload(client, query);
    final pages = (payload['query'] as Map?)?['pages'];
    if (pages is! Map) return null;

    final results = pages.values.whereType<Map>().toList()
      ..sort((a, b) {
        final match = _photoTitleMatchScore(
          b['title'],
          destinationName,
        ).compareTo(_photoTitleMatchScore(a['title'], destinationName));
        if (match != 0) return match;
        final aIndex = a['index'];
        final bIndex = b['index'];
        if (aIndex is int && bIndex is int) return aIndex.compareTo(bIndex);
        return 0;
      });
    for (final page in results) {
      final photo = _photoFromCommonsPage(page);
      if (photo != null) return photo;
    }
    return null;
  }

  static Future<EvacuationPointPhoto?> _findCommonsPhotoByName(
    http.Client client,
    String destinationName,
  ) async {
    final query = Uri.https('commons.wikimedia.org', '/w/api.php', {
      'action': 'query',
      'generator': 'search',
      'gsrsearch': destinationName,
      'gsrnamespace': '6',
      'gsrlimit': '5',
      'prop': 'imageinfo',
      'iiprop': 'url|extmetadata',
      'iiurlwidth': '640',
      'format': 'json',
    });
    final payload = await _getCommonsPayload(client, query);
    final pages = (payload['query'] as Map?)?['pages'];
    if (pages is! Map) return null;

    final results = pages.values.whereType<Map>().toList()
      ..sort(
        (a, b) => _photoTitleMatchScore(
          b['title'],
          destinationName,
        ).compareTo(_photoTitleMatchScore(a['title'], destinationName)),
      );
    for (final page in results) {
      final title = page['title'];
      if (title is! String ||
          _photoTitleMatchScore(title, destinationName) == 0) {
        continue;
      }
      final photo = _photoFromCommonsPage(page);
      if (photo != null) return photo;
    }
    return null;
  }

  static Future<Map<String, dynamic>> _getCommonsPayload(
    http.Client client,
    Uri query,
  ) async {
    final response = await client
        .get(query, headers: const {'Accept': 'application/json'})
        .timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) {
      throw http.ClientException(
        'Destination photo provider returned HTTP ${response.statusCode}.',
      );
    }

    final payload = jsonDecode(response.body);
    if (payload is! Map<String, dynamic>) {
      throw const FormatException('Destination photo data is invalid.');
    }
    return payload;
  }

  static EvacuationPointPhoto? _photoFromCommonsPage(Map page) {
    final title = page['title'];
    if (title is! String) return null;
    final imageInfo = page['imageinfo'];
    if (imageInfo is! List || imageInfo.isEmpty || imageInfo.first is! Map) {
      return null;
    }
    final info = imageInfo.first as Map;
    final thumbnail = info['thumburl'];
    final source = info['descriptionurl'];
    if (thumbnail is! String || source is! String) return null;
    final imageUri = Uri.tryParse(thumbnail);
    final sourceUri = Uri.tryParse(source);
    if (imageUri == null ||
        sourceUri == null ||
        imageUri.scheme != 'https' ||
        sourceUri.scheme != 'https') {
      return null;
    }
    final metadata = info['extmetadata'] as Map?;
    final artist = _plainMetadataValue(metadata?['Artist']);
    final license = _plainMetadataValue(metadata?['LicenseShortName']);
    final attributionParts = [
      if (artist.isNotEmpty) artist,
      if (license.isNotEmpty) license,
    ];
    return EvacuationPointPhoto(
      imageUrl: imageUri,
      sourceUrl: sourceUri,
      attribution: attributionParts.isEmpty
          ? 'Wikimedia Commons'
          : attributionParts.join(' · '),
      title: title.replaceFirst(RegExp(r'^File:'), ''),
    );
  }

  static int _photoTitleMatchScore(Object? title, String destinationName) {
    if (title is! String) return 0;
    String normalize(String value) => value
        .toLowerCase()
        .replaceAll(RegExp(r'\.[a-z0-9]{2,5}$'), '')
        .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
        .trim();

    final normalizedTitle = normalize(
      title.replaceFirst(RegExp(r'^File:'), ''),
    );
    final normalizedDestination = normalize(destinationName);
    final destinationTokens = normalizedDestination
        .split(' ')
        .where(
          (token) =>
              token.isNotEmpty && !_genericPhotoSearchTerms.contains(token),
        )
        .toSet();
    if (destinationTokens.isEmpty) return 0;
    if (normalizedTitle.contains(normalizedDestination)) return 1000;
    final titleTokens = normalizedTitle.split(' ').toSet();
    final matches = destinationTokens.intersection(titleTokens).length;
    final score = matches * 100 ~/ destinationTokens.length;
    return score >= 50 ? score : 0;
  }

  static const _genericPhotoSearchTerms = {
    'community',
    'mapped',
    'evacuation',
    'center',
    'centre',
    'assembly',
    'point',
  };

  static String _plainMetadataValue(Object? metadata) {
    if (metadata is! Map || metadata['value'] is! String) return '';
    return (metadata['value'] as String)
        .replaceAll(RegExp(r'<[^>]*>'), '')
        .replaceAll('&amp;', '&')
        .replaceAll('&nbsp;', ' ')
        .trim();
  }

  static List<EvacuationPoint> searchEvacuationPoints(
    List<EvacuationPoint> destinations, {
    required String query,
    LatLng? origin,
  }) {
    final normalizedQuery = query.trim().toLowerCase();
    final results = destinations.where((destination) {
      return destination.name.toLowerCase().contains(normalizedQuery);
    }).toList();
    if (origin != null) {
      results.sort(
        (a, b) => a.distanceFrom(origin).compareTo(b.distanceFrom(origin)),
      );
    }
    return results;
  }

  static Future<List<EvacuationPoint>> findNearbyEvacuationPoints(
    http.Client client, {
    required LatLng center,
    int radiusMeters = 20000,
  }) async {
    final latitude = center.latitude.toStringAsFixed(6);
    final longitude = center.longitude.toStringAsFixed(6);
    final query = _evacuationQuery(
      latitude: latitude,
      longitude: longitude,
      radiusMeters: radiusMeters,
    );
    final response = await client
        .get(
          Uri.https('overpass-api.de', '/api/interpreter', {'data': query}),
          headers: const {'Accept': 'application/json'},
        )
        .timeout(const Duration(seconds: 25));
    if (response.statusCode != 200) {
      throw http.ClientException(
        'Evacuation point provider returned HTTP ${response.statusCode}.',
      );
    }

    return _parseEvacuationPoints(response.body, center);
  }

  static Future<List<EvacuationPoint>> searchNearbyEvacuationPoints(
    http.Client client, {
    required LatLng center,
    required String query,
    int radiusMeters = 100000,
  }) async {
    final searchTerm = query.trim();
    if (searchTerm.isEmpty) return const [];
    final escapedTerm = searchTerm
        .replaceAll(RegExp(r'([\\.^$|?*+(){}\[\]])'), r'\$1')
        .replaceAll('"', r'\"');
    final latitude = center.latitude.toStringAsFixed(6);
    final longitude = center.longitude.toStringAsFixed(6);
    final areaFilter = '(around:$radiusMeters,$latitude,$longitude)';
    final nameFilter = '["name"~"$escapedTerm",i]';
    final searchQuery =
        '[out:json][timeout:20];('
        'nwr$areaFilter["emergency"="assembly_point"]$nameFilter;'
        'nwr$areaFilter["evacuation_center"="yes"]$nameFilter;'
        'nwr$areaFilter["amenity"="shelter"]["shelter_type"="emergency"]$nameFilter;'
        ');out center tags;';
    final response = await client
        .get(
          Uri.https('overpass-api.de', '/api/interpreter', {
            'data': searchQuery,
          }),
          headers: const {'Accept': 'application/json'},
        )
        .timeout(const Duration(seconds: 25));
    if (response.statusCode != 200) {
      throw http.ClientException(
        'Evacuation point provider returned HTTP ${response.statusCode}.',
      );
    }
    return _parseEvacuationPoints(response.body, center);
  }

  static String _evacuationQuery({
    required String latitude,
    required String longitude,
    required int radiusMeters,
  }) =>
      '[out:json][timeout:20];'
      '('
      'nwr(around:$radiusMeters,$latitude,$longitude)["emergency"="assembly_point"];'
      'nwr(around:$radiusMeters,$latitude,$longitude)["evacuation_center"="yes"];'
      'nwr(around:$radiusMeters,$latitude,$longitude)["amenity"="shelter"]["shelter_type"="emergency"];'
      ');out center tags;';

  static List<EvacuationPoint> _parseEvacuationPoints(
    String responseBody,
    LatLng center,
  ) {
    final payload = jsonDecode(responseBody);
    if (payload is! Map<String, dynamic> || payload['elements'] is! List) {
      throw const FormatException('Evacuation point data is invalid.');
    }
    final points = <EvacuationPoint>[];
    for (final element in payload['elements'] as List) {
      if (element is! Map<String, dynamic>) continue;
      final tags = element['tags'];
      if (tags is! Map<String, dynamic>) continue;
      final isAssemblyPoint = tags['emergency'] == 'assembly_point';
      final isEvacuationCenter = tags['evacuation_center'] == 'yes';
      final isEmergencyShelter =
          tags['amenity'] == 'shelter' && tags['shelter_type'] == 'emergency';
      if (!isAssemblyPoint && !isEvacuationCenter && !isEmergencyShelter) {
        continue;
      }
      final centerValue = element['center'];
      final centerTags = centerValue is Map ? centerValue : const {};
      final latitudeValue = element['lat'] ?? centerTags['lat'];
      final longitudeValue = element['lon'] ?? centerTags['lon'];
      final id = element['id'];
      if (latitudeValue is! num || longitudeValue is! num || id == null) {
        continue;
      }
      final name = tags['name'];
      points.add(
        EvacuationPoint(
          id: '${element['type'] ?? 'element'}:$id',
          name: name is String && name.trim().isNotEmpty
              ? name.trim()
              : 'Community-mapped evacuation point',
          location: LatLng(latitudeValue.toDouble(), longitudeValue.toDouble()),
        ),
      );
    }
    points.sort(
      (a, b) => a.distanceFrom(center).compareTo(b.distanceFrom(center)),
    );
    return points;
  }

  static Future<SafeTrackRoute> getDrivingRoute(
    http.Client client, {
    required LatLng origin,
    required LatLng destination,
  }) async {
    final coordinates =
        '${origin.longitude},${origin.latitude};'
        '${destination.longitude},${destination.latitude}';
    final uri = Uri.https(
      'router.project-osrm.org',
      '/route/v1/driving/$coordinates',
      {'overview': 'full', 'geometries': 'geojson', 'steps': 'false'},
    );
    final response = await client
        .get(uri, headers: const {'Accept': 'application/json'})
        .timeout(const Duration(seconds: 25));
    if (response.statusCode != 200) {
      throw http.ClientException(
        'Routing provider returned HTTP ${response.statusCode}.',
      );
    }

    final payload = jsonDecode(response.body);
    if (payload is! Map<String, dynamic> ||
        payload['code'] != 'Ok' ||
        payload['routes'] is! List ||
        (payload['routes'] as List).isEmpty) {
      throw const FormatException('No drivable route was found.');
    }
    final route = (payload['routes'] as List).first;
    if (route is! Map<String, dynamic> ||
        route['distance'] is! num ||
        route['duration'] is! num ||
        route['geometry'] is! Map<String, dynamic>) {
      throw const FormatException('Routing response is incomplete.');
    }
    final coordinatesValue =
        (route['geometry'] as Map<String, dynamic>)['coordinates'];
    if (coordinatesValue is! List || coordinatesValue.length < 2) {
      throw const FormatException('Route geometry is unavailable.');
    }
    final points = <LatLng>[];
    for (final coordinate in coordinatesValue) {
      if (coordinate is! List ||
          coordinate.length < 2 ||
          coordinate[0] is! num ||
          coordinate[1] is! num) {
        throw const FormatException('Route geometry is invalid.');
      }
      points.add(
        LatLng(
          (coordinate[1] as num).toDouble(),
          (coordinate[0] as num).toDouble(),
        ),
      );
    }
    return SafeTrackRoute(
      points: points,
      distanceMeters: (route['distance'] as num).toDouble(),
      drivingSeconds: (route['duration'] as num).toDouble(),
    );
  }
}

/// A tropical cyclone reported by GDACS (sourced from JTWC/NOAA advisories).
class StormEvent {
  const StormEvent({
    required this.name,
    required this.alertLevel,
    required this.country,
    required this.description,
    required this.latitude,
    required this.longitude,
    required this.isCurrent,
    required this.reportUrl,
    this.windKmh,
    this.fromDate,
    this.toDate,
    this.eventId,
    this.episodeId,
  });

  final String name;
  final String alertLevel;
  final String country;
  final String description;
  final double latitude;
  final double longitude;
  final bool isCurrent;
  final String reportUrl;
  final double? windKmh;
  final DateTime? fromDate;
  final DateTime? toDate;
  final int? eventId;
  final int? episodeId;

  LatLng get location => LatLng(latitude, longitude);

  double distanceFrom(LatLng point) {
    const earthRadiusKm = 6371.0;
    final dLat = _toRadians(point.latitude - latitude);
    final dLon = _toRadians(point.longitude - longitude);
    final a =
        math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(_toRadians(latitude)) *
            math.cos(_toRadians(point.latitude)) *
            math.sin(dLon / 2) *
            math.sin(dLon / 2);
    return earthRadiusKm * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
  }
}

double _toRadians(double degrees) => degrees * math.pi / 180;

/// Fetches active/recent tropical cyclones from the free GDACS API.
class StormService {
  const StormService._();

  static Future<List<StormEvent>> fetchNearbyStorms(
    http.Client client, {
    required LatLng center,
    double? radiusKm = 1300,
    int lookbackDays = 14,
  }) async {
    final now = DateTime.now();
    final fromDate = now.subtract(Duration(days: lookbackDays));
    final uri = Uri.https(
      'www.gdacs.org',
      '/gdacsapi/api/events/geteventlist/SEARCH',
      {
        'eventlist': 'TC',
        'fromdate': _gdacsDate(fromDate),
        'todate': _gdacsDate(now.add(const Duration(days: 2))),
      },
    );

    final response = await client.get(uri).timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) {
      throw http.ClientException(
        'Storm service returned HTTP ${response.statusCode}.',
      );
    }

    final payload = jsonDecode(response.body);
    if (payload is! Map<String, dynamic> || payload['features'] is! List) {
      throw const FormatException('Storm data is missing.');
    }

    final storms = <StormEvent>[];
    for (final feature in payload['features'] as List) {
      if (feature is! Map<String, dynamic>) continue;
      final geometry = feature['geometry'];
      final properties = feature['properties'];
      if (geometry is! Map<String, dynamic> ||
          properties is! Map<String, dynamic>) {
        continue;
      }
      final coordinates = geometry['coordinates'];
      if (coordinates is! List || coordinates.length < 2) continue;
      final longitude = coordinates[0];
      final latitude = coordinates[1];
      if (latitude is! num || longitude is! num) continue;

      final storm = StormEvent(
        name: _string(properties['eventname']) ?? 'Unnamed cyclone',
        alertLevel: _string(properties['alertlevel']) ?? 'Green',
        country: _string(properties['country']) ?? '',
        description: _string(properties['htmldescription']) ?? '',
        latitude: latitude.toDouble(),
        longitude: longitude.toDouble(),
        isCurrent: _string(properties['iscurrent'])?.toLowerCase() == 'true',
        reportUrl: _reportUrl(properties['url']),
        windKmh: _severityWind(properties['severitydata']),
        fromDate: _parseDate(properties['fromdate']),
        toDate: _parseDate(properties['todate']),
        eventId: _int(properties['eventid']),
        episodeId: _int(properties['episodeid']),
      );
      if (radiusKm == null || storm.distanceFrom(center) <= radiusKm) {
        storms.add(storm);
      }
    }

    storms.sort((a, b) {
      if (a.isCurrent != b.isCurrent) return a.isCurrent ? -1 : 1;
      return a.distanceFrom(center).compareTo(b.distanceFrom(center));
    });
    return storms;
  }

  static double? _severityWind(Object? value) {
    if (value is! Map) return null;
    final severity = value['severity'];
    final unit = value['severityunit'];
    if (severity is! num) return null;
    return unit == 'km/h' ? severity.toDouble() : null;
  }
}

/// A possible low pressure area detected from forecast sea-level pressure.
class LowPressureArea {
  const LowPressureArea({
    required this.location,
    required this.pressureHpa,
    required this.windKmh,
  });

  final LatLng location;
  final double pressureHpa;
  final double windKmh;
}

/// Current conditions plus a peak outlook for the next 24 hours.
class WeatherConditions {
  const WeatherConditions({
    required this.temperatureC,
    required this.feelsLikeC,
    required this.rainChance,
    required this.windKmh,
    required this.pressureHpa,
    required this.weatherCode,
    required this.peakRainChance,
    required this.peakWindKmh,
    required this.peakWeatherCode,
  });

  final double temperatureC;
  final double feelsLikeC;
  final int rainChance;
  final double windKmh;
  final double pressureHpa;
  final int weatherCode;
  final int peakRainChance;
  final double peakWindKmh;
  final int peakWeatherCode;

  bool get thunderstorm => peakWeatherCode >= 95;
  bool get heavyRain =>
      peakRainChance >= 70 ||
      peakWeatherCode == 65 ||
      peakWeatherCode == 67 ||
      peakWeatherCode == 82;
}

/// Online forecast intelligence and heuristic LPA detection.
class ForecastIntelService {
  const ForecastIntelService._();

  static Future<WeatherConditions> fetchConditions(
    http.Client client,
    LatLng location,
  ) async {
    final uri = Uri.https('api.open-meteo.com', '/v1/forecast', {
      'latitude': location.latitude.toString(),
      'longitude': location.longitude.toString(),
      'current':
          'temperature_2m,apparent_temperature,weather_code,'
          'wind_speed_10m,pressure_msl',
      'hourly': 'precipitation_probability,weather_code,wind_speed_10m',
      'forecast_days': '2',
      'timezone': 'Asia/Manila',
    });
    final response = await client.get(uri).timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) {
      throw http.ClientException(
        'Weather provider returned HTTP ${response.statusCode}.',
      );
    }
    final payload = jsonDecode(response.body);
    if (payload is! Map<String, dynamic> ||
        payload['current'] is! Map<String, dynamic> ||
        payload['hourly'] is! Map<String, dynamic>) {
      throw const FormatException('Weather intelligence data is missing.');
    }
    final current = payload['current'] as Map<String, dynamic>;
    final hourly = payload['hourly'] as Map<String, dynamic>;
    final rain = hourly['precipitation_probability'];
    final codes = hourly['weather_code'];
    final winds = hourly['wind_speed_10m'];
    if (rain is! List || codes is! List || winds is! List) {
      throw const FormatException('Weather intelligence forecast is invalid.');
    }

    final count = [
      rain.length,
      codes.length,
      winds.length,
    ].reduce((a, b) => a < b ? a : b);
    final currentRainChance = _number(rain.first)?.round() ?? 0;
    var peakRain = 0;
    var peakWind = _number(current['wind_speed_10m']) ?? 0;
    var peakCode = _number(current['weather_code'])?.round() ?? 0;
    for (var index = 0; index < count && index < 24; index++) {
      final rainValue = _number(rain[index]);
      final windValue = _number(winds[index]);
      final codeValue = _number(codes[index]);
      if (rainValue != null && rainValue > peakRain) {
        peakRain = rainValue.round();
      }
      if (windValue != null && windValue > peakWind) peakWind = windValue;
      if (codeValue != null && codeValue > peakCode) {
        peakCode = codeValue.round();
      }
    }

    return WeatherConditions(
      temperatureC: _number(current['temperature_2m']) ?? 0,
      feelsLikeC: _number(current['apparent_temperature']) ?? 0,
      rainChance: currentRainChance,
      windKmh: _number(current['wind_speed_10m']) ?? 0,
      pressureHpa: _number(current['pressure_msl']) ?? 1013,
      weatherCode: _number(current['weather_code'])?.round() ?? 0,
      peakRainChance: peakRain,
      peakWindKmh: peakWind,
      peakWeatherCode: peakCode,
    );
  }

  /// Samples a coarse grid around [center]; a sea-level pressure minimum below
  /// [thresholdHpa] is flagged as a possible low pressure area.
  static Future<LowPressureArea?> detectLowPressure(
    http.Client client,
    LatLng center, {
    double thresholdHpa = 1007,
  }) async {
    final latitudes = <String>[];
    final longitudes = <String>[];
    for (final latOffset in const [-4.0, 0.0, 4.0]) {
      for (final lonOffset in const [-4.0, 0.0, 4.0]) {
        latitudes.add((center.latitude + latOffset).toStringAsFixed(3));
        longitudes.add((center.longitude + lonOffset).toStringAsFixed(3));
      }
    }
    final uri = Uri.https('api.open-meteo.com', '/v1/forecast', {
      'latitude': latitudes.join(','),
      'longitude': longitudes.join(','),
      'current': 'pressure_msl,wind_speed_10m',
      'timezone': 'Asia/Manila',
    });
    final response = await client.get(uri).timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) {
      throw http.ClientException(
        'Low-pressure service returned HTTP ${response.statusCode}.',
      );
    }
    final payload = jsonDecode(response.body);
    final entries = payload is List
        ? payload.whereType<Map<String, dynamic>>().toList()
        : <Map<String, dynamic>>[if (payload is Map<String, dynamic>) payload];
    if (entries.length > latitudes.length) {
      throw const FormatException(
        'Low-pressure forecast contains more locations than requested.',
      );
    }

    LowPressureArea? lowest;
    for (var index = 0; index < entries.length; index++) {
      final current = entries[index]['current'];
      if (current is! Map<String, dynamic>) continue;
      final pressure = _number(current['pressure_msl']);
      if (pressure == null) continue;
      final wind = _number(current['wind_speed_10m']) ?? 0;
      final lat = double.tryParse(latitudes[index]);
      final lon = double.tryParse(longitudes[index]);
      if (lat == null || lon == null) continue;
      if (pressure < thresholdHpa &&
          (lowest == null || pressure < lowest.pressureHpa)) {
        lowest = LowPressureArea(
          location: LatLng(lat, lon),
          pressureHpa: pressure,
          windKmh: wind,
        );
      }
    }
    return lowest;
  }
}

/// Location-based risk score derived from forecast and nearby hazards.
class RiskAssessment {
  const RiskAssessment({
    required this.score,
    required this.level,
    required this.factors,
    required this.actions,
  });

  final int score;
  final String level;
  final List<String> factors;
  final List<String> actions;
}

class HazardAssessment {
  const HazardAssessment._();

  static RiskAssessment assess({
    required WeatherConditions conditions,
    required List<StormEvent> storms,
    required LowPressureArea? lowPressure,
    required LatLng location,
  }) {
    var score = 0;
    final factors = <String>[];
    final actions = <String>[];

    if (conditions.peakRainChance >= 80) {
      score += 30;
      factors.add('Very high rain chance (${conditions.peakRainChance}%)');
    } else if (conditions.peakRainChance >= 60) {
      score += 20;
      factors.add('High rain chance (${conditions.peakRainChance}%)');
    } else if (conditions.peakRainChance >= 40) {
      score += 10;
      factors.add('Moderate rain chance (${conditions.peakRainChance}%)');
    }

    if (conditions.peakWindKmh >= 90) {
      score += 30;
      factors.add('Damaging winds near ${conditions.peakWindKmh.round()} km/h');
    } else if (conditions.peakWindKmh >= 60) {
      score += 20;
      factors.add('Strong winds near ${conditions.peakWindKmh.round()} km/h');
    } else if (conditions.peakWindKmh >= 45) {
      score += 10;
      factors.add('Gusty winds near ${conditions.peakWindKmh.round()} km/h');
    }

    if (conditions.thunderstorm) {
      score += 10;
      factors.add('Thunderstorms in the forecast');
    }
    if (conditions.heavyRain) {
      score += 10;
      factors.add('Potential for heavy rainfall and localized flooding');
    }

    if (storms.isNotEmpty) {
      final nearest = storms.first;
      final distance = nearest.distanceFrom(location);
      if (distance < 200) {
        score += 40;
        factors.add('${nearest.name} is about ${distance.round()} km away');
      } else if (distance < 400) {
        score += 30;
        factors.add('${nearest.name} is about ${distance.round()} km away');
      } else if (distance < 700) {
        score += 20;
        factors.add('${nearest.name} is about ${distance.round()} km away');
      } else {
        score += 10;
        factors.add('${nearest.name} is being monitored in the region');
      }
      if ((nearest.windKmh ?? 0) >= 118) score += 15;
      actions.add('Monitor PAGASA bulletins for ${nearest.name}.');
    }

    if (lowPressure != null) {
      score += 10;
      factors.add(
        'Low pressure area near '
        '${lowPressure.location.latitude.toStringAsFixed(1)}, '
        '${lowPressure.location.longitude.toStringAsFixed(1)} '
        '(${lowPressure.pressureHpa.round()} hPa)',
      );
      actions.add('Watch for low pressure area updates and possible rain.');
    }

    if (conditions.peakRainChance >= 60 || conditions.heavyRain) {
      actions.add('Prepare an emergency bag and check drainage around you.');
    }
    if ((conditions.peakWindKmh >= 60) || storms.isNotEmpty) {
      actions.add(
        'Secure loose objects and identify your nearest evacuation '
        'center.',
      );
    }
    if (actions.isEmpty) {
      actions.add('Conditions look manageable. Keep monitoring the forecast.');
    }

    final clamped = score.clamp(0, 100);
    final level = clamped >= 75
        ? 'Severe'
        : clamped >= 50
        ? 'High'
        : clamped >= 25
        ? 'Moderate'
        : 'Low';

    return RiskAssessment(
      score: clamped,
      level: level,
      factors: factors.isEmpty
          ? ['No significant hazards detected in the next 24 hours']
          : factors,
      actions: actions,
    );
  }
}

/// Produces a plain-language briefing from the forecast and hazard data.
class IntelligenceBriefing {
  const IntelligenceBriefing._();

  static String generate({
    required String locationLabel,
    required LatLng location,
    required WeatherConditions conditions,
    required List<StormEvent> storms,
    required LowPressureArea? lowPressure,
    required RiskAssessment risk,
  }) {
    final buffer = StringBuffer();
    buffer.write(
      'For $locationLabel, expect about '
      '${conditions.temperatureC.round()}°C '
      '(feels like ${conditions.feelsLikeC.round()}°C) with a peak rain '
      'chance of ${conditions.peakRainChance}% in the next 24 hours. ',
    );

    if (conditions.peakWindKmh >= 45) {
      buffer.write(
        'Winds may reach around ${conditions.peakWindKmh.round()} km/h, so '
        'take care near trees, roofs, and the coast. ',
      );
    }

    if (storms.isNotEmpty) {
      final nearest = storms.first;
      buffer.write(
        '${nearest.name} is the closest monitored cyclone, roughly '
        '${nearest.distanceFrom(location).round()} km away. ',
      );
    } else {
      buffer.write('No tropical cyclone is currently tracked near you. ');
    }

    if (lowPressure != null) {
      buffer.write(
        'A possible low pressure area is being monitored near '
        '${lowPressure.location.latitude.toStringAsFixed(1)}, '
        '${lowPressure.location.longitude.toStringAsFixed(1)} with a central '
        'pressure of ${lowPressure.pressureHpa.round()} hPa; this can bring '
        'scattered rain and gusty winds. ',
      );
    }

    buffer.write(
      'Overall risk is ${risk.level} (${risk.score}/100). '
      'This briefing is generated from forecast-model data and is not an '
      'official PAGASA warning.',
    );
    return buffer.toString();
  }
}

String? _string(Object? value) => value is String ? value : null;

int? _int(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value);
  return null;
}

String _reportUrl(Object? value) {
  if (value is Map) {
    final report = value['report'];
    if (report is String) return report;
  }
  return '';
}

double? _number(Object? value) => value is num ? value.toDouble() : null;

DateTime? _parseDate(Object? value) {
  if (value is! String) return null;
  return DateTime.tryParse(value);
}

String _gdacsDate(DateTime date) {
  final month = date.month.toString().padLeft(2, '0');
  final day = date.day.toString().padLeft(2, '0');
  return '${date.year}-$month-$day';
}
