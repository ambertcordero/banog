import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'intel_services.dart';

/// The official PAGASA Philippine Area of Responsibility boundary.
///
/// Source: PAGASA. The PAR is bounded by rhumb lines connecting:
/// 5N 115E, 15N 115E, 21N 120E, 25N 120E, 25N 135E, 5N 135E.
class ParBoundary {
  const ParBoundary._();

  static const List<LatLng> vertices = [
    LatLng(5, 115),
    LatLng(15, 115),
    LatLng(21, 120),
    LatLng(25, 120),
    LatLng(25, 135),
    LatLng(5, 135),
  ];

  static const LatLng labelLocation = LatLng(20.2, 127.4);

  /// Point-in-polygon test using the ray casting algorithm.
  static bool contains(LatLng point) {
    var inside = false;
    for (var i = 0, j = vertices.length - 1; i < vertices.length; j = i++) {
      final xi = vertices[i].longitude;
      final yi = vertices[i].latitude;
      final xj = vertices[j].longitude;
      final yj = vertices[j].latitude;
      final crossesLatitude = (yi > point.latitude) != (yj > point.latitude);
      if (!crossesLatitude) continue;
      final xAtLatitude = (xj - xi) * (point.latitude - yi) / (yj - yi) + xi;
      if (point.longitude < xAtLatitude) inside = !inside;
    }
    return inside;
  }

  /// A slightly larger box used to keep storms that are approaching the PAR.
  static bool isMonitorable(LatLng point) {
    return point.latitude >= 0 &&
        point.latitude <= 27 &&
        point.longitude >= 110 &&
        point.longitude <= 140;
  }
}

enum StormWindCategory {
  tropicalDepression,
  tropicalStorm,
  severeTropicalStorm,
  typhoon,
  superTyphoon,
}

extension StormWindCategoryInfo on StormWindCategory {
  String get label => switch (this) {
    StormWindCategory.tropicalDepression => 'Tropical Depression',
    StormWindCategory.tropicalStorm => 'Tropical Storm',
    StormWindCategory.severeTropicalStorm => 'Severe Tropical Storm',
    StormWindCategory.typhoon => 'Typhoon',
    StormWindCategory.superTyphoon => 'Super Typhoon',
  };

  String get shortLabel => switch (this) {
    StormWindCategory.tropicalDepression => 'TD',
    StormWindCategory.tropicalStorm => 'TS',
    StormWindCategory.severeTropicalStorm => 'STS',
    StormWindCategory.typhoon => 'TY',
    StormWindCategory.superTyphoon => 'STY',
  };

  static StormWindCategory fromWind(double? kmh) {
    if (kmh == null || kmh < 62) {
      return StormWindCategory.tropicalDepression;
    }
    if (kmh < 89) return StormWindCategory.tropicalStorm;
    if (kmh < 118) return StormWindCategory.severeTropicalStorm;
    if (kmh < 185) return StormWindCategory.typhoon;
    return StormWindCategory.superTyphoon;
  }
}

class StormTrackPoint {
  const StormTrackPoint({
    required this.location,
    required this.time,
    required this.isForecast,
    required this.isCurrent,
    required this.advisoryNumber,
    this.windKmh,
    this.status = '',
  });

  final LatLng location;
  final DateTime time;
  final bool isForecast;
  final bool isCurrent;
  final int advisoryNumber;
  final double? windKmh;
  final String status;

  StormWindCategory get category => StormWindCategoryInfo.fromWind(windKmh);

  Map<String, dynamic> toJson() => {
    'lat': location.latitude,
    'lon': location.longitude,
    'time': time.toUtc().toIso8601String(),
    'forecast': isForecast,
    'current': isCurrent,
    'advisory': advisoryNumber,
    'wind': windKmh,
    'status': status,
  };

