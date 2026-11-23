import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A single recorded GPS fix.
class TripPoint {
  const TripPoint({
    required this.location,
    required this.timestamp,
    this.speedMetersPerSecond = 0,
    this.accuracyMeters = 0,
    this.altitudeMeters = 0,
  });

  final LatLng location;
  final DateTime timestamp;
  final double speedMetersPerSecond;
  final double accuracyMeters;
  final double altitudeMeters;

  Map<String, dynamic> toJson() => {
    'lat': location.latitude,
    'lon': location.longitude,
    'time': timestamp.millisecondsSinceEpoch,
    'speed': speedMetersPerSecond,
    'accuracy': accuracyMeters,
    'altitude': altitudeMeters,
  };

  factory TripPoint.fromJson(Map<String, dynamic> json) => TripPoint(
    location: LatLng(
      (json['lat'] as num).toDouble(),
      (json['lon'] as num).toDouble(),
    ),
    timestamp: DateTime.fromMillisecondsSinceEpoch(json['time'] as int),
    speedMetersPerSecond: (json['speed'] as num?)?.toDouble() ?? 0,
    accuracyMeters: (json['accuracy'] as num?)?.toDouble() ?? 0,
    altitudeMeters: (json['altitude'] as num?)?.toDouble() ?? 0,
  );
}

/// A completed trip saved on the device.
class SavedTrip {
  const SavedTrip({
    required this.id,
    required this.startedAt,
    required this.endedAt,
    required this.points,
  });

  final String id;
  final DateTime startedAt;
  final DateTime endedAt;
  final List<TripPoint> points;

  Duration get duration => endedAt.difference(startedAt);

  double get distanceMeters {
    var total = 0.0;
    for (var i = 1; i < points.length; i++) {
      total += _distanceBetween(points[i - 1].location, points[i].location);
    }
    return total;
  }

  double get averageSpeedMetersPerSecond {
    final seconds = duration.inMilliseconds / 1000;
    if (seconds <= 0) return 0;
    return distanceMeters / seconds;
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'startedAt': startedAt.millisecondsSinceEpoch,
    'endedAt': endedAt.millisecondsSinceEpoch,
    'points': points.map((point) => point.toJson()).toList(),
  };

  factory SavedTrip.fromJson(Map<String, dynamic> json) => SavedTrip(
    id: json['id'] as String,
    startedAt: DateTime.fromMillisecondsSinceEpoch(json['startedAt'] as int),
    endedAt: DateTime.fromMillisecondsSinceEpoch(json['endedAt'] as int),
    points: (json['points'] as List<dynamic>)
        .map((point) => TripPoint.fromJson(point as Map<String, dynamic>))
        .toList(),
  );
}

double _distanceBetween(LatLng a, LatLng b) {
  const earthRadiusMeters = 6371000.0;
  final lat1 = a.latitude * math.pi / 180;
  final lat2 = b.latitude * math.pi / 180;
  final deltaLat = (b.latitude - a.latitude) * math.pi / 180;
  final deltaLon = (b.longitude - a.longitude) * math.pi / 180;
  final haversine =
      math.sin(deltaLat / 2) * math.sin(deltaLat / 2) +
      math.cos(lat1) *
          math.cos(lat2) *
          math.sin(deltaLon / 2) *
          math.sin(deltaLon / 2);
  return earthRadiusMeters *
      2 *
      math.atan2(math.sqrt(haversine), math.sqrt(1 - haversine));
}

/// Records the device's GPS track. Uses only the GPS hardware, so it works
/// without mobile data or Wi-Fi.
class TripRecorder {
  TripRecorder();

  static const _distanceFilterMeters = 8;

  final List<TripPoint> _points = [];
  final StreamController<List<TripPoint>> _updates =
      StreamController<List<TripPoint>>.broadcast();
  StreamSubscription<Position>? _subscription;
  DateTime? _startedAt;
  bool _isRecording = false;
  double _currentSpeedMetersPerSecond = 0;
  String? _lastError;

  bool get isRecording => _isRecording;
  String? get lastError => _lastError;
  List<TripPoint> get points => List.unmodifiable(_points);
  Stream<List<TripPoint>> get updates => _updates.stream;
  LatLng? get lastLocation => _points.isEmpty ? null : _points.last.location;
  double get currentSpeedMetersPerSecond => _currentSpeedMetersPerSecond;

  DateTime? get startedAt => _startedAt;