  static StormTrackPoint? fromJson(Object? value) {
    if (value is! Map) return null;
    final lat = _asDouble(value['lat']);
    final lon = _asDouble(value['lon']);
    if (lat == null || lon == null) return null;
    return StormTrackPoint(
      location: LatLng(lat, lon),
      time:
          DateTime.tryParse('${value['time']}')?.toUtc() ??
          DateTime.now().toUtc(),
      isForecast: value['forecast'] == true,
      isCurrent: value['current'] == true,
      advisoryNumber: _asInt(value['advisory']) ?? 0,
      windKmh: _asDouble(value['wind']),
      status: '${value['status'] ?? ''}',
    );
  }
}

class StormTrack {
  const StormTrack({
    required this.eventId,
    required this.name,
    required this.observed,
    required this.forecast,
    required this.fetchedAt,
    this.source = 'GDACS / JTWC',
  });

  final int eventId;
  final String name;
  final List<StormTrackPoint> observed;
  final List<StormTrackPoint> forecast;
  final DateTime fetchedAt;
  final String source;

  StormTrackPoint? get currentPoint {
    for (final point in observed) {
      if (point.isCurrent) return point;
    }
    return observed.isEmpty ? null : observed.last;
  }

  LatLng? get currentLocation => currentPoint?.location;

  double? get currentWindKmh => currentPoint?.windKmh;

  String get currentStatus {
    final status = currentPoint?.status;
    if (status != null && status.isNotEmpty) return status;
    return StormWindCategoryInfo.fromWind(currentWindKmh).label;
  }

  /// All forecast drawing points, including the current position as the start.
  List<LatLng> get forecastLine => [
    ?currentLocation,
    for (final point in forecast) point.location,
  ];

  bool get isMonitorable {
    final current = currentLocation;
    if (current != null && ParBoundary.isMonitorable(current)) return true;
    return forecast.any((point) => ParBoundary.isMonitorable(point.location));
  }

  bool get touchesPar {
    final current = currentLocation;
    if (current != null && ParBoundary.contains(current)) return true;
    return forecast.any((point) => ParBoundary.contains(point.location));
  }

  /// Whether any recorded point of the track passed through the PAR.
  bool get passesPar =>
      observed.any((point) => ParBoundary.contains(point.location)) ||
      forecast.any((point) => ParBoundary.contains(point.location));

  Map<String, dynamic> toJson() => {
    'eventId': eventId,
    'name': name,
    'source': source,
    'fetchedAt': fetchedAt.toUtc().toIso8601String(),
    'observed': observed.map((point) => point.toJson()).toList(),
    'forecast': forecast.map((point) => point.toJson()).toList(),
  };

  static StormTrack? fromJson(Object? value) {
    if (value is! Map) return null;
    final eventId = _asInt(value['eventId']);
    if (eventId == null) return null;
    final rawObserved = value['observed'];
    final rawForecast = value['forecast'];
    return StormTrack(
      eventId: eventId,
      name: '${value['name'] ?? 'Unnamed cyclone'}',
      source: '${value['source'] ?? 'GDACS / JTWC'}',
      fetchedAt:
          DateTime.tryParse('${value['fetchedAt']}')?.toUtc() ??
          DateTime.now().toUtc(),
      observed: rawObserved is List
          ? rawObserved
                .map(StormTrackPoint.fromJson)
                .whereType<StormTrackPoint>()
                .toList()
          : const [],
      forecast: rawForecast is List
          ? rawForecast
                .map(StormTrackPoint.fromJson)
                .whereType<StormTrackPoint>()
                .toList()
          : const [],
    );
  }
}

/// A point along a storm's observed → forecast timeline.
class TyphoonPlaybackFrame {
  const TyphoonPlaybackFrame({
    required this.location,
    required this.time,
    required this.isForecast,
    required this.progress,
    required this.windKmh,
    required this.status,
  });

  final LatLng location;
  final DateTime time;
  final bool isForecast;
  final double progress;
  final double? windKmh;
  final String status;
}

/// Moves a playhead along a track's observed and forecast points.
class TyphoonPlayback {
  TyphoonPlayback(this.track, {double progress = 1, this.speed = 1})
    : progress = progress.clamp(0.0, 1.0);

  /// Duration of one full animation pass at 1x speed.
  static const Duration loopDuration = Duration(seconds: 14);

  static const List<int> speeds = [1, 2, 4];

  final StormTrack track;
  double progress;
  int speed;

  late final List<StormTrackPoint> path = _buildPath();

  bool get canPlay =>
      path.length > 1 && path.last.time.isAfter(path.first.time);

  /// Fraction of the timeline occupied by the current advisory.
  double get currentFraction {
    if (path.isEmpty) return 1;
    final current = track.currentPoint;
    if (current == null || path.length == 1) return 1;
    final first = path.first.time;
    final span = path.last.time.difference(first).inMilliseconds;
    if (span <= 0) {
      final index = path.indexWhere(
        (point) =>
            point.time == current.time &&
            point.location.latitude == current.location.latitude &&
            point.location.longitude == current.location.longitude,
      );
      return index < 0 ? 1 : index / (path.length - 1);
    }
    final elapsed = current.time.difference(first).inMilliseconds;
    return (elapsed / span).clamp(0.0, 1.0);
  }

  TyphoonPlaybackFrame? get frame => frameAt(progress);

  /// Advances the playhead and returns `true` when the loop has finished.
  bool advance(Duration delta) {
    final multiplier = speed <= 0 ? 1 : speed;
    final step =
        delta.inMilliseconds * multiplier / loopDuration.inMilliseconds;
    progress = (progress + step).clamp(0.0, 1.0);
    return progress >= 1;
  }

  TyphoonPlaybackFrame? frameAt(double value) {
    if (path.isEmpty) return null;
    final clamped = value.clamp(0.0, 1.0);
    final first = path.first;
    final last = path.last;
    if (path.length == 1) {
      return TyphoonPlaybackFrame(
        location: first.location,
        time: first.time,
        isForecast: first.isForecast,
        progress: clamped,
        windKmh: first.windKmh,
        status: first.status,
      );
    }

    final span = last.time.difference(first.time).inMilliseconds;
    if (span <= 0) {
      final scaled = clamped * (path.length - 1);
      final index = scaled.floor().clamp(0, path.length - 2);
      final t = scaled - index;
      return _interpolate(
        path[index],
        path[index + 1],
        t,
        clamped,
        path[index].time,
      );
    }

    final target = first.time.add(
      Duration(milliseconds: (span * clamped).round()),
    );
    for (var i = 0; i < path.length - 1; i++) {
      final a = path[i];
      final b = path[i + 1];
      if (target.isBefore(a.time)) break;
      if (target.isAfter(b.time)) continue;
      final segment = b.time.difference(a.time).inMilliseconds;
      final t = segment <= 0
          ? 0.0
          : target.difference(a.time).inMilliseconds / segment;
      return _interpolate(a, b, t, clamped, target);
    }
    return TyphoonPlaybackFrame(
      location: last.location,
      time: last.time,
      isForecast: last.isForecast,
      progress: clamped,
      windKmh: last.windKmh,
      status: last.status,
    );
  }

  TyphoonPlaybackFrame _interpolate(
    StormTrackPoint a,
    StormTrackPoint b,
    double t,
    double progress,
    DateTime time,
  ) {
    final current = track.currentPoint;
    final isForecast = current == null
        ? (a.isForecast || b.isForecast)
        : time.isAfter(current.time);
    final source = isForecast && b.isForecast ? b : a;
    final fallback = isForecast ? b : a;
    final status = source.status.isNotEmpty ? source.status : fallback.status;
    final double? wind;
    if (a.windKmh != null && b.windKmh != null) {
      wind = a.windKmh! + (b.windKmh! - a.windKmh!) * t;
    } else {
      wind = a.windKmh ?? b.windKmh;
    }
    return TyphoonPlaybackFrame(
      location: LatLng(
        a.location.latitude + (b.location.latitude - a.location.latitude) * t,
        a.location.longitude +
            (b.location.longitude - a.location.longitude) * t,
      ),
      time: time,
      isForecast: isForecast,
      progress: progress,
      windKmh: wind,
      status: status,
    );
  }