  Duration get elapsed => _startedAt == null
      ? Duration.zero
      : DateTime.now().difference(_startedAt!);

  double get distanceMeters {
    var total = 0.0;
    for (var i = 1; i < _points.length; i++) {
      total += _distanceBetween(_points[i - 1].location, _points[i].location);
    }
    return total;
  }

  /// Start listening to GPS updates. Returns an error message on failure.
  Future<String?> start() async {
    if (_isRecording) return null;
    _lastError = null;
    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        return _lastError =
            'Location services are turned off. Turn on GPS and try again.';
      }

      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied) {
        return _lastError = 'Location permission was denied.';
      }
      if (permission == LocationPermission.deniedForever) {
        return _lastError =
            'Location permission is permanently denied. Allow it in app settings.';
      }

      final initial = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 20),
        ),
      );

      _points
        ..clear()
        ..add(_pointFromPosition(initial));
      _startedAt = DateTime.now();
      _isRecording = true;
      _currentSpeedMetersPerSecond = initial.speed;
      _updates.add(points);

      _subscription =
          Geolocator.getPositionStream(
            locationSettings: const LocationSettings(
              accuracy: LocationAccuracy.high,
              distanceFilter: _distanceFilterMeters,
            ),
          ).listen(
            (position) {
              _points.add(_pointFromPosition(position));
              _currentSpeedMetersPerSecond = position.speed;
              _updates.add(points);
            },
            onError: (Object error) {
              _lastError = 'GPS tracking stopped: $error';
              _updates.add(points);
            },
          );
      return null;
    } on TimeoutException {
      return _lastError = 'Getting your starting location timed out.';
    } catch (error) {
      return _lastError = 'Could not start GPS tracking: $error';
    }
  }

  TripPoint _pointFromPosition(Position position) => TripPoint(
    location: LatLng(position.latitude, position.longitude),
    timestamp: position.timestamp,
    speedMetersPerSecond: position.speed,
    accuracyMeters: position.accuracy,
    altitudeMeters: position.altitude,
  );

  /// Stop tracking and return the completed trip, or `null` if there was not
  /// enough movement to record.
  Future<SavedTrip?> stop() async {
    if (!_isRecording) return null;
    _isRecording = false;
    await _subscription?.cancel();
    _subscription = null;
    final started = _startedAt;
    _startedAt = null;
    _updates.add(points);
    if (started == null || _points.length < 2) return null;
    return SavedTrip(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      startedAt: started,
      endedAt: DateTime.now(),
      points: List.unmodifiable(_points),
    );
  }

  void clear() {
    _points.clear();
    _startedAt = null;
    _currentSpeedMetersPerSecond = 0;
    _updates.add(points);
  }

  void dispose() {
    _subscription?.cancel();
    _subscription = null;
    _updates.close();
  }
}

/// Persists recorded trips in shared preferences on the device.
class TripStorage {
  const TripStorage._();

  static const _storageKey = 'banog_saved_trips';

  static Future<List<SavedTrip>> load() async {
    final preferences = await SharedPreferences.getInstance();
    final stored = preferences.getStringList(_storageKey) ?? [];
    final trips = <SavedTrip>[];
    for (final entry in stored) {
      try {
        final decoded = jsonDecode(entry);
        if (decoded is Map<String, dynamic>) {
          trips.add(SavedTrip.fromJson(decoded));
        }
      } catch (_) {
        // Skip any unreadable entry instead of losing the whole list.
      }
    }
    trips.sort((a, b) => b.startedAt.compareTo(a.startedAt));
    return trips;
  }

  static Future<void> add(SavedTrip trip) async {
    final preferences = await SharedPreferences.getInstance();
    final stored = preferences.getStringList(_storageKey) ?? [];
    stored.add(jsonEncode(trip.toJson()));
    await preferences.setStringList(_storageKey, stored);
  }

  static Future<void> delete(String id) async {
    final preferences = await SharedPreferences.getInstance();
    final stored = preferences.getStringList(_storageKey) ?? [];
    final remaining = <String>[];
    for (final entry in stored) {
      try {
        final decoded = jsonDecode(entry);
        if (decoded is Map<String, dynamic> && decoded['id'] == id) {
          continue;
        }
      } catch (_) {
        // Keep unreadable entries only if they cannot be matched.
      }
      remaining.add(entry);
    }
    await preferences.setStringList(_storageKey, remaining);
  }

  static Future<void> clear() async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.remove(_storageKey);
  }
}