  List<StormTrackPoint> _buildPath() {
    final points = <StormTrackPoint>[...track.observed, ...track.forecast]
      ..sort((a, b) => a.time.compareTo(b.time));
    final deduped = <StormTrackPoint>[];
    for (final point in points) {
      if (deduped.isNotEmpty) {
        final last = deduped.last;
        final sameSpot =
            last.time == point.time &&
            (last.location.latitude - point.location.latitude).abs() < 1e-6 &&
            (last.location.longitude - point.location.longitude).abs() < 1e-6;
        if (sameSpot) {
          if (point.isCurrent && !last.isCurrent) {
            deduped[deduped.length - 1] = point;
          }
          continue;
        }
      }
      deduped.add(point);
    }
    return deduped;
  }
}

class StormTrackCache {
  const StormTrackCache({required this.tracks, this.savedAt});

  final List<StormTrack> tracks;
  final DateTime? savedAt;

  bool get isEmpty => tracks.isEmpty;

  Duration? get age {
    final saved = savedAt;
    if (saved == null) return null;
    return DateTime.now().toUtc().difference(saved.toUtc());
  }

  bool isStale({Duration maxAge = const Duration(hours: 6)}) {
    final cacheAge = age;
    return cacheAge == null || cacheAge > maxAge;
  }
}

class StormTrackUnavailableException implements Exception {
  const StormTrackUnavailableException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Fetches observed and forecast typhoon tracks from GDACS (JTWC advisories).
class StormTrackService {
  const StormTrackService._();

  static const _cacheKey = 'banog_storm_tracks_v1';
  static const maxCachedTracks = 3;

  /// Fetches tracks for active storms that are inside or approaching the PAR.
  ///
  /// Throws [StormTrackUnavailableException] when at least one active storm was
  /// found but none of their tracks could be downloaded, so callers can keep
  /// showing the last cached track instead of treating it as "no storms".
  static Future<List<StormTrack>> fetchParTracks(http.Client client) async {
    final storms = await StormService.fetchNearbyStorms(
      client,
      center: const LatLng(12, 125),
      radiusKm: null,
    );
    final tracks = <StormTrack>[];
    var attempts = 0;
    var failures = 0;
    for (final storm in storms.where((storm) => storm.isCurrent).take(4)) {
      if (storm.eventId == null) continue;
      attempts++;
      try {
        final track = await fetchTrack(client, storm);
        if (track == null) {
          failures++;
        } else if (track.isMonitorable) {
          tracks.add(track);
        }
      } catch (_) {
        failures++;
      }
    }
    if (attempts > 0 && tracks.isEmpty && failures == attempts) {
      throw const StormTrackUnavailableException(
        'Storm track data is temporarily unavailable.',
      );
    }
    return tracks;
  }

  /// Fetches the most recent completed track that passed through the PAR.
  ///
  /// Lets users replay the typhoon timeline when no cyclone is active.
  static Future<StormTrack?> fetchRecentParTrack(
    http.Client client, {
    int lookbackDays = 45,
  }) async {
    final storms = await StormService.fetchNearbyStorms(
      client,
      center: const LatLng(12, 125),
      radiusKm: null,
      lookbackDays: lookbackDays,
    );
    final recent =
        storms
            .where((storm) => !storm.isCurrent && storm.eventId != null)
            .toList()
          ..sort((a, b) {
            final aTime =
                a.toDate ??
                a.fromDate ??
                DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
            final bTime =
                b.toDate ??
                b.fromDate ??
                DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
            return bTime.compareTo(aTime);
          });
    for (final storm in recent.take(6)) {
      try {
        final track = await fetchTrack(client, storm);
        if (track != null && track.passesPar) return track;
      } catch (_) {
        // Try the next most recent storm.
      }
    }
    return null;
  }

  /// A short human-readable age such as "just now", "12m ago", or "3h ago".
  static String describeAge(Duration? age) {
    if (age == null) return '';
    if (age.inMinutes < 1) return 'just now';
    if (age.inMinutes < 60) return '${age.inMinutes}m ago';
    if (age.inHours < 24) return '${age.inHours}h ago';
    return '${age.inDays}d ago';
  }

  static Future<StormTrack?> fetchTrack(
    http.Client client,
    StormEvent storm,
  ) async {
    final eventId = storm.eventId;
    if (eventId == null) return null;
    final timelineUrl = await _timelineUrlFor(client, storm);
    if (timelineUrl == null) return null;

    final response = await client
        .get(Uri.parse(timelineUrl))
        .timeout(const Duration(seconds: 30));
    if (response.statusCode != 200) return null;

    final payload = jsonDecode(response.body);
    final points = _parseTimeline(payload);
    if (points.isEmpty) return null;

    final maxAdvisory = points.fold<int>(
      0,
      (max, point) => point.advisoryNumber > max ? point.advisoryNumber : max,
    );

    final observed = <StormTrackPoint>[];
    final observedIndex = <String, int>{};
    final observedCandidates =
        points.where((point) => !point.isForecast).toList()
          ..sort((a, b) => a.time.compareTo(b.time));
    for (final point in observedCandidates) {
      final key =
          '${point.time.toIso8601String()}|'
          '${point.location.latitude.toStringAsFixed(3)}|'
          '${point.location.longitude.toStringAsFixed(3)}';
      final existing = observedIndex[key];
      if (existing == null) {
        observedIndex[key] = observed.length;
        observed.add(point);
      } else if (point.isCurrent && !observed[existing].isCurrent) {
        observed[existing] = point;
      }
    }

    final forecast =
        points
            .where(
              (point) =>
                  point.isForecast && point.advisoryNumber == maxAdvisory,
            )
            .toList()
          ..sort((a, b) => a.time.compareTo(b.time));

    return StormTrack(
      eventId: eventId,
      name: storm.name,
      observed: observed,
      forecast: forecast,
      fetchedAt: DateTime.now().toUtc(),
    );
  }

  static Future<String?> _timelineUrlFor(
    http.Client client,
    StormEvent storm,
  ) async {
    var episodeId = storm.episodeId;
    if (episodeId == null) {
      final payload = await _getJson(
        client,
        Uri.https('www.gdacs.org', '/gdacsapi/api/events/geteventdata', {
          'eventtype': 'TC',
          'eventid': '${storm.eventId}',
        }),
      );
      final properties = payload?['properties'];
      if (properties is Map) {
        episodeId = _asInt(properties['episodeid']);
      }
    }
    if (episodeId == null) return null;

    final payload = await _getJson(
      client,
      Uri.https('www.gdacs.org', '/gdacsapi/api/events/getepisodedata', {
        'eventtype': 'TC',
        'eventid': '${storm.eventId}',
        'episodeid': '$episodeId',
      }),
    );
    final properties = payload?['properties'];
    if (properties is! Map) return null;
    return _timelineFromImpacts(properties['impacts']);
  }

  static String? _timelineFromImpacts(Object? impacts) {
    if (impacts is Map) return _timelineFromImpact(impacts);
    if (impacts is List) {
      for (final impact in impacts) {
        final url = _timelineFromImpact(impact);
        if (url != null) return url;
      }
    }
    return null;
  }

  static String? _timelineFromImpact(Object? impact) {
    if (impact is! Map) return null;
    final resource = impact['resource'];
    if (resource is! Map) return null;
    final timeline = resource['timeline'];
    return timeline is String && timeline.isNotEmpty ? timeline : null;
  }

  static Future<Map<String, dynamic>?> _getJson(
    http.Client client,
    Uri uri,
  ) async {
    final response = await client.get(uri).timeout(const Duration(seconds: 25));
    if (response.statusCode != 200) return null;
    final payload = jsonDecode(response.body);
    return payload is Map<String, dynamic> ? payload : null;
  }

  static List<StormTrackPoint> _parseTimeline(Object? payload) {
    if (payload is! Map) return const [];
    final channel = payload['channel'];
    if (channel is! Map) return const [];
    final rawItems = channel['item'];
    final items = rawItems is List ? rawItems : [rawItems];

    final points = <StormTrackPoint>[];
    for (final item in items) {
      if (item is! Map) continue;
      final latitude = _asDouble(item['latitude']);
      final longitude = _asDouble(item['longitude']);
      final time = _parseGdacsDate(item['advisory_datetime']);
      if (latitude == null || longitude == null || time == null) continue;

      final rawWind = _asDouble(item['wind_speed']);
      final status = item['storm_status'];
      points.add(
        StormTrackPoint(
          location: LatLng(latitude, longitude),
          time: time,
          isForecast: !_asBool(item['actual']),
          isCurrent: _asBool(item['current']),
          advisoryNumber: _asInt(item['advisory_number']) ?? 0,
          windKmh: rawWind == null ? null : rawWind * 3.6,
          status: status is List && status.isNotEmpty
              ? '${status.first}'
              : '${status ?? ''}',
        ),
      );
    }
    return points;
  }

  static Future<void> saveCache(List<StormTrack> tracks) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(
      _cacheKey,
      jsonEncode({
        'savedAt': DateTime.now().toUtc().toIso8601String(),
        'tracks': tracks
            .take(maxCachedTracks)
            .map((track) => track.toJson())
            .toList(),
      }),
    );
  }

  static Future<StormTrackCache> loadCache() async {
    final preferences = await SharedPreferences.getInstance();
    final raw = preferences.getString(_cacheKey);
    if (raw == null || raw.isEmpty) {
      return const StormTrackCache(tracks: []);
    }
    try {
      final payload = jsonDecode(raw);
      if (payload is! Map) return const StormTrackCache(tracks: []);
      final rawTracks = payload['tracks'];
      final tracks = rawTracks is List
          ? rawTracks
                .map(StormTrack.fromJson)
                .whereType<StormTrack>()
                .take(maxCachedTracks)
                .toList()
          : const <StormTrack>[];
      return StormTrackCache(
        tracks: tracks,
        savedAt: DateTime.tryParse('${payload['savedAt']}')?.toUtc(),
      );
    } catch (_) {
      return const StormTrackCache(tracks: []);
    }
  }

  static const _months = {
    'jan': 1,
    'feb': 2,
    'mar': 3,
    'apr': 4,
    'may': 5,
    'jun': 6,
    'jul': 7,
    'aug': 8,
    'sep': 9,
    'oct': 10,
    'nov': 11,
    'dec': 12,
  };

  static DateTime? _parseGdacsDate(Object? value) {
    if (value is! String) return null;
    final parts = value.trim().split(RegExp(r'\s+'));
    if (parts.length < 4) return null;
    final day = int.tryParse(parts[0]);
    final month = _months[parts[1].toLowerCase()];
    final year = int.tryParse(parts[2]);
    final clock = parts[3].split(':');
    if (day == null || month == null || year == null || clock.length < 2) {
      return null;
    }
    final hour = int.tryParse(clock[0]);
    final minute = int.tryParse(clock[1]);
    if (hour == null || minute == null) return null;
    return DateTime.utc(year, month, day, hour, minute);
  }
}

double? _asDouble(Object? value) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value.trim());
  return null;
}

int? _asInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value.trim());
  return null;
}

bool _asBool(Object? value) {
  if (value is bool) return value;
  if (value is String) return value.toLowerCase() == 'true';
  return false;
}
