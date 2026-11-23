import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import 'services/intel_services.dart';
import 'services/offline_maps.dart';
import 'services/storm_tracking.dart';
import 'services/trip_tracking.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await OfflineMapsService.initialiseCache();
  runApp(const BanogWeatherApp());
}

const _blue = Color(0xFF2878C7);
const _navy = Color(0xFF174E83);
const _ink = Color(0xFF183B5B);
const _muted = Color(0xFF6D8398);
const _canvas = Color(0xFFF4F8FC);
const _darkCanvas = Color(0xFF101820);
const _darkSurface = Color(0xFF1B2732);
const _darkInk = Color(0xFFE5EEF5);
const _darkMuted = Color(0xFFA8BBCB);
const _backgroundStyleOptions = [
  'Classic',
  'Sky',
  'Sage',
  'Mist',
  'Sunset',
  'Glass',
  'Custom',
];
const _customBackgroundSwatches = [
  (Color(0xFFEDE9FE), 'Lilac'),
  (Color(0xFFE0F2FE), 'Sky Blue'),
  (Color(0xFFD1FAE5), 'Mint'),
  (Color(0xFFFFEDD5), 'Peach'),
  (Color(0xFFFFE4E6), 'Rose'),
  (Color(0xFFFEF3C7), 'Amber'),
  (Color(0xFFE0F7FA), 'Cyan'),
  (Color(0xFFE2E8F0), 'Slate'),
  (Color(0xFF1E293B), 'Navy Dark'),
  (Color(0xFF14241B), 'Forest Dark'),
  (Color(0xFF261924), 'Plum Dark'),
  (Color(0xFF2A1C16), 'Mocha Dark'),
];
const _fontStyleOptions = ['Sans', 'Serif'];
const _defaultMapLocation = LatLng(11.2341, 125.5392);
const _forecastRefreshInterval = Duration(minutes: 15);
const _radarRefreshInterval = Duration(minutes: 10);
const _typhoonPastColor = Color(0xFF1565C0);
const _typhoonForecastColor = Color(0xFFEF6C00);
const _parBoundaryColor = Color(0xFF0F8B8D);

Color _stormCategoryColor(StormWindCategory category) => switch (category) {
  StormWindCategory.tropicalDepression => const Color(0xFF64B5F6),
  StormWindCategory.tropicalStorm => const Color(0xFF43A047),
  StormWindCategory.severeTropicalStorm => const Color(0xFFF9A825),
  StormWindCategory.typhoon => const Color(0xFFEF6C00),
  StormWindCategory.superTyphoon => const Color(0xFFAD1457),
};
const _phlAdm1Asset = 'assets/boundaries/phl_adm1_regions.geojson';
const _phlAdm2Asset = 'assets/boundaries/phl_adm2_provinces.geojson';
const _phlAdm3Asset = 'assets/boundaries/phl_adm3_municipalities.geojson';

String _normalizeBoundaryName(String value) {
  var name = value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();
  name = name.replaceFirst(
    RegExp(r'^(city|municipality|province|region|barangay) of '),
    '',
  );
  name = name.replaceFirst(
    RegExp(r'\b(?:city|municipality|province|region)\b$'),
    '',
  );
  return name.replaceAll(RegExp(r'\s+'), ' ').trim();
}

List<dynamic> _boundaryPolygonsFromGeometry(Map<String, dynamic> geometry) {
  final type = geometry['type'];
  final coordinates = geometry['coordinates'];
  if (coordinates is! List) return const [];
  if (type == 'Polygon') {
    final polygon = _boundaryPolygonFromCoordinates(coordinates);
    return polygon == null ? const [] : [polygon];
  }
  if (type == 'MultiPolygon') {
    final polygons = <dynamic>[];
    for (final item in coordinates) {
      final polygon = _boundaryPolygonFromCoordinates(item);
      if (polygon != null) polygons.add(polygon);
    }
    return polygons;
  }
  return const [];
}

List<dynamic>? _boundaryPolygonFromCoordinates(Object? coordinates) {
  if (coordinates is! List || coordinates.isEmpty) return null;
  final outer = coordinates.first;
  if (outer is! List || outer.length < 3) return null;
  final holes = <dynamic>[];
  for (final ring in coordinates.skip(1)) {
    if (ring is List && ring.length >= 3) holes.add(ring);
  }
  return <dynamic>[outer, holes];
}

List<dynamic>? _findBoundaryInGeoJson(List<Object?> args) {
  final raw = args[0] as String;
  final candidates = (args[1] as List).whereType<String>().toSet();
  final latitude = args[2] as double?;
  final longitude = args[3] as double?;
  final decoded = jsonDecode(raw);
  if (decoded is! Map<String, dynamic>) return null;
  final features = decoded['features'];
  if (features is! List) return null;

  List<dynamic>? best;
  var bestArea = double.infinity;
  List<dynamic>? fallback;
  for (final feature in features) {
    if (feature is! Map<String, dynamic>) continue;
    final properties = feature['properties'];
    final geometry = feature['geometry'];
    if (properties is! Map<String, dynamic> ||
        geometry is! Map<String, dynamic>) {
      continue;
    }
    final shapeName = properties['shapeName'];
    if (shapeName is! String ||
        !candidates.contains(_normalizeBoundaryName(shapeName))) {
      continue;
    }
    final polygons = _boundaryPolygonsFromGeometry(geometry);
    if (polygons.isEmpty) continue;
    fallback ??= polygons;
    if (latitude == null || longitude == null) continue;
    if (!_pointInBoundaryPolygons(polygons, latitude, longitude)) continue;
    final area = _boundaryBoundsArea(polygons);
    if (area < bestArea) {
      bestArea = area;
      best = polygons;
    }
  }
  return best ?? fallback;
}

bool _pointInBoundaryPolygons(
  List<dynamic> polygons,
  double latitude,
  double longitude,
) {
  for (final polygon in polygons) {
    if (polygon is! List || polygon.isEmpty) continue;
    final outer = polygon[0];
    if (outer is! List || !_pointInBoundaryRing(outer, latitude, longitude)) {
      continue;
    }
    var inHole = false;
    if (polygon.length > 1 && polygon[1] is List) {
      for (final hole in polygon[1] as List) {
        if (hole is List && _pointInBoundaryRing(hole, latitude, longitude)) {
          inHole = true;
          break;
        }
      }
    }
    if (!inHole) return true;
  }
  return false;
}

bool _pointInBoundaryRing(
  List<dynamic> ring,
  double latitude,
  double longitude,
) {
  var inside = false;
  for (var i = 0, j = ring.length - 1; i < ring.length; j = i++) {
    final current = ring[i];
    final previous = ring[j];
    if (current is! List ||
        previous is! List ||
        current.length < 2 ||
        previous.length < 2) {
      continue;
    }
    final currentX = current[0];
    final currentY = current[1];
    final previousX = previous[0];
    final previousY = previous[1];
    if (currentX is! num ||
        currentY is! num ||
        previousX is! num ||
        previousY is! num) {
      continue;
    }
    final x1 = currentX.toDouble();
    final y1 = currentY.toDouble();
    final x2 = previousX.toDouble();
    final y2 = previousY.toDouble();
    if ((y1 > latitude) == (y2 > latitude)) continue;
    final intersectionX = (x2 - x1) * (latitude - y1) / (y2 - y1) + x1;
    if (longitude < intersectionX) inside = !inside;
  }
  return inside;
}

double _boundaryBoundsArea(List<dynamic> polygons) {
  var minLatitude = double.infinity;
  var minLongitude = double.infinity;
  var maxLatitude = -double.infinity;
  var maxLongitude = -double.infinity;
  for (final polygon in polygons) {
    if (polygon is! List || polygon.isEmpty) continue;
    final ring = polygon[0];
    if (ring is! List) continue;
    for (final point in ring) {
      if (point is! List || point.length < 2) continue;
      final x = point[0];
      final y = point[1];
      if (x is! num || y is! num) continue;
      final longitude = x.toDouble();
      final latitude = y.toDouble();
      if (latitude < minLatitude) minLatitude = latitude;
      if (latitude > maxLatitude) maxLatitude = latitude;
      if (longitude < minLongitude) minLongitude = longitude;
      if (longitude > maxLongitude) maxLongitude = longitude;
    }
  }
  if (minLatitude.isInfinite) return double.infinity;
  return (maxLatitude - minLatitude) * (maxLongitude - minLongitude);
}

enum _MapType { standard, humanitarian, topographic }

enum _WeatherLayer { radar, rain, wind, satellite }

class _WeatherPoint {
  const _WeatherPoint({
    required this.location,
    required this.precipitation,
    required this.windSpeed,
    required this.windDirection,
    required this.windGust,
  });

  final LatLng location;
  final double precipitation;
  final double windSpeed;
  final double windDirection;
  final double windGust;
}

class _HourlyWeather {
  const _HourlyWeather({
    required this.time,
    required this.temperature,
    required this.feelsLike,
    required this.precipitationProbability,
    required this.weatherCode,
  });

  final DateTime time;
  final double temperature;
  final double feelsLike;
  final int precipitationProbability;
  final int weatherCode;
}

class _WeatherAlert {
  const _WeatherAlert({
    required this.title,
    required this.message,
    required this.category,
    required this.icon,
    required this.color,
  });

  final String title;
  final String message;
  final String category;
  final IconData icon;
  final Color color;
}

Future<List<_WeatherAlert>> _fetchWeatherAlerts(
  http.Client client, {
  bool isImperial = false,
  bool use24HourTime = false,
  LatLng location = _defaultMapLocation,
}) async {
  final uri = Uri.https('api.open-meteo.com', '/v1/forecast', {
    'latitude': location.latitude.toString(),
    'longitude': location.longitude.toString(),
    'current': 'temperature_2m',
    'hourly': 'precipitation_probability,weather_code,wind_speed_10m',
    'forecast_days': '2',
    'timezone': 'Asia/Manila',
  });
  final response = await client.get(uri).timeout(const Duration(seconds: 15));
  if (response.statusCode != 200) {
    throw http.ClientException(
      'Forecast provider returned HTTP ${response.statusCode}.',
    );
  }

  final payload = jsonDecode(response.body);
  if (payload is! Map<String, dynamic> ||
      payload['hourly'] is! Map<String, dynamic> ||
      payload['current'] is! Map<String, dynamic>) {
    throw const FormatException('Weather alert forecast is missing.');
  }
  final hourly = payload['hourly'] as Map<String, dynamic>;
  final current = payload['current'] as Map<String, dynamic>;
  final times = hourly['time'];
  final precipitation = hourly['precipitation_probability'];
  final weatherCodes = hourly['weather_code'];
  final windSpeeds = hourly['wind_speed_10m'];
  if (times is! List ||
      precipitation is! List ||
      weatherCodes is! List ||
      windSpeeds is! List) {
    throw const FormatException('Weather alert forecast arrays are invalid.');
  }

  final currentTime = current['time'];
  final currentHour = currentTime is String && currentTime.length >= 13
      ? currentTime.substring(0, 13)
      : DateTime.now().toIso8601String().substring(0, 13);
  var firstHourIndex = times.indexWhere(
    (time) => time is String && time.startsWith(currentHour),
  );
  if (firstHourIndex < 0) firstHourIndex = 0;
  final availableHours = [
    times.length,
    precipitation.length,
    weatherCodes.length,
    windSpeeds.length,
  ].reduce((shortest, length) => shortest < length ? shortest : length);

  int? thunderstormHour;
  int? rainHour;
  int? windHour;
  for (var index = firstHourIndex; index < availableHours; index++) {
    final code = weatherCodes[index];
    final rainChance = precipitation[index];
    final windSpeed = windSpeeds[index];
    if (code is! num || rainChance is! num || windSpeed is! num) continue;

    final weatherCode = code.toInt();
    if (thunderstormHour == null && weatherCode >= 95) {
      thunderstormHour = index;
    }
    if (rainHour == null &&
        (rainChance >= 60 ||
            weatherCode == 65 ||
            weatherCode == 67 ||
            weatherCode == 82)) {
      rainHour = index;
    }
    if (windHour == null && windSpeed >= 45) windHour = index;
  }

  final alerts = <_WeatherAlert>[];
  if (thunderstormHour != null) {
    alerts.add(
      _WeatherAlert(
        title: 'Thunderstorm possible',
        message:
            'Thunderstorms are forecast around ${_formatAlertHour(times[thunderstormHour], use24HourTime: use24HourTime)}. Seek shelter indoors and avoid exposed areas.',
        category: 'Thunderstorm',
        icon: Icons.thunderstorm_rounded,
        color: const Color(0xFFFFC18F),
      ),
    );
  }
  if (rainHour != null) {
    final chance = precipitation[rainHour] as num;
    alerts.add(
      _WeatherAlert(
        title: chance >= 70 ? 'Heavy rain possible' : 'Rain likely',
        message:
            'Rain is forecast around ${_formatAlertHour(times[rainHour], use24HourTime: use24HourTime)} with a ${chance.round()}% chance. Plan for wet conditions.',
        category: 'Rain',
        icon: Icons.water_drop_rounded,
        color: const Color(0xFFFFDE77),
      ),
    );
  }
  if (windHour != null) {
    final rawSpeed = (windSpeeds[windHour] as num).toDouble();
    final speed = _displayWindSpeed(rawSpeed, isImperial).round();
    alerts.add(
      _WeatherAlert(
        title: 'Strong winds possible',
        message:
            'Winds may reach $speed ${isImperial ? 'mph' : 'km/h'} around ${_formatAlertHour(times[windHour], use24HourTime: use24HourTime)}. Take care near trees and along the coast.',
        category: 'Wind',
        icon: Icons.air_rounded,
        color: const Color(0xFFB3D4F1),
      ),
    );
  }
  return alerts;
}

String _formatHourOfDay(int? hour, {bool use24HourTime = false}) {
  if (hour == null || hour < 0 || hour > 23) return 'the next 24 hours';
  if (use24HourTime) return '${hour.toString().padLeft(2, '0')}:00';
  final displayHour = hour % 12 == 0 ? 12 : hour % 12;
  return '$displayHour ${hour < 12 ? 'AM' : 'PM'}';
}

String _formatAlertHour(Object? value, {bool use24HourTime = false}) {
  if (value is! String || value.length < 13) return 'the next 24 hours';
  final hour = int.tryParse(value.substring(11, 13));
  return _formatHourOfDay(hour, use24HourTime: use24HourTime);
}

bool _isDarkMode(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark;

class _BackgroundStyleTheme extends ThemeExtension<_BackgroundStyleTheme> {
  const _BackgroundStyleTheme({required this.style, this.customColor});

  final String style;
  final Color? customColor;

  @override
  _BackgroundStyleTheme copyWith({String? style, Color? customColor}) =>
      _BackgroundStyleTheme(
        style: style ?? this.style,
        customColor: customColor ?? this.customColor,
      );

  @override
  _BackgroundStyleTheme lerp(
    covariant _BackgroundStyleTheme? other,
    double t,
  ) => other == null || t < 0.5 ? this : other;
}

String _backgroundStyleOf(BuildContext context) =>
    Theme.of(context).extension<_BackgroundStyleTheme>()?.style ?? 'Classic';

bool _isGlassBackground(BuildContext context) =>
    _backgroundStyleOf(context) == 'Glass';

Color _surfaceColor(BuildContext context) {
  final dark = _isDarkMode(context);
  if (_isGlassBackground(context)) {
    return dark
        ? _darkSurface.withValues(alpha: 0.72)
        : Colors.white.withValues(alpha: 0.70);
  }
  return dark ? _darkSurface : Colors.white;
}

Border? _glassBorder(BuildContext context) {
  if (!_isGlassBackground(context)) return null;
  final dark = _isDarkMode(context);
  return Border.all(
    color: dark
        ? Colors.white.withValues(alpha: 0.16)
        : Colors.white.withValues(alpha: 0.82),
    width: 1.2,
  );
}

Color _primaryTextColor(BuildContext context) =>
    _isDarkMode(context) ? _darkInk : _ink;

Color _secondaryTextColor(BuildContext context) =>
    _isDarkMode(context) ? _darkMuted : _muted;

const _windLabelThresholdKmh = 20.0;

Color _windSpeedColor(double speedKmh) {
  if (speedKmh < 20) return const Color(0xFF2BB3A3);
  if (speedKmh < 40) return const Color(0xFF2878C7);
  if (speedKmh < 60) return const Color(0xFFE08A1E);
  return const Color(0xFFD84372);
}

double _windArrowSize(double speedKmh) {
  final normalized = (speedKmh / 60).clamp(0.0, 1.0).toDouble();
  return 18 + normalized * 12;
}

String _compassDirection(double degrees) {
  const labels = ['N', 'NE', 'E', 'SE', 'S', 'SW', 'W', 'NW'];
  final index = ((degrees % 360) / 45).round() % 8;
  return labels[index];
}

String _fontFamilyFor(String fontStyle) =>
    fontStyle == 'Serif' ? 'serif' : 'sans-serif';

Color _backgroundColorFor(
  String backgroundStyle,
  bool isDarkMode, {
  Color? customColor,
}) {
  if (backgroundStyle == 'Custom') {
    final base = customColor ?? const Color(0xFFEDE9FE);
    if (isDarkMode) {
      if (base.computeLuminance() > 0.3) {
        final hsl = HSLColor.fromColor(base);
        return hsl
            .withLightness(math.min(hsl.lightness, 0.12))
            .withSaturation(math.min(hsl.saturation, 0.35))
            .toColor();
      }
      return base;
    } else {
      if (base.computeLuminance() < 0.5) {
        final hsl = HSLColor.fromColor(base);
        return hsl
            .withLightness(0.96)
            .withSaturation(math.min(hsl.saturation, 0.35))
            .toColor();
      }
      return base;
    }
  }
  return switch ((backgroundStyle, isDarkMode)) {
    ('Glass', _) => Colors.transparent,
    ('Sky', false) => const Color(0xFFEFF7FF),
    ('Sky', true) => const Color(0xFF101C28),
    ('Sage', false) => const Color(0xFFF1F7F1),
    ('Sage', true) => const Color(0xFF142019),
    ('Mist', false) => const Color(0xFFF4F1FB),
    ('Mist', true) => const Color(0xFF17131F),
    ('Sunset', false) => const Color(0xFFFFF4EC),
    ('Sunset', true) => const Color(0xFF211511),
    (_, false) => _canvas,
    (_, true) => _darkCanvas,
  };
}

IconData _backgroundStyleIcon(String style) => switch (style) {
  'Sky' => Icons.wb_cloudy_rounded,
  'Sage' => Icons.eco_rounded,
  'Mist' => Icons.blur_on_rounded,
  'Sunset' => Icons.wb_twilight_rounded,
  'Glass' => Icons.auto_awesome_rounded,
  'Custom' => Icons.tune_rounded,
  _ => Icons.color_lens_outlined,
};

String _backgroundStyleDescription(String style) => switch (style) {
  'Sky' => 'Cool, airy blue tint',
  'Sage' => 'Soft, natural green tint',
  'Mist' => 'Calm lavender haze',
  'Sunset' => 'Warm evening glow',
  'Glass' => 'Frosted glass over a soft gradient',
  'Custom' => 'Personalized color tint or custom hex code',
  _ => 'Original Banog background',
};

String _colorToHex(Color color) {
  final rgb = color.toARGB32() & 0x00FFFFFF;
  return rgb.toRadixString(16).padLeft(6, '0').toUpperCase();
}

Color? _parseHexColor(String hex) {
  var clean = hex.replaceAll('#', '').trim();
  if (clean.length == 6) {
    clean = 'FF$clean';
  }
  if (clean.length == 8) {
    final value = int.tryParse(clean, radix: 16);
    if (value != null) {
      return Color(value);
    }
  }
  return null;
}

class _GlassBackdrop extends StatelessWidget {
  const _GlassBackdrop({required this.isDarkMode, required this.child});

  final bool isDarkMode;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final baseColors = isDarkMode
        ? const [Color(0xFF0A111B), Color(0xFF101C2A)]
        : const [Color(0xFFF2F7FD), Color(0xFFE6EFFA)];
    final blobs = <(Alignment, double, Color)>[
      (
        const Alignment(-0.9, -1.1),
        430,
        isDarkMode ? const Color(0xFF1E4E7A) : const Color(0xFF8FC1EE),
      ),
      (
        const Alignment(1.1, -0.5),
        380,
        isDarkMode ? const Color(0xFF2A3E6B) : const Color(0xFFC4D5F5),
      ),
      (
        const Alignment(-1.1, 0.9),
        420,
        isDarkMode ? const Color(0xFF1F5A4E) : const Color(0xFFB7E2D1),
      ),
      (
        const Alignment(1.0, 1.2),
        360,
        isDarkMode ? const Color(0xFF5A3650) : const Color(0xFFF1CEE4),
      ),
    ];

    return Stack(
      fit: StackFit.expand,
      children: [
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: baseColors,
            ),
          ),
        ),
        ImageFiltered(
          imageFilter: ui.ImageFilter.blur(sigmaX: 46, sigmaY: 46),
          child: Stack(
            fit: StackFit.expand,
            children: [
              for (final (alignment, size, color) in blobs)
                Align(
                  alignment: alignment,
                  child: Container(
                    width: size,
                    height: size,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: color.withValues(alpha: isDarkMode ? 0.55 : 0.72),
                    ),
                  ),
                ),
            ],
          ),
        ),
        child,
      ],
    );
  }
}

int _displayTemperature(double celsius, bool isImperial) =>
    isImperial ? ((celsius * 9 / 5) + 32).round() : celsius.round();

double _displayWindSpeed(double kilometersPerHour, bool isImperial) =>
    isImperial ? kilometersPerHour * 0.621371 : kilometersPerHour;

Future<String> _reverseGeocodeLabel(LatLng location) async {
  http.Client? client;
  try {
    client = http.Client();
    final uri = Uri.https('nominatim.openstreetmap.org', '/reverse', {
      'format': 'jsonv2',
      'lat': location.latitude.toString(),
      'lon': location.longitude.toString(),
      'zoom': '12',
      'addressdetails': '1',
    });
    final response = await client
        .get(
          uri,
          headers: {'User-Agent': 'BanogWeatherApp/1.0 (mobile weather app)'},
        )
        .timeout(const Duration(seconds: 12));
    if (response.statusCode != 200) return 'My location';
    final payload = jsonDecode(response.body);
    if (payload is Map<String, dynamic>) {
      final name = payload['name'];
      if (name is String && name.trim().isNotEmpty) return name.trim();
      final address = payload['address'];
      if (address is Map) {
        for (final key in [
          'city',
          'town',
          'municipality',
          'village',
          'county',
        ]) {
          final value = address[key];
          if (value is String && value.trim().isNotEmpty) return value.trim();
        }
      }
      final display = payload['display_name'];
      if (display is String && display.trim().isNotEmpty) {
        return display.split(',').take(2).join(',').trim();
      }
    }
  } catch (_) {
    // Fall back to a generic label when reverse geocoding is unavailable.
  } finally {
    client?.close();
  }
  return 'My location';
}

class BanogWeatherApp extends StatefulWidget {
  const BanogWeatherApp({super.key, this.forecastClient, this.alertClient});

  final http.Client? forecastClient;
  final http.Client? alertClient;

  @override
  State<BanogWeatherApp> createState() => _BanogWeatherAppState();
}

class _BanogWeatherAppState extends State<BanogWeatherApp> {
  bool _preferencesLoaded = false;
  bool _hasSeenOnboarding = false;
  bool _isDarkMode = false;
  bool _isImperial = false;
  bool _use24HourTime = false;
  bool _notificationsEnabled = true;
  String _fontStyle = 'Sans';
  String _backgroundStyle = 'Classic';
  Color _customBackgroundColor = const Color(0xFFEDE9FE);
  Set<String> _enabledAlertTypes = {'Rain', 'Thunderstorm', 'Wind'};
  List<String> _savedLocations = ['General MacArthur, Eastern Samar'];
  LatLng _activeLocation = _defaultMapLocation;
  String _activeLocationLabel = 'General MacArthur, Eastern Samar';
  String _emergencyContactName = '';
  String _emergencyContactNumber = '';

  @override
  void initState() {
    super.initState();
    _loadPreferences();
  }

  Future<void> _loadPreferences() async {
    final preferences = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _hasSeenOnboarding = preferences.getBool('hasSeenOnboarding') ?? false;
      _isDarkMode = preferences.getBool('darkMode') ?? false;
      _isImperial = preferences.getBool('imperialUnits') ?? false;
      _use24HourTime = preferences.getBool('use24HourTime') ?? false;
      _notificationsEnabled =
          preferences.getBool('notificationsEnabled') ?? true;
      final savedFontStyle = preferences.getString('fontStyle') ?? 'Sans';
      _fontStyle = _fontStyleOptions.contains(savedFontStyle)
          ? savedFontStyle
          : 'Sans';
      final savedBackgroundStyle =
          preferences.getString('backgroundStyle') ?? 'Classic';
      _backgroundStyle = _backgroundStyleOptions.contains(savedBackgroundStyle)
          ? savedBackgroundStyle
          : 'Classic';
      final savedCustomColor = preferences.getInt('customBackgroundColor');
      if (savedCustomColor != null) {
        _customBackgroundColor = Color(savedCustomColor);
      }
      _enabledAlertTypes =
          preferences.getStringList('enabledAlertTypes')?.toSet() ??
          {'Rain', 'Thunderstorm', 'Wind'};
      _savedLocations =
          preferences.getStringList('savedLocations') ??
          ['General MacArthur, Eastern Samar'];
      final savedLatitude = preferences.getDouble('activeLatitude');
      final savedLongitude = preferences.getDouble('activeLongitude');
      if (savedLatitude != null && savedLongitude != null) {
        _activeLocation = LatLng(savedLatitude, savedLongitude);
      }
      _activeLocationLabel =
          preferences.getString('activeLocationLabel') ??
          'General MacArthur, Eastern Samar';
      _emergencyContactName =
          preferences.getString('emergencyContactName') ?? '';
      _emergencyContactNumber =
          preferences.getString('emergencyContactNumber') ?? '';
      _preferencesLoaded = true;
    });
  }

  Future<void> _completeOnboarding() async {
    setState(() => _hasSeenOnboarding = true);
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool('hasSeenOnboarding', true);
  }

  Future<void> _setDarkMode(bool value) async {
    setState(() => _isDarkMode = value);
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool('darkMode', value);
  }

  Future<void> _setFontStyle(String value) async {
    setState(() => _fontStyle = value);
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString('fontStyle', value);
  }

  Future<void> _setBackgroundStyle(String value) async {
    setState(() => _backgroundStyle = value);
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString('backgroundStyle', value);
  }

  Future<void> _setCustomBackgroundColor(Color value) async {
    setState(() => _customBackgroundColor = value);
    final preferences = await SharedPreferences.getInstance();
    await preferences.setInt('customBackgroundColor', value.toARGB32());
  }

  Future<void> _setImperialUnits(bool value) async {
    setState(() => _isImperial = value);
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool('imperialUnits', value);
  }

  Future<void> _set24HourTime(bool value) async {
    setState(() => _use24HourTime = value);
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool('use24HourTime', value);
  }

  Future<void> _setNotificationsEnabled(bool value) async {
    setState(() => _notificationsEnabled = value);
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool('notificationsEnabled', value);
  }

  Future<void> _setAlertTypes(Set<String> value) async {
    setState(() => _enabledAlertTypes = value);
    final preferences = await SharedPreferences.getInstance();
    await preferences.setStringList('enabledAlertTypes', value.toList());
  }

  Future<void> _setSavedLocations(List<String> value) async {
    setState(() => _savedLocations = value);
    final preferences = await SharedPreferences.getInstance();
    await preferences.setStringList('savedLocations', value);
  }

  Future<void> _setActiveLocation(LatLng location, String label) async {
    setState(() {
      _activeLocation = location;
      _activeLocationLabel = label;
    });
    final preferences = await SharedPreferences.getInstance();
    await preferences.setDouble('activeLatitude', location.latitude);
    await preferences.setDouble('activeLongitude', location.longitude);
    await preferences.setString('activeLocationLabel', label);
  }

  Future<void> _setEmergencyContact(String name, String number) async {
    setState(() {
      _emergencyContactName = name;
      _emergencyContactNumber = number;
    });
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString('emergencyContactName', name);
    await preferences.setString('emergencyContactNumber', number);
  }

  @override
  Widget build(BuildContext context) {
    final lightColorScheme = ColorScheme.fromSeed(
      seedColor: _blue,
      brightness: Brightness.light,
    );
    final darkColorScheme = ColorScheme.fromSeed(
      seedColor: _blue,
      brightness: Brightness.dark,
    );
    return MaterialApp(
      title: 'Banog Weather App',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: _backgroundColorFor(
          _backgroundStyle,
          false,
          customColor: _customBackgroundColor,
        ),
        colorScheme: lightColorScheme,
        fontFamily: _fontFamilyFor(_fontStyle),
        extensions: [
          _BackgroundStyleTheme(
            style: _backgroundStyle,
            customColor: _customBackgroundColor,
          ),
        ],
        navigationBarTheme: const NavigationBarThemeData(
          backgroundColor: Colors.white,
          indicatorColor: Color(0xFFDCEBFA),
        ),
        snackBarTheme: const SnackBarThemeData(
          behavior: SnackBarBehavior.floating,
        ),
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: _backgroundColorFor(
          _backgroundStyle,
          true,
          customColor: _customBackgroundColor,
        ),
        colorScheme: darkColorScheme,
        fontFamily: _fontFamilyFor(_fontStyle),
        cardColor: _darkSurface,
        dividerColor: const Color(0xFF344451),
        extensions: [
          _BackgroundStyleTheme(
            style: _backgroundStyle,
            customColor: _customBackgroundColor,
          ),
        ],
        navigationBarTheme: const NavigationBarThemeData(
          backgroundColor: _darkSurface,
          indicatorColor: Color(0xFF344A5C),
        ),
        snackBarTheme: const SnackBarThemeData(
          behavior: SnackBarBehavior.floating,
        ),
      ),
      themeMode: _isDarkMode ? ThemeMode.dark : ThemeMode.light,
      builder: (context, child) {
        final content = child ?? const SizedBox.shrink();
        if (_backgroundStyle != 'Glass') return content;
        return _GlassBackdrop(isDarkMode: _isDarkMode, child: content);
      },
      home: !_preferencesLoaded
          ? const _StartupLoadingPage()
          : _hasSeenOnboarding
          ? WeatherShell(
              forecastClient: widget.forecastClient,
              alertClient: widget.alertClient,
              isDarkMode: _isDarkMode,
              onToggleDarkMode: () => _setDarkMode(!_isDarkMode),
              onDarkModeChanged: _setDarkMode,
              fontStyle: _fontStyle,
              backgroundStyle: _backgroundStyle,
              customBackgroundColor: _customBackgroundColor,
              onFontStyleChanged: _setFontStyle,
              onBackgroundStyleChanged: _setBackgroundStyle,
              onCustomBackgroundColorChanged: _setCustomBackgroundColor,
              isImperial: _isImperial,
              use24HourTime: _use24HourTime,
              notificationsEnabled: _notificationsEnabled,
              enabledAlertTypes: _enabledAlertTypes,
              savedLocations: _savedLocations,
              activeLocation: _activeLocation,
              activeLocationLabel: _activeLocationLabel,
              emergencyContactName: _emergencyContactName,
              emergencyContactNumber: _emergencyContactNumber,
              onImperialChanged: _setImperialUnits,
              on24HourTimeChanged: _set24HourTime,
              onNotificationsEnabledChanged: _setNotificationsEnabled,
              onAlertTypesChanged: _setAlertTypes,
              onSavedLocationsChanged: _setSavedLocations,
              onActiveLocationChanged: _setActiveLocation,
              onEmergencyContactChanged: _setEmergencyContact,
            )
          : _OnboardingPage(onCompleted: _completeOnboarding),
    );
  }
}

class _StartupLoadingPage extends StatelessWidget {
  const _StartupLoadingPage();

  @override
  Widget build(BuildContext context) => const Scaffold(
    body: Center(child: CircularProgressIndicator(color: _blue)),
  );
}

class _OnboardingPage extends StatefulWidget {
  const _OnboardingPage({required this.onCompleted});

  final VoidCallback onCompleted;

  @override
  State<_OnboardingPage> createState() => _OnboardingPageState();
}

class _OnboardingPageState extends State<_OnboardingPage> {
  static const _slides = [
    _OnboardingSlide(
      title: 'Meet your weather companion',
      description:
          'Banog brings a friendly, local weather outlook along for every day.',
      image: 'Mascot.jpg',
      imageFit: BoxFit.cover,
    ),
    _OnboardingSlide(
      title: 'Plan with confidence',
      description:
          'Check the forecast, rain, wind, and map layers before heading out.',
      image: 'logo.jpg',
      imageFit: BoxFit.contain,
    ),
    _OnboardingSlide(
      title: 'Stay ready for the skies',
      description:
          'See hourly conditions and weather alerts, all in one place.',
      image: 'Mascot.jpg',
      imageFit: BoxFit.cover,
    ),
  ];

  final _pageController = PageController();
  int _currentPage = 0;

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _nextPage() {
    if (_currentPage == _slides.length - 1) {
      widget.onCompleted();
      return;
    }
    _pageController.nextPage(
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = _isDarkMode(context);
    final surface = _surfaceColor(context);
    final ink = _primaryTextColor(context);
    final muted = _secondaryTextColor(context);

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(22, 8, 22, 20),
          child: Column(
            children: [
              SizedBox(
                height: 44,
                child: Row(
                  children: [
                    Image.asset(
                      'logo.jpg',
                      key: const ValueKey('onboarding-logo'),
                      width: 42,
                      height: 42,
                      fit: BoxFit.cover,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'Banog',
                      style: TextStyle(
                        color: isDark ? _darkInk : _navy,
                        fontSize: 17,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const Spacer(),
                    if (_currentPage < _slides.length - 1)
                      TextButton(
                        key: const ValueKey('onboarding-skip'),
                        onPressed: widget.onCompleted,
                        child: const Text(
                          'Skip',
                          style: TextStyle(
                            color: _blue,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      )
                    else
                      const SizedBox(width: 64),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: PageView.builder(
                  key: const ValueKey('onboarding-page-view'),
                  controller: _pageController,
                  itemCount: _slides.length,
                  onPageChanged: (page) => setState(() => _currentPage = page),
                  itemBuilder: (context, index) {
                    final slide = _slides[index];
                    return Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 2),
                      child: Column(
                        children: [
                          Expanded(
                            flex: 6,
                            child: Container(
                              width: double.infinity,
                              margin: const EdgeInsets.only(top: 6, bottom: 20),
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  begin: Alignment.topLeft,
                                  end: Alignment.bottomRight,
                                  colors: index == 1
                                      ? const [
                                          Color(0xFFDCEEFF),
                                          Color(0xFFF4FAFF),
                                        ]
                                      : const [
                                          Color(0xFFE7F5FF),
                                          Color(0xFFCBE7FC),
                                        ],
                                ),
                                borderRadius: BorderRadius.circular(30),
                              ),
                              clipBehavior: Clip.antiAlias,
                              child: Stack(
                                alignment: Alignment.center,
                                children: [
                                  Positioned(
                                    right: -15,
                                    top: -25,
                                    child: Icon(
                                      Icons.wb_sunny_rounded,
                                      size: 112,
                                      color: const Color(0xFFFFC943)
                                          .withValues(alpha: 0.62),
                                    ),
                                  ),
                                  Positioned(
                                    left: -20,
                                    bottom: -34,
                                    child: Icon(
                                      Icons.cloud_rounded,
                                      size: 160,
                                      color: Colors.white.withValues(
                                        alpha: 0.68,
                                      ),
                                    ),
                                  ),
                                  Padding(
                                    padding: const EdgeInsets.all(14),
                                    child: Image.asset(
                                      slide.image,
                                      key: ValueKey('onboarding-art-$index'),
                                      fit: slide.imageFit,
                                    ),
                                  ),
                                  if (index == 2)
                                    Positioned(
                                      right: 20,
                                      bottom: 20,
                                      child: Container(
                                        padding: const EdgeInsets.all(7),
                                        decoration: BoxDecoration(
                                          color: surface,
                                          borderRadius: BorderRadius.circular(
                                            14,
                                          ),
                                          boxShadow: [
                                            BoxShadow(
                                              color: _navy.withValues(
                                                alpha: 0.14,
                                              ),
                                              blurRadius: 16,
                                              offset: const Offset(0, 5),
                                            ),
                                          ],
                                        ),
                                        child: Image.asset(
                                          'logo.jpg',
                                          key: const ValueKey(
                                            'onboarding-final-logo',
                                          ),
                                          width: 50,
                                          height: 50,
                                          fit: BoxFit.cover,
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                          Expanded(
                            flex: 3,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                              ),
                              child: Column(
                                children: [
                                  Text(
                                    slide.title,
                                    key: ValueKey('onboarding-title-$index'),
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      color: ink,
                                      fontSize: 24,
                                      fontWeight: FontWeight.w900,
                                      height: 1.15,
                                      letterSpacing: -0.5,
                                    ),
                                  ),
                                  const SizedBox(height: 12),
                                  Text(
                                    slide.description,
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      color: muted,
                                      fontSize: 13,
                                      height: 1.5,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
              Row(
                children: [
                  Row(
                    children: List.generate(_slides.length, (index) {
                      final isActive = index == _currentPage;
                      return AnimatedContainer(
                        key: ValueKey('onboarding-indicator-$index'),
                        duration: const Duration(milliseconds: 200),
                        width: isActive ? 22 : 7,
                        height: 7,
                        margin: const EdgeInsets.only(right: 6),
                        decoration: BoxDecoration(
                          color: isActive
                              ? _blue
                              : muted.withValues(alpha: 0.35),
                          borderRadius: BorderRadius.circular(10),
                        ),
                      );
                    }),
                  ),
                  const Spacer(),
                  FilledButton(
                    key: const ValueKey('onboarding-next'),
                    onPressed: _nextPage,
                    style: FilledButton.styleFrom(
                      backgroundColor: _blue,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 23,
                        vertical: 13,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(15),
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          _currentPage == _slides.length - 1
                              ? 'Get started'
                              : 'Next',
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(width: 7),
                        const Icon(Icons.arrow_forward_rounded, size: 17),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _OnboardingSlide {
  const _OnboardingSlide({
    required this.title,
    required this.description,
    required this.image,
    required this.imageFit,
  });

  final String title;
  final String description;
  final String image;
  final BoxFit imageFit;
}

class WeatherShell extends StatefulWidget {
  const WeatherShell({
    super.key,
    this.forecastClient,
    this.alertClient,
    this.isDarkMode = false,
    this.onToggleDarkMode,
    this.onDarkModeChanged,
    this.fontStyle = 'Sans',
    this.backgroundStyle = 'Classic',
    this.customBackgroundColor = const Color(0xFFEDE9FE),
    this.onFontStyleChanged,
    this.onBackgroundStyleChanged,
    this.onCustomBackgroundColorChanged,
    this.isImperial = false,
    this.use24HourTime = false,
    this.notificationsEnabled = true,
    this.enabledAlertTypes = const {'Rain', 'Thunderstorm', 'Wind'},
    this.savedLocations = const ['General MacArthur, Eastern Samar'],
    this.activeLocation = _defaultMapLocation,
    this.activeLocationLabel = 'General MacArthur, Eastern Samar',
    this.emergencyContactName = '',
    this.emergencyContactNumber = '',
    this.onImperialChanged,
    this.on24HourTimeChanged,
    this.onNotificationsEnabledChanged,
    this.onAlertTypesChanged,
    this.onSavedLocationsChanged,
    this.onActiveLocationChanged,
    this.onEmergencyContactChanged,
  });

  final http.Client? forecastClient;
  final http.Client? alertClient;
  final bool isDarkMode;
  final VoidCallback? onToggleDarkMode;
  final ValueChanged<bool>? onDarkModeChanged;
  final String fontStyle;
  final String backgroundStyle;
  final Color customBackgroundColor;
  final ValueChanged<String>? onFontStyleChanged;
  final ValueChanged<String>? onBackgroundStyleChanged;
  final ValueChanged<Color>? onCustomBackgroundColorChanged;
  final bool isImperial;
  final bool use24HourTime;
  final bool notificationsEnabled;
  final Set<String> enabledAlertTypes;
  final List<String> savedLocations;
  final LatLng activeLocation;
  final String activeLocationLabel;
  final String emergencyContactName;
  final String emergencyContactNumber;
  final ValueChanged<bool>? onImperialChanged;
  final ValueChanged<bool>? on24HourTimeChanged;
  final ValueChanged<bool>? onNotificationsEnabledChanged;
  final ValueChanged<Set<String>>? onAlertTypesChanged;
  final ValueChanged<List<String>>? onSavedLocationsChanged;
  final void Function(LatLng location, String label)? onActiveLocationChanged;
  final void Function(String name, String number)? onEmergencyContactChanged;

  @override
  State<WeatherShell> createState() => _WeatherShellState();
}

class _WeatherShellState extends State<WeatherShell> {
  int _selectedPage = 0;
  bool _quickActionsOpen = false;
  bool _isMapImmersive = false;
  final _mapPageKey = GlobalKey<_MapPageState>();

  void _selectPage(int index) {
    setState(() {
      _selectedPage = index;
      _quickActionsOpen = false;
      if (index != 1) _isMapImmersive = false;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _mapPageKey.currentState?.setMapActive(index == 1);
    });
  }

  void _showQuickActions() {
    setState(() => _quickActionsOpen = !_quickActionsOpen);
  }

  void _openQuickAction(Widget page) {
    setState(() => _quickActionsOpen = false);
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));
  }

  Widget _quickActionButton({
    required String keyName,
    required String label,
    required Widget icon,
    required double left,
    required double bottom,
    required Widget page,
  }) {
    return AnimatedPositioned(
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutBack,
      left: left,
      bottom: _quickActionsOpen ? bottom : -12,
      width: 82,
      height: 88,
      child: IgnorePointer(
        ignoring: !_quickActionsOpen,
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 160),
          opacity: _quickActionsOpen ? 1 : 0,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.start,
            children: [
              FloatingActionButton.small(
                key: ValueKey(keyName),
                heroTag: keyName,
                tooltip: label,
                onPressed: () => _openQuickAction(page),
                backgroundColor: _surfaceColor(context),
                foregroundColor: _blue,
                elevation: 5,
                child: icon,
              ),
              const SizedBox(height: 4),
              Text(
                label,
                maxLines: 2,
                textAlign: TextAlign.center,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 9,
                  height: 1.1,
                  fontWeight: FontWeight.w700,
                  shadows: [Shadow(color: Colors.black54, blurRadius: 4)],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _navigationItem({
    required int index,
    required IconData icon,
    required IconData selectedIcon,
    required String label,
  }) {
    final selected = _selectedPage == index;
    final color = selected
        ? _blue
        : _isDarkMode(context)
        ? const Color(0xFFB5C4D0)
        : _muted;

    return Expanded(
      child: Semantics(
        button: true,
        selected: selected,
        label: label,
        child: InkWell(
          key: ValueKey('bottom-nav-$label'.toLowerCase()),
          onTap: () => _selectPage(index),
          borderRadius: BorderRadius.circular(14),
          child: SizedBox(
            height: 68,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(selected ? selectedIcon : icon, color: color, size: 22),
                const SizedBox(height: 3),
                Text(
                  label,
                  style: TextStyle(
                    color: color,
                    fontSize: 10,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _openSettingsSheet() {
    var isDarkMode = widget.isDarkMode;
    var isImperial = widget.isImperial;
    var use24HourTime = widget.use24HourTime;
    var notificationsEnabled = widget.notificationsEnabled;
    var enabledAlertTypes = {...widget.enabledAlertTypes};
    var savedLocations = [...widget.savedLocations];
    var emergencyContactName = widget.emergencyContactName;
    var emergencyContactNumber = widget.emergencyContactNumber;
    var fontStyle = widget.fontStyle;
    var backgroundStyle = widget.backgroundStyle;
    var customBackgroundColor = widget.customBackgroundColor;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      backgroundColor: _surfaceColor(context),
      shape: RoundedRectangleBorder(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(26)),
        side: _isGlassBackground(context)
            ? BorderSide(
                color: _isDarkMode(context)
                    ? Colors.white.withValues(alpha: 0.16)
                    : Colors.white.withValues(alpha: 0.82),
                width: 1.2,
              )
            : BorderSide.none,
      ),
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setSheetState) => SizedBox(
          height: MediaQuery.sizeOf(sheetContext).height * 0.9,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 2, 10, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Settings',
                        style: TextStyle(
                          color: _primaryTextColor(sheetContext),
                          fontSize: 21,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    IconButton(
                      key: const ValueKey('settings-sheet-close'),
                      tooltip: 'Close settings',
                      onPressed: () => Navigator.of(sheetContext).pop(),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: SettingsPage(
                  showHeader: false,
                  isDarkMode: isDarkMode,
                  isImperial: isImperial,
                  use24HourTime: use24HourTime,
                  notificationsEnabled: notificationsEnabled,
                  enabledAlertTypes: enabledAlertTypes,
                  savedLocations: savedLocations,
                  activeLocationLabel: widget.activeLocationLabel,
                  onActiveLocationChanged: widget.onActiveLocationChanged,
                  emergencyContactName: emergencyContactName,
                  emergencyContactNumber: emergencyContactNumber,
                  onDarkModeChanged: (value) {
                    isDarkMode = value;
                    widget.onDarkModeChanged?.call(value);
                    setSheetState(() {});
                  },
                  fontStyle: fontStyle,
                  backgroundStyle: backgroundStyle,
                  customBackgroundColor: customBackgroundColor,
                  onFontStyleChanged: (value) {
                    fontStyle = value;
                    widget.onFontStyleChanged?.call(value);
                    setSheetState(() {});
                  },
                  onBackgroundStyleChanged: (value) {
                    backgroundStyle = value;
                    widget.onBackgroundStyleChanged?.call(value);
                    setSheetState(() {});
                  },
                  onCustomBackgroundColorChanged: (value) {
                    customBackgroundColor = value;
                    widget.onCustomBackgroundColorChanged?.call(value);
                    setSheetState(() {});
                  },
                  onImperialChanged: (value) {
                    isImperial = value;
                    widget.onImperialChanged?.call(value);
                    setSheetState(() {});
                  },
                  on24HourTimeChanged: (value) {
                    use24HourTime = value;
                    widget.on24HourTimeChanged?.call(value);
                    setSheetState(() {});
                  },
                  onNotificationsEnabledChanged: (value) {
                    notificationsEnabled = value;
                    widget.onNotificationsEnabledChanged?.call(value);
                    setSheetState(() {});
                  },
                  onAlertTypesChanged: (value) {
                    enabledAlertTypes = value;
                    widget.onAlertTypesChanged?.call(value);
                    setSheetState(() {});
                  },
                  onSavedLocationsChanged: (value) {
                    savedLocations = value;
                    widget.onSavedLocationsChanged?.call(value);
                    setSheetState(() {});
                  },
                  onEmergencyContactChanged: (name, number) {
                    emergencyContactName = name;
                    emergencyContactNumber = number;
                    widget.onEmergencyContactChanged?.call(name, number);
                    setSheetState(() {});
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          IndexedStack(
            index: _selectedPage,
            children: [
              SafeArea(
                bottom: false,
                child: HomePage(
                  forecastClient: widget.forecastClient,
                  alertClient: widget.alertClient,
                  isDarkMode: widget.isDarkMode,
                  onToggleDarkMode: widget.onToggleDarkMode,
                  onOpenSettings: _openSettingsSheet,
                  isImperial: widget.isImperial,
                  use24HourTime: widget.use24HourTime,
                  notificationsEnabled: widget.notificationsEnabled,
                  enabledAlertTypes: widget.enabledAlertTypes,
                  activeLocation: widget.activeLocation,
                  activeLocationLabel: widget.activeLocationLabel,
                  onActiveLocationChanged: widget.onActiveLocationChanged,
                ),
              ),
              MapPage(
                key: _mapPageKey,
                isImperial: widget.isImperial,
                client: widget.alertClient,
                isImmersive: _isMapImmersive,
                onImmersiveChanged: (value) {
                  setState(() {
                    _isMapImmersive = value;
                    if (value) _quickActionsOpen = false;
                  });
                },
                activeLocation: widget.activeLocation,
                onActiveLocationChanged: widget.onActiveLocationChanged,
              ),
              SafeArea(
                bottom: false,
                child: StormsPage(
                  client: widget.alertClient,
                  isImperial: widget.isImperial,
                  activeLocation: widget.activeLocation,
                  activeLocationLabel: widget.activeLocationLabel,
                  emergencyContactName: widget.emergencyContactName,
                  emergencyContactNumber: widget.emergencyContactNumber,
                ),
              ),
              SafeArea(
                bottom: false,
                child: AlertsPage(
                  client: widget.alertClient,
                  enabledAlertTypes: widget.enabledAlertTypes,
                  isImperial: widget.isImperial,
                  use24HourTime: widget.use24HourTime,
                  notificationsEnabled: widget.notificationsEnabled,
                  location: widget.activeLocation,
                  locationLabel: widget.activeLocationLabel,
                  emergencyContactName: widget.emergencyContactName,
                  emergencyContactNumber: widget.emergencyContactNumber,
                  onActiveLocationChanged: widget.onActiveLocationChanged,
                ),
              ),
            ],
          ),
          if (_quickActionsOpen)
            Positioned.fill(
              child: GestureDetector(
                key: const ValueKey('quick-actions-dismiss'),
                behavior: HitTestBehavior.opaque,
                onTap: () => setState(() => _quickActionsOpen = false),
                child: ColoredBox(color: Colors.black.withValues(alpha: 0.48)),
              ),
            ),
          Positioned.fill(
            child: IgnorePointer(
              ignoring: !_quickActionsOpen,
              child: LayoutBuilder(
                builder: (context, constraints) => Stack(
                  clipBehavior: Clip.none,
                  children: [
                    if (_quickActionsOpen)
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 166,
                        child: Text(
                          'Quick actions',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.w800,
                            shadows: [
                              Shadow(color: Colors.black54, blurRadius: 5),
                            ],
                          ),
                        ),
                      ),
                    _quickActionButton(
                      keyName: 'quick-action-ebakwet',
                      label: 'Ebakwet Chat AI',
                      icon: ClipOval(
                        child: Image.asset(
                          'ebakwet.jpg',
                          key: const ValueKey('quick-action-ebakwet-image'),
                          width: 38,
                          height: 38,
                          fit: BoxFit.cover,
                        ),
                      ),
                      left: constraints.maxWidth * 0.01,
                      bottom: 14,
                      page: const _EbakwetChatPage(),
                    ),
                    _quickActionButton(
                      keyName: 'quick-action-emergency',
                      label: 'Emergency Help',
                      icon: const Icon(Icons.emergency_rounded),
                      left: constraints.maxWidth * 0.25,
                      bottom: 72,
                      page: _EmergencyHelpPage(
                        contactName: widget.emergencyContactName,
                        contactNumber: widget.emergencyContactNumber,
                        locationLabel: widget.activeLocationLabel,
                      ),
                    ),
                    _quickActionButton(
                      keyName: 'quick-action-safetrack',
                      label: 'SafeTrack',
                      icon: const Icon(Icons.near_me_rounded),
                      left: constraints.maxWidth * 0.41,
                      bottom: 112,
                      page: _SafeTrackPage(
                        client: widget.alertClient,
                        initialLocation: widget.activeLocation,
                      ),
                    ),
                    _quickActionButton(
                      keyName: 'quick-action-evacuation',
                      label: 'Evacuation Guide',
                      icon: const Icon(Icons.route_rounded),
                      left: constraints.maxWidth * 0.60,
                      bottom: 72,
                      page: const _EvacuationGuidePage(),
                    ),
                    _quickActionButton(
                      keyName: 'quick-action-checklist',
                      label: 'Safety Checklist',
                      icon: const Icon(Icons.checklist_rounded),
                      left: constraints.maxWidth * 0.79,
                      bottom: 14,
                      page: const _SafetyChecklistPage(),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerDocked,
      floatingActionButton: _isMapImmersive
          ? null
          : FloatingActionButton(
              key: const ValueKey('bottom-nav-add'),
              tooltip: 'Quick actions',
              onPressed: _showQuickActions,
              backgroundColor: _blue,
              foregroundColor: Colors.white,
              elevation: 3,
              shape: const CircleBorder(),
              child: AnimatedRotation(
                turns: _quickActionsOpen ? 0.125 : 0,
                duration: const Duration(milliseconds: 220),
                child: const Icon(Icons.add_rounded, size: 30),
              ),
            ),
      bottomNavigationBar: _isMapImmersive
          ? null
          : BottomAppBar(
              shape: const CircularNotchedRectangle(),
              notchMargin: 8,
              color: _surfaceColor(context),
              elevation: 10,
              padding: EdgeInsets.zero,
              child: SizedBox(
                height: 68,
                child: Row(
                  children: [
                    _navigationItem(
                      index: 0,
                      icon: Icons.home_outlined,
                      selectedIcon: Icons.home_rounded,
                      label: 'Home',
                    ),
                    _navigationItem(
                      index: 1,
                      icon: Icons.public_outlined,
                      selectedIcon: Icons.public_rounded,
                      label: 'Map',
                    ),
                    const SizedBox(width: 72),
                    _navigationItem(
                      index: 2,
                      icon: Icons.cyclone_outlined,
                      selectedIcon: Icons.cyclone_rounded,
                      label: 'Storms',
                    ),
                    _navigationItem(
                      index: 3,
                      icon: Icons.notifications_none_rounded,
                      selectedIcon: Icons.notifications_active_rounded,
                      label: 'Alerts',
                    ),
                  ],
                ),
              ),
            ),
    );
  }
}

class _EbakwetChatPage extends StatefulWidget {
  const _EbakwetChatPage();

  @override
  State<_EbakwetChatPage> createState() => _EbakwetChatPageState();
}

class _EbakwetChatPageState extends State<_EbakwetChatPage> {
  final _scrollController = ScrollController();
  final _messages = <({String text, bool fromUser})>[
    (
      text:
          'Hi, I’m Ebakwet. Choose a topic and I’ll share practical '
          'preparedness guidance.',
      fromUser: false,
    ),
  ];

  static const _topics = <String, String>{
    'How do I prepare for a typhoon?':
        'Charge phones and power banks, prepare drinking water and food, '
        'secure loose outdoor items, and monitor PAGASA and local government '
        'updates. Evacuate early if authorities advise it.',
    'What should I bring when evacuating?':
        'Bring water, ready-to-eat food, medicines, IDs and important '
        'documents in a waterproof bag, a flashlight, a radio, a power bank, '
        'clothes, and essential items for children or older adults.',
    'How can I stay safe during floods?':
        'Move to higher ground when directed. Never walk or drive through '
        'floodwater, and stay away from downed wires. Follow evacuation '
        'instructions from local authorities.',
    'What should be in an emergency kit?':
        'Pack water, food, first-aid supplies, regular medicines, flashlight, '
        'radio, batteries, power bank, hygiene items, cash, and copies of '
        'important documents.',
  };

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _ask(String question) {
    setState(() {
      _messages
        ..add((text: question, fromUser: true))
        ..add((text: _topics[question]!, fromUser: false));
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            _PageHeader(
              title: 'Ebakwet Chat AI',
              subtitle: 'Preparedness and weather safety',
              leading: IconButton(
                key: const ValueKey('quick-action-back'),
                tooltip: 'Back',
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.arrow_back_rounded),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: _isDarkMode(context)
                      ? const Color(0xFF2C3945)
                      : const Color(0xFFEAF4FD),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Text(
                  'Guided answers are available now. An AI model is not '
                  'connected yet; for urgent danger, call 911.',
                  style: TextStyle(
                    color: _primaryTextColor(context),
                    fontSize: 11,
                    height: 1.4,
                  ),
                ),
              ),
            ),
            Expanded(
              child: ListView.builder(
                controller: _scrollController,
                padding: const EdgeInsets.symmetric(horizontal: 18),
                itemCount: _messages.length,
                itemBuilder: (context, index) {
                  final message = _messages[index];
                  return Align(
                    alignment: message.fromUser
                        ? Alignment.centerRight
                        : Alignment.centerLeft,
                    child: message.fromUser
                        ? _chatMessageBubble(context, message.text, true)
                        : Row(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              ClipOval(
                                child: Image.asset(
                                  'ebakwet.jpg',
                                  key: const ValueKey('ebakwet-chat-avatar'),
                                  width: 34,
                                  height: 34,
                                  fit: BoxFit.cover,
                                  semanticLabel: 'Ebakwet',
                                ),
                              ),
                              const SizedBox(width: 8),
                              Flexible(
                                child: _chatMessageBubble(
                                  context,
                                  message.text,
                                  false,
                                ),
                              ),
                            ],
                          ),
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  for (final question in _topics.keys)
                    ActionChip(
                      label: Text(question),
                      onPressed: () => _ask(question),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _chatMessageBubble(BuildContext context, String text, bool fromUser) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 270),
      margin: const EdgeInsets.only(bottom: 9),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: fromUser ? _blue : _surfaceColor(context),
        borderRadius: BorderRadius.circular(16),
        border: fromUser ? null : Border.all(color: const Color(0xFFE4EDF5)),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: fromUser ? Colors.white : _primaryTextColor(context),
          fontSize: 12,
          height: 1.4,
        ),
      ),
    );
  }
}

class _SafeTrackPage extends StatefulWidget {
  const _SafeTrackPage({this.client, required this.initialLocation});

  final http.Client? client;
  final LatLng initialLocation;

  @override
  State<_SafeTrackPage> createState() => _SafeTrackPageState();
}

class _SafeTrackPageState extends State<_SafeTrackPage> {
  late final http.Client _client = widget.client ?? http.Client();
  final _mapController = MapController();
  final _sheetController = DraggableScrollableController();
  LatLng? _userLocation;
  List<EvacuationPoint> _destinations = [];
  EvacuationPoint? _selectedDestination;
  EvacuationPointPhoto? _destinationPhoto;
  SafeTrackRoute? _route;
  String? _locationError;
  String? _destinationError;
  String? _routeError;
  String? _destinationPhotoMessage;
  bool _isLoadingLocation = true;
  bool _isLoadingDestinations = false;
  bool _isLoadingRoute = false;
  bool _isLoadingDestinationPhoto = false;
  int _requestGeneration = 0;

  @override
  void initState() {
    super.initState();
    _loadLocationAndDestinations();
  }

  @override
  void dispose() {
    _requestGeneration++;
    _sheetController.dispose();
    _mapController.dispose();
    if (widget.client == null) _client.close();
    super.dispose();
  }

  Future<void> _loadLocationAndDestinations() async {
    final generation = ++_requestGeneration;
    setState(() {
      _isLoadingLocation = true;
      _isLoadingDestinations = false;
      _locationError = null;
      _destinationError = null;
      _routeError = null;
      _route = null;
    });
    final locationResult = await DeviceLocationService.getCurrentPosition();
    if (!mounted || generation != _requestGeneration) return;
    final location = locationResult.position;
    if (location == null) {
      setState(() {
        _isLoadingLocation = false;
        _locationError =
            locationResult.error ?? 'Your current location is unavailable.';
      });
      return;
    }

    setState(() {
      _userLocation = location;
      _isLoadingLocation = false;
      _isLoadingDestinations = true;
    });
    _mapController.move(location, 12);
    try {
      final destinations = await SafeTrackService.findNearbyEvacuationPoints(
        _client,
        center: location,
      );
      if (!mounted || generation != _requestGeneration) return;
      setState(() {
        _destinations = destinations.take(30).toList();
        _selectedDestination = _destinations.isEmpty ? null : _destinations[0];
        _isLoadingDestinations = false;
        _destinationError = _destinations.isEmpty
            ? 'No nearby community-mapped evacuation points were found.'
            : null;
      });
      if (_selectedDestination != null) {
        await _loadRoute(_selectedDestination!, generation: generation);
      }
    } on http.ClientException {
      if (!mounted || generation != _requestGeneration) return;
      setState(() {
        _isLoadingDestinations = false;
        _destinationError =
            'Could not load mapped evacuation points. Check your connection.';
      });
    } on FormatException {
      if (!mounted || generation != _requestGeneration) return;
      setState(() {
        _isLoadingDestinations = false;
        _destinationError = 'Evacuation point data could not be read.';
      });
    } on TimeoutException {
      if (!mounted || generation != _requestGeneration) return;
      setState(() {
        _isLoadingDestinations = false;
        _destinationError = 'Loading evacuation points timed out.';
      });
    }
  }

  Future<void> _loadRoute(
    EvacuationPoint destination, {
    int? generation,
  }) async {
    final location = _userLocation;
    if (location == null) return;
    final requestGeneration = generation ?? _requestGeneration;
    setState(() {
      _selectedDestination = destination;
      _isLoadingRoute = true;
      _route = null;
      _routeError = null;
      _destinationPhoto = null;
      _destinationPhotoMessage = null;
      _isLoadingDestinationPhoto = true;
    });
    unawaited(_loadDestinationPhoto(destination, requestGeneration));
    try {
      final route = await SafeTrackService.getDrivingRoute(
        _client,
        origin: location,
        destination: destination.location,
      );
      if (!mounted ||
          requestGeneration != _requestGeneration ||
          _selectedDestination?.id != destination.id) {
        return;
      }
      setState(() {
        _route = route;
        _isLoadingRoute = false;
      });
      if (route.points.isNotEmpty) {
        _mapController.fitCamera(
          CameraFit.bounds(
            bounds: LatLngBounds.fromPoints(route.points),
            padding: const EdgeInsets.fromLTRB(48, 150, 48, 310),
            maxZoom: 15,
          ),
        );
      }
    } on http.ClientException {
      if (!mounted ||
          requestGeneration != _requestGeneration ||
          _selectedDestination?.id != destination.id) {
        return;
      }
      setState(() {
        _isLoadingRoute = false;
        _routeError = 'Could not load the road route. Please try again.';
      });
    } on FormatException {
      if (!mounted ||
          requestGeneration != _requestGeneration ||
          _selectedDestination?.id != destination.id) {
        return;
      }
      setState(() {
        _isLoadingRoute = false;
        _routeError = 'No road route is available for this destination.';
      });
    } on TimeoutException {
      if (!mounted ||
          requestGeneration != _requestGeneration ||
          _selectedDestination?.id != destination.id) {
        return;
      }
      setState(() {
        _isLoadingRoute = false;
        _routeError = 'Route request timed out. Please try again.';
      });
    }
  }

  Future<void> _loadDestinationPhoto(
    EvacuationPoint destination,
    int requestGeneration,
  ) async {
    try {
      final photo = await SafeTrackService.findEvacuationPointPhoto(
        _client,
        destinationName: destination.name,
        location: destination.location,
      );
      if (!mounted ||
          requestGeneration != _requestGeneration ||
          _selectedDestination?.id != destination.id) {
        return;
      }
      setState(() {
        _destinationPhoto = photo;
        _destinationPhotoMessage = photo == null ? 'No site photo found' : null;
        _isLoadingDestinationPhoto = false;
      });
    } on http.ClientException {
      _setDestinationPhotoUnavailable(destination, requestGeneration);
    } on FormatException {
      _setDestinationPhotoUnavailable(destination, requestGeneration);
    } on TimeoutException {
      _setDestinationPhotoUnavailable(destination, requestGeneration);
    }
  }

  void _setDestinationPhotoUnavailable(
    EvacuationPoint destination,
    int requestGeneration,
  ) {
    if (!mounted ||
        requestGeneration != _requestGeneration ||
        _selectedDestination?.id != destination.id) {
      return;
    }
    setState(() {
      _destinationPhoto = null;
      _destinationPhotoMessage = 'Site photo is unavailable';
      _isLoadingDestinationPhoto = false;
    });
  }

  Future<void> _searchEvacuationPoints() async {
    final destination = await showDialog<EvacuationPoint>(
      context: context,
      builder: (_) => _EvacuationPointSearchDialog(
        client: _client,
        destinations: _destinations,
        origin: _userLocation,
      ),
    );
    if (!mounted || destination == null) return;
    await _loadRoute(destination);
  }

  String _durationLabel(double seconds) {
    final minutes = (seconds / 60).round();
    if (minutes < 60) return '$minutes min';
    final hours = minutes ~/ 60;
    final remainingMinutes = minutes % 60;
    return remainingMinutes == 0
        ? '${hours}h'
        : '${hours}h ${remainingMinutes}m';
  }

  @override
  Widget build(BuildContext context) {
    final center = _userLocation ?? widget.initialLocation;
    final selected = _selectedDestination;
    final route = _route;
    final distanceKm = route == null ? null : route.distanceMeters / 1000;
    final walkingTime = distanceKm == null
        ? null
        : _durationLabel(distanceKm / 4.5 * 3600);

    return Scaffold(
      body: Stack(
        children: [
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: center,
              initialZoom: 12,
              minZoom: 5,
              maxZoom: 19,
              onLongPress: (_, point) {
                final manualDestination = EvacuationPoint(
                  id: 'manual-destination',
                  name: 'Selected map destination',
                  location: point,
                );
                setState(() {
                  _selectedDestination = manualDestination;
                  _destinations = [
                    manualDestination,
                    ..._destinations.where(
                      (destination) => destination.id != manualDestination.id,
                    ),
                  ];
                  _destinationError = null;
                });
                if (_userLocation != null) {
                  _loadRoute(manualDestination);
                }
              },
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.example.banog',
              ),
              if (route != null)
                PolylineLayer(
                  polylines: [
                    Polyline(
                      points: route.points,
                      strokeWidth: 6,
                      color: _blue,
                    ),
                  ],
                ),
              MarkerLayer(
                markers: [
                  if (_userLocation != null)
                    Marker(
                      point: _userLocation!,
                      width: 52,
                      height: 58,
                      child: Column(
                        children: [
                          Container(
                            width: 38,
                            height: 38,
                            padding: const EdgeInsets.all(3),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              shape: BoxShape.circle,
                              border: Border.all(color: _blue, width: 2),
                              boxShadow: const [
                                BoxShadow(color: Colors.black26, blurRadius: 5),
                              ],
                            ),
                            child: ClipOval(
                              child: Image.asset('logo.jpg', fit: BoxFit.cover),
                            ),
                          ),
                          const Icon(
                            Icons.arrow_drop_down_rounded,
                            color: _blue,
                            size: 18,
                          ),
                        ],
                      ),
                    ),
                  for (final destination in _destinations)
                    Marker(
                      point: destination.location,
                      width: 46,
                      height: 46,
                      alignment: Alignment.topCenter,
                      child: GestureDetector(
                        key: ValueKey(
                          'safetrack-destination-${destination.id}',
                        ),
                        onTap: () => _loadRoute(destination),
                        child: destination.id == selected?.id
                            ? const _SelectedEvacuationMapMarker()
                            : const Icon(
                                Icons.location_on_rounded,
                                color: _navy,
                                size: 42,
                                shadows: [
                                  Shadow(color: Colors.white, blurRadius: 5),
                                ],
                              ),
                      ),
                    ),
                ],
              ),
            ],
          ),
          SafeArea(
            child: Align(
              alignment: Alignment.topCenter,
              child: _PageHeader(
                title: 'SafeTrack',
                subtitle: 'Route to a nearby mapped evacuation point',
                leading: IconButton(
                  key: const ValueKey('safetrack-back'),
                  tooltip: 'Back',
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.arrow_back_rounded),
                ),
              ),
            ),
          ),
          Positioned(
            right: 8,
            top: MediaQuery.paddingOf(context).top + 82,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.9),
                borderRadius: BorderRadius.circular(5),
              ),
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                child: Text(
                  '© OpenStreetMap contributors',
                  style: TextStyle(fontSize: 9, color: _ink),
                ),
              ),
            ),
          ),
          DraggableScrollableSheet(
            key: const ValueKey('safetrack-draggable-sheet'),
            controller: _sheetController,
            initialChildSize: 0.42,
            minChildSize: 0.11,
            maxChildSize: 0.62,
            snap: true,
            snapSizes: const [0.11, 0.42, 0.62],
            builder: (context, scrollController) => _safeTrackRouteCard(
              context,
              scrollController: scrollController,
              selected: selected,
              route: route,
              distanceKm: distanceKm,
              walkingTime: walkingTime,
            ),
          ),
        ],
      ),
    );
  }

  Widget _safeTrackRouteCard(
    BuildContext context, {
    required ScrollController scrollController,
    required EvacuationPoint? selected,
    required SafeTrackRoute? route,
    required double? distanceKm,
    required String? walkingTime,
  }) {
    final error = _locationError ?? _destinationError ?? _routeError;
    return Container(
      key: const ValueKey('safetrack-sheet-panel'),
      width: double.infinity,
      decoration: BoxDecoration(
        color: _surfaceColor(context),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
        boxShadow: const [
          BoxShadow(
            color: Colors.black26,
            blurRadius: 14,
            offset: Offset(0, -3),
          ),
        ],
      ),
      child: ListView(
        controller: scrollController,
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 18),
        children: [
          Center(
            child: SizedBox(
              key: const ValueKey('safetrack-sheet-handle'),
              width: 52,
              height: 24,
              child: Center(
                child: Container(
                  width: 38,
                  height: 4,
                  decoration: BoxDecoration(
                    color: _secondaryTextColor(context).withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ),
            ),
          ),
          Container(
            key: const ValueKey('safetrack-destination-image'),
            width: double.infinity,
            height: 150,
            decoration: BoxDecoration(
              color: _blue.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(12),
            ),
            clipBehavior: Clip.antiAlias,
            child: _destinationPhoto == null
                ? Center(
                    child: _isLoadingDestinationPhoto
                        ? const SizedBox(
                            width: 26,
                            height: 26,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Icon(
                            Icons.location_city_rounded,
                            color: _blue,
                            size: 38,
                          ),
                  )
                : Image.network(
                    _destinationPhoto!.imageUrl.toString(),
                    fit: BoxFit.contain,
                    errorBuilder: (context, error, stackTrace) => Center(
                      child: Icon(
                        Icons.location_city_rounded,
                        color: _blue,
                        size: 38,
                      ),
                    ),
                  ),
          ),
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      selected?.name ?? 'Find an evacuation point',
                      key: const ValueKey('safetrack-selected-destination'),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: _primaryTextColor(context),
                        fontSize: 14,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      selected == null
                          ? 'Choose a point on the map or search nearby'
                          : 'Community-mapped evacuation point',
                      key: const ValueKey('safetrack-destination-source'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: _secondaryTextColor(context),
                        fontSize: 10,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (_destinationPhoto != null)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                key: const ValueKey('safetrack-photo-credit'),
                onPressed: () => launchUrl(
                  _destinationPhoto!.sourceUrl,
                  mode: LaunchMode.externalApplication,
                ),
                style: TextButton.styleFrom(
                  minimumSize: Size.zero,
                  padding: const EdgeInsets.only(top: 2, bottom: 0),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: Text(
                  'Photo: ${_destinationPhoto!.title} · '
                  '${_destinationPhoto!.attribution}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: _secondaryTextColor(context),
                    fontSize: 9,
                  ),
                ),
              ),
            )
          else if (_destinationPhotoMessage != null)
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Text(
                _destinationPhotoMessage!,
                style: TextStyle(
                  color: _secondaryTextColor(context),
                  fontSize: 9,
                ),
              ),
            ),
          Row(
            children: [
              const Spacer(),
              IconButton(
                key: const ValueKey('safetrack-search'),
                tooltip: 'Search evacuation points',
                onPressed: _isLoadingRoute ? null : _searchEvacuationPoints,
                icon: const Icon(Icons.search_rounded, color: _blue),
              ),
              IconButton(
                key: const ValueKey('safetrack-sheet-toggle'),
                tooltip:
                    _sheetController.isAttached && _sheetController.size > 0.2
                    ? 'Hide route details'
                    : 'Show route details',
                onPressed: !_sheetController.isAttached
                    ? null
                    : () => _sheetController.animateTo(
                        _sheetController.size > 0.2 ? 0.11 : 0.42,
                        duration: const Duration(milliseconds: 220),
                        curve: Curves.easeOut,
                      ),
                icon: Icon(
                  _sheetController.isAttached && _sheetController.size > 0.2
                      ? Icons.keyboard_arrow_down_rounded
                      : Icons.keyboard_arrow_up_rounded,
                  color: _blue,
                ),
              ),
            ],
          ),
          if (_isLoadingLocation)
            const LinearProgressIndicator()
          else if (_isLoadingDestinations || _isLoadingRoute)
            const LinearProgressIndicator(),
          if (_isLoadingLocation)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text('Getting your current GPS location...'),
            )
          else if (error != null) ...[
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                error,
                style: const TextStyle(color: Color(0xFFB34343), fontSize: 12),
              ),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                key: const ValueKey('safetrack-retry'),
                onPressed: _loadLocationAndDestinations,
                icon: const Icon(Icons.refresh_rounded, size: 17),
                label: const Text('Retry'),
              ),
            ),
          ] else if (route != null && selected != null) ...[
            Row(
              children: [
                Expanded(
                  child: _SafeTrackMetric(
                    icon: Icons.route_rounded,
                    label: 'Route distance',
                    value: '${distanceKm!.toStringAsFixed(1)} km',
                  ),
                ),
                Expanded(
                  child: _SafeTrackMetric(
                    icon: Icons.directions_car_rounded,
                    label: 'Drive estimate',
                    value: _durationLabel(route.drivingSeconds),
                  ),
                ),
                Expanded(
                  child: _SafeTrackMetric(
                    icon: Icons.directions_walk_rounded,
                    label: 'Walk estimate',
                    value: walkingTime!,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Drive estimate excludes live traffic. Walking time is a rough '
              'estimate using road-route distance, not a pedestrian-safe '
              'route. Destinations are community-mapped, not officially '
              'verified. Follow local authorities and do not enter '
              'floodwater.',
              style: TextStyle(
                color: _secondaryTextColor(context),
                fontSize: 9,
                height: 1.35,
              ),
            ),
          ] else if (!_isLoadingDestinations)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'No route is available yet. Check location and network access.',
                style: TextStyle(
                  color: _secondaryTextColor(context),
                  fontSize: 11,
                ),
              ),
            ),
          if (_destinations.isEmpty &&
              !_isLoadingLocation &&
              !_isLoadingDestinations) ...[
            const SizedBox(height: 4),
            Text(
              'Long-press the map to select a destination.',
              style: TextStyle(
                color: _secondaryTextColor(context),
                fontSize: 10,
              ),
            ),
          ],
          const SizedBox(height: 4),
          Text(
            'Evacuation points and routing © OpenStreetMap contributors.',
            style: TextStyle(color: _secondaryTextColor(context), fontSize: 9),
          ),
        ],
      ),
    );
  }
}

class _SelectedEvacuationMapMarker extends StatelessWidget {
  const _SelectedEvacuationMapMarker();

  @override
  Widget build(BuildContext context) {
    return const Icon(
      Icons.location_on_rounded,
      color: Color(0xFFB34343),
      size: 42,
      shadows: [Shadow(color: Colors.white, blurRadius: 4)],
    );
  }
}

class _EvacuationPointSearchDialog extends StatefulWidget {
  const _EvacuationPointSearchDialog({
    required this.client,
    required this.destinations,
    required this.origin,
  });

  final http.Client client;
  final List<EvacuationPoint> destinations;
  final LatLng? origin;

  @override
  State<_EvacuationPointSearchDialog> createState() =>
      _EvacuationPointSearchDialogState();
}

class _EvacuationPointSearchDialogState
    extends State<_EvacuationPointSearchDialog> {
  final _searchController = TextEditingController();
  String _query = '';
  List<EvacuationPoint> _remoteResults = [];
  String? _searchError;
  bool _isSearching = false;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _searchOnline() async {
    final query = _query.trim();
    if (query.isEmpty) return;
    final origin = widget.origin;
    if (origin == null) {
      setState(() {
        _searchError = 'Get your current location before searching nearby.';
      });
      return;
    }

    setState(() {
      _isSearching = true;
      _searchError = null;
      _remoteResults = [];
    });
    try {
      final results = await SafeTrackService.searchNearbyEvacuationPoints(
        widget.client,
        center: origin,
        query: query,
      );
      if (!mounted || query != _query.trim()) return;
      setState(() {
        _remoteResults = results;
        _isSearching = false;
        _searchError = results.isEmpty
            ? 'No mapped evacuation point matched "$query" nearby.'
            : null;
      });
    } on http.ClientException {
      if (!mounted || query != _query.trim()) return;
      setState(() {
        _isSearching = false;
        _searchError =
            'Search could not connect. Check your internet and retry.';
      });
    } on FormatException {
      if (!mounted || query != _query.trim()) return;
      setState(() {
        _isSearching = false;
        _searchError = 'Search results could not be read.';
      });
    } on TimeoutException {
      if (!mounted || query != _query.trim()) return;
      setState(() {
        _isSearching = false;
        _searchError = 'Search timed out. Please try again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final localResults = SafeTrackService.searchEvacuationPoints(
      widget.destinations,
      query: _query,
      origin: widget.origin,
    );
    final results = localResults.isNotEmpty ? localResults : _remoteResults;

    return AlertDialog(
      key: const ValueKey('safetrack-search-dialog'),
      title: const Text('Search evacuation points'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              key: const ValueKey('safetrack-search-field'),
              controller: _searchController,
              autofocus: true,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _searchOnline(),
              onChanged: (value) => setState(() {
                _query = value;
                _remoteResults = [];
                _searchError = null;
              }),
              decoration: InputDecoration(
                hintText: 'Search by area or center name',
                prefixIcon: const Icon(Icons.search_rounded),
                suffixIcon: _query.isEmpty
                    ? null
                    : IconButton(
                        key: const ValueKey('safetrack-search-submit'),
                        tooltip: 'Search evacuation points',
                        onPressed: _isSearching ? null : _searchOnline,
                        icon: _isSearching
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.arrow_forward_rounded),
                      ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
            ),
            if (_searchError != null) ...[
              const SizedBox(height: 8),
              Text(
                _searchError!,
                key: const ValueKey('safetrack-search-message'),
                style: TextStyle(
                  color: _isSearching
                      ? _secondaryTextColor(context)
                      : const Color(0xFFB34343),
                  fontSize: 11,
                ),
              ),
            ],
            const SizedBox(height: 8),
            Flexible(
              child: results.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.all(18),
                      child: Text(
                        widget.destinations.isEmpty
                            ? 'No nearby mapped evacuation points are loaded.'
                            : 'No evacuation point matches your search.',
                        textAlign: TextAlign.center,
                      ),
                    )
                  : ListView.separated(
                      shrinkWrap: true,
                      itemCount: results.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final destination = results[index];
                        final distanceKm = widget.origin == null
                            ? null
                            : destination.distanceFrom(widget.origin!) / 1000;
                        return ListTile(
                          key: ValueKey(
                            'safetrack-search-result-${destination.id}',
                          ),
                          leading: const Icon(
                            Icons.location_on_rounded,
                            color: _blue,
                          ),
                          title: Text(destination.name),
                          subtitle: distanceKm == null
                              ? const Text('Community-mapped')
                              : Text(
                                  '${distanceKm.toStringAsFixed(1)} km away · '
                                  'Community-mapped',
                                ),
                          onTap: () => Navigator.of(context).pop(destination),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}

class _SafeTrackMetric extends StatelessWidget {
  const _SafeTrackMetric({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Icon(icon, size: 19, color: _blue),
        const SizedBox(height: 4),
        Text(
          label,
          textAlign: TextAlign.center,
          style: TextStyle(color: _secondaryTextColor(context), fontSize: 9),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: _primaryTextColor(context),
            fontSize: 12,
            fontWeight: FontWeight.w800,
          ),
        ),
      ],
    );
  }
}

class _EmergencyHelpPage extends StatelessWidget {
  const _EmergencyHelpPage({
    required this.contactName,
    required this.contactNumber,
    required this.locationLabel,
  });

  final String contactName;
  final String contactNumber;
  final String locationLabel;

  Future<void> _callEmergencyServices(BuildContext context) async {
    final opened = await launchUrl(
      Uri(scheme: 'tel', path: '911'),
      mode: LaunchMode.externalApplication,
    );
    if (!context.mounted || opened) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Could not open the phone dialer.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final hasContact = contactNumber.trim().isNotEmpty;
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.only(bottom: 24),
          children: [
            _PageHeader(
              title: 'Emergency Help',
              subtitle: 'Get help and contact someone you trust',
              leading: IconButton(
                key: const ValueKey('quick-action-back'),
                tooltip: 'Back',
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.arrow_back_rounded),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(
                    padding: const EdgeInsets.all(18),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFFEFED),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: const Text(
                      'If you are in immediate danger, move to a safer place '
                      'if possible and contact emergency services. Follow '
                      'instructions from local authorities.',
                      style: TextStyle(color: _ink, fontSize: 13, height: 1.45),
                    ),
                  ),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    key: const ValueKey('emergency-call-911'),
                    onPressed: () => _callEmergencyServices(context),
                    icon: const Icon(Icons.call_rounded),
                    label: const Text('Call 911'),
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFFB34343),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                  ),
                  const SizedBox(height: 10),
                  if (hasContact)
                    _EmergencySmsButton(
                      contactName: contactName,
                      contactNumber: contactNumber,
                      message:
                          'I need help at $locationLabel. '
                          'Please contact me as soon as possible.',
                    )
                  else
                    Text(
                      'Add an emergency contact in Settings to prepare an '
                      'SMS from here.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: _secondaryTextColor(context),
                        fontSize: 11,
                      ),
                    ),
                  const SizedBox(height: 14),
                  Text(
                    'Banog opens your phone or messaging app; it does not '
                    'place calls or send messages automatically.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: _secondaryTextColor(context),
                      fontSize: 10,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EvacuationGuidePage extends StatelessWidget {
  const _EvacuationGuidePage();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.only(bottom: 24),
          children: [
            _PageHeader(
              title: 'Evacuation Guide',
              subtitle: 'Prepare early and follow local instructions',
              leading: IconButton(
                key: const ValueKey('quick-action-back'),
                tooltip: 'Back',
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.arrow_back_rounded),
              ),
            ),
            const _GuideSection(
              icon: Icons.schedule_rounded,
              title: 'Before you leave',
              details:
                  'Know your nearest evacuation center and safe routes. Pack '
                  'essential medicines, water, food, IDs, cash, a flashlight, '
                  'and a charged phone. Tell family where you are going.',
            ),
            const _GuideSection(
              icon: Icons.campaign_rounded,
              title: 'When officials advise evacuation',
              details:
                  'Leave early, use the route advised by local authorities, '
                  'and bring only essential belongings. Help children, older '
                  'adults, and people who need assistance.',
            ),
            const _GuideSection(
              icon: Icons.water_rounded,
              title: 'If flooding is possible',
              details:
                  'Move to higher ground. Never walk, swim, or drive through '
                  'floodwater. Stay away from downed power lines and damaged '
                  'bridges.',
            ),
            const _GuideSection(
              icon: Icons.home_work_rounded,
              title: 'At the evacuation center',
              details:
                  'Register with center staff, keep your family together, '
                  'follow health and safety instructions, and wait for '
                  'official clearance before returning home.',
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
              child: Text(
                'This guide is general information. Follow current advisories '
                'from PAGASA and your local disaster risk reduction office.',
                style: TextStyle(
                  color: _secondaryTextColor(context),
                  fontSize: 10,
                  height: 1.4,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _GuideSection extends StatelessWidget {
  const _GuideSection({
    required this.icon,
    required this.title,
    required this.details,
  });

  final IconData icon;
  final String title;
  final String details;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(20, 0, 20, 12),
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: _surfaceColor(context),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFE4EDF5)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: _blue, size: 23),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: _primaryTextColor(context),
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  details,
                  style: TextStyle(
                    color: _secondaryTextColor(context),
                    fontSize: 11,
                    height: 1.45,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SafetyChecklistPage extends StatefulWidget {
  const _SafetyChecklistPage();

  @override
  State<_SafetyChecklistPage> createState() => _SafetyChecklistPageState();
}

class _SafetyChecklistPageState extends State<_SafetyChecklistPage> {
  static const _items = [
    'Drinking water and ready-to-eat food',
    'First-aid kit and regular medicines',
    'IDs and important documents in a waterproof bag',
    'Flashlight, radio, and spare batteries',
    'Charged phone, power bank, and emergency contacts',
    'Clothes, hygiene items, and supplies for family members',
    'Know your evacuation center and safe route',
  ];

  final _checkedItems = <String>{};

  @override
  Widget build(BuildContext context) {
    final completed = _checkedItems.length;
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.only(bottom: 24),
          children: [
            _PageHeader(
              title: 'Safety Checklist',
              subtitle: '$completed of ${_items.length} items ready',
              leading: IconButton(
                key: const ValueKey('quick-action-back'),
                tooltip: 'Back',
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.arrow_back_rounded),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: LinearProgressIndicator(
                  value: completed / _items.length,
                  minHeight: 7,
                  backgroundColor: const Color(0xFFE2EAF1),
                  color: _blue,
                ),
              ),
            ),
            const SizedBox(height: 14),
            for (final item in _items)
              CheckboxListTile(
                key: ValueKey('safety-check-${_items.indexOf(item)}'),
                value: _checkedItems.contains(item),
                onChanged: (checked) => setState(() {
                  if (checked ?? false) {
                    _checkedItems.add(item);
                  } else {
                    _checkedItems.remove(item);
                  }
                }),
                controlAffinity: ListTileControlAffinity.leading,
                title: Text(
                  item,
                  style: TextStyle(
                    color: _primaryTextColor(context),
                    fontSize: 12,
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
              child: Text(
                'Needs vary by household. Follow local evacuation guidance '
                'and add any essential medicines or supplies you need.',
                style: TextStyle(
                  color: _secondaryTextColor(context),
                  fontSize: 10,
                  height: 1.4,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class HomePage extends StatelessWidget {
  const HomePage({
    super.key,
    this.forecastClient,
    this.alertClient,
    this.isDarkMode = false,
    this.onToggleDarkMode,
    this.onOpenSettings,
    this.isImperial = false,
    this.use24HourTime = false,
    this.notificationsEnabled = true,
    this.enabledAlertTypes = const {'Rain', 'Thunderstorm', 'Wind'},
    this.activeLocation = _defaultMapLocation,
    this.activeLocationLabel = 'General MacArthur, Eastern Samar',
    this.onActiveLocationChanged,
  });

  final http.Client? forecastClient;
  final http.Client? alertClient;
  final bool isDarkMode;
  final VoidCallback? onToggleDarkMode;
  final VoidCallback? onOpenSettings;
  final bool isImperial;
  final bool use24HourTime;
  final bool notificationsEnabled;
  final Set<String> enabledAlertTypes;
  final LatLng activeLocation;
  final String activeLocationLabel;
  final void Function(LatLng location, String label)? onActiveLocationChanged;

  Future<void> _useMyLocation(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      const SnackBar(content: Text('Getting your current location...')),
    );
    final result = await DeviceLocationService.getCurrentPosition();
    if (!context.mounted) return;
    if (!result.isSuccess) {
      messenger.showSnackBar(
        SnackBar(content: Text(result.error ?? 'Location is unavailable.')),
      );
      return;
    }
    final position = result.position!;
    final label = await _reverseGeocodeLabel(position);
    if (!context.mounted) return;
    onActiveLocationChanged?.call(position, label);
    messenger.showSnackBar(
      SnackBar(content: Text('Now showing weather for $label.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return _PageScroll(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _BrandHeader(
            isDarkMode: isDarkMode,
            onToggleDarkMode: onToggleDarkMode,
            onOpenSettings: onOpenSettings,
          ),
          const SizedBox(height: 18),
          _LocationLine(
            icon: Icons.location_on_rounded,
            text: activeLocationLabel,
            onTap: () => _useMyLocation(context),
          ),
          const SizedBox(height: 16),
          _CurrentWeatherCard(isImperial: isImperial),
          const SizedBox(height: 24),
          const _SectionHeader(
            title: 'Hourly Forecast',
            trailing: 'Next 24 Hours  ›',
          ),
          const SizedBox(height: 12),
          _HourlyForecast(
            client: forecastClient,
            isImperial: isImperial,
            use24HourTime: use24HourTime,
            location: activeLocation,
          ),
          const SizedBox(height: 24),
          const _SectionHeader(title: 'Weather Alert', trailing: 'View all  ›'),
          const SizedBox(height: 12),
          _AlertCard(
            client: alertClient,
            enabledAlertTypes: enabledAlertTypes,
            notificationsEnabled: notificationsEnabled,
            isImperial: isImperial,
            use24HourTime: use24HourTime,
            location: activeLocation,
          ),
          const SizedBox(height: 18),
        ],
      ),
    );
  }
}

class _BrandHeader extends StatelessWidget {
  const _BrandHeader({
    required this.isDarkMode,
    required this.onToggleDarkMode,
    required this.onOpenSettings,
  });

  final bool isDarkMode;
  final VoidCallback? onToggleDarkMode;
  final VoidCallback? onOpenSettings;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            color: _surfaceColor(context),
            borderRadius: BorderRadius.circular(16),
          ),
          clipBehavior: Clip.antiAlias,
          child: Image.asset(
            'logo.jpg',
            key: const ValueKey('banog-logo'),
            fit: BoxFit.cover,
          ),
        ),
        const SizedBox(width: 11),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Banog',
              style: TextStyle(
                color: _isDarkMode(context) ? _darkInk : _navy,
                fontSize: 22,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.5,
              ),
            ),
            const Text(
              'WEATHER APP',
              style: TextStyle(
                fontSize: 9,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.4,
              ),
            ),
          ],
        ),
        const Spacer(),
        Container(
          decoration: const BoxDecoration(
            color: Colors.transparent,
            shape: BoxShape.circle,
          ),
          child: IconButton(
            key: const ValueKey('theme-toggle'),
            tooltip: isDarkMode
                ? 'Switch to light theme'
                : 'Switch to dark theme',
            onPressed: onToggleDarkMode,
            icon: Icon(
              isDarkMode ? Icons.light_mode_rounded : Icons.dark_mode_rounded,
              color: _isDarkMode(context) ? _darkInk : _navy,
            ),
          ),
        ),
        IconButton(
          key: const ValueKey('home-settings'),
          tooltip: 'Open settings',
          onPressed: onOpenSettings,
          icon: Icon(
            Icons.settings_outlined,
            color: _isDarkMode(context) ? _darkInk : _navy,
          ),
        ),
      ],
    );
  }
}

class _LocationLine extends StatelessWidget {
  const _LocationLine({required this.icon, required this.text, this.onTap});

  final IconData icon;
  final String text;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            children: [
              Icon(icon, size: 16, color: _blue),
              const SizedBox(width: 5),
              Expanded(
                child: Text(
                  text,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: _secondaryTextColor(context),
                  ),
                ),
              ),
              if (onTap != null)
                const Padding(
                  padding: EdgeInsets.only(right: 4),
                  child: Icon(Icons.gps_fixed_rounded, size: 16, color: _blue),
                ),
              Icon(
                Icons.keyboard_arrow_down_rounded,
                size: 18,
                color: _secondaryTextColor(context),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CurrentWeatherCard extends StatelessWidget {
  const _CurrentWeatherCard({required this.isImperial});

  final bool isImperial;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('home-weather-card'),
      width: double.infinity,
      height: 208,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(25),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFB8DDF8), Color(0xFF72B4E9), Color(0xFF4D98D6)],
        ),
        boxShadow: [
          BoxShadow(
            color: _blue.withValues(alpha: 0.18),
            blurRadius: 22,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final mascotWidth = constraints.maxWidth * 0.49;
          return Stack(
            clipBehavior: Clip.hardEdge,
            children: [
              Positioned(
                top: 0,
                bottom: 0,
                right: 0,
                width: mascotWidth,
                child: ClipRect(
                  key: const ValueKey('home-mascot-slot'),
                  child: Image.asset(
                    'Mascot.jpg',
                    key: const ValueKey('home-weather-mascot'),
                    width: mascotWidth,
                    height: 208,
                    fit: BoxFit.contain,
                    alignment: Alignment.centerRight,
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(21, 17, 18, 15),
                child: SizedBox(
                  width: constraints.maxWidth - mascotWidth + 6,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 5,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.68),
                          borderRadius: BorderRadius.circular(30),
                        ),
                        child: const Text(
                          'Magandang Umaga!',
                          style: TextStyle(
                            color: _navy,
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '${_displayTemperature(28, isImperial)}°',
                        style: TextStyle(
                          color: Colors.white,
                          height: 1,
                          fontSize: 54,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -2,
                        ),
                      ),
                      const SizedBox(height: 7),
                      const Text(
                        'Partly Cloudy',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        'Feels like ${_displayTemperature(32, isImperial)}°',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.88),
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Positioned(
                left: 21,
                right: mascotWidth + 6,
                bottom: 15,
                child: const Text(
                  'May posibilidad ng ulan mamayang hapon.',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, required this.trailing});

  final String title;
  final String trailing;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(
            title,
            style: TextStyle(
              color: _primaryTextColor(context),
              fontSize: 15,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        Text(
          trailing,
          style: const TextStyle(
            color: _blue,
            fontSize: 11,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }
}

class _HourlyForecast extends StatefulWidget {
  const _HourlyForecast({
    this.client,
    required this.isImperial,
    this.use24HourTime = false,
    this.location = _defaultMapLocation,
  });

  final http.Client? client;
  final bool isImperial;
  final bool use24HourTime;
  final LatLng location;

  @override
  State<_HourlyForecast> createState() => _HourlyForecastState();
}

class _HourlyForecastState extends State<_HourlyForecast>
    with WidgetsBindingObserver {
  late final _client = widget.client ?? http.Client();
  Timer? _refreshTimer;
  List<_HourlyWeather> _hours = [];
  DateTime? _updatedAt;
  String? _error;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadForecast();
    _scheduleRefresh();
  }

  @override
  void didUpdateWidget(covariant _HourlyForecast oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.location != widget.location) _loadForecast();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _loadForecast();
      _scheduleRefresh();
    } else {
      _refreshTimer?.cancel();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _refreshTimer?.cancel();
    if (widget.client == null) _client.close();
    super.dispose();
  }

  void _scheduleRefresh() {
    _refreshTimer?.cancel();
    _refreshTimer = Timer.periodic(_forecastRefreshInterval, (_) {
      _loadForecast();
    });
  }

  Future<void> _loadForecast() async {
    if (!mounted) return;
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final uri = Uri.https('api.open-meteo.com', '/v1/forecast', {
        'latitude': widget.location.latitude.toString(),
        'longitude': widget.location.longitude.toString(),
        'current': 'temperature_2m',
        'hourly': 'temperature_2m,apparent_temperature,precipitation_probability,weather_code',
        'forecast_days': '2',
        'timezone': 'Asia/Manila',
      });
      final response = await _client
          .get(uri)
          .timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) {
        throw http.ClientException(
          'Forecast provider returned HTTP ${response.statusCode}.',
        );
      }

      final payload = jsonDecode(response.body);
      if (payload is! Map<String, dynamic> ||
          payload['hourly'] is! Map<String, dynamic> ||
          payload['current'] is! Map<String, dynamic>) {
        throw const FormatException('Hourly forecast data is missing.');
      }
      final hourly = payload['hourly'] as Map<String, dynamic>;
      final current = payload['current'] as Map<String, dynamic>;
      final times = hourly['time'];
      final temperatures = hourly['temperature_2m'];
      final apparentTemperatures = hourly['apparent_temperature'];
      final precipitationProbabilities = hourly['precipitation_probability'];
      final weatherCodes = hourly['weather_code'];
      if (times is! List ||
          temperatures is! List ||
          apparentTemperatures is! List ||
          precipitationProbabilities is! List ||
          weatherCodes is! List) {
        throw const FormatException('Hourly forecast arrays are invalid.');
      }

      final currentTime = current['time'];
      final currentHour = currentTime is String && currentTime.length >= 13
          ? currentTime.substring(0, 13)
          : null;
      var firstHourIndex = currentHour == null
          ? -1
          : times.indexWhere(
              (time) => time is String && time.startsWith(currentHour),
            );
      if (firstHourIndex < 0) firstHourIndex = 0;

      final forecast = <_HourlyWeather>[];
      final availableHours = [
        times.length,
        temperatures.length,
        apparentTemperatures.length,
        precipitationProbabilities.length,
        weatherCodes.length,
      ].reduce((shortest, length) => shortest < length ? shortest : length);
      for (
        var index = firstHourIndex;
        index < availableHours && forecast.length < 24;
        index++
      ) {
        final timeValue = times[index];
        final time = timeValue is String ? DateTime.tryParse(timeValue) : null;
        final temperature = _readForecastNumber(temperatures[index]);
        final feelsLike = _readForecastNumber(apparentTemperatures[index]);
        final precipitation = _readForecastNumber(
          precipitationProbabilities[index],
        );
        final weatherCode = _readForecastNumber(weatherCodes[index]);
        if (time == null ||
            temperature == null ||
            feelsLike == null ||
            precipitation == null ||
            weatherCode == null) {
          continue;
        }
        forecast.add(
          _HourlyWeather(
            time: time,
            temperature: temperature,
            feelsLike: feelsLike,
            precipitationProbability: precipitation.round(),
            weatherCode: weatherCode.round(),
          ),
        );
      }
      if (forecast.isEmpty) {
        throw const FormatException('No hourly forecast is available.');
      }

      if (!mounted) return;
      setState(() {
        _hours = forecast;
        _updatedAt = DateTime.now();
        _error = null;
        _isLoading = false;
      });
    } on http.ClientException {
      _showForecastError('Could not connect to the weather forecast.');
    } on FormatException {
      _showForecastError('The hourly forecast data is invalid.');
    } on TimeoutException {
      _showForecastError('Hourly forecast request timed out.');
    }
  }

  double? _readForecastNumber(Object? value) =>
      value is num ? value.toDouble() : null;

  void _showForecastError(String message) {
    if (!mounted) return;
    setState(() {
      _error = message;
      _isLoading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading && _hours.isEmpty) {
      return const SizedBox(
        height: 115,
        child: Center(
          child: CircularProgressIndicator(
            key: ValueKey('hourly-forecast-loading'),
            strokeWidth: 2,
          ),
        ),
      );
    }
    if (_error != null && _hours.isEmpty) {
      return SizedBox(
        height: 115,
        child: Center(
          child: TextButton.icon(
            onPressed: _loadForecast,
            icon: const Icon(Icons.refresh_rounded),
            label: Text('$_error  Retry'),
          ),
        ),
      );
    }

    final updatedAt = _updatedAt;
    final timeLabel = updatedAt == null
        ? 'Next 24 Hours'
        : 'Updated ${updatedAt.hour.toString().padLeft(2, '0')}:'
              '${updatedAt.minute.toString().padLeft(2, '0')}  ↻';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: 131,
          child: ListView.separated(
            key: const ValueKey('hourly-forecast-list'),
            scrollDirection: Axis.horizontal,
            itemCount: _hours.length,
            separatorBuilder: (_, _) => const SizedBox(width: 9),
            itemBuilder: (context, index) {
              final hour = _hours[index];
              return Tooltip(
                message:
                    'Feels like ${_displayTemperature(hour.feelsLike, widget.isImperial)}°',
                child: Container(
                  width: 67,
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  decoration: BoxDecoration(
                    color: index == 0
                        ? (_isDarkMode(context)
                              ? const Color(0xFF29445A)
                              : const Color(0xFFD5EAF9))
                        : _surfaceColor(context),
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(
                      color: _isDarkMode(context)
                          ? const Color(0xFF344451)
                          : const Color(0xFFE4EDF5),
                    ),
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        index == 0 ? 'Now' : _formatHour(hour.time),
                        style: TextStyle(
                          color: _secondaryTextColor(context),
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Icon(
                        _weatherIcon(hour.weatherCode),
                        color: _weatherColor(hour.weatherCode),
                        size: 24,
                      ),
                      Text(
                        '${_displayTemperature(hour.temperature, widget.isImperial)}°',
                        style: TextStyle(
                          color: _primaryTextColor(context),
                          fontSize: 13,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.water_drop_rounded,
                            size: 10,
                            color: _blue,
                          ),
                          Text(
                            '${hour.precipitationProbability}%',
                            style: TextStyle(
                              color: _secondaryTextColor(context),
                              fontSize: 9,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            Expanded(
              child: Text(
                'Temperature · rain chance',
                style: TextStyle(
                  color: _secondaryTextColor(context),
                  fontSize: 9,
                ),
              ),
            ),
            if (_isLoading)
              const SizedBox(
                width: 11,
                height: 11,
                child: CircularProgressIndicator(strokeWidth: 1.5),
              ),
            if (_error != null)
              const Icon(
                Icons.cloud_off_outlined,
                color: Color(0xFFB34343),
                size: 14,
              ),
            TextButton(
              key: const ValueKey('hourly-forecast-refresh'),
              onPressed: _loadForecast,
              style: TextButton.styleFrom(
                minimumSize: Size.zero,
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: Text(
                timeLabel,
                style: const TextStyle(
                  fontSize: 9,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  String _formatHour(DateTime time) {
    return _formatHourOfDay(time.hour, use24HourTime: widget.use24HourTime);
  }

  IconData _weatherIcon(int code) {
    if (code == 0) return Icons.wb_sunny_rounded;
    if (code <= 2) return Icons.cloud_queue_rounded;
    if (code == 3 || code == 45 || code == 48) {
      return Icons.cloud_rounded;
    }
    if (code >= 95) return Icons.thunderstorm_rounded;
    if (code >= 80 || (code >= 61 && code <= 67)) {
      return Icons.cloudy_snowing;
    }
    return Icons.grain_rounded;
  }

  Color _weatherColor(int code) {
    if (code == 0) return const Color(0xFFF2A72F);
    if (code >= 95) return const Color(0xFF8061C7);
    if (code >= 51) return _blue;
    return const Color(0xFF6D9AC3);
  }
}

class _AlertCard extends StatefulWidget {
  const _AlertCard({
    this.client,
    required this.enabledAlertTypes,
    this.notificationsEnabled = true,
    required this.isImperial,
    this.use24HourTime = false,
    this.location = _defaultMapLocation,
  });

  final http.Client? client;
  final Set<String> enabledAlertTypes;
  final bool notificationsEnabled;
  final bool isImperial;
  final bool use24HourTime;
  final LatLng location;

  @override
  State<_AlertCard> createState() => _AlertCardState();
}

class _AlertCardState extends State<_AlertCard> with WidgetsBindingObserver {
  late final _client = widget.client ?? http.Client();
  Timer? _refreshTimer;
  List<_WeatherAlert> _alerts = [];
  String? _error;
  bool _isLoading = true;

  @override
  void didUpdateWidget(covariant _AlertCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.location != widget.location) _loadAlerts();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadAlerts();
    _scheduleRefresh();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _loadAlerts();
      _scheduleRefresh();
    } else {
      _refreshTimer?.cancel();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _refreshTimer?.cancel();
    if (widget.client == null) _client.close();
    super.dispose();
  }

  void _scheduleRefresh() {
    _refreshTimer?.cancel();
    _refreshTimer = Timer.periodic(_forecastRefreshInterval, (_) {
      _loadAlerts();
    });
  }

  Future<void> _loadAlerts() async {
    if (!mounted) return;
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final alerts = await _fetchWeatherAlerts(
        _client,
        isImperial: widget.isImperial,
        use24HourTime: widget.use24HourTime,
        location: widget.location,
      );
      if (!mounted) return;
      setState(() {
        _alerts = alerts;
        _isLoading = false;
        _error = null;
      });
    } on http.ClientException {
      _showError('Could not connect to the weather forecast.');
    } on FormatException {
      _showError('Weather alert forecast data is invalid.');
    } on TimeoutException {
      _showError('Weather alert request timed out.');
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    setState(() {
      _error = message;
      _isLoading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final visibleAlerts = widget.notificationsEnabled
        ? _alerts
              .where(
                (alert) => widget.enabledAlertTypes.contains(alert.category),
              )
              .toList()
        : <_WeatherAlert>[];
    final alert = visibleAlerts.isNotEmpty ? visibleAlerts.first : null;
    final title = _error != null && alert == null
        ? 'Weather alert unavailable'
        : alert?.title ?? 'No significant weather alerts';
    final message = _error != null && alert == null
        ? _error!
        : alert?.message ??
              (!widget.notificationsEnabled
                  ? 'In-app weather alerts are turned off in Settings.'
                  : widget.enabledAlertTypes.isEmpty
                  ? 'All in-app weather alert types are turned off in Settings.'
                  : 'No significant rain, thunderstorm, or strong wind is predicted in the next 24 hours.');
    final color = alert?.color ?? const Color(0xFFDCEBFA);
    final iconColor = alert == null
        ? _blue
        : alert.color.withValues(alpha: 0.9);
    return Container(
      key: const ValueKey('home-weather-alert'),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: iconColor,
              borderRadius: BorderRadius.circular(11),
            ),
            child: Icon(
              alert?.icon ?? Icons.check_rounded,
              color: Colors.white,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: _navy,
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  message,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: _primaryTextColor(context),
                    fontSize: 10,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 4),
          if (_isLoading)
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 1.5),
            )
          else
            IconButton(
              key: const ValueKey('home-alert-refresh'),
              tooltip: 'Refresh weather alert',
              onPressed: _loadAlerts,
              visualDensity: VisualDensity.compact,
              icon: Icon(
                _error == null
                    ? Icons.refresh_rounded
                    : Icons.cloud_off_outlined,
                color: _navy,
                size: 18,
              ),
            ),
        ],
      ),
    );
  }
}

class MapPage extends StatefulWidget {
  const MapPage({
    super.key,
    this.isImperial = false,
    this.client,
    this.useIsolateForBoundaryLookup = true,
    this.activeLocation = _defaultMapLocation,
    this.activeLocationLabel = 'General MacArthur, Eastern Samar',
    this.onActiveLocationChanged,
    this.isImmersive = false,
    this.onImmersiveChanged,
  });

  final bool isImperial;
  final http.Client? client;
  final bool useIsolateForBoundaryLookup;
  final LatLng activeLocation;
  final String activeLocationLabel;
  final void Function(LatLng location, String label)? onActiveLocationChanged;
  final bool isImmersive;
  final ValueChanged<bool>? onImmersiveChanged;

  @override
  State<MapPage> createState() => _MapPageState();
}

class _MapPageState extends State<MapPage> with WidgetsBindingObserver {
  final _mapController = MapController();
  final _searchController = TextEditingController();
  http.Client? _ownedHttpClient;
  http.Client get _httpClient =>
      widget.client ?? (_ownedHttpClient ??= http.Client());
  LatLng _selectedLocation = _defaultMapLocation;
  _MapType _mapType = _MapType.standard;
  _WeatherLayer _weatherLayer = _WeatherLayer.radar;
  List<_WeatherPoint> _weatherPoints = [];
  _WeatherPoint? _selectedWindPoint;
  Timer? _mapMoveDebounceTimer;
  Timer? _autoRefreshTimer;
  Timer? _searchDebounceTimer;
  String? _radarTileUrl;
  String? _layerError;
  DateTime? _lastDataUpdatedAt;
  bool _isLayerLoading = false;
  bool _isMapActive = false;
  bool _isAppInForeground = true;
  bool _weatherRefreshPending = false;
  int _weatherRequestGeneration = 0;
  String _locationLabel = 'General MacArthur, Eastern Samar';
  bool _isSearching = false;
  bool _isControlsCollapsed = false;
  bool _isImmersive = false;
  bool _showTyphoonTracks = false;
  bool _showParBoundary = false;
  List<StormTrack> _stormTracks = [];
  bool _isTyphoonLoading = false;
  String? _typhoonError;
  DateTime? _typhoonUpdatedAt;
  bool _typhoonUsingCache = false;
  bool _typhoonPreviewing = false;
  bool _isTyphoonPreviewLoading = false;
  Timer? _typhoonRefreshTimer;
  double? _typhoonPlayhead;
  bool _typhoonPlaying = false;
  int _typhoonPlaybackSpeed = 1;
  Timer? _typhoonPlaybackTimer;
  List<Polygon> _highlightPolygons = [];
  final Map<String, String> _boundaryAssetCache = {};
  int _searchGeneration = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _selectedLocation = widget.activeLocation;
    _locationLabel = widget.activeLocationLabel;
    _isImmersive = widget.isImmersive;
  }

  @override
  void didUpdateWidget(covariant MapPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isImmersive != widget.isImmersive) {
      _isImmersive = widget.isImmersive;
    }
    if (oldWidget.activeLocation != widget.activeLocation) {
      setState(() {
        _selectedLocation = widget.activeLocation;
        _locationLabel = widget.activeLocationLabel;
      });
      if (_isMapActive) {
        _mapController.move(widget.activeLocation, 11);
      }
    }
  }

  void _toggleImmersive() {
    final next = !_isImmersive;
    setState(() => _isImmersive = next);
    widget.onImmersiveChanged?.call(next);
  }

  void _setTyphoonTracksEnabled(bool value) {
    _cancelTyphoonPlaybackTimer();
    final wasPreview = _typhoonPreviewing;
    setState(() {
      _showTyphoonTracks = value;
      if (value) _showParBoundary = true;
      _typhoonPlaying = false;
      _typhoonPlayhead = null;
      _typhoonPreviewing = false;
      _isTyphoonPreviewLoading = false;
      if (wasPreview) _stormTracks = [];
    });
    if (!value) {
      _typhoonRefreshTimer?.cancel();
      return;
    }
    if (_stormTracks.isEmpty) _restoreTyphoonCache();
    _loadTyphoonTracks();
    _scheduleTyphoonRefresh();
  }

  void _setParBoundaryEnabled(bool value) {
    setState(() => _showParBoundary = value);
  }

  Future<void> _restoreTyphoonCache() async {
    try {
      final cache = await StormTrackService.loadCache();
      if (!mounted || cache.isEmpty || _stormTracks.isNotEmpty) return;
      setState(() {
        _stormTracks = cache.tracks;
        _typhoonUpdatedAt = cache.savedAt;
      });
    } catch (_) {
      // Cache is best-effort only.
    }
  }

  Future<void> _loadTyphoonTracks({bool force = false}) async {
    if (!_showTyphoonTracks || _isTyphoonLoading) return;
    if (!_isMapActive || !_isAppInForeground || !mounted) return;
    final updatedAt = _typhoonUpdatedAt;
    if (!force &&
        _typhoonError == null &&
        updatedAt != null &&
        DateTime.now().difference(updatedAt).inMinutes < 15) {
      return;
    }

    _cancelTyphoonPlaybackTimer();
    setState(() {
      _isTyphoonLoading = true;
      _typhoonError = null;
      _typhoonPlaying = false;
      _typhoonPlayhead = null;
    });
    try {
      final tracks = await StormTrackService.fetchParTracks(_httpClient);
      if (tracks.isEmpty && _typhoonPreviewing) {
        if (!mounted) return;
        setState(() {
          _isTyphoonLoading = false;
          _typhoonError = null;
        });
        return;
      }
      try {
        await StormTrackService.saveCache(tracks);
      } catch (_) {
        // Ignore cache write failures; the live data is still usable.
      }
      if (!mounted) return;
      setState(() {
        _stormTracks = tracks;
        _typhoonUpdatedAt = DateTime.now();
        _isTyphoonLoading = false;
        _typhoonError = null;
        _typhoonUsingCache = false;
        _typhoonPreviewing = false;
      });
    } catch (_) {
      var cache = const StormTrackCache(tracks: []);
      try {
        cache = await StormTrackService.loadCache();
      } catch (_) {
        // Ignore unreadable cache.
      }
      if (!mounted) return;
      if (_typhoonPreviewing) {
        setState(() {
          _isTyphoonLoading = false;
          _typhoonError = 'Live update failed · showing replay';
        });
        return;
      }
      final ageLabel = StormTrackService.describeAge(cache.age);
      setState(() {
        _stormTracks = cache.tracks;
        _typhoonUpdatedAt = cache.savedAt;
        _isTyphoonLoading = false;
        _typhoonUsingCache = !cache.isEmpty;
        _typhoonError = cache.isEmpty
            ? 'Live update failed · no saved track'
            : ageLabel.isEmpty
            ? 'Live update failed · using saved track'
            : 'Live update failed · saved $ageLabel';
      });
    }
  }

  Future<void> _loadRecentTyphoonPreview() async {
    if (!_showTyphoonTracks || _isTyphoonLoading || _isTyphoonPreviewLoading) {
      return;
    }
    if (!_isMapActive || !_isAppInForeground || !mounted) return;
    _cancelTyphoonPlaybackTimer();
    setState(() {
      _isTyphoonPreviewLoading = true;
      _typhoonError = null;
      _typhoonPlaying = false;
      _typhoonPlayhead = null;
    });
    try {
      final track = await StormTrackService.fetchRecentParTrack(_httpClient);
      if (!mounted) return;
      if (track == null) {
        setState(() {
          _isTyphoonPreviewLoading = false;
          _typhoonError = 'No recent PAR storm to replay.';
        });
        return;
      }
      setState(() {
        _stormTracks = [track];
        _typhoonPreviewing = true;
        _typhoonUpdatedAt = null;
        _typhoonUsingCache = false;
        _isTyphoonPreviewLoading = false;
        _typhoonError = null;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _isTyphoonPreviewLoading = false;
        _typhoonError = 'Could not load the last storm.';
      });
    }
  }

  void _scheduleTyphoonRefresh() {
    _typhoonRefreshTimer?.cancel();
    if (!_showTyphoonTracks) return;
    _typhoonRefreshTimer = Timer.periodic(const Duration(minutes: 15), (_) {
      _loadTyphoonTracks(force: true);
    });
  }

  void _cancelTyphoonPlaybackTimer() {
    _typhoonPlaybackTimer?.cancel();
    _typhoonPlaybackTimer = null;
  }

  void _toggleTyphoonPlayback() {
    if (_typhoonPlaying) {
      _stopTyphoonPlayback();
      return;
    }
    final playback = _typhoonPrimaryPlayback;
    if (playback == null) return;
    final current = _typhoonPlayhead ?? playback.currentFraction;
    final start = _typhoonPlayhead == null || current >= 1 ? 0.0 : current;
    _cancelTyphoonPlaybackTimer();
    setState(() {
      _typhoonPlayhead = start;
      _typhoonPlaying = true;
    });
    _typhoonPlaybackTimer = Timer.periodic(
      const Duration(milliseconds: 80),
      (_) => _tickTyphoonPlayback(const Duration(milliseconds: 80)),
    );
  }

  void _tickTyphoonPlayback(Duration delta) {
    if (!mounted || !_typhoonPlaying) return;
    final playback = _typhoonPrimaryPlayback;
    if (playback == null) {
      _stopTyphoonPlayback();
      return;
    }
    playback.progress = _typhoonPlayhead ?? playback.currentFraction;
    playback.speed = _typhoonPlaybackSpeed;
    final finished = playback.advance(delta);
    setState(() {
      _typhoonPlayhead = playback.progress;
      if (finished) _typhoonPlaying = false;
    });
    if (finished) _cancelTyphoonPlaybackTimer();
  }

  void _stopTyphoonPlayback() {
    _cancelTyphoonPlaybackTimer();
    if (!_typhoonPlaying) return;
    if (mounted) {
      setState(() => _typhoonPlaying = false);
    } else {
      _typhoonPlaying = false;
    }
  }

  void _cycleTyphoonPlaybackSpeed() {
    setState(() {
      _typhoonPlaybackSpeed = switch (_typhoonPlaybackSpeed) {
        1 => 2,
        2 => 4,
        _ => 1,
      };
    });
  }

  void _seekTyphoonPlayback(double value) {
    setState(() => _typhoonPlayhead = value.clamp(0.0, 1.0));
  }

  void _resetTyphoonPlayback() {
    _cancelTyphoonPlaybackTimer();
    setState(() {
      _typhoonPlaying = false;
      _typhoonPlayhead = null;
    });
  }

  Future<void> _locateMe() async {
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      const SnackBar(content: Text('Getting your current location...')),
    );
    final result = await DeviceLocationService.getCurrentPosition();
    if (!mounted) return;
    if (!result.isSuccess) {
      messenger.showSnackBar(
        SnackBar(content: Text(result.error ?? 'Location is unavailable.')),
      );
      return;
    }
    final position = result.position!;
    final label = await _reverseGeocodeLabel(position);
    if (!mounted) return;
    setState(() {
      _selectedLocation = position;
      _locationLabel = label;
      _highlightPolygons = [];
    });
    _mapController.move(position, 11);
    widget.onActiveLocationChanged?.call(position, label);
    if (_weatherLayer == _WeatherLayer.rain ||
        _weatherLayer == _WeatherLayer.wind) {
      _loadWeatherForecast();
    }
  }

  void setMapActive(bool active) {
    if (_isMapActive == active) return;
    if (!active) {
      _isMapActive = false;
      _mapMoveDebounceTimer?.cancel();
      _autoRefreshTimer?.cancel();
      _typhoonRefreshTimer?.cancel();
      _cancelTyphoonPlaybackTimer();
      _weatherRequestGeneration++;
      _weatherRefreshPending = false;
      final needsRebuild = _isLayerLoading || _typhoonPlaying;
      _typhoonPlaying = false;
      if (needsRebuild && mounted) {
        setState(() => _isLayerLoading = false);
      }
      return;
    }

    _isMapActive = true;
    _loadSelectedWeatherLayer();
    _scheduleAutoRefresh();
    if (_showTyphoonTracks) {
      _loadTyphoonTracks();
      _scheduleTyphoonRefresh();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _isAppInForeground = state == AppLifecycleState.resumed;
    if (!_isAppInForeground) {
      _mapMoveDebounceTimer?.cancel();
      _autoRefreshTimer?.cancel();
      _typhoonRefreshTimer?.cancel();
      _cancelTyphoonPlaybackTimer();
      _weatherRequestGeneration++;
      _weatherRefreshPending = false;
      final needsRebuild = _isLayerLoading || _typhoonPlaying;
      _typhoonPlaying = false;
      if (needsRebuild && mounted) {
        setState(() => _isLayerLoading = false);
      }
      return;
    }
    if (_isMapActive) {
      _loadSelectedWeatherLayer();
      _scheduleAutoRefresh();
      if (_showTyphoonTracks) {
        _loadTyphoonTracks();
        _scheduleTyphoonRefresh();
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _mapMoveDebounceTimer?.cancel();
    _autoRefreshTimer?.cancel();
    _typhoonRefreshTimer?.cancel();
    _cancelTyphoonPlaybackTimer();
    _searchDebounceTimer?.cancel();
    _weatherRequestGeneration++;
    _weatherRefreshPending = false;
    _mapController.dispose();
    _searchController.dispose();
    _ownedHttpClient?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final topInset = MediaQuery.of(context).padding.top;
    final typhoonPlayback = _typhoonPrimaryPlayback;
    final typhoonPlayhead =
        _typhoonPlayhead ?? typhoonPlayback?.currentFraction ?? 1.0;
    final typhoonFrame = typhoonPlayback?.frameAt(typhoonPlayhead);
    return Stack(
      fit: StackFit.expand,
      children: [
        FlutterMap(
          mapController: _mapController,
          options: MapOptions(
            initialCenter: _defaultMapLocation,
            initialZoom: 10,
            minZoom: 4,
            maxZoom: 19,
            keepAlive: true,
            onPositionChanged: _onMapPositionChanged,
          ),
          children: [
            TileLayer(
              urlTemplate: _tileUrlFor(_mapType, _weatherLayer),
              userAgentPackageName: 'com.example.banog',
              maxNativeZoom: 19,
            ),
            if (_weatherLayer == _WeatherLayer.radar && _radarTileUrl != null)
              TileLayer(
                key: ValueKey(_radarTileUrl),
                urlTemplate: _radarTileUrl!,
                userAgentPackageName: 'com.example.banog',
                maxNativeZoom: 7,
                maxZoom: 19,
                tileDimension: 256,
                tileDisplay: const TileDisplay.fadeIn(
                  duration: Duration(milliseconds: 180),
                ),
              ),
            if (_weatherLayer == _WeatherLayer.rain &&
                _weatherPoints.isNotEmpty)
              CircleLayer(circles: _rainCircles),
            if (_weatherLayer == _WeatherLayer.wind &&
                _weatherPoints.isNotEmpty)
              MarkerLayer(markers: _windMarkers),
            if (_showParBoundary) ...[
              PolygonLayer(
                polygons: [
                  Polygon(
                    points: ParBoundary.vertices,
                    color: _parBoundaryColor.withValues(alpha: 0.05),
                    borderColor: _parBoundaryColor.withValues(alpha: 0.8),
                    borderStrokeWidth: 1.6,
                    pattern: StrokePattern.dashed(segments: const [10, 7]),
                  ),
                ],
              ),
              MarkerLayer(
                markers: [
                  Marker(
                    point: ParBoundary.labelLocation,
                    width: 150,
                    height: 22,
                    child: IgnorePointer(
                      child: Center(
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: _parBoundaryColor.withValues(alpha: 0.9),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: const Text(
                            'PAR',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 10,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 0.8,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
            if (_showTyphoonTracks && _stormTracks.isNotEmpty) ...[
              PolylineLayer(polylines: _typhoonPastPolylines),
              PolylineLayer(polylines: _typhoonForecastPolylines),
              MarkerLayer(markers: _typhoonMarkers),
            ],
            if (_highlightPolygons.isNotEmpty)
              PolygonLayer(polygons: _highlightPolygons),
            MarkerLayer(
              markers: [
                Marker(
                  point: _selectedLocation,
                  width: 48,
                  height: 60,
                  alignment: Alignment.topCenter,
                  child: SizedBox(
                    width: 48,
                    height: 60,
                    child: Stack(
                      alignment: Alignment.topCenter,
                      children: [
                        const Icon(
                          Icons.location_on_rounded,
                          color: _blue,
                          size: 46,
                          shadows: [
                            Shadow(
                              color: Colors.black38,
                              blurRadius: 5,
                              offset: Offset(0, 2),
                            ),
                          ],
                        ),
                        Positioned(
                          top: 5,
                          child: Container(
                            width: 25,
                            height: 25,
                            padding: const EdgeInsets.all(2),
                            decoration: const BoxDecoration(
                              color: Colors.white,
                              shape: BoxShape.circle,
                            ),
                            child: ClipOval(
                              child: Image.asset(
                                'logo.jpg',
                                key: const ValueKey(
                                  'selected-location-marker-logo',
                                ),
                                fit: BoxFit.cover,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
        if (!_isImmersive)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: IgnorePointer(
              child: Container(
                height: topInset + 260,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.black.withValues(
                        alpha: _isDarkMode(context) ? 0.35 : 0.18,
                      ),
                      Colors.transparent,
                    ],
                  ),
                ),
              ),
            ),
          ),
        if (!_isImmersive)
          Positioned(
            top: topInset + 8,
            left: 12,
            right: 12,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                AnimatedSize(
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeInOutCubic,
                  alignment: Alignment.topCenter,
                  child: _isControlsCollapsed
                      ? Align(
                          alignment: Alignment.centerLeft,
                          child: Material(
                            color: _surfaceColor(context)
                                .withValues(alpha: 0.95),
                            elevation: 3,
                            borderRadius: BorderRadius.circular(16),
                            child: InkWell(
                              borderRadius: BorderRadius.circular(16),
                              onTap: () =>
                                  setState(() => _isControlsCollapsed = false),
                              child: Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  12,
                                  8,
                                  10,
                                  8,
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Icon(
                                      Icons.map_rounded,
                                      color: _blue,
                                      size: 18,
                                    ),
                                    const SizedBox(width: 7),
                                    Text(
                                      'Weather Map',
                                      style: TextStyle(
                                        color: _primaryTextColor(context),
                                        fontSize: 13,
                                        fontWeight: FontWeight.w800,
                                      ),
                                    ),
                                    const SizedBox(width: 4),
                                    const Icon(
                                      Icons.expand_more_rounded,
                                      color: _blue,
                                      size: 20,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        )
                      : DecoratedBox(
                          decoration: BoxDecoration(
                            color: _surfaceColor(context)
                                .withValues(alpha: 0.95),
                            borderRadius: BorderRadius.circular(22),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.16),
                                blurRadius: 16,
                                offset: const Offset(0, 5),
                              ),
                            ],
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(22),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                _PageHeader(
                                  title: 'Weather Map',
                                  subtitle:
                                      _weatherLayer == _WeatherLayer.rain ||
                                          _weatherLayer == _WeatherLayer.wind
                                      ? 'Rain & wind refresh every 15 minutes'
                                      : 'Map of the Philippines',
                                  leading: Container(
                                    width: 42,
                                    height: 42,
                                    margin: const EdgeInsets.only(right: 11),
                                    decoration: BoxDecoration(
                                      gradient: LinearGradient(
                                        colors: [
                                          _blue.withValues(alpha: 0.18),
                                          _blue.withValues(alpha: 0.08),
                                        ],
                                      ),
                                      borderRadius: BorderRadius.circular(13),
                                    ),
                                    child: const Icon(
                                      Icons.map_rounded,
                                      color: _blue,
                                      size: 21,
                                    ),
                                  ),
                                  action: IconButton(
                                    tooltip: 'Collapse map panel',
                                    onPressed: () => setState(
                                      () => _isControlsCollapsed = true,
                                    ),
                                    icon: const Icon(
                                      Icons.expand_less_rounded,
                                      color: _blue,
                                    ),
                                  ),
                                ),
                                Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    14,
                                    0,
                                    14,
                                    10,
                                  ),
                                  child: TextField(
                                    controller: _searchController,
                                    textInputAction: TextInputAction.search,
                                    onSubmitted: _searchLocation,
                                    onChanged: _scheduleSearch,
                                    decoration: InputDecoration(
                                      hintText: 'Search a place in the Philippines...',
                                      hintStyle: const TextStyle(
                                        color: _muted,
                                        fontSize: 13,
                                      ),
                                      prefixIcon: const Icon(
                                        Icons.search_rounded,
                                        color: _muted,
                                      ),
                                      suffixIcon: IconButton(
                                        tooltip: 'Search location',
                                        onPressed: _isSearching
                                            ? null
                                            : () => _searchLocation(
                                                _searchController.text,
                                              ),
                                        icon: _isSearching
                                            ? const SizedBox(
                                                width: 18,
                                                height: 18,
                                                child:
                                                    CircularProgressIndicator(
                                                      strokeWidth: 2,
                                                    ),
                                              )
                                            : const Icon(
                                                Icons.search_rounded,
                                                size: 20,
                                                color: _blue,
                                              ),
                                      ),
                                      filled: true,
                                      fillColor: _surfaceColor(context),
                                      contentPadding: EdgeInsets.zero,
                                      border: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(16),
                                        borderSide: const BorderSide(
                                          color: Color(0xFFE3ECF4),
                                        ),
                                      ),
                                      enabledBorder: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(16),
                                        borderSide: const BorderSide(
                                          color: Color(0xFFE3ECF4),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                                Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    14,
                                    0,
                                    14,
                                    14,
                                  ),
                                  child: Row(
                                    children: [
                                      Text(
                                        'Weather overlay',
                                        style: TextStyle(
                                          color: _secondaryTextColor(context),
                                          fontSize: 11,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                      const Spacer(),
                                      _WeatherOverlayChip(
                                        key: const ValueKey(
                                          'current-weather-overlay',
                                        ),
                                        icon: _weatherLayerIcon(_weatherLayer),
                                        label: _weatherLayerName(_weatherLayer),
                                        onTap: _showMapLayersSheet,
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: _surfaceColor(context).withValues(alpha: 0.95),
                      borderRadius: BorderRadius.circular(14),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.12),
                          blurRadius: 12,
                          offset: const Offset(0, 3),
                        ),
                      ],
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 9,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.location_on_rounded,
                            color: _blue,
                            size: 17,
                          ),
                          const SizedBox(width: 6),
                          ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 240),
                            child: Text(
                              _locationLabel,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: _primaryTextColor(context),
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          if (_highlightPolygons.isNotEmpty) ...[
                            const SizedBox(width: 4),
                            Tooltip(
                              message: 'Clear highlight',
                              child: GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onTap: _clearSearchHighlight,
                                child: const Padding(
                                  padding: EdgeInsets.all(2),
                                  child: Icon(
                                    Icons.close_rounded,
                                    size: 16,
                                    color: _muted,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                if (_isLayerLoading || _layerError != null)
                  _WeatherLayerStatus(
                    loading: _isLayerLoading,
                    message: _layerError ?? _loadingMessage,
                    failed: _layerError != null,
                    onRetry: _layerError == null
                        ? null
                        : _loadSelectedWeatherLayer,
                  )
                else
                  _WeatherLayerStatus(
                    loading: false,
                    message: _weatherLayerDescription,
                    failed: false,
                    onRetry: _weatherLayer == _WeatherLayer.satellite
                        ? null
                        : _loadSelectedWeatherLayer,
                  ),
              ],
            ),
          ),
        if (!_isImmersive)
          Positioned(
            left: 12,
            right: 72,
            bottom: 3,
            child: _MapAttribution(text: _attributionFor(_mapType)),
          ),
        Positioned(
          right: 0,
          top: 0,
          bottom: 0,
          child: Align(
            alignment: const Alignment(1, -0.15),
            child: _MapHideTab(
              key: const ValueKey('map-immersive-toggle'),
              immersive: _isImmersive,
              onTap: _toggleImmersive,
            ),
          ),
        ),
        if (!_isImmersive)
          Positioned(
            right: 12,
            bottom: 16,
            child: _MapToolRail(
              onZoomIn: () => _zoomBy(1),
              onZoomOut: () => _zoomBy(-1),
              onLayers: _showMapLayersSheet,
              onLocate: _centerOnSelectedLocation,
              onLocateWithGps: _locateMe,
            ),
          ),
        if (!_isImmersive && _weatherLayer == _WeatherLayer.wind)
          Positioned(
            left: 12,
            bottom: 40,
            child: _WindLegend(isImperial: widget.isImperial),
          ),
        if (!_isImmersive &&
            _weatherLayer == _WeatherLayer.wind &&
            _selectedWindPoint != null)
          Positioned(
            left: 12,
            right: 76,
            bottom: 120,
            child: _WindDetailCard(
              point: _selectedWindPoint!,
              isImperial: widget.isImperial,
              onClose: () => setState(() => _selectedWindPoint = null),
            ),
          ),
        if (!_isImmersive && (_showTyphoonTracks || _showParBoundary))
          Positioned(
            left: 12,
            bottom: _weatherLayer == _WeatherLayer.wind
                ? (_selectedWindPoint != null ? 246 : 112)
                : 40,
            child: _TyphoonLegend(
              tracks: _stormTracks,
              showTracks: _showTyphoonTracks,
              showPar: _showParBoundary,
              loading: _isTyphoonLoading || _isTyphoonPreviewLoading,
              usingCache: _typhoonUsingCache,
              previewing: _typhoonPreviewing,
              error: _typhoonError,
              updatedAt: _typhoonUpdatedAt,
              frame: typhoonFrame,
              playbackAvailable: typhoonPlayback != null,
              playing: _typhoonPlaying,
              speed: _typhoonPlaybackSpeed,
              playhead: typhoonPlayhead,
              onTogglePlay: _toggleTyphoonPlayback,
              onCycleSpeed: _cycleTyphoonPlaybackSpeed,
              onSeek: _seekTyphoonPlayback,
              onSeekStart: _stopTyphoonPlayback,
              onResetPlayback: _resetTyphoonPlayback,
              onPreview: _loadRecentTyphoonPreview,
              onRefresh: () => _loadTyphoonTracks(force: true),
              onRetry: () => _loadTyphoonTracks(force: true),
              onClose: () {
                _cancelTyphoonPlaybackTimer();
                final wasPreview = _typhoonPreviewing;
                setState(() {
                  _showTyphoonTracks = false;
                  _showParBoundary = false;
                  _typhoonPlaying = false;
                  _typhoonPlayhead = null;
                  _typhoonPreviewing = false;
                  _isTyphoonPreviewLoading = false;
                  if (wasPreview) _stormTracks = [];
                });
                _typhoonRefreshTimer?.cancel();
              },
            ),
          ),
      ],
    );
  }

  TyphoonPlayback? get _typhoonPrimaryPlayback {
    if (_stormTracks.isEmpty) return null;
    final playback = TyphoonPlayback(_stormTracks.first);
    return playback.canPlay ? playback : null;
  }

  double get _typhoonPlayheadValue =>
      _typhoonPlayhead ?? _typhoonPrimaryPlayback?.currentFraction ?? 1;

  TyphoonPlaybackFrame? get _typhoonPlaybackFrame =>
      _typhoonPrimaryPlayback?.frameAt(_typhoonPlayheadValue);

  List<Polyline> get _typhoonPastPolylines => [
    for (final track in _stormTracks)
      if (track.observed.length >= 2)
        Polyline(
          points: track.observed.map((point) => point.location).toList(),
          color: _typhoonPastColor,
          strokeWidth: 3.4,
          borderColor: Colors.white.withValues(alpha: 0.75),
          borderStrokeWidth: 1,
        ),
  ];

  List<Polyline> get _typhoonForecastPolylines => [
    for (final track in _stormTracks)
      if (track.forecast.isNotEmpty)
        Polyline(
          points: track.forecastLine,
          color: _typhoonForecastColor,
          strokeWidth: 3,
          borderColor: Colors.white.withValues(alpha: 0.8),
          borderStrokeWidth: 1,
          pattern: StrokePattern.dashed(segments: const [9, 6]),
        ),
  ];

  List<Marker> get _typhoonMarkers {
    final markers = <Marker>[];
    for (final track in _stormTracks) {
      final playhead = _typhoonPlaybackFrame;
      if (identical(track, _stormTracks.first) &&
          playhead != null &&
          (_typhoonPlaying || _typhoonPlayhead != null)) {
        final color = playhead.isForecast
            ? _typhoonForecastColor
            : _typhoonPastColor;
        markers.add(
          Marker(
            point: playhead.location,
            width: 46,
            height: 46,
            child: IgnorePointer(
              child: Center(
                child: Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.24),
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.92),
                      width: 2,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: color.withValues(alpha: 0.45),
                        blurRadius: 10,
                      ),
                    ],
                  ),
                  child: Center(
                    child: Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        color: color,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      }

      final current = track.currentPoint;
      if (current != null) {
        final color = _stormCategoryColor(current.category);
        markers.add(
          Marker(
            point: current.location,
            width: 160,
            height: 76,
            alignment: Alignment.topCenter,
            child: IgnorePointer(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: color,
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 2),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.25),
                          blurRadius: 8,
                          offset: const Offset(0, 3),
                        ),
                      ],
                    ),
                    child: const Icon(
                      Icons.cyclone_rounded,
                      color: Colors.white,
                      size: 24,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.68),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      '${track.name} · ${_phShortDateTime(current.time)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 9,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      }

      DateTime? lastPastLabelTime;
      for (final point in track.observed) {
        if (point.isCurrent) continue;
        final labelled =
            lastPastLabelTime == null ||
            point.time.difference(lastPastLabelTime).inHours >= 24;
        if (labelled) lastPastLabelTime = point.time;
        markers.add(
          Marker(
            point: point.location,
            width: labelled ? 68 : 18,
            height: labelled ? 32 : 18,
            alignment: labelled ? Alignment.bottomCenter : Alignment.center,
            child: IgnorePointer(
              child: labelled
                  ? Column(
                      mainAxisSize: MainAxisSize.min,
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        Text(
                          _phShortDateTime(point.time),
                          maxLines: 1,
                          style: const TextStyle(
                            color: _typhoonPastColor,
                            fontSize: 9,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        Container(
                          width: 11,
                          height: 11,
                          decoration: BoxDecoration(
                            color: _typhoonPastColor,
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: Colors.white,
                              width: 1.5,
                            ),
                          ),
                        ),
                      ],
                    )
                  : Center(
                      child: Container(
                        width: 9,
                        height: 9,
                        decoration: BoxDecoration(
                          color: _typhoonPastColor,
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 1.5),
                        ),
                      ),
                    ),
            ),
          ),
        );
      }

      final currentTime = track.currentPoint?.time;
      for (final point in track.forecast) {
        final leadHours = currentTime == null
            ? null
            : point.time.difference(currentTime).inHours;
        final labelled =
            leadHours != null &&
            leadHours > 0 &&
            leadHours <= 120 &&
            leadHours % 24 == 0;
        markers.add(
          Marker(
            point: point.location,
            width: labelled ? 48 : 18,
            height: labelled ? 32 : 18,
            child: IgnorePointer(
              child: Center(
                child: labelled
                    ? Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 11,
                            height: 11,
                            decoration: BoxDecoration(
                              color: _typhoonForecastColor,
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: Colors.white,
                                width: 1.5,
                              ),
                            ),
                          ),
                          Text(
                            '${leadHours}h',
                            style: const TextStyle(
                              color: _typhoonForecastColor,
                              fontSize: 9,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ],
                      )
                    : Container(
                        width: 9,
                        height: 9,
                        decoration: BoxDecoration(
                          color: _typhoonForecastColor,
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 1.5),
                        ),
                      ),
              ),
            ),
          ),
        );
      }
    }
    return markers;
  }

  String get _loadingMessage => switch (_weatherLayer) {
    _WeatherLayer.radar => 'Fetching latest available radar frame…',
    _WeatherLayer.rain => 'Refreshing rain model · auto every 15m',
    _WeatherLayer.wind => 'Refreshing wind model · auto every 15m',
    _WeatherLayer.satellite => 'Loading satellite imagery…',
  };

  String get _weatherLayerDescription => switch (_weatherLayer) {
    _WeatherLayer.radar => 'Latest available precipitation radar · RainViewer',
    _WeatherLayer.rain =>
      _weatherPoints.isNotEmpty &&
              _weatherPoints.every((point) => point.precipitation == 0)
          ? 'No rain forecast · Open-Meteo · ${_updateDescription()}'
          : 'Rain estimate · mm · Open-Meteo · ${_updateDescription()}',
    _WeatherLayer.wind =>
      'Wind estimate · ${widget.isImperial ? 'mph' : 'km/h'} · Open-Meteo · ${_updateDescription()}',
    _WeatherLayer.satellite => 'Satellite imagery · Esri',
  };

  String _updateDescription() {
    final updatedAt = _lastDataUpdatedAt;
    final interval = _weatherLayer == _WeatherLayer.radar
        ? _radarRefreshInterval
        : _forecastRefreshInterval;
    final intervalMinutes = interval.inMinutes;
    if (updatedAt == null) return 'auto every ${intervalMinutes}m';
    final hour = updatedAt.hour.toString().padLeft(2, '0');
    final minute = updatedAt.minute.toString().padLeft(2, '0');
    return 'updated $hour:$minute · auto every ${intervalMinutes}m';
  }

  String _weatherLayerName(_WeatherLayer layer) => switch (layer) {
    _WeatherLayer.radar => 'Radar',
    _WeatherLayer.rain => 'Rain',
    _WeatherLayer.wind => 'Wind',
    _WeatherLayer.satellite => 'Satellite',
  };

  IconData _weatherLayerIcon(_WeatherLayer layer) => switch (layer) {
    _WeatherLayer.radar => Icons.radar_rounded,
    _WeatherLayer.rain => Icons.water_drop_rounded,
    _WeatherLayer.wind => Icons.air_rounded,
    _WeatherLayer.satellite => Icons.satellite_alt_rounded,
  };

  String _weatherOverlaySubtitle(_WeatherLayer layer) => switch (layer) {
    _WeatherLayer.radar => 'Live precipitation radar · RainViewer',
    _WeatherLayer.rain => 'Rain estimate · Open-Meteo',
    _WeatherLayer.wind => 'Wind estimate · Open-Meteo',
    _WeatherLayer.satellite => 'Satellite imagery · Esri',
  };

  void _selectWeatherLayer(_WeatherLayer layer) {
    if (_weatherLayer == layer && !_isLayerLoading && _layerError == null) {
      _loadSelectedWeatherLayer();
      return;
    }

    _autoRefreshTimer?.cancel();
    _weatherRequestGeneration++;
    setState(() {
      _weatherLayer = layer;
      _layerError = null;
      _isLayerLoading = false;
      _lastDataUpdatedAt = null;
      _weatherPoints = [];
      _selectedWindPoint = null;
    });
    _loadSelectedWeatherLayer();
    _scheduleAutoRefresh();
  }

  Future<void> _loadSelectedWeatherLayer() async {
    if (!_isMapActive || !_isAppInForeground || !mounted || _isLayerLoading) {
      return;
    }
    if (_weatherLayer == _WeatherLayer.satellite) {
      setState(() {
        _isLayerLoading = false;
        _layerError = null;
      });
      _autoRefreshTimer?.cancel();
      return;
    }
    if (_weatherLayer == _WeatherLayer.radar) {
      await _loadRadarFrame();
      return;
    }
    await _loadWeatherForecast();
  }

  Future<void> _loadRadarFrame() async {
    final requestGeneration = ++_weatherRequestGeneration;
    setState(() {
      _isLayerLoading = true;
      _layerError = null;
    });

    try {
      final response = await _httpClient
          .get(Uri.https('api.rainviewer.com', '/public/weather-maps.json'))
          .timeout(const Duration(seconds: 12));
      if (response.statusCode != 200) {
        throw http.ClientException(
          'Radar provider returned HTTP ${response.statusCode}.',
        );
      }

      final payload = jsonDecode(response.body);
      if (payload is! Map<String, dynamic> ||
          payload['host'] is! String ||
          payload['radar'] is! Map<String, dynamic>) {
        throw const FormatException('Radar response is incomplete.');
      }
      final host = payload['host'] as String;
      final radar = payload['radar'] as Map<String, dynamic>;
      final frames = radar['past'];
      if (frames is! List || frames.isEmpty || frames.last is! Map) {
        throw const FormatException('No recent radar frames are available.');
      }
      final frame = frames.last as Map;
      final path = frame['path'];
      final frameTime = _readNumber(frame['time']);
      if (path is! String || !path.startsWith('/') || frameTime == null) {
        throw const FormatException('Radar frame path is invalid.');
      }

      if (!mounted || requestGeneration != _weatherRequestGeneration) return;
      setState(() {
        _radarTileUrl = '$host$path/256/{z}/{x}/{y}/2/1_1.png';
        _lastDataUpdatedAt = DateTime.fromMillisecondsSinceEpoch(
          frameTime.round() * 1000,
          isUtc: true,
        ).toLocal();
        _layerError = null;
        _isLayerLoading = false;
      });
    } on http.ClientException {
      _setLayerError(
        requestGeneration,
        'Radar is unavailable right now. Check your connection and retry.',
      );
    } on FormatException {
      _setLayerError(
        requestGeneration,
        'The radar provider returned invalid data. Please retry.',
      );
    } on TimeoutException {
      _setLayerError(
        requestGeneration,
        'Radar request timed out. Check your connection and retry.',
      );
    }
  }

  Future<void> _loadWeatherForecast() async {
    if (_isLayerLoading || !_isMapActive || !_isAppInForeground || !mounted) {
      return;
    }
    final requestGeneration = ++_weatherRequestGeneration;
    setState(() {
      _isLayerLoading = true;
      _layerError = null;
    });

    try {
      final bounds = _mapController.camera.visibleBounds;
      const gridSize = 4;
      final coordinates = <LatLng>[
        for (var row = 0; row < gridSize; row++)
          for (var column = 0; column < gridSize; column++)
            LatLng(
              bounds.south +
                  (bounds.north - bounds.south) * (row + 0.5) / gridSize,
              bounds.west +
                  (bounds.east - bounds.west) * (column + 0.5) / gridSize,
            ),
      ];
      final uri = Uri.https('api.open-meteo.com', '/v1/forecast', {
        'latitude': coordinates.map((point) => point.latitude).join(','),
        'longitude': coordinates.map((point) => point.longitude).join(','),
        'current':
            'precipitation,wind_speed_10m,wind_direction_10m,wind_gusts_10m',
        'forecast_days': '1',
        'timeformat': 'unixtime',
      });
      final response = await _httpClient
          .get(uri)
          .timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) {
        throw http.ClientException(
          'Weather provider returned HTTP ${response.statusCode}.',
        );
      }

      final decoded = jsonDecode(response.body);
      final entries = decoded is List ? decoded : [decoded];
      final points = <_WeatherPoint>[];
      DateTime? dataUpdatedAt;
      for (
        var index = 0;
        index < entries.length && index < coordinates.length;
        index++
      ) {
        final entry = entries[index];
        if (entry is! Map<String, dynamic>) continue;
        final current = entry['current'];
        if (current is! Map<String, dynamic>) continue;
        final precipitation = _readNumber(current['precipitation']);
        final windSpeed = _readNumber(current['wind_speed_10m']);
        final windDirection = _readNumber(current['wind_direction_10m']);
        final windGust = _readNumber(current['wind_gusts_10m']);
        final time = _readNumber(current['time']);
        if (precipitation == null ||
            windSpeed == null ||
            windDirection == null ||
            time == null) {
          continue;
        }
        dataUpdatedAt ??= DateTime.fromMillisecondsSinceEpoch(
          time.round() * 1000,
          isUtc: true,
        ).toLocal();
        points.add(
          _WeatherPoint(
            location: coordinates[index],
            precipitation: precipitation,
            windSpeed: windSpeed,
            windDirection: windDirection,
            windGust: windGust ?? windSpeed,
          ),
        );
      }
      if (points.isEmpty) {
        throw const FormatException(
          'Weather response contains no current data.',
        );
      }

      if (!mounted || requestGeneration != _weatherRequestGeneration) return;
      setState(() {
        _weatherPoints = points;
        _lastDataUpdatedAt = dataUpdatedAt;
        _layerError = null;
        _isLayerLoading = false;
        _selectedWindPoint = null;
      });
    } on http.ClientException {
      _setLayerError(
        requestGeneration,
        'Weather data is unavailable. Check your connection and retry.',
      );
    } on FormatException {
      _setLayerError(
        requestGeneration,
        'The weather provider returned invalid data. Please retry.',
      );
    } on TimeoutException {
      _setLayerError(
        requestGeneration,
        'Weather request timed out. Check your connection and retry.',
      );
    } finally {
      if (requestGeneration == _weatherRequestGeneration &&
          _weatherRefreshPending) {
        _weatherRefreshPending = false;
        if (_isMapActive &&
            _isAppInForeground &&
            (_weatherLayer == _WeatherLayer.rain ||
                _weatherLayer == _WeatherLayer.wind)) {
          _mapMoveDebounceTimer?.cancel();
          _mapMoveDebounceTimer = Timer(Duration.zero, () {
            if (mounted) _loadWeatherForecast();
          });
        }
      }
    }
  }

  double? _readNumber(Object? value) => value is num ? value.toDouble() : null;

  void _setLayerError(int requestGeneration, String message) {
    if (!mounted || requestGeneration != _weatherRequestGeneration) return;
    setState(() {
      _isLayerLoading = false;
      _layerError = message;
    });
  }

  void _onMapPositionChanged(MapCamera camera, bool hasGesture) {
    if (!hasGesture ||
        !_isMapActive ||
        (_weatherLayer != _WeatherLayer.rain &&
            _weatherLayer != _WeatherLayer.wind)) {
      return;
    }
    _mapMoveDebounceTimer?.cancel();
    _mapMoveDebounceTimer = Timer(const Duration(milliseconds: 900), () {
      if (mounted && _isMapActive && _isAppInForeground) {
        _requestForecastForViewport();
      }
    });
  }

  void _requestForecastForViewport() {
    if (_isLayerLoading) {
      _weatherRefreshPending = true;
      return;
    }
    _loadWeatherForecast();
  }

  void _scheduleAutoRefresh() {
    _autoRefreshTimer?.cancel();
    if (!_isMapActive ||
        !_isAppInForeground ||
        _weatherLayer == _WeatherLayer.satellite) {
      return;
    }
    final interval = _weatherLayer == _WeatherLayer.radar
        ? _radarRefreshInterval
        : _forecastRefreshInterval;
    _autoRefreshTimer = Timer.periodic(interval, (_) {
      if (!_isLayerLoading) _loadSelectedWeatherLayer();
    });
  }

  List<CircleMarker> get _rainCircles => _weatherPoints
      .where((point) => point.precipitation > 0)
      .map(
        (point) => CircleMarker(
          point: point.location,
          radius: 9000,
          useRadiusInMeter: true,
          color: _rainColor(point.precipitation).withValues(alpha: 0.48),
          borderColor: _rainColor(point.precipitation).withValues(alpha: 0.75),
          borderStrokeWidth: 1,
        ),
      )
      .toList();

  List<Marker> get _windMarkers => _weatherPoints.map((point) {
    final color = _windSpeedColor(point.windSpeed);
    final arrowSize = _windArrowSize(point.windSpeed);
    final showLabel = point.windSpeed >= _windLabelThresholdKmh;
    final selected =
        _selectedWindPoint != null &&
        _selectedWindPoint!.location.latitude == point.location.latitude &&
        _selectedWindPoint!.location.longitude == point.location.longitude;
    return Marker(
      point: point.location,
      width: 56,
      height: 54,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => setState(() => _selectedWindPoint = point),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Transform.rotate(
                angle: (point.windDirection + 180) * math.pi / 180,
                child: Icon(
                  Icons.navigation_rounded,
                  size: arrowSize,
                  color: color,
                  shadows: const [
                    Shadow(color: Colors.white, blurRadius: 5),
                    Shadow(
                      color: Colors.black26,
                      blurRadius: 2,
                      offset: Offset(0, 1),
                    ),
                  ],
                ),
              ),
              if (showLabel)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 5,
                    vertical: 1,
                  ),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: selected ? 1 : 0.92),
                    borderRadius: BorderRadius.circular(7),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.85),
                      width: selected ? 1.4 : 0.8,
                    ),
                    boxShadow: const [
                      BoxShadow(
                        color: Colors.black26,
                        blurRadius: 3,
                        offset: Offset(0, 1),
                      ),
                    ],
                  ),
                  child: Text(
                    '${_displayWindSpeed(point.windSpeed, widget.isImperial).round()}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 9,
                      fontWeight: FontWeight.w800,
                      height: 1.1,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }).toList();

  Color _rainColor(double precipitation) {
    if (precipitation < 1) return const Color(0xFF5ABCEB);
    if (precipitation < 3) return const Color(0xFF348BDA);
    if (precipitation < 7) return const Color(0xFF7657D5);
    return const Color(0xFFD84372);
  }

  void _centerOnSelectedLocation() {
    _mapController.move(_selectedLocation, 10);
  }

  String _tileUrlFor(_MapType mapType, _WeatherLayer weatherLayer) {
    if (weatherLayer == _WeatherLayer.satellite) {
      return 'https://server.arcgisonline.com/ArcGIS/rest/services/'
          'World_Imagery/MapServer/tile/{z}/{y}/{x}';
    }
    return switch (mapType) {
      _MapType.standard => 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
      _MapType.humanitarian =>
        'https://tile.openstreetmap.fr/hot/{z}/{x}/{y}.png',
      _MapType.topographic => 'https://tile.opentopomap.org/{z}/{x}/{y}.png',
    };
  }

  String _attributionFor(_MapType mapType) {
    if (_weatherLayer == _WeatherLayer.satellite) {
      return 'Imagery © Esri, Maxar, Earthstar Geographics';
    }
    final mapAttribution = switch (mapType) {
      _MapType.standard => '© OpenStreetMap contributors',
      _MapType.humanitarian => '© OpenStreetMap contributors, HOT',
      _MapType.topographic =>
        '© OpenStreetMap contributors, SRTM | © OpenTopoMap',
    };
    return switch (_weatherLayer) {
      _WeatherLayer.radar => '$mapAttribution | Radar © RainViewer',
      _WeatherLayer.rain ||
      _WeatherLayer.wind => '$mapAttribution | Weather © Open-Meteo',
      _WeatherLayer.satellite => mapAttribution,
    };
  }

  void _showMapLayersSheet() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: _surfaceColor(context),
      barrierColor: Colors.black.withValues(alpha: 0.45),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      clipBehavior: Clip.antiAlias,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheetState) => SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * 0.82,
            ),
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 22),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Center(
                    child: Container(
                      width: 38,
                      height: 4,
                      decoration: BoxDecoration(
                        color: _isDarkMode(context)
                            ? const Color(0xFF526472)
                            : const Color(0xFFD4DEE7),
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                  ),
                  const SizedBox(height: 19),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: 46,
                        height: 46,
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [
                              _blue.withValues(alpha: 0.18),
                              _blue.withValues(alpha: 0.08),
                            ],
                          ),
                          borderRadius: BorderRadius.circular(15),
                        ),
                        child: const Icon(
                          Icons.layers_rounded,
                          color: _blue,
                          size: 23,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Layers',
                              style: TextStyle(
                                color: _isDarkMode(context) ? _darkInk : _navy,
                                fontSize: 20,
                                fontWeight: FontWeight.w800,
                                letterSpacing: -0.3,
                              ),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              'Choose a weather overlay and base map for your weather view.',
                              style: TextStyle(
                                color: _secondaryTextColor(context),
                                fontSize: 11,
                              ),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        key: const ValueKey('close-map-layers'),
                        tooltip: 'Close layers',
                        onPressed: () => Navigator.pop(context),
                        icon: Icon(
                          Icons.close_rounded,
                          color: _secondaryTextColor(context),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  Row(
                    children: [
                      Text(
                        'WEATHER OVERLAY',
                        style: TextStyle(
                          color: _secondaryTextColor(context),
                          fontSize: 10,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 1.1,
                        ),
                      ),
                      const Spacer(),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 9,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: _blue.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          '${_weatherLayerName(_weatherLayer)} selected',
                          style: const TextStyle(
                            color: _blue,
                            fontSize: 9,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  for (final layer in _WeatherLayer.values)
                    _WeatherOverlayOption(
                      key: ValueKey(
                        'weather-overlay-${_weatherLayerName(layer)}',
                      ),
                      title: _weatherLayerName(layer),
                      subtitle: _weatherOverlaySubtitle(layer),
                      icon: _weatherLayerIcon(layer),
                      selected: _weatherLayer == layer,
                      onTap: () {
                        Navigator.pop(context);
                        _selectWeatherLayer(layer);
                      },
                    ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Text(
                        'BASE MAP',
                        style: TextStyle(
                          color: _secondaryTextColor(context),
                          fontSize: 10,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 1.1,
                        ),
                      ),
                      const Spacer(),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 9,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: _blue.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          '${_mapTypeName(_mapType)} selected',
                          style: const TextStyle(
                            color: _blue,
                            fontSize: 9,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  for (final mapType in _MapType.values)
                    _MapTypeOption(
                      key: ValueKey('map-type-${_mapTypeName(mapType)}'),
                      title: _mapTypeName(mapType),
                      subtitle: _mapTypeDescription(mapType),
                      icon: _mapTypeIcon(mapType),
                      mapType: mapType,
                      selected: _mapType == mapType,
                      onTap: () {
                        setState(() {
                          _mapType = mapType;
                          if (_weatherLayer == _WeatherLayer.satellite) {
                            _weatherLayer = _WeatherLayer.radar;
                          }
                        });
                        if (_isMapActive) _loadSelectedWeatherLayer();
                        Navigator.pop(context);
                      },
                    ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Text(
                        'TYPHOON TRACK',
                        style: TextStyle(
                          color: _secondaryTextColor(context),
                          fontSize: 10,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 1.1,
                        ),
                      ),
                      const Spacer(),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 9,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: _typhoonForecastColor.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: const Text(
                          'GDACS / JTWC',
                          style: TextStyle(
                            color: _typhoonForecastColor,
                            fontSize: 9,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  _TyphoonToggleOption(
                    key: const ValueKey('typhoon-tracks-toggle'),
                    icon: Icons.cyclone_rounded,
                    title: 'Typhoon track & forecast',
                    subtitle: 'Observed path plus the latest JTWC forecast near the PAR',
                    value: _showTyphoonTracks,
                    onChanged: (value) {
                      _setTyphoonTracksEnabled(value);
                      setSheetState(() {});
                    },
                  ),
                  _TyphoonToggleOption(
                    key: const ValueKey('par-boundary-toggle'),
                    icon: Icons.public_rounded,
                    title: 'PAR boundary',
                    subtitle:
                        'Show the PAGASA Philippine Area of Responsibility',
                    value: _showParBoundary,
                    onChanged: (value) {
                      _setParBoundaryEnabled(value);
                      setSheetState(() {});
                    },
                  ),
                  const SizedBox(height: 9),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(15),
                    decoration: BoxDecoration(
                      color: _isDarkMode(context)
                          ? const Color(0xFF202F3A)
                          : const Color(0xFFF1F7FC),
                      borderRadius: BorderRadius.circular(19),
                      border: Border.all(
                        color: _isDarkMode(context)
                            ? const Color(0xFF344451)
                            : const Color(0xFFE2ECF4),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Container(
                              width: 34,
                              height: 34,
                              decoration: BoxDecoration(
                                color: _blue.withValues(alpha: 0.12),
                                borderRadius: BorderRadius.circular(11),
                              ),
                              child: const Icon(
                                Icons.cloud_queue_rounded,
                                color: _blue,
                                size: 19,
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'About the Banog weather map',
                                    style: TextStyle(
                                      color: _primaryTextColor(context),
                                      fontSize: 12,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    '${_weatherLayerName(_weatherLayer)} · ${_weatherLayerSource(_weatherLayer)}',
                                    style: TextStyle(
                                      color: _secondaryTextColor(context),
                                      fontSize: 10,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 11),
                        Divider(
                          height: 1,
                          color: _isDarkMode(context)
                              ? const Color(0xFF344451)
                              : const Color(0xFFDCE7F0),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          'Radar imagery is supplied by RainViewer. Rain and wind are forecast-model estimates that refresh every 15 minutes while the map is open. They are not ground-station measurements or official warnings. Tap a wind arrow to see its speed, gusts, and direction.',
                          style: TextStyle(
                            color: _secondaryTextColor(context),
                            fontSize: 10,
                            height: 1.45,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Icon(
                        Icons.info_outline_rounded,
                        size: 14,
                        color: _secondaryTextColor(context),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          'Downloaded maps work offline. Weather layers and place search still need a connection.',
                          style: TextStyle(
                            color: _secondaryTextColor(context),
                            fontSize: 9,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  String _weatherLayerSource(_WeatherLayer layer) => switch (layer) {
    _WeatherLayer.radar => 'RainViewer',
    _WeatherLayer.rain || _WeatherLayer.wind => 'Open-Meteo',
    _WeatherLayer.satellite => 'Esri',
  };

  String _mapTypeName(_MapType mapType) => switch (mapType) {
    _MapType.standard => 'Standard',
    _MapType.humanitarian => 'Humanitarian',
    _MapType.topographic => 'Topographic',
  };

  String _mapTypeDescription(_MapType mapType) => switch (mapType) {
    _MapType.standard => 'Roads, places, and boundaries',
    _MapType.humanitarian => 'High-contrast community map',
    _MapType.topographic => 'Terrain and elevation details',
  };

  IconData _mapTypeIcon(_MapType mapType) => switch (mapType) {
    _MapType.standard => Icons.map_outlined,
    _MapType.humanitarian => Icons.diversity_3_rounded,
    _MapType.topographic => Icons.terrain_rounded,
  };

  void _zoomBy(double amount) {
    final camera = _mapController.camera;
    final zoom = (camera.zoom + amount).clamp(4.0, 19.0).toDouble();
    _mapController.move(camera.center, zoom);
  }

  void _scheduleSearch(String value) {
    _searchDebounceTimer?.cancel();
    final searchTerm = value.trim();
    if (searchTerm.length < 3) return;
    _searchDebounceTimer = Timer(const Duration(milliseconds: 900), () {
      if (mounted) _searchLocation(searchTerm);
    });
  }

  Future<void> _searchLocation(String query) async {
    final searchTerm = query.trim();
    if (searchTerm.isEmpty) return;

    final generation = ++_searchGeneration;
    setState(() => _isSearching = true);
    try {
      final uri = Uri.https('nominatim.openstreetmap.org', '/search', {
        'q': searchTerm,
        'format': 'jsonv2',
        'limit': '1',
        'countrycodes': 'ph',
        'addressdetails': '1',
        'polygon_geojson': '1',
        'polygon_threshold': '0.0005',
      });
      final response = await _httpClient
          .get(
            uri,
            headers: const {
              'User-Agent': 'BanogWeatherApp/1.0 (mobile weather app)',
            },
          )
          .timeout(const Duration(seconds: 12));

      if (!mounted || generation != _searchGeneration) return;

      if (response.statusCode == 429) {
        _showSearchMessage('Search is busy. Please try again in a moment.');
        return;
      }
      if (response.statusCode != 200) {
        _showSearchMessage('Location search failed. Please try again.');
        return;
      }

      final decoded = jsonDecode(response.body);
      if (decoded is! List || decoded.isEmpty) {
        _showSearchMessage('No matching place found in the Philippines.');
        return;
      }

      final results = decoded.whereType<Map<String, dynamic>>().toList();
      if (results.isEmpty) {
        _showSearchMessage('No matching place found in the Philippines.');
        return;
      }

      final result = results.first;
      final latitude = double.tryParse(result['lat'] as String? ?? '');
      final longitude = double.tryParse(result['lon'] as String? ?? '');
      if (latitude == null || longitude == null) {
        _showSearchMessage('The location returned an invalid map position.');
        return;
      }

      final location = LatLng(latitude, longitude);
      final displayName = result['display_name'] as String?;
      final label =
          result['name'] as String? ??
          (displayName != null && displayName.trim().isNotEmpty
              ? displayName.split(',').first.trim()
              : searchTerm);

      final datasetPolygons = await _lookupBoundaryPolygons(
        name: label,
        displayName: displayName,
        latitude: latitude,
        longitude: longitude,
        addressType: result['addresstype'] as String?,
      );
      if (!mounted || generation != _searchGeneration) return;

      final selectedPolygons =
          datasetPolygons ?? _polygonsFromGeoJson(result['geojson']);
      final bounds = _boundsForPolygons(selectedPolygons);
      setState(() {
        _selectedLocation = location;
        _locationLabel = label;
        _highlightPolygons = selectedPolygons;
      });
      if (bounds != null) {
        _mapController.fitCamera(
          CameraFit.bounds(
            bounds: bounds,
            padding: const EdgeInsets.fromLTRB(48, 260, 48, 120),
            maxZoom: 15,
          ),
        );
      } else {
        _mapController.move(location, 12);
      }
      _showSearchMessage(
        selectedPolygons.isEmpty
            ? 'No boundary found for $label. Showing pin.'
            : 'Highlighted boundary for $label.',
      );
      if (_weatherLayer == _WeatherLayer.rain ||
          _weatherLayer == _WeatherLayer.wind) {
        _requestForecastForViewport();
      }
    } on http.ClientException {
      if (mounted && generation == _searchGeneration) {
        _showSearchMessage('Could not connect to location search.');
      }
    } on FormatException {
      if (mounted && generation == _searchGeneration) {
        _showSearchMessage('Location search returned an invalid response.');
      }
    } on TimeoutException {
      if (mounted && generation == _searchGeneration) {
        _showSearchMessage('Location search timed out. Please try again.');
      }
    } finally {
      if (mounted && generation == _searchGeneration) {
        setState(() => _isSearching = false);
      }
    }
  }

  List<String> _boundaryAssetPathsFor(String? addressType) {
    final type = (addressType ?? '').toLowerCase();
    if (type == 'region') {
      return const [_phlAdm1Asset, _phlAdm2Asset, _phlAdm3Asset];
    }
    if (type == 'state' || type == 'province' || type == 'county') {
      return const [_phlAdm2Asset, _phlAdm1Asset, _phlAdm3Asset];
    }
    return const [_phlAdm3Asset, _phlAdm2Asset, _phlAdm1Asset];
  }

  Future<List<Polygon>?> _lookupBoundaryPolygons({
    required String name,
    required String? displayName,
    required double latitude,
    required double longitude,
    required String? addressType,
  }) async {
    final candidates = <String>{
      _normalizeBoundaryName(name),
      if (displayName != null && displayName.trim().isNotEmpty)
        _normalizeBoundaryName(displayName.split(',').first),
    }..removeWhere((value) => value.isEmpty);
    if (candidates.isEmpty) return null;

    try {
      for (final asset in _boundaryAssetPathsFor(addressType)) {
        final raw = _boundaryAssetCache[asset] ??= await rootBundle.loadString(
          asset,
        );
        final arguments = <Object?>[
          raw,
          candidates.toList(),
          latitude,
          longitude,
        ];
        final polygons = widget.useIsolateForBoundaryLookup
            ? await compute(_findBoundaryInGeoJson, arguments)
            : _findBoundaryInGeoJson(arguments);
        if (polygons != null && polygons.isNotEmpty) {
          return _polygonsFromBoundaryResult(polygons);
        }
      }
    } catch (error) {
      debugPrint('Boundary dataset lookup failed: $error');
      _showSearchMessage(
        'Local boundaries are unavailable. Showing search-result outline if available.',
      );
      return null;
    }
    return null;
  }

  List<Polygon> _polygonsFromBoundaryResult(Object? result) {
    if (result is! List) return const [];
    final polygons = <Polygon>[];
    for (final boundary in result) {
      if (boundary is! List || boundary.isEmpty) continue;
      final rings = <Object?>[boundary.first];
      if (boundary.length > 1 && boundary[1] is List) {
        rings.addAll(boundary[1] as List);
      }
      final polygon = _polygonFromCoordinates(rings);
      if (polygon != null) polygons.add(polygon);
    }
    return polygons;
  }

  List<Polygon> _polygonsFromGeoJson(Object? geojson) {
    if (geojson is! Map<String, dynamic>) return const [];
    final type = geojson['type'];
    final coordinates = geojson['coordinates'];
    switch (type) {
      case 'Polygon':
        final polygon = _polygonFromCoordinates(coordinates);
        return polygon == null ? const [] : [polygon];
      case 'MultiPolygon':
        if (coordinates is! List) return const [];
        final polygons = <Polygon>[];
        for (final item in coordinates) {
          final polygon = _polygonFromCoordinates(item);
          if (polygon != null) polygons.add(polygon);
        }
        return polygons;
    }
    return const [];
  }

  Polygon? _polygonFromCoordinates(Object? coordinates) {
    if (coordinates is! List || coordinates.isEmpty) return null;
    final outer = _ringToLatLng(coordinates.first);
    if (outer.length < 3) return null;
    final holes = <List<LatLng>>[];
    for (final ring in coordinates.skip(1)) {
      final hole = _ringToLatLng(ring);
      if (hole.length >= 3) holes.add(hole);
    }
    return Polygon(
      points: outer,
      holePointsList: holes.isEmpty ? null : holes,
      color: _blue.withValues(alpha: 0.28),
      borderColor: _blue,
      borderStrokeWidth: 3.5,
      pattern: StrokePattern.dashed(segments: [14, 9]),
    );
  }

  List<LatLng> _ringToLatLng(Object? ring) {
    if (ring is! List) return const [];
    final points = <LatLng>[];
    for (final coordinate in ring) {
      if (coordinate is! List || coordinate.length < 2) continue;
      final longitude = coordinate[0];
      final latitude = coordinate[1];
      if (longitude is! num || latitude is! num) continue;
      final lat = latitude.toDouble();
      final lon = longitude.toDouble();
      if (lat < -90 || lat > 90 || lon < -180 || lon > 180) continue;
      points.add(LatLng(lat, lon));
    }
    return points;
  }

  LatLngBounds? _boundsForPolygons(List<Polygon> polygons) {
    final points = <LatLng>[];
    for (final polygon in polygons) {
      points.addAll(polygon.points);
    }
    if (points.isEmpty) return null;
    return LatLngBounds.fromPoints(points);
  }

  void _clearSearchHighlight() {
    if (_highlightPolygons.isEmpty) return;
    setState(() => _highlightPolygons = []);
  }

  void _showSearchMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }
}

class _MapToolRail extends StatelessWidget {
  const _MapToolRail({
    required this.onZoomIn,
    required this.onZoomOut,
    required this.onLayers,
    required this.onLocate,
    required this.onLocateWithGps,
  });

  final VoidCallback onZoomIn;
  final VoidCallback onZoomOut;
  final VoidCallback onLayers;
  final VoidCallback onLocate;
  final VoidCallback onLocateWithGps;

  @override
  Widget build(BuildContext context) {
    final dividerColor = _isDarkMode(context)
        ? Colors.white.withValues(alpha: 0.12)
        : const Color(0xFFE3ECF4);
    return Material(
      color: _surfaceColor(context),
      elevation: 4,
      borderRadius: BorderRadius.circular(26),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _railButton(
              icon: Icons.add_rounded,
              label: 'Zoom in',
              onPressed: onZoomIn,
            ),
            Container(width: 22, height: 1, color: dividerColor),
            _railButton(
              icon: Icons.remove_rounded,
              label: 'Zoom out',
              onPressed: onZoomOut,
            ),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Container(width: 26, height: 1, color: dividerColor),
            ),
            _railButton(
              icon: Icons.layers_rounded,
              label: 'Layers',
              onPressed: onLayers,
            ),
            GestureDetector(
              onLongPress: onLocateWithGps,
              child: IconButton(
                tooltip: 'Center on selected location · hold for GPS',
                onPressed: onLocate,
                icon: const Icon(
                  Icons.my_location_rounded,
                  color: _blue,
                  size: 22,
                ),
                constraints: const BoxConstraints.tightFor(
                  width: 46,
                  height: 44,
                ),
                padding: EdgeInsets.zero,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _railButton({
    required IconData icon,
    required String label,
    required VoidCallback onPressed,
  }) {
    return IconButton(
      tooltip: label,
      onPressed: onPressed,
      icon: Icon(icon, color: _blue, size: 22),
      constraints: const BoxConstraints.tightFor(width: 46, height: 44),
      padding: EdgeInsets.zero,
    );
  }
}

class _MapHideTab extends StatelessWidget {
  const _MapHideTab({super.key, required this.immersive, required this.onTap});

  final bool immersive;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: immersive ? 'Show map controls' : 'Hide map controls',
      child: Material(
        color: _surfaceColor(context).withValues(alpha: 0.95),
        elevation: 3,
        borderRadius: const BorderRadius.horizontal(left: Radius.circular(14)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(3, 12, 1, 12),
            child: Icon(
              immersive
                  ? Icons.visibility_rounded
                  : Icons.visibility_off_rounded,
              color: _blue,
              size: 18,
            ),
          ),
        ),
      ),
    );
  }
}

class _WeatherOverlayChip extends StatelessWidget {
  const _WeatherOverlayChip({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: _blue.withValues(alpha: 0.1),
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 6, 8, 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: _blue, size: 16),
              const SizedBox(width: 6),
              Text(
                label,
                style: const TextStyle(
                  color: _blue,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(width: 2),
              const Icon(Icons.expand_more_rounded, color: _blue, size: 16),
            ],
          ),
        ),
      ),
    );
  }
}

class _WeatherLayerStatus extends StatelessWidget {
  const _WeatherLayerStatus({
    required this.loading,
    required this.message,
    required this.failed,
    this.onRetry,
  });

  final bool loading;
  final String message;
  final bool failed;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Material(
        color: Colors.white.withValues(alpha: 0.96),
        elevation: 2,
        borderRadius: BorderRadius.circular(13),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (loading)
                const Icon(Icons.downloading_rounded, color: _blue, size: 15)
              else
                Icon(
                  failed ? Icons.cloud_off_outlined : Icons.cloud_done_outlined,
                  color: failed ? const Color(0xFFB34343) : _blue,
                  size: 15,
                ),
              const SizedBox(width: 7),
              Flexible(
                child: Text(
                  message,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: _ink,
                    fontSize: 9,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (onRetry != null) ...[
                const SizedBox(width: 5),
                TextButton(
                  onPressed: onRetry,
                  style: TextButton.styleFrom(
                    minimumSize: Size.zero,
                    padding: const EdgeInsets.symmetric(horizontal: 5),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: Text(
                    failed ? 'Retry' : 'Refresh',
                    style: const TextStyle(fontSize: 10),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _MapAttribution extends StatelessWidget {
  const _MapAttribution({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.bottomCenter,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.9),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          text,
          textAlign: TextAlign.center,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: _navy,
            fontSize: 8,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

class _WindLegend extends StatelessWidget {
  const _WindLegend({required this.isImperial});

  final bool isImperial;

  @override
  Widget build(BuildContext context) {
    final unit = isImperial ? 'mph' : 'km/h';
    return Material(
      color: _surfaceColor(context).withValues(alpha: 0.94),
      borderRadius: BorderRadius.circular(14),
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Wind speed · $unit',
              style: TextStyle(
                color: _primaryTextColor(context),
                fontSize: 9,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 5),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _WindLegendItem(color: _windSpeedColor(10), label: 'Calm'),
                const SizedBox(width: 8),
                _WindLegendItem(color: _windSpeedColor(30), label: 'Breezy'),
                const SizedBox(width: 8),
                _WindLegendItem(color: _windSpeedColor(50), label: 'Strong'),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Tap an arrow for details',
              style: TextStyle(
                color: _secondaryTextColor(context),
                fontSize: 8,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _WindLegendItem extends StatelessWidget {
  const _WindLegendItem({required this.color, required this.label});

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 3),
        Text(
          label,
          style: TextStyle(
            color: _secondaryTextColor(context),
            fontSize: 8,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

class _TyphoonLegend extends StatefulWidget {
  const _TyphoonLegend({
    required this.tracks,
    required this.showTracks,
    required this.showPar,
    required this.loading,
    required this.usingCache,
    required this.previewing,
    required this.error,
    required this.updatedAt,
    required this.frame,
    required this.playbackAvailable,
    required this.playing,
    required this.speed,
    required this.playhead,
    required this.onTogglePlay,
    required this.onCycleSpeed,
    required this.onSeek,
    required this.onSeekStart,
    required this.onResetPlayback,
    required this.onPreview,
    required this.onRefresh,
    required this.onRetry,
    required this.onClose,
  });

  final List<StormTrack> tracks;
  final bool showTracks;
  final bool showPar;
  final bool loading;
  final bool usingCache;
  final bool previewing;
  final String? error;
  final DateTime? updatedAt;
  final TyphoonPlaybackFrame? frame;
  final bool playbackAvailable;
  final bool playing;
  final int speed;
  final double playhead;
  final VoidCallback onTogglePlay;
  final VoidCallback onCycleSpeed;
  final ValueChanged<double> onSeek;
  final VoidCallback onSeekStart;
  final VoidCallback onResetPlayback;
  final VoidCallback onPreview;
  final VoidCallback onRefresh;
  final VoidCallback onRetry;
  final VoidCallback onClose;

  @override
  State<_TyphoonLegend> createState() => _TyphoonLegendState();
}

class _TyphoonLegendState extends State<_TyphoonLegend> {
  bool _expanded = true;

  @override
  Widget build(BuildContext context) {
    final updatedAge = widget.updatedAt == null
        ? ''
        : StormTrackService.describeAge(
            DateTime.now().toUtc().difference(widget.updatedAt!.toUtc()),
          );
    if (!_expanded) {
      return Material(
        color: _surfaceColor(context).withValues(alpha: 0.95),
        borderRadius: BorderRadius.circular(14),
        elevation: 2,
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => setState(() => _expanded = true),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.cyclone_rounded,
                  color: _typhoonForecastColor,
                  size: 16,
                ),
                const SizedBox(width: 5),
                Text(
                  widget.previewing ? 'Typhoon replay' : 'Typhoon track',
                  style: TextStyle(
                    color: _primaryTextColor(context),
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const Icon(Icons.expand_less_rounded, color: _blue, size: 16),
              ],
            ),
          ),
        ),
      );
    }

    return Material(
      color: _surfaceColor(context).withValues(alpha: 0.95),
      borderRadius: BorderRadius.circular(14),
      elevation: 3,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 252),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 7, 5, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  const Icon(
                    Icons.cyclone_rounded,
                    color: _typhoonForecastColor,
                    size: 16,
                  ),
                  const SizedBox(width: 5),
                  Expanded(
                    child: Text(
                      widget.previewing ? 'Typhoon replay' : 'Typhoon track',
                      style: TextStyle(
                        color: _primaryTextColor(context),
                        fontSize: 10,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  if (widget.showTracks)
                    InkWell(
                      borderRadius: BorderRadius.circular(8),
                      onTap: widget.loading ? null : widget.onRefresh,
                      child: Padding(
                        padding: const EdgeInsets.all(3),
                        child: widget.loading
                            ? const SizedBox(
                                width: 13,
                                height: 13,
                                child: CircularProgressIndicator(
                                  strokeWidth: 1.6,
                                  color: _blue,
                                ),
                              )
                            : const Icon(
                                Icons.refresh_rounded,
                                color: _blue,
                                size: 16,
                              ),
                      ),
                    ),
                  InkWell(
                    borderRadius: BorderRadius.circular(8),
                    onTap: () => setState(() => _expanded = false),
                    child: const Padding(
                      padding: EdgeInsets.all(3),
                      child: Icon(
                        Icons.expand_more_rounded,
                        color: _blue,
                        size: 17,
                      ),
                    ),
                  ),
                  InkWell(
                    borderRadius: BorderRadius.circular(8),
                    onTap: widget.onClose,
                    child: Padding(
                      padding: const EdgeInsets.all(3),
                      child: Icon(
                        Icons.close_rounded,
                        color: _secondaryTextColor(context),
                        size: 16,
                      ),
                    ),
                  ),
                ],
              ),
              if (widget.showTracks) ...[
                const SizedBox(height: 4),
                const _TyphoonLegendRow(
                  label: 'Past track',
                  sample: _LegendSolidLine(color: _typhoonPastColor),
                ),
                const SizedBox(height: 3),
                const _TyphoonLegendRow(
                  label: 'Forecast',
                  sample: _LegendDashedLine(color: _typhoonForecastColor),
                ),
                const SizedBox(height: 3),
                _TyphoonLegendRow(
                  label: 'Current position',
                  sample: Container(
                    width: 16,
                    height: 16,
                    decoration: const BoxDecoration(
                      color: _typhoonForecastColor,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.cyclone_rounded,
                      color: Colors.white,
                      size: 11,
                    ),
                  ),
                ),
              ],
              if (widget.showPar) ...[
                const SizedBox(height: 3),
                const _TyphoonLegendRow(
                  label: 'PAR boundary',
                  sample: _LegendParBox(),
                ),
              ],
              if (widget.showTracks) ...[
                const SizedBox(height: 6),
                Wrap(
                  spacing: 7,
                  runSpacing: 3,
                  children: [
                    for (final category in StormWindCategory.values)
                      _TyphoonCategoryDot(category: category),
                  ],
                ),
                if (widget.tracks.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  for (final track in widget.tracks.take(3))
                    Padding(
                      padding: const EdgeInsets.only(bottom: 2),
                      child: Row(
                        children: [
                          Container(
                            width: 7,
                            height: 7,
                            decoration: BoxDecoration(
                              color: _stormCategoryColor(
                                track.currentPoint?.category ??
                                    StormWindCategory.tropicalDepression,
                              ),
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              '${track.name} · ${track.currentStatus}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: _primaryTextColor(context),
                                fontSize: 8.5,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          if (track.currentWindKmh != null)
                            Text(
                              '${track.currentWindKmh!.round()} km/h',
                              style: TextStyle(
                                color: _secondaryTextColor(context),
                                fontSize: 8,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                        ],
                      ),
                    ),
                ],
                if (widget.tracks.isNotEmpty &&
                    widget.tracks.first.currentPoint != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 1, bottom: 2),
                    child: Text(
                      '${widget.previewing ? 'Final advisory' : 'Advisory'} '
                      '${widget.tracks.first.currentPoint!.advisoryNumber}'
                      ' · ${_shortDateTime(widget.tracks.first.currentPoint!.time)}',
                      style: TextStyle(
                        color: _secondaryTextColor(context),
                        fontSize: 7.5,
                      ),
                    ),
                  ),
                if (widget.showTracks && widget.playbackAvailable) ...[
                  const SizedBox(height: 3),
                  _TyphoonPlaybackControls(
                    frame: widget.frame,
                    currentTime: widget.tracks.first.currentPoint?.time,
                    playing: widget.playing,
                    speed: widget.speed,
                    playhead: widget.playhead,
                    onTogglePlay: widget.onTogglePlay,
                    onCycleSpeed: widget.onCycleSpeed,
                    onSeek: widget.onSeek,
                    onSeekStart: widget.onSeekStart,
                    onReset: widget.onResetPlayback,
                  ),
                ],
                const SizedBox(height: 5),
                if (widget.loading)
                  Row(
                    children: [
                      SizedBox(
                        width: 10,
                        height: 10,
                        child: CircularProgressIndicator(
                          strokeWidth: 1.6,
                          color: _blue.withValues(alpha: 0.8),
                        ),
                      ),
                      const SizedBox(width: 5),
                      Text(
                        'Updating track…',
                        style: TextStyle(
                          color: _secondaryTextColor(context),
                          fontSize: 8,
                        ),
                      ),
                    ],
                  )
                else ...[
                  if (widget.error != null)
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (widget.usingCache) ...[
                          Padding(
                            padding: const EdgeInsets.only(top: 1),
                            child: Icon(
                              Icons.cloud_off_rounded,
                              color: _secondaryTextColor(context),
                              size: 10,
                            ),
                          ),
                          const SizedBox(width: 3),
                        ],
                        Flexible(
                          child: Text(
                            widget.error!,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: _secondaryTextColor(context),
                              fontSize: 8,
                            ),
                          ),
                        ),
                        const SizedBox(width: 4),
                        InkWell(
                          onTap: widget.onRetry,
                          child: const Text(
                            'Retry',
                            style: TextStyle(
                              color: _blue,
                              fontSize: 8,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      ],
                    ),
                  if (widget.tracks.isEmpty) ...[
                    if (widget.error == null)
                      Text(
                        'No active storm near the PAR.',
                        style: TextStyle(
                          color: _secondaryTextColor(context),
                          fontSize: 8,
                        ),
                      ),
                    InkWell(
                      key: const ValueKey('typhoon-preview-button'),
                      borderRadius: BorderRadius.circular(8),
                      onTap: widget.onPreview,
                      child: const Padding(
                        padding: EdgeInsets.symmetric(vertical: 2),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.replay_rounded, color: _blue, size: 12),
                            SizedBox(width: 3),
                            Text(
                              'Preview last storm',
                              style: TextStyle(
                                color: _blue,
                                fontSize: 8,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ] else if (widget.previewing)
                    Text(
                      'Replay of a past storm · not active',
                      style: TextStyle(
                        color: _secondaryTextColor(context),
                        fontSize: 8,
                      ),
                    )
                  else if (widget.updatedAt != null)
                    Text(
                      updatedAge.isEmpty
                          ? 'Updated ${_shortDateTime(widget.updatedAt!)}'
                          : 'Updated ${_shortDateTime(widget.updatedAt!)}'
                                ' · $updatedAge',
                      style: TextStyle(
                        color: _secondaryTextColor(context),
                        fontSize: 8,
                      ),
                    ),
                ],
              ],
              const SizedBox(height: 4),
              Text(
                'GDACS / JTWC · not an official PAGASA bulletin',
                style: TextStyle(
                  color: _secondaryTextColor(context),
                  fontSize: 7.5,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TyphoonPlaybackControls extends StatelessWidget {
  const _TyphoonPlaybackControls({
    required this.frame,
    required this.currentTime,
    required this.playing,
    required this.speed,
    required this.playhead,
    required this.onTogglePlay,
    required this.onCycleSpeed,
    required this.onSeek,
    required this.onSeekStart,
    required this.onReset,
  });

  final TyphoonPlaybackFrame? frame;
  final DateTime? currentTime;
  final bool playing;
  final int speed;
  final double playhead;
  final VoidCallback onTogglePlay;
  final VoidCallback onCycleSpeed;
  final ValueChanged<double> onSeek;
  final VoidCallback onSeekStart;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    final frame = this.frame;
    final detail = [
      if (frame != null && frame.status.isNotEmpty) frame.status,
      if (frame?.windKmh != null) '${frame!.windKmh!.round()} km/h',
    ].join(' · ');
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Tooltip(
              message: playing
                  ? 'Pause typhoon timeline'
                  : 'Play typhoon timeline',
              child: InkWell(
                key: const ValueKey('typhoon-playback-toggle'),
                borderRadius: BorderRadius.circular(20),
                onTap: onTogglePlay,
                child: Container(
                  width: 26,
                  height: 26,
                  decoration: const BoxDecoration(
                    color: _blue,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                    color: Colors.white,
                    size: 17,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    frame == null
                        ? 'Timeline'
                        : '${_playbackLabel(frame, currentTime)}'
                              ' · ${_shortDateTime(frame.time)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: _primaryTextColor(context),
                      fontSize: 8.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (detail.isNotEmpty)
                    Text(
                      detail,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: _secondaryTextColor(context),
                        fontSize: 7.5,
                      ),
                    ),
                ],
              ),
            ),
            InkWell(
              key: const ValueKey('typhoon-playback-speed'),
              borderRadius: BorderRadius.circular(6),
              onTap: onCycleSpeed,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                decoration: BoxDecoration(
                  color: _blue.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  '${speed}x',
                  style: const TextStyle(
                    color: _blue,
                    fontSize: 8,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 2),
            InkWell(
              key: const ValueKey('typhoon-playback-reset'),
              borderRadius: BorderRadius.circular(8),
              onTap: onReset,
              child: Icon(
                Icons.restart_alt_rounded,
                color: _secondaryTextColor(context),
                size: 15,
              ),
            ),
          ],
        ),
        SizedBox(
          height: 22,
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 2.2,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 10),
              activeTrackColor: _typhoonForecastColor,
              inactiveTrackColor: _secondaryTextColor(context)
                  .withValues(alpha: 0.22),
              thumbColor: _blue,
              overlayColor: _blue.withValues(alpha: 0.12),
            ),
            child: Slider(
              key: const ValueKey('typhoon-playback-slider'),
              value: playhead.clamp(0.0, 1.0),
              onChangeStart: (_) => onSeekStart(),
              onChanged: onSeek,
            ),
          ),
        ),
      ],
    );
  }
}

String _playbackLabel(TyphoonPlaybackFrame frame, DateTime? current) {
  if (current == null) return frame.isForecast ? 'Forecast' : 'Observed';
  final delta = frame.time.difference(current);
  if (delta.isNegative) {
    final hours = -delta.inHours;
    return hours <= 0 ? 'Now' : 'Past ${hours}h';
  }
  if (delta.inMinutes < 30) return 'Now';
  if (delta.inHours < 1) return 'Forecast +${delta.inMinutes}m';
  return 'Forecast +${delta.inHours}h';
}

String _shortDateTime(DateTime time) {
  final local = time.toLocal();
  final hour = local.hour.toString().padLeft(2, '0');
  final minute = local.minute.toString().padLeft(2, '0');
  return '${local.month}/${local.day} $hour:$minute';
}

const _monthNames = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

String _phShortDateTime(DateTime time) {
  final ph = time.toUtc().add(const Duration(hours: 8));
  final hour = ph.hour.toString().padLeft(2, '0');
  final minute = ph.minute.toString().padLeft(2, '0');
  return '${_monthNames[ph.month - 1]} ${ph.day} $hour:$minute';
}

class _TyphoonLegendRow extends StatelessWidget {
  const _TyphoonLegendRow({required this.label, required this.sample});

  final String label;
  final Widget sample;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(width: 26, child: Center(child: sample)),
        const SizedBox(width: 5),
        Expanded(
          child: Text(
            label,
            style: TextStyle(
              color: _secondaryTextColor(context),
              fontSize: 8.5,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }
}

class _LegendSolidLine extends StatelessWidget {
  const _LegendSolidLine({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 24,
      height: 3,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(3),
      ),
    );
  }
}

class _LegendDashedLine extends StatelessWidget {
  const _LegendDashedLine({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        _dash(color, 7),
        const SizedBox(width: 3),
        _dash(color, 7),
        const SizedBox(width: 3),
        _dash(color, 4),
      ],
    );
  }

  Widget _dash(Color color, double width) {
    return Container(
      width: width,
      height: 3,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(3),
      ),
    );
  }
}

class _LegendParBox extends StatelessWidget {
  const _LegendParBox();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 24,
      height: 11,
      decoration: BoxDecoration(
        color: _parBoundaryColor.withValues(alpha: 0.08),
        border: Border.all(color: _parBoundaryColor, width: 1.2),
        borderRadius: BorderRadius.circular(3),
      ),
    );
  }
}

class _TyphoonCategoryDot extends StatelessWidget {
  const _TyphoonCategoryDot({required this.category});

  final StormWindCategory category;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(
            color: _stormCategoryColor(category),
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 2),
        Text(
          category.shortLabel,
          style: TextStyle(
            color: _secondaryTextColor(context),
            fontSize: 7.5,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }
}

class _WindDetailCard extends StatelessWidget {
  const _WindDetailCard({
    required this.point,
    required this.isImperial,
    required this.onClose,
  });

  final _WeatherPoint point;
  final bool isImperial;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final unit = isImperial ? 'mph' : 'km/h';
    final speed = _displayWindSpeed(point.windSpeed, isImperial).round();
    final gust = _displayWindSpeed(point.windGust, isImperial).round();
    final direction = _compassDirection(point.windDirection);
    final color = _windSpeedColor(point.windSpeed);
    return Material(
      color: _surfaceColor(context).withValues(alpha: 0.97),
      borderRadius: BorderRadius.circular(16),
      elevation: 3,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
        child: Row(
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.16),
                borderRadius: BorderRadius.circular(11),
              ),
              child: Icon(Icons.air_rounded, color: color, size: 19),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Wind from $direction · $speed $unit',
                    style: TextStyle(
                      color: _primaryTextColor(context),
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Gusts up to $gust $unit',
                    style: TextStyle(
                      color: _secondaryTextColor(context),
                      fontSize: 10,
                    ),
                  ),
                ],
              ),
            ),
            IconButton(
              key: const ValueKey('wind-detail-close'),
              tooltip: 'Close wind details',
              onPressed: onClose,
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.close_rounded, size: 18),
            ),
          ],
        ),
      ),
    );
  }
}

class _TyphoonToggleOption extends StatelessWidget {
  const _TyphoonToggleOption({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 9),
      child: Material(
        color: value
            ? (_isDarkMode(context)
                  ? const Color(0xFF233B4C)
                  : const Color(0xFFF2F8FD))
            : _surfaceColor(context),
        borderRadius: BorderRadius.circular(17),
        child: InkWell(
          borderRadius: BorderRadius.circular(17),
          onTap: () => onChanged(!value),
          child: Container(
            padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(17),
              border: Border.all(
                color: value
                    ? _blue.withValues(alpha: 0.75)
                    : (_isDarkMode(context)
                          ? const Color(0xFF33434F)
                          : const Color(0xFFE7EDF2)),
                width: value ? 1.4 : 1,
              ),
            ),
            child: Row(
              children: [
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: _blue.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(11),
                  ),
                  child: Icon(icon, color: _blue, size: 19),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          color: _primaryTextColor(context),
                          fontSize: 13,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        subtitle,
                        style: TextStyle(
                          color: _secondaryTextColor(context),
                          fontSize: 10,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 4),
                Switch.adaptive(value: value, onChanged: onChanged),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MapTypeOption extends StatelessWidget {
  const _MapTypeOption({
    super.key,
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.mapType,
    required this.selected,
    required this.onTap,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final _MapType mapType;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 9),
      child: Semantics(
        button: true,
        selected: selected,
        label: '$title map. $subtitle${selected ? ', selected' : ''}',
        child: Material(
          color: selected
              ? (_isDarkMode(context)
                    ? const Color(0xFF233B4C)
                    : const Color(0xFFF2F8FD))
              : _surfaceColor(context),
          borderRadius: BorderRadius.circular(17),
          child: InkWell(
            borderRadius: BorderRadius.circular(17),
            onTap: onTap,
            child: Container(
              padding: const EdgeInsets.all(9),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(17),
                border: Border.all(
                  color: selected
                      ? _blue.withValues(alpha: 0.75)
                      : (_isDarkMode(context)
                            ? const Color(0xFF33434F)
                            : const Color(0xFFE7EDF2)),
                  width: selected ? 1.4 : 1,
                ),
              ),
              child: Row(
                children: [
                  _MapStylePreview(mapType: mapType, icon: icon),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: TextStyle(
                            color: _primaryTextColor(context),
                            fontSize: 13,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          subtitle,
                          style: TextStyle(
                            color: _secondaryTextColor(context),
                            fontSize: 10,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Icon(
                    selected
                        ? Icons.check_circle_rounded
                        : Icons.circle_outlined,
                    color: selected
                        ? _blue
                        : _secondaryTextColor(context).withValues(alpha: 0.55),
                    size: 21,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _WeatherOverlayOption extends StatelessWidget {
  const _WeatherOverlayOption({
    super.key,
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 9),
      child: Semantics(
        button: true,
        selected: selected,
        label: '$title overlay. $subtitle${selected ? ', selected' : ''}',
        child: Material(
          color: selected
              ? (_isDarkMode(context)
                    ? const Color(0xFF233B4C)
                    : const Color(0xFFF2F8FD))
              : _surfaceColor(context),
          borderRadius: BorderRadius.circular(17),
          child: InkWell(
            borderRadius: BorderRadius.circular(17),
            onTap: onTap,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(17),
                border: Border.all(
                  color: selected
                      ? _blue.withValues(alpha: 0.75)
                      : (_isDarkMode(context)
                            ? const Color(0xFF33434F)
                            : const Color(0xFFE7EDF2)),
                  width: selected ? 1.4 : 1,
                ),
              ),
              child: Row(
                children: [
                  Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      color: _blue.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(11),
                    ),
                    child: Icon(icon, color: _blue, size: 19),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: TextStyle(
                            color: _primaryTextColor(context),
                            fontSize: 13,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          subtitle,
                          style: TextStyle(
                            color: _secondaryTextColor(context),
                            fontSize: 10,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Icon(
                    selected
                        ? Icons.check_circle_rounded
                        : Icons.circle_outlined,
                    color: selected
                        ? _blue
                        : _secondaryTextColor(context).withValues(alpha: 0.55),
                    size: 21,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MapStylePreview extends StatelessWidget {
  const _MapStylePreview({required this.mapType, required this.icon});

  final _MapType mapType;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final isDark = _isDarkMode(context);
    final groundColor = switch (mapType) {
      _MapType.standard =>
        isDark ? const Color(0xFF334A50) : const Color(0xFFDCE8D8),
      _MapType.humanitarian =>
        isDark ? const Color(0xFF59605C) : const Color(0xFFE6E2D9),
      _MapType.topographic =>
        isDark ? const Color(0xFF465747) : const Color(0xFFD8E5C8),
    };
    final routeColor = switch (mapType) {
      _MapType.standard => const Color(0xFFFFFEF7),
      _MapType.humanitarian => const Color(0xFFFAFAF5),
      _MapType.topographic => const Color(0xFFB7A486),
    };

    return ClipRRect(
      borderRadius: BorderRadius.circular(11),
      child: SizedBox(
        width: 76,
        height: 58,
        child: Stack(
          clipBehavior: Clip.hardEdge,
          children: [
            Positioned.fill(child: ColoredBox(color: groundColor)),
            Positioned(
              left: -9,
              top: 26,
              child: Transform.rotate(
                angle: -0.3,
                child: Container(width: 95, height: 5, color: routeColor),
              ),
            ),
            Positioned(
              left: 18,
              top: -8,
              child: Transform.rotate(
                angle: 0.75,
                child: Container(
                  width: 5,
                  height: 78,
                  color: routeColor.withValues(alpha: 0.9),
                ),
              ),
            ),
            if (mapType == _MapType.topographic) ...[
              Positioned(
                right: -9,
                top: 6,
                child: Container(
                  width: 35,
                  height: 22,
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: isDark
                          ? const Color(0xFF83916C)
                          : const Color(0xFF9CAC7E),
                      width: 1.2,
                    ),
                    borderRadius: BorderRadius.circular(50),
                  ),
                ),
              ),
              Positioned(
                right: -3,
                top: 11,
                child: Container(
                  width: 23,
                  height: 12,
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: isDark
                          ? const Color(0xFF83916C)
                          : const Color(0xFF9CAC7E),
                    ),
                    borderRadius: BorderRadius.circular(50),
                  ),
                ),
              ),
            ],
            if (mapType == _MapType.humanitarian)
              Positioned(
                right: 7,
                bottom: 8,
                child: Container(
                  width: 12,
                  height: 8,
                  decoration: BoxDecoration(
                    color: const Color(0xFFD2A078),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            Positioned(
              right: 7,
              top: 7,
              child: Icon(
                icon,
                size: 12,
                color: mapType == _MapType.humanitarian
                    ? const Color(0xFF985F50)
                    : const Color(0xFF3D7978),
              ),
            ),
            const Positioned(
              left: 34,
              top: 22,
              child: Icon(
                Icons.location_on_rounded,
                color: Color(0xFFD7564F),
                size: 17,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class AlertsPage extends StatefulWidget {
  const AlertsPage({
    super.key,
    this.client,
    this.enabledAlertTypes = const {'Rain', 'Thunderstorm', 'Wind'},
    this.isImperial = false,
    this.use24HourTime = false,
    this.notificationsEnabled = true,
    this.location = _defaultMapLocation,
    this.locationLabel = 'General MacArthur, Eastern Samar',
    this.emergencyContactName = '',
    this.emergencyContactNumber = '',
    this.onActiveLocationChanged,
  });

  final http.Client? client;
  final Set<String> enabledAlertTypes;
  final bool isImperial;
  final bool use24HourTime;
  final bool notificationsEnabled;
  final LatLng location;
  final String locationLabel;
  final String emergencyContactName;
  final String emergencyContactNumber;
  final void Function(LatLng location, String label)? onActiveLocationChanged;

  @override
  State<AlertsPage> createState() => _AlertsPageState();
}

class _AlertsPageState extends State<AlertsPage> with WidgetsBindingObserver {
  late final _client = widget.client ?? http.Client();
  Timer? _refreshTimer;
  List<_WeatherAlert> _alerts = [];
  String? _error;
  bool _isLoading = true;
  String _selectedFilter = 'All';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadAlerts();
    _scheduleRefresh();
  }

  @override
  void didUpdateWidget(covariant AlertsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.location != widget.location) _loadAlerts();
  }

  Future<void> _useMyLocation() async {
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      const SnackBar(content: Text('Getting your current location...')),
    );
    final result = await DeviceLocationService.getCurrentPosition();
    if (!mounted) return;
    if (!result.isSuccess) {
      messenger.showSnackBar(
        SnackBar(content: Text(result.error ?? 'Location is unavailable.')),
      );
      return;
    }
    final position = result.position!;
    final label = await _reverseGeocodeLabel(position);
    if (!mounted) return;
    widget.onActiveLocationChanged?.call(position, label);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _loadAlerts();
      _scheduleRefresh();
    } else {
      _refreshTimer?.cancel();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _refreshTimer?.cancel();
    if (widget.client == null) _client.close();
    super.dispose();
  }

  void _scheduleRefresh() {
    _refreshTimer?.cancel();
    _refreshTimer = Timer.periodic(_forecastRefreshInterval, (_) {
      _loadAlerts();
    });
  }

  Future<void> _loadAlerts() async {
    if (!mounted) return;
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final alerts = await _fetchWeatherAlerts(
        _client,
        isImperial: widget.isImperial,
        use24HourTime: widget.use24HourTime,
        location: widget.location,
      );
      if (!mounted) return;
      setState(() {
        _alerts = alerts;
        _isLoading = false;
        _error = null;
      });
    } on http.ClientException {
      _showError('Could not connect to the weather forecast.');
    } on FormatException {
      _showError('Weather alert forecast data is invalid.');
    } on TimeoutException {
      _showError('Weather alert request timed out.');
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    setState(() {
      _error = message;
      _isLoading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final visibleAlerts = _alerts.where((alert) {
      final enabled =
          widget.notificationsEnabled &&
          widget.enabledAlertTypes.contains(alert.category);
      final matchesFilter =
          _selectedFilter == 'All' || alert.category == _selectedFilter;
      return enabled && matchesFilter;
    }).toList();

    return _PageScroll(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _PageHeader(
            title: 'Weather Alerts',
            subtitle: 'Forecast-based outlook · ${widget.locationLabel}',
          ),
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Next 24 hours · Model-based estimates, not official warnings',
                  style: TextStyle(color: _muted, fontSize: 9),
                ),
              ),
              IconButton(
                key: const ValueKey('alerts-use-my-location'),
                tooltip: 'Use my current location',
                onPressed: _useMyLocation,
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.gps_fixed_rounded, color: _blue),
              ),
              if (_isLoading)
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 1.5),
                )
              else
                IconButton(
                  key: const ValueKey('alerts-refresh'),
                  tooltip: 'Refresh weather alerts',
                  onPressed: _loadAlerts,
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.refresh_rounded, color: _blue),
                ),
            ],
          ),
          const SizedBox(height: 13),
          _ChoiceChips(
            values: const ['All', 'Rain', 'Thunderstorm', 'Wind'],
            selected: _selectedFilter,
            onSelected: (value) => setState(() => _selectedFilter = value),
          ),
          const SizedBox(height: 16),
          if (_error != null && _alerts.isEmpty)
            _AlertStatusCard(
              message: _error!,
              actionLabel: 'Retry',
              onPressed: _loadAlerts,
            )
          else if (_isLoading && _alerts.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 36),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (visibleAlerts.isEmpty)
            _AlertStatusCard(
              message: !widget.notificationsEnabled
                  ? 'In-app weather alerts are turned off in Settings.'
                  : widget.enabledAlertTypes.isEmpty
                  ? 'All in-app weather alert types are turned off in Settings.'
                  : _alerts.isEmpty
                  ? 'No significant rain, thunderstorm, or strong wind is predicted in the next 24 hours.'
                  : 'No ${_selectedFilter.toLowerCase()} alerts are predicted in the next 24 hours.',
            )
          else
            for (final alert in visibleAlerts) ...[
              _DetailedAlertCard(
                alert: alert,
                locationLabel: widget.locationLabel,
              ),
              const SizedBox(height: 11),
            ],
          const SizedBox(height: 8),
          if (visibleAlerts.isNotEmpty)
            _EmergencySmsButton(
              contactName: widget.emergencyContactName,
              contactNumber: widget.emergencyContactNumber,
              message: _smsMessage(visibleAlerts),
            ),
          const SizedBox(height: 12),
          const _SafetyTipCard(),
        ],
      ),
    );
  }

  String _smsMessage(List<_WeatherAlert> alerts) {
    final summary = alerts.isEmpty
        ? 'Please check the current weather conditions.'
        : alerts.map((alert) => alert.title).join(', ');
    return 'Banog emergency alert for ${widget.locationLabel}: $summary '
        'Stay safe and monitor local authorities.';
  }
}

class _DetailedAlertCard extends StatelessWidget {
  const _DetailedAlertCard({
    required this.alert,
    this.locationLabel = 'General MacArthur',
  });

  final _WeatherAlert alert;
  final String locationLabel;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: alert.color,
        borderRadius: BorderRadius.circular(19),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.64),
              borderRadius: BorderRadius.circular(13),
            ),
            child: Icon(alert.icon, color: _blue, size: 21),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  alert.title,
                  style: const TextStyle(
                    color: _navy,
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  alert.message,
                  style: const TextStyle(
                    color: _ink,
                    fontSize: 11,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '$locationLabel · Forecast outlook',
                  style: const TextStyle(
                    color: _muted,
                    fontSize: 9,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          const Icon(Icons.chevron_right_rounded, color: _navy, size: 20),
        ],
      ),
    );
  }
}

class _AlertStatusCard extends StatelessWidget {
  const _AlertStatusCard({
    required this.message,
    this.actionLabel,
    this.onPressed,
  });

  final String message;
  final String? actionLabel;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _surfaceColor(context),
        borderRadius: BorderRadius.circular(18),
        border:
            _glassBorder(context) ??
            Border.all(
              color: _isDarkMode(context)
                  ? const Color(0xFF344451)
                  : const Color(0xFFE4EDF5),
            ),
      ),
      child: Column(
        children: [
          Icon(
            actionLabel == null
                ? Icons.check_circle_outline_rounded
                : Icons.cloud_off_outlined,
            color: actionLabel == null ? _blue : const Color(0xFFB34343),
            size: 24,
          ),
          const SizedBox(height: 8),
          Text(
            message,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: _primaryTextColor(context),
              fontSize: 11,
              height: 1.4,
            ),
          ),
          if (actionLabel != null) ...[
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: onPressed,
              icon: const Icon(Icons.refresh_rounded, size: 16),
              label: Text(actionLabel!),
            ),
          ],
        ],
      ),
    );
  }
}

class _EmergencySmsButton extends StatelessWidget {
  const _EmergencySmsButton({
    required this.contactName,
    required this.contactNumber,
    required this.message,
  });

  final String contactName;
  final String contactNumber;
  final String message;

  Future<void> _send(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    if (contactNumber.trim().isEmpty) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Add an emergency contact in Settings first.'),
        ),
      );
      return;
    }
    final sent = await EmergencySmsService.send(
      recipients: [contactNumber],
      message: message,
    );
    if (!context.mounted) return;
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          sent
              ? 'Opening your messaging app...'
              : 'Could not open the messaging app on this device.',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: FilledButton.icon(
        onPressed: () => _send(context),
        icon: const Icon(Icons.sms_rounded, size: 18),
        label: Text(
          contactName.trim().isEmpty
              ? 'Send emergency SMS'
              : 'Send emergency SMS · $contactName',
        ),
        style: FilledButton.styleFrom(
          backgroundColor: const Color(0xFFB34343),
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(vertical: 13),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),
    );
  }
}

class _SafetyTipCard extends StatelessWidget {
  const _SafetyTipCard();

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 146,
      width: double.infinity,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF67B8EA), Color(0xFFD8EEFF)],
        ),
      ),
      child: Stack(
        children: [
          Positioned(
            right: 18,
            bottom: -5,
            child: Icon(
              Icons.landscape_rounded,
              size: 150,
              color: Colors.white.withValues(alpha: 0.65),
            ),
          ),
          const Padding(
            padding: EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.shield_rounded, color: Colors.white, size: 24),
                SizedBox(height: 8),
                Text(
                  'Keep an eye on the skies',
                  style: TextStyle(
                    color: _navy,
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                SizedBox(height: 4),
                Text(
                  'Check local updates before you travel.',
                  style: TextStyle(color: _ink, fontSize: 11),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class StormsPage extends StatefulWidget {
  const StormsPage({
    super.key,
    this.client,
    this.isImperial = false,
    this.activeLocation = _defaultMapLocation,
    this.activeLocationLabel = 'General MacArthur, Eastern Samar',
    this.emergencyContactName = '',
    this.emergencyContactNumber = '',
  });

  final http.Client? client;
  final bool isImperial;
  final LatLng activeLocation;
  final String activeLocationLabel;
  final String emergencyContactName;
  final String emergencyContactNumber;

  @override
  State<StormsPage> createState() => _StormsPageState();
}

class _StormsPageState extends State<StormsPage> with WidgetsBindingObserver {
  late final _client = widget.client ?? http.Client();
  Timer? _refreshTimer;
  WeatherConditions? _conditions;
  List<StormEvent> _storms = [];
  LowPressureArea? _lowPressure;
  String? _lowPressureError;
  RiskAssessment? _risk;
  String? _briefing;
  String? _error;
  bool _stormError = false;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
    _scheduleRefresh();
  }

  @override
  void didUpdateWidget(covariant StormsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.activeLocation != widget.activeLocation) _load();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _load();
      _scheduleRefresh();
    } else {
      _refreshTimer?.cancel();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _refreshTimer?.cancel();
    if (widget.client == null) _client.close();
    super.dispose();
  }

  void _scheduleRefresh() {
    _refreshTimer?.cancel();
    _refreshTimer = Timer.periodic(_forecastRefreshInterval, (_) => _load());
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final conditions = await ForecastIntelService.fetchConditions(
        _client,
        widget.activeLocation,
      );
      var storms = <StormEvent>[];
      var stormFailed = false;
      try {
        storms = await StormService.fetchNearbyStorms(
          _client,
          center: widget.activeLocation,
        );
      } catch (_) {
        stormFailed = true;
      }
      LowPressureArea? lowPressure;
      String? lowPressureError;
      try {
        lowPressure = await ForecastIntelService.detectLowPressure(
          _client,
          widget.activeLocation,
        );
      } on http.ClientException {
        lowPressureError =
            'Low-pressure forecast data is temporarily unavailable.';
      } on FormatException {
        lowPressureError = 'Low-pressure forecast data was invalid.';
      } on TimeoutException {
        lowPressureError = 'Low-pressure forecast request timed out.';
      }
      final risk = HazardAssessment.assess(
        conditions: conditions,
        storms: storms,
        lowPressure: lowPressure,
        location: widget.activeLocation,
      );
      final briefing = IntelligenceBriefing.generate(
        locationLabel: widget.activeLocationLabel,
        location: widget.activeLocation,
        conditions: conditions,
        storms: storms,
        lowPressure: lowPressure,
        risk: risk,
      );
      if (!mounted) return;
      setState(() {
        _conditions = conditions;
        _storms = storms;
        _lowPressure = lowPressure;
        _lowPressureError = lowPressureError;
        _risk = risk;
        _briefing = briefing;
        _stormError = stormFailed;
        _isLoading = false;
        _error = null;
      });
    } on http.ClientException {
      _showError('Could not load the online intelligence feed.');
    } on FormatException {
      _showError('The intelligence feed returned invalid data.');
    } on TimeoutException {
      _showError('The intelligence request timed out.');
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    setState(() {
      _error = message;
      _isLoading = false;
    });
  }

  String get _smsMessage {
    final location = widget.activeLocationLabel;
    final level = _risk?.level ?? 'Unknown';
    final storm = _storms.isNotEmpty
        ? ' Nearest cyclone: ${_storms.first.name}.'
        : '';
    return 'Banog emergency alert for $location. Risk level: $level.$storm '
        'Please check conditions and stay safe.';
  }

  Color _riskColor(String level) => switch (level) {
    'Severe' => const Color(0xFFB34343),
    'High' => const Color(0xFFE07A3F),
    'Moderate' => const Color(0xFFD9A62E),
    _ => const Color(0xFF4F9D69),
  };

  Color _alertLevelColor(String level) => switch (level.toLowerCase()) {
    'red' => const Color(0xFFB34343),
    'orange' => const Color(0xFFE07A3F),
    'green' => const Color(0xFF4F9D69),
    _ => _blue,
  };

  @override
  Widget build(BuildContext context) {
    return _PageScroll(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _PageHeader(
            title: 'Storms & Risk',
            subtitle: '${widget.activeLocationLabel} · online intelligence',
          ),
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Tropical cyclones · LPA watch · location risk',
                  style: TextStyle(color: _muted, fontSize: 10),
                ),
              ),
              if (_isLoading)
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 1.5),
                )
              else
                IconButton(
                  key: const ValueKey('storms-refresh'),
                  tooltip: 'Refresh storm and risk data',
                  onPressed: _load,
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.refresh_rounded, color: _blue),
                ),
            ],
          ),
          const SizedBox(height: 12),
          if (_error != null && _risk == null)
            _AlertStatusCard(
              message: _error!,
              actionLabel: 'Retry',
              onPressed: _load,
            )
          else if (_isLoading && _risk == null)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 40),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_risk != null && _conditions != null) ...[
            _riskCard(_risk!),
            const SizedBox(height: 12),
            _conditionsRow(_conditions!),
            const SizedBox(height: 14),
            if (_briefing != null) ...[
              _briefingCard(_briefing!),
              const SizedBox(height: 14),
            ],
            _stormsSection(),
            const SizedBox(height: 14),
            _lpaCard(),
            const SizedBox(height: 14),
            if (_risk!.level == 'High' || _risk!.level == 'Severe')
              _EmergencySmsButton(
                contactName: widget.emergencyContactName,
                contactNumber: widget.emergencyContactNumber,
                message: _smsMessage,
              ),
            const SizedBox(height: 12),
            Text(
              'Storm alerts come from GDACS/JTWC advisories. Risk and the '
              'briefing are derived from forecast-model data and are not '
              'official PAGASA warnings. Always follow local authorities.',
              style: TextStyle(
                color: _secondaryTextColor(context),
                fontSize: 9.5,
                height: 1.4,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _riskCard(RiskAssessment risk) {
    final color = _riskColor(risk.level);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            color.withValues(alpha: 0.95),
            color.withValues(alpha: 0.66),
          ],
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 78,
            height: 78,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.22),
              shape: BoxShape.circle,
            ),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '${risk.score}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 28,
                      fontWeight: FontWeight.w900,
                      height: 1,
                    ),
                  ),
                  const Text(
                    '/100',
                    style: TextStyle(
                      color: Colors.white70,
                      fontSize: 9,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'LOCATION RISK',
                  style: TextStyle(
                    color: Colors.white70,
                    fontSize: 9,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.2,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  risk.level,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 6),
                for (final factor in risk.factors.take(3))
                  Padding(
                    padding: const EdgeInsets.only(bottom: 2),
                    child: Text(
                      '• $factor',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 10.5,
                        height: 1.3,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _conditionsRow(WeatherConditions conditions) {
    return Row(
      children: [
        _metricChip(
          Icons.thermostat_rounded,
          '${_displayTemperature(conditions.temperatureC, widget.isImperial)}°',
          surface: true,
        ),
        const SizedBox(width: 8),
        _metricChip(
          Icons.water_drop_rounded,
          '${conditions.peakRainChance}% rain',
          surface: true,
        ),
        const SizedBox(width: 8),
        _metricChip(
          Icons.air_rounded,
          '${_displayWindSpeed(conditions.peakWindKmh, widget.isImperial).round()} '
          '${widget.isImperial ? 'mph' : 'km/h'}',
          surface: true,
        ),
      ],
    );
  }

  Widget _briefingCard(String briefing) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _surfaceColor(context),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: _blue.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.auto_awesome_rounded, color: _blue, size: 20),
              const SizedBox(width: 8),
              Text(
                'Banog intelligence briefing',
                style: TextStyle(
                  color: _primaryTextColor(context),
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            briefing,
            style: TextStyle(
              color: _secondaryTextColor(context),
              fontSize: 11,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }

  Widget _stormsSection() {
    if (_stormError && _storms.isEmpty) {
      return _AlertStatusCard(
        message:
            'Storm tracking is temporarily unavailable. Forecast risk is '
            'still shown.',
        actionLabel: 'Retry',
        onPressed: _load,
      );
    }
    if (_storms.isEmpty) {
      return _sectionCard(
        icon: Icons.verified_rounded,
        title: 'No nearby cyclone',
        children: [
          Text(
            'No active tropical cyclone is tracked within about 1,300 km of '
            'your location in the latest advisories.',
            style: TextStyle(
              color: _secondaryTextColor(context),
              fontSize: 11,
              height: 1.4,
            ),
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'ACTIVE STORMS',
          style: TextStyle(
            color: _secondaryTextColor(context),
            fontSize: 10,
            fontWeight: FontWeight.w800,
            letterSpacing: 1.3,
          ),
        ),
        const SizedBox(height: 8),
        for (final storm in _storms) ...[
          _stormCard(storm),
          const SizedBox(height: 10),
        ],
      ],
    );
  }

  Widget _stormCard(StormEvent storm) {
    final color = _alertLevelColor(storm.alertLevel);
    final distance = storm.distanceFrom(widget.activeLocation).round();
    final wind = storm.windKmh;
    return Container(
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: _surfaceColor(context),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: color.withValues(alpha: 0.55), width: 1.4),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.cyclone_rounded, color: color, size: 22),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  storm.name,
                  style: TextStyle(
                    color: _primaryTextColor(context),
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  '${storm.alertLevel} alert',
                  style: TextStyle(
                    color: color,
                    fontSize: 9,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              _metricChip(Icons.near_me_rounded, '$distance km away'),
              if (wind != null)
                _metricChip(
                  Icons.air_rounded,
                  '${_displayWindSpeed(wind, widget.isImperial).round()} '
                  '${widget.isImperial ? 'mph' : 'km/h'}',
                ),
              if (storm.isCurrent)
                _metricChip(Icons.bolt_rounded, 'Active now'),
            ],
          ),
          if (storm.description.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              storm.description,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: _secondaryTextColor(context),
                fontSize: 10.5,
                height: 1.35,
              ),
            ),
          ],
          if (storm.reportUrl.isNotEmpty)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => launchUrl(
                  Uri.parse(storm.reportUrl),
                  mode: LaunchMode.externalApplication,
                ),
                child: const Text(
                  'View GDACS report',
                  style: TextStyle(fontSize: 11),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _lpaCard() {
    final lowPressure = _lowPressure;
    final error = _lowPressureError;
    if (error != null) {
      return _sectionCard(
        icon: Icons.cloud_off_rounded,
        title: 'Low pressure data unavailable',
        children: [
          Text(
            error,
            style: TextStyle(
              color: _secondaryTextColor(context),
              fontSize: 11,
              height: 1.4,
            ),
          ),
        ],
      );
    }
    if (lowPressure == null) {
      return _sectionCard(
        icon: Icons.cloud_off_rounded,
        title: 'No low pressure area detected',
        children: [
          Text(
            'No significant pressure minimum was found near your location in '
            'the latest model sample.',
            style: TextStyle(
              color: _secondaryTextColor(context),
              fontSize: 11,
              height: 1.4,
            ),
          ),
        ],
      );
    }
    return _sectionCard(
      icon: Icons.cloud_rounded,
      title: 'Low pressure area watch',
      accent: const Color(0xFFD9A62E),
      children: [
        Text(
          'A possible LPA is being monitored near '
          '${lowPressure.location.latitude.toStringAsFixed(1)}, '
          '${lowPressure.location.longitude.toStringAsFixed(1)} with a '
          'pressure of ${lowPressure.pressureHpa.round()} hPa.',
          style: TextStyle(
            color: _secondaryTextColor(context),
            fontSize: 11,
            height: 1.4,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          'LPA detection is derived from forecast pressure and is not an '
          'official PAGASA bulletin.',
          style: TextStyle(
            color: _secondaryTextColor(context),
            fontSize: 9.5,
            height: 1.35,
          ),
        ),
      ],
    );
  }

  Widget _sectionCard({
    required IconData icon,
    required String title,
    required List<Widget> children,
    Color accent = _blue,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _surfaceColor(context),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFE4EDF5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: accent, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    color: _primaryTextColor(context),
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ...children,
        ],
      ),
    );
  }

  Widget _metricChip(IconData icon, String label, {bool surface = false}) {
    final color = surface ? _blue : _secondaryTextColor(context);
    final background = surface
        ? _surfaceColor(context)
        : _blue.withValues(alpha: 0.1);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 10,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class SettingsPage extends StatelessWidget {
  const SettingsPage({
    super.key,
    this.showHeader = true,
    required this.isDarkMode,
    required this.isImperial,
    this.use24HourTime = false,
    this.notificationsEnabled = true,
    required this.enabledAlertTypes,
    required this.savedLocations,
    this.activeLocationLabel = 'General MacArthur, Eastern Samar',
    this.onActiveLocationChanged,
    required this.emergencyContactName,
    required this.emergencyContactNumber,
    required this.onDarkModeChanged,
    required this.fontStyle,
    required this.backgroundStyle,
    this.customBackgroundColor = const Color(0xFFEDE9FE),
    required this.onFontStyleChanged,
    required this.onBackgroundStyleChanged,
    this.onCustomBackgroundColorChanged,
    required this.onImperialChanged,
    this.on24HourTimeChanged,
    this.onNotificationsEnabledChanged,
    required this.onAlertTypesChanged,
    required this.onSavedLocationsChanged,
    required this.onEmergencyContactChanged,
  });

  final bool showHeader;
  final bool isDarkMode;
  final bool isImperial;
  final bool use24HourTime;
  final bool notificationsEnabled;
  final Set<String> enabledAlertTypes;
  final List<String> savedLocations;
  final String activeLocationLabel;
  final void Function(LatLng location, String label)? onActiveLocationChanged;
  final String emergencyContactName;
  final String emergencyContactNumber;
  final ValueChanged<bool> onDarkModeChanged;
  final String fontStyle;
  final String backgroundStyle;
  final Color customBackgroundColor;
  final ValueChanged<String>? onFontStyleChanged;
  final ValueChanged<String>? onBackgroundStyleChanged;
  final ValueChanged<Color>? onCustomBackgroundColorChanged;
  final ValueChanged<bool>? onImperialChanged;
  final ValueChanged<bool>? on24HourTimeChanged;
  final ValueChanged<bool>? onNotificationsEnabledChanged;
  final ValueChanged<Set<String>>? onAlertTypesChanged;
  final ValueChanged<List<String>>? onSavedLocationsChanged;
  final void Function(String name, String number)? onEmergencyContactChanged;

  @override
  Widget build(BuildContext context) {
    return _PageScroll(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (showHeader) ...[
            const _PageHeader(
              title: 'Settings',
              subtitle: 'Make Banog work for you.',
            ),
            const SizedBox(height: 16),
          ],
          const _SettingsHero(),
          const SizedBox(height: 19),
          _SettingsCategory(
            title: 'General settings',
            subtitle: 'Language, units, time, and your places.',
            icon: Icons.tune_rounded,
            children: [
              _SettingsRow(
                icon: Icons.language_rounded,
                title: 'Language',
                subtitle: 'English · currently available',
                onTap: () => _showInfo(
                  context,
                  'Language',
                  'English is currently the available app language. '
                      'Additional translations can be added in a future release.',
                ),
              ),
              _SettingsRow(
                icon: Icons.straighten_rounded,
                title: 'Temperature & wind units',
                subtitle: isImperial ? '°F, mph, in' : '°C, km/h, mm',
                onTap: () => _showUnits(context),
              ),
              _SettingsRow(
                icon: Icons.schedule_rounded,
                title: 'Time format',
                subtitle: use24HourTime ? '24-hour · 14:00' : '12-hour · 2 PM',
                onTap: () => _showTimeFormat(context),
              ),
              _SettingsRow(
                icon: Icons.location_on_rounded,
                title: 'Saved Locations',
                subtitle:
                    '${savedLocations.length} saved · $activeLocationLabel',
                showDivider: false,
                onTap: () => _showSavedLocations(context),
              ),
            ],
          ),
          const SizedBox(height: 16),
          _SettingsCategory(
            title: 'Appearance',
            subtitle: 'Theme, typography, backgrounds, and map style.',
            icon: Icons.palette_rounded,
            children: [
              _SettingsRow(
                icon: Icons.palette_outlined,
                title: 'Theme & display',
                subtitle:
                    '${isDarkMode ? 'Dark' : 'Light'} · $fontStyle · $backgroundStyle',
                showDivider: false,
                onTap: () => _showAppearance(context),
              ),
              const _SettingsInfoRow(
                icon: Icons.map_outlined,
                title: 'Map appearance',
                subtitle: 'Choose Standard, Humanitarian, or Topographic in Map layers.',
              ),
              const _SettingsInfoRow(
                icon: Icons.text_fields_rounded,
                title: 'Theme and text options',
                subtitle: 'Light/dark mode, Sans/Serif fonts, color presets, a custom color tint, and a frosted glass background are available. System theme, accent-color selection, and adjustable font size are not configured.',
                showDivider: false,
              ),
            ],
          ),
          const SizedBox(height: 16),
          _SettingsCategory(
            title: 'Notifications',
            subtitle: 'Control forecast alerts shown inside Banog.',
            icon: Icons.notifications_active_rounded,
            children: [
              Material(
                color: Colors.transparent,
                child: SwitchListTile.adaptive(
                  key: const ValueKey('settings-notifications-toggle'),
                  contentPadding: const EdgeInsets.symmetric(vertical: 2),
                  secondary: const Icon(
                    Icons.notifications_active_rounded,
                    color: _blue,
                  ),
                  title: const Text(
                    'In-app weather alerts',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
                  ),
                  subtitle: Text(
                    notificationsEnabled
                        ? 'Show enabled forecast alerts in Banog'
                        : 'Forecast alerts are hidden in Banog',
                    style: const TextStyle(fontSize: 10),
                  ),
                  value: notificationsEnabled,
                  onChanged: onNotificationsEnabledChanged,
                ),
              ),
              _SettingsRow(
                icon: Icons.warning_amber_rounded,
                title: 'Weather alert preferences',
                subtitle: '${enabledAlertTypes.length} alert types enabled',
                onTap: () => _showNotifications(context),
              ),
              _SettingsRow(
                icon: Icons.sms_rounded,
                title: 'Emergency contact',
                subtitle: emergencyContactNumber.isEmpty
                    ? 'Not set · used for SMS alerts'
                    : '${emergencyContactName.isEmpty ? 'Contact' : emergencyContactName} · '
                          '$emergencyContactNumber',
                onTap: () => _showEmergencyContact(context),
              ),
              const _SettingsInfoRow(
                icon: Icons.notifications_off_outlined,
                title: 'Push, sound & vibration',
                subtitle: 'Push delivery, typhoon and flood warnings, notification sound, and vibration are not configured. Banog currently shows in-app forecast-based rain, thunderstorm, and wind alerts.',
                showDivider: false,
              ),
            ],
          ),
          const SizedBox(height: 16),
          _SettingsCategory(
            title: 'Location & GPS',
            subtitle: 'Set the location used for forecasts and risk estimates.',
            icon: Icons.my_location_rounded,
            children: [
              _SettingsRow(
                icon: Icons.gps_fixed_rounded,
                title: 'Use current GPS location',
                subtitle: activeLocationLabel,
                onTap: () => _useCurrentLocation(context),
              ),
              _SettingsRow(
                icon: Icons.bookmark_outline_rounded,
                title: 'Saved places',
                subtitle:
                    'Location permission is requested only when you use GPS.',
                onTap: () => _showSavedLocations(context),
              ),
              _SettingsRow(
                icon: Icons.route_rounded,
                title: 'GPS trip tracking',
                subtitle:
                    'Record and save trips with GPS only — no mobile data',
                onTap: () => _showTripTracking(context),
              ),
              const _SettingsInfoRow(
                icon: Icons.gps_not_fixed_rounded,
                title: 'GPS permission & accuracy',
                subtitle: 'Banog asks for location permission when you choose GPS. Trip tracking runs while the tracking screen is open and works without mobile data or Wi-Fi.',
                showDivider: false,
              ),
            ],
          ),
          const SizedBox(height: 16),
          _SettingsCategory(
            title: 'Offline & data management',
            subtitle: 'Download maps and manage storage.',
            icon: Icons.storage_rounded,
            children: [
              _SettingsRow(
                icon: Icons.download_for_offline_outlined,
                title: 'Offline maps',
                subtitle: 'Download Eastern Samar street & terrain maps',
                onTap: () => _showOfflineMaps(context),
              ),
              const _SettingsInfoRow(
                icon: Icons.cloud_outlined,
                title: 'Weather & map data',
                subtitle: 'Downloaded maps work offline. Forecasts, place search, and weather layers still need a connection. Satellite imagery is cached only for areas you view online.',
              ),
              const _SettingsInfoRow(
                icon: Icons.sync_rounded,
                title: 'Data synchronization',
                subtitle: 'Banog refreshes forecast data when connected. It does not sync an account or download map packs automatically.',
                showDivider: false,
              ),
            ],
          ),
          const SizedBox(height: 16),
          _SettingsCategory(
            title: 'AI configuration',
            subtitle: 'How Banog calculates local hazard insights.',
            icon: Icons.auto_awesome_rounded,
            children: const [
              _SettingsInfoRow(
                icon: Icons.analytics_outlined,
                title: 'Risk & weather analysis',
                subtitle: 'Risk scores and briefings use forecast-model data and transparent heuristics. Banog does not currently run an AI model or offline AI.',
              ),
              _SettingsInfoRow(
                icon: Icons.history_rounded,
                title: 'Historical data & model',
                subtitle: 'No historical weather archive or configurable AI model is stored in the app.',
              ),
              _SettingsInfoRow(
                icon: Icons.cyclone_outlined,
                title: 'Typhoon analysis',
                subtitle: 'Storm information is retrieved from GDACS advisories. Always follow official PAGASA and local authority guidance.',
                showDivider: false,
              ),
            ],
          ),
          const SizedBox(height: 16),
          _SettingsCategory(
            title: 'Privacy & security',
            subtitle:
                'Understand what stays on this device and what is online.',
            icon: Icons.shield_outlined,
            children: [
              const _SettingsInfoRow(
                icon: Icons.lock_outline_rounded,
                title: 'Local data protection',
                subtitle: 'Saved places and preferences are stored on this device. GPS coordinates are sent to weather and map providers when those features are used.',
              ),
              _SettingsRow(
                icon: Icons.privacy_tip_outlined,
                title: 'Privacy policy & data details',
                subtitle: 'View Banog privacy and data-source information.',
                showDivider: false,
                onTap: () => _showAbout(context),
              ),
            ],
          ),
          const SizedBox(height: 16),
          _SettingsCategory(
            title: 'About & support',
            subtitle: 'App version, sources, and important guidance.',
            icon: Icons.info_outline_rounded,
            children: [
              _SettingsRow(
                icon: Icons.info_rounded,
                title: 'About Banog',
                subtitle: 'Version, acknowledgements, sources & disclaimers',
                showDivider: false,
                onTap: () => _showAbout(context),
              ),
            ],
          ),
          const SizedBox(height: 18),
          Center(
            child: Text(
              'BANOG WEATHER  •  VERSION 1.0.0',
              style: TextStyle(
                color: _muted.withValues(alpha: 0.8),
                fontSize: 9,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.8,
              ),
            ),
          ),
          const SizedBox(height: 12),
        ],
      ),
    );
  }

  void _showSavedLocations(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _SavedLocationsPage(
          savedLocations: savedLocations,
          onSavedLocationsChanged: onSavedLocationsChanged ?? (_) {},
        ),
      ),
    );
  }

  void _showOfflineMaps(BuildContext context) {
    Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => const _OfflineMapsPage()));
  }

  void _showTripTracking(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _TripTrackingPage(initialLocation: _defaultMapLocation),
      ),
    );
  }

  Future<void> _showUnits(BuildContext context) => _showSettingsSheet<void>(
    context: context,
    icon: Icons.straighten_rounded,
    title: 'Weather units',
    subtitle: 'Choose how temperature and wind are displayed.',
    content: RadioGroup<bool>(
      groupValue: isImperial,
      onChanged: (value) {
        if (value != null) onImperialChanged?.call(value);
        Navigator.pop(context);
      },
      child: const Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          RadioListTile<bool>(
            key: ValueKey('metric-units'),
            title: Text('Metric'),
            subtitle: Text('°C · km/h · mm'),
            value: false,
          ),
          RadioListTile<bool>(
            key: ValueKey('imperial-units'),
            title: Text('Imperial'),
            subtitle: Text('°F · mph · in'),
            value: true,
          ),
        ],
      ),
    ),
  );

  Future<void> _showTimeFormat(BuildContext context) =>
      _showSettingsSheet<void>(
        context: context,
        icon: Icons.schedule_rounded,
        title: 'Time format',
        subtitle: 'Choose how forecast times are displayed.',
        content: RadioGroup<bool>(
          groupValue: use24HourTime,
          onChanged: (value) {
            if (value != null) on24HourTimeChanged?.call(value);
            Navigator.pop(context);
          },
          child: const Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              RadioListTile<bool>(
                key: ValueKey('time-format-12-hour'),
                title: Text('12-hour'),
                subtitle: Text('2:00 PM'),
                value: false,
              ),
              RadioListTile<bool>(
                key: ValueKey('time-format-24-hour'),
                title: Text('24-hour'),
                subtitle: Text('14:00'),
                value: true,
              ),
            ],
          ),
        ),
      );

  Future<void> _useCurrentLocation(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      const SnackBar(content: Text('Getting your current location...')),
    );
    final result = await DeviceLocationService.getCurrentPosition();
    if (!context.mounted) return;
    if (!result.isSuccess) {
      messenger.showSnackBar(
        SnackBar(content: Text(result.error ?? 'Location is unavailable.')),
      );
      return;
    }
    final location = result.position!;
    final label = await _reverseGeocodeLabel(location);
    if (!context.mounted) return;
    onActiveLocationChanged?.call(location, label);
    messenger.showSnackBar(
      SnackBar(content: Text('Now showing weather for $label.')),
    );
  }

  void _showInfo(BuildContext context, String title, String message) {
    _showSettingsSheet<void>(
      context: context,
      icon: Icons.info_outline_rounded,
      title: title,
      subtitle: message,
      content: const SizedBox.shrink(),
      actions: [
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Done'),
        ),
      ],
    );
  }

  Future<void> _showEmergencyContact(BuildContext context) async {
    final result = await _showSettingsSheet<(String, String)>(
      context: context,
      icon: Icons.contact_phone_rounded,
      title: 'Emergency contact',
      subtitle:
          'Saved on this device and used to prefill emergency SMS messages.',
      content: _EmergencyContactForm(
        name: emergencyContactName,
        number: emergencyContactNumber,
        onCancel: () => Navigator.pop(context),
        onSave: (name, number) => Navigator.pop(context, (name, number)),
      ),
    );
    if (result != null) {
      onEmergencyContactChanged?.call(result.$1, result.$2);
    }
  }

  Future<void> _showNotifications(BuildContext context) {
    var selectedTypes = {...enabledAlertTypes};
    return _showSettingsSheet<void>(
      context: context,
      icon: Icons.notifications_active_rounded,
      title: 'Alert preferences',
      subtitle: 'Choose which forecast alerts appear in Banog. These are in-app alerts; push notifications are not configured.',
      content: StatefulBuilder(
        builder: (context, setSheetState) => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final type in ['Rain', 'Thunderstorm', 'Wind'])
              SwitchListTile(
                key: ValueKey('alert-toggle-$type'),
                contentPadding: EdgeInsets.zero,
                title: Text(type),
                value: selectedTypes.contains(type),
                onChanged: (enabled) {
                  if (enabled) {
                    selectedTypes.add(type);
                  } else {
                    selectedTypes.remove(type);
                  }
                  onAlertTypesChanged?.call({...selectedTypes});
                  setSheetState(() {});
                },
              ),
          ],
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Done'),
        ),
      ],
    );
  }

  Future<T?> _showSettingsSheet<T>({
    required BuildContext context,
    required IconData icon,
    required String title,
    required String subtitle,
    required Widget content,
    List<Widget> actions = const [],
  }) {
    return showModalBottomSheet<T>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      backgroundColor: _surfaceColor(context),
      shape: RoundedRectangleBorder(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(26)),
        side: _isGlassBackground(context)
            ? BorderSide(
                color: _isDarkMode(context)
                    ? Colors.white.withValues(alpha: 0.16)
                    : Colors.white.withValues(alpha: 0.82),
                width: 1.2,
              )
            : BorderSide.none,
      ),
      builder: (sheetContext) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(sheetContext).bottom,
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.82,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 6, 12, 14),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(icon, color: _blue, size: 25),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title,
                            style: TextStyle(
                              color: _primaryTextColor(sheetContext),
                              fontSize: 18,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            subtitle,
                            style: TextStyle(
                              color: _secondaryTextColor(sheetContext),
                              fontSize: 11,
                              height: 1.4,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: 'Close',
                      onPressed: () => Navigator.pop(sheetContext),
                      icon: const Icon(Icons.close_rounded),
                      visualDensity: VisualDensity.compact,
                    ),
                  ],
                ),
              ),
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: content,
                ),
              ),
              if (actions.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 14),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: actions,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  void _showAppearance(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _AppearancePage(
          isDarkMode: isDarkMode,
          fontStyle: fontStyle,
          backgroundStyle: backgroundStyle,
          customBackgroundColor: customBackgroundColor,
          onDarkModeChanged: onDarkModeChanged,
          onFontStyleChanged: onFontStyleChanged ?? (_) {},
          onBackgroundStyleChanged: onBackgroundStyleChanged ?? (_) {},
          onCustomBackgroundColorChanged:
              onCustomBackgroundColorChanged ?? (_) {},
        ),
      ),
    );
  }

  void _showAbout(BuildContext context) {
    Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => const _AboutBanogPage()));
  }
}

class _SavedLocationsPage extends StatefulWidget {
  const _SavedLocationsPage({
    required this.savedLocations,
    required this.onSavedLocationsChanged,
  });

  final List<String> savedLocations;
  final ValueChanged<List<String>> onSavedLocationsChanged;

  @override
  State<_SavedLocationsPage> createState() => _SavedLocationsPageState();
}

class _SavedLocationsPageState extends State<_SavedLocationsPage> {
  final _locationController = TextEditingController();
  late List<String> _locations = [...widget.savedLocations];

  @override
  void dispose() {
    _locationController.dispose();
    super.dispose();
  }

  void _addLocation() {
    final name = _locationController.text.trim();
    if (name.isEmpty ||
        _locations.any(
          (location) => location.toLowerCase() == name.toLowerCase(),
        )) {
      return;
    }

    final updatedLocations = [..._locations, name];
    setState(() {
      _locations = updatedLocations;
      _locationController.clear();
    });
    widget.onSavedLocationsChanged(updatedLocations);
  }

  void _removeLocation(String location) {
    final updatedLocations = [..._locations]..remove(location);
    setState(() => _locations = updatedLocations);
    widget.onSavedLocationsChanged(updatedLocations);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: SafeArea(
        child: _PageScroll(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _PageHeader(
                title: 'Saved Locations',
                subtitle: 'Keep your favorite places close.',
                leading: IconButton(
                  key: const ValueKey('saved-locations-back'),
                  tooltip: 'Back',
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.arrow_back_rounded),
                ),
              ),
              const SizedBox(height: 17),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(17),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [Color(0xFF2878C7), Color(0xFF56A4DA)],
                  ),
                  borderRadius: BorderRadius.circular(22),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 46,
                      height: 46,
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.18),
                        borderRadius: BorderRadius.circular(15),
                      ),
                      child: const Icon(
                        Icons.location_on_rounded,
                        color: Colors.white,
                        size: 25,
                      ),
                    ),
                    const SizedBox(width: 13),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${_locations.length} ${_locations.length == 1 ? 'place' : 'places'} saved',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            'Your locations are stored on this device.',
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.88),
                              fontSize: 10,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 23),
              Text(
                'ADD A LOCATION',
                style: TextStyle(
                  color: _secondaryTextColor(context),
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.2,
                ),
              ),
              const SizedBox(height: 9),
              Container(
                padding: const EdgeInsets.fromLTRB(13, 4, 5, 4),
                decoration: BoxDecoration(
                  color: _surfaceColor(context),
                  borderRadius: BorderRadius.circular(17),
                  border:
                      _glassBorder(context) ??
                      Border.all(
                        color: _isDarkMode(context)
                            ? const Color(0xFF344451)
                            : const Color(0xFFE1EAF2),
                      ),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.search_rounded,
                      color: _secondaryTextColor(context),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        key: const ValueKey('saved-location-input'),
                        controller: _locationController,
                        textInputAction: TextInputAction.done,
                        onChanged: (_) => setState(() {}),
                        onSubmitted: (_) => _addLocation(),
                        decoration: const InputDecoration(
                          hintText: 'Enter a city or place name',
                          border: InputBorder.none,
                          isDense: true,
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    FilledButton(
                      key: const ValueKey('add-saved-location'),
                      onPressed: _addLocation,
                      style: FilledButton.styleFrom(
                        backgroundColor: _blue,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 15,
                          vertical: 12,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(13),
                        ),
                      ),
                      child: const Icon(Icons.add_rounded, size: 19),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Saved place names are stored locally. Forecasts use your active location, which updates when you tap the location bar or use the map locate button.',
                style: TextStyle(
                  color: _secondaryTextColor(context),
                  fontSize: 10,
                  height: 1.45,
                ),
              ),
              const SizedBox(height: 23),
              Row(
                children: [
                  Text(
                    'YOUR PLACES',
                    style: TextStyle(
                      color: _secondaryTextColor(context),
                      fontSize: 10,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.2,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    '${_locations.length}',
                    style: TextStyle(
                      color: _secondaryTextColor(context),
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 9),
              if (_locations.isEmpty)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 28,
                  ),
                  decoration: BoxDecoration(
                    color: _surfaceColor(context),
                    borderRadius: BorderRadius.circular(20),
                    border:
                        _glassBorder(context) ??
                        Border.all(
                          color: _isDarkMode(context)
                              ? const Color(0xFF344451)
                              : const Color(0xFFE4EDF5),
                        ),
                  ),
                  child: Column(
                    children: [
                      Icon(
                        Icons.location_off_outlined,
                        color: _secondaryTextColor(context),
                        size: 31,
                      ),
                      const SizedBox(height: 9),
                      Text(
                        'No saved places yet',
                        style: TextStyle(
                          color: _primaryTextColor(context),
                          fontSize: 13,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Add a city above to keep it on your list.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: _secondaryTextColor(context),
                          fontSize: 10,
                        ),
                      ),
                    ],
                  ),
                )
              else
                _SettingsGroup(
                  children: [
                    for (var index = 0; index < _locations.length; index++)
                      _SavedLocationRow(
                        key: ValueKey('saved-location-${_locations[index]}'),
                        location: _locations[index],
                        showDivider: index < _locations.length - 1,
                        onRemove: () => _removeLocation(_locations[index]),
                      ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SavedLocationRow extends StatelessWidget {
  const _SavedLocationRow({
    super.key,
    required this.location,
    required this.showDivider,
    required this.onRemove,
  });

  final String location;
  final bool showDivider;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Material(
          color: Colors.transparent,
          child: ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 14),
            leading: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: _blue.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(13),
              ),
              child: const Icon(
                Icons.location_on_outlined,
                color: _blue,
                size: 20,
              ),
            ),
            title: Text(
              location,
              style: TextStyle(
                color: _primaryTextColor(context),
                fontSize: 12,
                fontWeight: FontWeight.w800,
              ),
            ),
            subtitle: Text(
              'Saved on this device',
              style: TextStyle(
                color: _secondaryTextColor(context),
                fontSize: 9,
              ),
            ),
            trailing: IconButton(
              tooltip: 'Remove $location',
              onPressed: onRemove,
              icon: const Icon(
                Icons.delete_outline_rounded,
                color: Color(0xFFB34343),
              ),
            ),
          ),
        ),
        if (showDivider)
          Padding(
            padding: const EdgeInsets.only(left: 66),
            child: Divider(
              height: 1,
              color: _isGlassBackground(context)
                  ? (_isDarkMode(context)
                        ? Colors.white.withValues(alpha: 0.12)
                        : Colors.white.withValues(alpha: 0.35))
                  : null,
            ),
          ),
      ],
    );
  }
}

class _AppearancePage extends StatefulWidget {
  const _AppearancePage({
    required this.isDarkMode,
    required this.fontStyle,
    required this.backgroundStyle,
    this.customBackgroundColor = const Color(0xFFEDE9FE),
    required this.onDarkModeChanged,
    required this.onFontStyleChanged,
    required this.onBackgroundStyleChanged,
    this.onCustomBackgroundColorChanged,
  });

  final bool isDarkMode;
  final String fontStyle;
  final String backgroundStyle;
  final Color customBackgroundColor;
  final ValueChanged<bool> onDarkModeChanged;
  final ValueChanged<String> onFontStyleChanged;
  final ValueChanged<String> onBackgroundStyleChanged;
  final ValueChanged<Color>? onCustomBackgroundColorChanged;

  @override
  State<_AppearancePage> createState() => _AppearancePageState();
}

class _AppearancePageState extends State<_AppearancePage> {
  late bool _isDarkMode = widget.isDarkMode;
  late String _fontStyle = widget.fontStyle;
  late String _backgroundStyle = widget.backgroundStyle;
  late Color _customBackgroundColor = widget.customBackgroundColor;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: SafeArea(
        child: _PageScroll(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _PageHeader(
                title: 'Appearance',
                subtitle: 'Make Banog feel like yours.',
                leading: IconButton(
                  key: const ValueKey('appearance-back'),
                  tooltip: 'Back to settings',
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.arrow_back_rounded),
                ),
              ),
              const SizedBox(height: 17),
              _SettingsGroup(
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    child: Row(
                      children: [
                        _AppearanceIcon(
                          icon: _isDarkMode
                              ? Icons.dark_mode_rounded
                              : Icons.light_mode_rounded,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Dark theme',
                                style: TextStyle(
                                  color: _primaryTextColor(context),
                                  fontSize: 13,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                _isDarkMode
                                    ? 'Easier on the eyes in low light'
                                    : 'A bright, clear look for daytime',
                                style: TextStyle(
                                  color: _secondaryTextColor(context),
                                  fontSize: 10,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Switch.adaptive(
                          key: const ValueKey('appearance-dark-theme'),
                          value: _isDarkMode,
                          onChanged: (value) {
                            setState(() => _isDarkMode = value);
                            widget.onDarkModeChanged(value);
                          },
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 23),
              const _AppearanceSectionHeading(
                title: 'FONT STYLE',
                subtitle: 'Choose how text looks across the app.',
              ),
              const SizedBox(height: 10),
              _SettingsGroup(
                children: [
                  for (var index = 0; index < _fontStyleOptions.length; index++)
                    _AppearanceChoiceTile(
                      key: ValueKey(
                        'appearance-font-${_fontStyleOptions[index]}',
                      ),
                      title: _fontStyleOptions[index],
                      subtitle: _fontStyleOptions[index] == 'Serif'
                          ? 'Classic lettering with elegant details'
                          : 'Clean, familiar, and easy to scan',
                      selected: _fontStyle == _fontStyleOptions[index],
                      previewFontFamily: _fontFamilyFor(
                        _fontStyleOptions[index],
                      ),
                      showDivider: index < _fontStyleOptions.length - 1,
                      onTap: () {
                        final value = _fontStyleOptions[index];
                        setState(() => _fontStyle = value);
                        widget.onFontStyleChanged(value);
                      },
                    ),
                ],
              ),
              const SizedBox(height: 23),
              const _AppearanceSectionHeading(
                title: 'BACKGROUND STYLE',
                subtitle: 'Pick a color mood, frosted glass, or custom tint.',
              ),
              const SizedBox(height: 10),
              _SettingsGroup(
                children: [
                  for (
                    var index = 0;
                    index < _backgroundStyleOptions.length;
                    index++
                  ) ...[
                    _AppearanceBackgroundChoice(
                      key: ValueKey(
                        'appearance-background-${_backgroundStyleOptions[index]}',
                      ),
                      title: _backgroundStyleOptions[index],
                      selected:
                          _backgroundStyle == _backgroundStyleOptions[index],
                      color: _backgroundColorFor(
                        _backgroundStyleOptions[index],
                        _isDarkMode,
                        customColor: _customBackgroundColor,
                      ),
                      showDivider:
                          index < _backgroundStyleOptions.length - 1 ||
                          (_backgroundStyleOptions[index] == 'Custom' &&
                              _backgroundStyle == 'Custom'),
                      onTap: () {
                        final value = _backgroundStyleOptions[index];
                        setState(() => _backgroundStyle = value);
                        widget.onBackgroundStyleChanged(value);
                      },
                    ),
                    if (_backgroundStyleOptions[index] == 'Custom' &&
                        _backgroundStyle == 'Custom')
                      _CustomColorSelector(
                        selectedColor: _customBackgroundColor,
                        isDarkMode: _isDarkMode,
                        onColorSelected: (color) {
                          setState(() => _customBackgroundColor = color);
                          widget.onCustomBackgroundColorChanged?.call(color);
                        },
                      ),
                  ],
                ],
              ),
              const SizedBox(height: 14),
              Text(
                'Your appearance choices are saved on this device.',
                style: TextStyle(
                  color: _secondaryTextColor(context),
                  fontSize: 10,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CustomColorSelector extends StatefulWidget {
  const _CustomColorSelector({
    required this.selectedColor,
    required this.isDarkMode,
    required this.onColorSelected,
  });

  final Color selectedColor;
  final bool isDarkMode;
  final ValueChanged<Color> onColorSelected;

  @override
  State<_CustomColorSelector> createState() => _CustomColorSelectorState();
}

class _CustomColorSelectorState extends State<_CustomColorSelector> {
  late final TextEditingController _hexController = TextEditingController(
    text: _colorToHex(widget.selectedColor),
  );
  String? _errorText;

  @override
  void didUpdateWidget(covariant _CustomColorSelector oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selectedColor != widget.selectedColor) {
      final currentHex = _colorToHex(widget.selectedColor);
      if (_hexController.text.toUpperCase() != currentHex) {
        _hexController.text = currentHex;
      }
    }
  }

  @override
  void dispose() {
    _hexController.dispose();
    super.dispose();
  }

  void _applyHex(String input) {
    final parsed = _parseHexColor(input);
    if (parsed != null) {
      setState(() => _errorText = null);
      widget.onColorSelected(parsed);
    } else {
      setState(() => _errorText = 'Enter 6 hex digits (e.g. E0F2FE)');
    }
  }

  @override
  Widget build(BuildContext context) {
    final effectiveBg = _backgroundColorFor(
      'Custom',
      widget.isDarkMode,
      customColor: widget.selectedColor,
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 4, 14, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  color: effectiveBg,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: widget.isDarkMode
                        ? Colors.white.withValues(alpha: 0.25)
                        : _navy.withValues(alpha: 0.2),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                'PRESET TINTS',
                style: TextStyle(
                  color: _secondaryTextColor(context),
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.1,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final (color, name) in _customBackgroundSwatches)
                Tooltip(
                  message: name,
                  child: InkWell(
                    key: ValueKey('custom-swatch-${_colorToHex(color)}'),
                    onTap: () {
                      _hexController.text = _colorToHex(color);
                      setState(() => _errorText = null);
                      widget.onColorSelected(color);
                    },
                    borderRadius: BorderRadius.circular(10),
                    child: Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        color: color,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color:
                              (widget.selectedColor.toARGB32() & 0x00FFFFFF) ==
                                  (color.toARGB32() & 0x00FFFFFF)
                              ? _blue
                              : (widget.isDarkMode
                                    ? Colors.white.withValues(alpha: 0.2)
                                    : Colors.black.withValues(alpha: 0.12)),
                          width:
                              (widget.selectedColor.toARGB32() & 0x00FFFFFF) ==
                                  (color.toARGB32() & 0x00FFFFFF)
                              ? 2.5
                              : 1,
                        ),
                      ),
                      child:
                          (widget.selectedColor.toARGB32() & 0x00FFFFFF) ==
                              (color.toARGB32() & 0x00FFFFFF)
                          ? Icon(
                              Icons.check_rounded,
                              size: 16,
                              color: color.computeLuminance() > 0.5
                                  ? _navy
                                  : Colors.white,
                            )
                          : null,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 14),
          Text(
            'CUSTOM HEX CODE',
            style: TextStyle(
              color: _secondaryTextColor(context),
              fontSize: 10,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.1,
            ),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 42,
                  child: TextField(
                    key: const ValueKey('custom-hex-input'),
                    controller: _hexController,
                    textCapitalization: TextCapitalization.characters,
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(
                        RegExp(r'[0-9a-fA-F#]'),
                      ),
                      LengthLimitingTextInputFormatter(7),
                    ],
                    onSubmitted: _applyHex,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.2,
                      color: _primaryTextColor(context),
                    ),
                    decoration: InputDecoration(
                      prefixText: '# ',
                      prefixStyle: TextStyle(
                        fontWeight: FontWeight.w800,
                        color: _secondaryTextColor(context),
                      ),
                      hintText: 'EDE9FE',
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(
                          color: widget.isDarkMode
                              ? const Color(0xFF344451)
                              : const Color(0xFFE2EAF2),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                key: const ValueKey('custom-hex-apply'),
                onPressed: () => _applyHex(_hexController.text),
                style: FilledButton.styleFrom(
                  backgroundColor: _blue,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 11,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: const Text(
                  'Apply',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
          if (_errorText != null) ...[
            const SizedBox(height: 4),
            Text(
              _errorText!,
              style: const TextStyle(color: Color(0xFFDC2626), fontSize: 10),
            ),
          ],
        ],
      ),
    );
  }
}

class _AppearanceIcon extends StatelessWidget {
  const _AppearanceIcon({required this.icon});

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: _blue.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(13),
      ),
      child: Icon(icon, color: _blue, size: 21),
    );
  }
}

class _AppearanceSectionHeading extends StatelessWidget {
  const _AppearanceSectionHeading({
    required this.title,
    required this.subtitle,
  });

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: TextStyle(
            color: _secondaryTextColor(context),
            fontSize: 10,
            fontWeight: FontWeight.w800,
            letterSpacing: 1.2,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          subtitle,
          style: TextStyle(color: _secondaryTextColor(context), fontSize: 10),
        ),
      ],
    );
  }
}

class _AppearanceChoiceTile extends StatelessWidget {
  const _AppearanceChoiceTile({
    super.key,
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.previewFontFamily,
    required this.showDivider,
    required this.onTap,
  });

  final String title;
  final String subtitle;
  final bool selected;
  final String previewFontFamily;
  final bool showDivider;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Material(
          color: Colors.transparent,
          child: ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 14),
            leading: _AppearanceIcon(
              icon: title == 'Serif'
                  ? Icons.menu_book_rounded
                  : Icons.text_fields_rounded,
            ),
            title: Text(
              title,
              style: TextStyle(
                color: _primaryTextColor(context),
                fontSize: 13,
                fontWeight: FontWeight.w800,
              ),
            ),
            subtitle: Text(
              subtitle,
              style: TextStyle(
                color: _secondaryTextColor(context),
                fontSize: 10,
              ),
            ),
            trailing: Icon(
              selected ? Icons.check_circle_rounded : Icons.circle_outlined,
              color: selected ? _blue : _secondaryTextColor(context),
            ),
            onTap: onTap,
          ),
        ),
        if (showDivider)
          Padding(
            padding: const EdgeInsets.only(left: 66),
            child: Divider(
              height: 1,
              color: _isGlassBackground(context)
                  ? (_isDarkMode(context)
                        ? Colors.white.withValues(alpha: 0.12)
                        : Colors.white.withValues(alpha: 0.35))
                  : null,
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(66, 0, 14, 11),
          child: Text(
            'Banog weather  •  28°',
            style: TextStyle(
              color: _primaryTextColor(context),
              fontFamily: previewFontFamily,
              fontSize: 12,
            ),
          ),
        ),
      ],
    );
  }
}

class _AppearanceBackgroundChoice extends StatelessWidget {
  const _AppearanceBackgroundChoice({
    super.key,
    required this.title,
    required this.selected,
    required this.color,
    required this.showDivider,
    required this.onTap,
  });

  final String title;
  final bool selected;
  final Color color;
  final bool showDivider;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final dark = _isDarkMode(context);
    final isGlass = title == 'Glass';
    return Column(
      children: [
        Material(
          color: Colors.transparent,
          child: ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 14),
            leading: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: isGlass ? null : color,
                gradient: isGlass
                    ? LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: dark
                            ? const [Color(0xFF24425F), Color(0xFF152233)]
                            : const [Color(0xFFBBD9F5), Color(0xFFE8F3FE)],
                      )
                    : null,
                borderRadius: BorderRadius.circular(13),
                border: Border.all(
                  color: dark
                      ? Colors.white.withValues(alpha: 0.15)
                      : _navy.withValues(alpha: 0.12),
                ),
              ),
              child: Icon(
                _backgroundStyleIcon(title),
                color: dark ? _darkInk : _navy,
                size: 19,
              ),
            ),
            title: Text(
              title,
              style: TextStyle(
                color: _primaryTextColor(context),
                fontSize: 13,
                fontWeight: FontWeight.w800,
              ),
            ),
            subtitle: Text(
              _backgroundStyleDescription(title),
              style: TextStyle(
                color: _secondaryTextColor(context),
                fontSize: 10,
              ),
            ),
            trailing: Icon(
              selected ? Icons.check_circle_rounded : Icons.circle_outlined,
              color: selected ? _blue : _secondaryTextColor(context),
            ),
            onTap: onTap,
          ),
        ),
        if (showDivider)
          Padding(
            padding: const EdgeInsets.only(left: 66),
            child: Divider(
              height: 1,
              color: _isGlassBackground(context)
                  ? (dark
                        ? Colors.white.withValues(alpha: 0.12)
                        : Colors.white.withValues(alpha: 0.35))
                  : null,
            ),
          ),
      ],
    );
  }
}

class _AboutBanogPage extends StatelessWidget {
  const _AboutBanogPage();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: SafeArea(
        child: _PageScroll(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _PageHeader(
                title: 'About Banog',
                subtitle: 'App information, data sources, and privacy.',
                leading: IconButton(
                  key: const ValueKey('about-back'),
                  tooltip: 'Back to settings',
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.arrow_back_rounded),
                ),
              ),
              const SizedBox(height: 8),
              _SettingsGroup(
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 18),
                    child: Row(
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(14),
                          child: Image.asset(
                            'logo.jpg',
                            width: 56,
                            height: 56,
                            fit: BoxFit.cover,
                          ),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Banog Weather App',
                                style: TextStyle(
                                  color: _primaryTextColor(context),
                                  fontSize: 16,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                'Version 1.0.0+1',
                                key: const ValueKey('about-version'),
                                style: TextStyle(
                                  color: _secondaryTextColor(context),
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              _AboutSection(
                title: 'About the app',
                icon: Icons.cloud_outlined,
                content: 'Banog provides forecast-based weather information for the Philippines, including hourly forecasts, map layers, and weather outlooks.',
              ),
              const SizedBox(height: 12),
              _AboutSection(
                title: 'Weather data and sources',
                icon: Icons.public_rounded,
                content: 'Forecasts are provided by Open-Meteo. Map tiles come from OpenStreetMap and its tile partners; radar imagery is provided by RainViewer. Place search and reverse geocoding use OpenStreetMap Nominatim. Tropical cyclone data come from GDACS (JTWC advisories). These services require an internet connection.',
              ),
              const SizedBox(height: 12),
              _AboutSection(
                title: 'Privacy & data',
                icon: Icons.shield_outlined,
                content: 'Banog does not require an account. Saved locations, emergency contacts, and display preferences are stored locally on this device. When you tap use my location, the app requests GPS permission and sends the coordinates to the services listed above. Emergency SMS is composed and opened in your messaging app; Banog does not send messages on its own. Banog does not collect or operate a user account database.',
              ),
              const SizedBox(height: 12),
              _AboutSection(
                title: 'Weather alert disclaimer',
                icon: Icons.warning_amber_rounded,
                content: 'Weather alerts in Banog are generated from forecast-model estimates. They are not official warnings or emergency notifications. For urgent weather information, follow PAGASA and local authorities.',
              ),
              const SizedBox(height: 20),
              Center(
                child: Text(
                  'BANOG WEATHER · VERSION 1.0.0+1',
                  style: TextStyle(
                    color: _secondaryTextColor(context),
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.6,
                  ),
                ),
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }
}

class _AboutSection extends StatelessWidget {
  const _AboutSection({
    required this.title,
    required this.icon,
    required this.content,
  });

  final String title;
  final IconData icon;
  final String content;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _surfaceColor(context),
        borderRadius: BorderRadius.circular(18),
        border:
            _glassBorder(context) ??
            Border.all(
              color: _isDarkMode(context)
                  ? const Color(0xFF344451)
                  : const Color(0xFFE4EDF5),
            ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 19, color: _blue),
              const SizedBox(width: 9),
              Text(
                title,
                style: TextStyle(
                  color: _primaryTextColor(context),
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
          const SizedBox(height: 9),
          Text(
            content,
            style: TextStyle(
              color: _secondaryTextColor(context),
              fontSize: 12,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }
}

class _SettingsHero extends StatelessWidget {
  const _SettingsHero();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(23),
        border: _glassBorder(context),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFB7DDF8), Color(0xFFE8F5FF), Color(0xFF90C3E8)],
        ),
      ),
      child: Stack(
        children: [
          Positioned(
            right: -8,
            bottom: -49,
            child: Icon(
              Icons.landscape_rounded,
              size: 200,
              color: const Color(0xFF73A96D).withValues(alpha: 0.6),
            ),
          ),
          Positioned(
            right: 14,
            top: 13,
            child: Icon(
              Icons.wb_sunny_rounded,
              size: 42,
              color: const Color(0xFFFFD366).withValues(alpha: 0.9),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(17),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Banog Weather App',
                  style: TextStyle(
                    color: _navy,
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 5),
                const Text(
                  'Tamang impormasyon.\nLigtas na biyahe.',
                  style: TextStyle(color: _ink, fontSize: 12, height: 1.35),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Container(
                      width: 34,
                      height: 34,
                      padding: const EdgeInsets.all(2),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: _navy.withValues(alpha: 0.12),
                            blurRadius: 8,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      child: ClipOval(
                        child: Image.asset(
                          'logo.jpg',
                          key: const ValueKey('settings-brand-logo'),
                          fit: BoxFit.cover,
                        ),
                      ),
                    ),
                    const SizedBox(width: 7),
                    const Text(
                      'Your weather companion',
                      style: TextStyle(
                        color: _navy,
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SettingsGroup extends StatelessWidget {
  const _SettingsGroup({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: _surfaceColor(context),
        borderRadius: BorderRadius.circular(22),
        border: _glassBorder(context),
        boxShadow: [
          BoxShadow(
            color: _navy.withValues(alpha: 0.045),
            blurRadius: 18,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(children: children),
    );
  }
}

class _SettingsCategory extends StatelessWidget {
  const _SettingsCategory({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.children,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              icon,
              key: ValueKey('settings-category-icon-$title'),
              color: _blue,
              size: 23,
            ),
            const SizedBox(width: 11),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      color: _primaryTextColor(context),
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(
                      color: _secondaryTextColor(context),
                      fontSize: 10,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 9),
        _SettingsGroup(children: children),
      ],
    );
  }
}

class _SettingsInfoRow extends StatelessWidget {
  const _SettingsInfoRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.showDivider = true,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool showDivider;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 13),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                icon,
                key: ValueKey('settings-info-icon-$title'),
                color: _blue,
                size: 21,
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        color: _primaryTextColor(context),
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: TextStyle(
                        color: _secondaryTextColor(context),
                        fontSize: 10,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        if (showDivider)
          Divider(
            height: 1,
            color: _isGlassBackground(context)
                ? (_isDarkMode(context)
                      ? Colors.white.withValues(alpha: 0.12)
                      : Colors.white.withValues(alpha: 0.35))
                : null,
          ),
      ],
    );
  }
}

class _EmergencyContactForm extends StatefulWidget {
  const _EmergencyContactForm({
    required this.name,
    required this.number,
    required this.onCancel,
    required this.onSave,
  });

  final String name;
  final String number;
  final VoidCallback onCancel;
  final void Function(String name, String number) onSave;

  @override
  State<_EmergencyContactForm> createState() => _EmergencyContactFormState();
}

class _EmergencyContactFormState extends State<_EmergencyContactForm> {
  late final _nameController = TextEditingController(text: widget.name);
  late final _numberController = TextEditingController(text: widget.number);

  @override
  void dispose() {
    _nameController.dispose();
    _numberController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        TextField(
          key: const ValueKey('emergency-contact-name'),
          controller: _nameController,
          textInputAction: TextInputAction.next,
          decoration: const InputDecoration(
            labelText: 'Name',
            hintText: 'e.g. Barangay rescue',
            prefixIcon: Icon(Icons.person_outline_rounded),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          key: const ValueKey('emergency-contact-number'),
          controller: _numberController,
          keyboardType: TextInputType.phone,
          decoration: const InputDecoration(
            labelText: 'Mobile number',
            hintText: 'e.g. 09171234567',
            prefixIcon: Icon(Icons.phone_outlined),
          ),
        ),
        const SizedBox(height: 18),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton(onPressed: widget.onCancel, child: const Text('Cancel')),
            const SizedBox(width: 8),
            FilledButton.icon(
              onPressed: () => widget.onSave(
                _nameController.text.trim(),
                _numberController.text.trim(),
              ),
              icon: const Icon(Icons.save_outlined),
              label: const Text('Save contact'),
            ),
          ],
        ),
      ],
    );
  }
}

class _SettingsRow extends StatelessWidget {
  const _SettingsRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.showDivider = true,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final bool showDivider;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Material(
          color: Colors.transparent,
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            minLeadingWidth: 42,
            leading: Icon(
              icon,
              key: ValueKey('settings-row-icon-$title'),
              color: _blue,
              size: 22,
            ),
            title: Text(
              title,
              style: TextStyle(
                color: _primaryTextColor(context),
                fontSize: 13,
                fontWeight: FontWeight.w800,
              ),
            ),
            subtitle: Text(
              subtitle,
              style: TextStyle(
                color: _secondaryTextColor(context),
                fontSize: 10,
              ),
            ),
            trailing: Icon(
              Icons.chevron_right_rounded,
              color: _secondaryTextColor(context),
              size: 20,
            ),
            onTap: onTap,
          ),
        ),
        if (showDivider)
          Divider(
            height: 1,
            indent: 50,
            color: _isGlassBackground(context)
                ? (_isDarkMode(context)
                      ? Colors.white.withValues(alpha: 0.12)
                      : Colors.white.withValues(alpha: 0.35))
                : (_isDarkMode(context)
                      ? const Color(0xFF344451)
                      : const Color(0xFFEAF0F5)),
          ),
      ],
    );
  }
}

class _PageHeader extends StatelessWidget {
  const _PageHeader({
    required this.title,
    required this.subtitle,
    this.leading,
    this.action,
  });

  final String title;
  final String subtitle;
  final Widget? leading;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 13, 14, 16),
      child: Row(
        children: [
          ?leading,
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: _isDarkMode(context) ? _darkInk : _navy,
                    fontSize: 23,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.5,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  subtitle,
                  style: TextStyle(
                    color: _secondaryTextColor(context),
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
          ?action,
        ],
      ),
    );
  }
}

class _ChoiceChips extends StatelessWidget {
  const _ChoiceChips({
    required this.values,
    required this.selected,
    required this.onSelected,
  });

  final List<String> values;
  final String selected;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 38,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: values.length,
        separatorBuilder: (_, _) => const SizedBox(width: 7),
        itemBuilder: (context, index) {
          final value = values[index];
          final isSelected = value == selected;
          return ChoiceChip(
            label: Text(value),
            selected: isSelected,
            onSelected: (_) => onSelected(value),
            showCheckmark: false,
            backgroundColor: _surfaceColor(context),
            selectedColor: _blue,
            labelStyle: TextStyle(
              color: isSelected ? Colors.white : _secondaryTextColor(context),
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
            side: BorderSide(
              color: isSelected ? _blue : const Color(0xFFE3ECF4),
            ),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(30),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 8),
          );
        },
      ),
    );
  }
}

class _PageScroll extends StatelessWidget {
  const _PageScroll({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(18, 12, 18, 18),
      child: child,
    );
  }
}

const _monthShortNames = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

String _formatBytesShort(int bytes) {
  if (bytes < 1024) return '$bytes B';
  final kilobytes = bytes / 1024;
  if (kilobytes < 1024) return '${kilobytes.toStringAsFixed(0)} KB';
  final megabytes = kilobytes / 1024;
  if (megabytes < 1024) return '${megabytes.toStringAsFixed(1)} MB';
  return '${(megabytes / 1024).toStringAsFixed(2)} GB';
}

String _formatTimestamp(DateTime time) =>
    '${_monthShortNames[time.month - 1]} ${time.day}, ${time.year} · '
    '${time.hour.toString().padLeft(2, '0')}:'
    '${time.minute.toString().padLeft(2, '0')}';

String _formatTripDuration(Duration duration) {
  final hours = duration.inHours;
  final minutes = duration.inMinutes % 60;
  final seconds = duration.inSeconds % 60;
  if (hours > 0) return '${hours}h ${minutes}m';
  if (minutes > 0) return '${minutes}m ${seconds}s';
  return '${seconds}s';
}

class _OfflineMapsPage extends StatefulWidget {
  const _OfflineMapsPage();

  @override
  State<_OfflineMapsPage> createState() => _OfflineMapsPageState();
}

class _OfflineMapsPageState extends State<_OfflineMapsPage> {
  static const _lastDownloadKey = 'offlineMapsLastDownload';

  final Set<OfflineMapLayer> _layers = {
    OfflineMapLayer.street,
    OfflineMapLayer.terrain,
  };

  bool _isDownloading = false;
  bool _cancelRequested = false;
  OfflineDownloadProgress _progress = const OfflineDownloadProgress();
  int _storageBytes = 0;
  DateTime? _lastDownload;
  String? _statusMessage;

  @override
  void initState() {
    super.initState();
    _loadStatus();
  }

  Future<void> _loadStatus() async {
    final bytes = await OfflineMapsService.storageBytes();
    final preferences = await SharedPreferences.getInstance();
    final last = DateTime.tryParse(
      preferences.getString(_lastDownloadKey) ?? '',
    );
    if (!mounted) return;
    setState(() {
      _storageBytes = bytes;
      _lastDownload = last;
    });
  }

  Future<void> _startDownload() async {
    if (_isDownloading || _layers.isEmpty) return;
    setState(() {
      _isDownloading = true;
      _cancelRequested = false;
      _statusMessage = null;
      _progress = OfflineDownloadProgress(
        total: OfflineMapsService.tileCountFor(_layers),
      );
    });
    try {
      final result = await OfflineMapsService.download(
        layers: _layers,
        isCancelled: () => _cancelRequested,
        onProgress: (progress) {
          if (!mounted) return;
          if (progress.completed % 5 == 0 ||
              progress.done ||
              progress.total == 0) {
            setState(() => _progress = progress);
          }
        },
      );
      final preferences = await SharedPreferences.getInstance();
      final now = DateTime.now();
      await preferences.setString(_lastDownloadKey, now.toIso8601String());
      if (!mounted) return;
      setState(() {
        _isDownloading = false;
        _progress = result;
        _lastDownload = now;
        _statusMessage = result.cancelled
            ? 'Download cancelled. ${result.downloaded} tiles saved.'
            : 'Download complete. ${result.downloaded} new tiles saved, '
                  '${result.skipped} were already cached.';
      });
      // Give the cache writer isolate a moment to flush before measuring.
      await Future<void>.delayed(const Duration(milliseconds: 600));
      await _loadStatus();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _isDownloading = false;
        _statusMessage = 'Download failed: $error';
      });
    }
  }

  Future<void> _clearCache() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete offline maps?'),
        content: const Text(
          'This removes every cached map tile, including areas viewed online. '
          'You can download Eastern Samar again later.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await OfflineMapsService.clearCache();
    await _loadStatus();
    if (!mounted) return;
    setState(() {
      _progress = const OfflineDownloadProgress();
      _statusMessage = 'Offline map cache cleared.';
    });
  }

  void _toggleLayer(OfflineMapLayer layer, bool selected) {
    setState(() {
      if (selected) {
        _layers.add(layer);
      } else {
        _layers.remove(layer);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final progress = _progress;
    final percent = (progress.fraction * 100).clamp(0, 100).toStringAsFixed(0);
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: SafeArea(
        child: _PageScroll(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _PageHeader(
                title: 'Offline Maps',
                subtitle: 'Keep Eastern Samar on your device.',
                leading: IconButton(
                  key: const ValueKey('offline-maps-back'),
                  tooltip: 'Back',
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.arrow_back_rounded),
                ),
              ),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(17),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [Color(0xFF2878C7), Color(0xFF56A4DA)],
                  ),
                  borderRadius: BorderRadius.circular(22),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 46,
                      height: 46,
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.18),
                        borderRadius: BorderRadius.circular(15),
                      ),
                      child: const Icon(
                        Icons.download_for_offline_rounded,
                        color: Colors.white,
                        size: 26,
                      ),
                    ),
                    const SizedBox(width: 13),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${_formatBytesShort(_storageBytes)} cached',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            _lastDownload == null
                                ? 'No offline download yet.'
                                : 'Last download · ${_formatTimestamp(_lastDownload!)}',
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.9),
                              fontSize: 10,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 22),
              Text(
                'MAP PACKS',
                style: TextStyle(
                  color: _secondaryTextColor(context),
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.2,
                ),
              ),
              const SizedBox(height: 9),
              Container(
                decoration: BoxDecoration(
                  color: _surfaceColor(context),
                  borderRadius: BorderRadius.circular(20),
                  border:
                      _glassBorder(context) ??
                      Border.all(
                        color: _isDarkMode(context)
                            ? const Color(0xFF344451)
                            : const Color(0xFFE4EDF5),
                      ),
                ),
                clipBehavior: Clip.antiAlias,
                child: Column(
                  children: [
                    for (final layer in OfflineMapLayer.values)
                      CheckboxListTile.adaptive(
                        key: ValueKey('offline-layer-${layer.name}'),
                        value: _layers.contains(layer),
                        onChanged: !layer.supportsBulkDownload || _isDownloading
                            ? null
                            : (value) => _toggleLayer(layer, value ?? false),
                        title: Text(
                          layer.title,
                          style: TextStyle(
                            color: _primaryTextColor(context),
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        subtitle: Text(
                          layer.subtitle,
                          style: TextStyle(
                            color: _secondaryTextColor(context),
                            fontSize: 10,
                          ),
                        ),
                        secondary: Icon(switch (layer) {
                          OfflineMapLayer.street => Icons.map_outlined,
                          OfflineMapLayer.terrain => Icons.terrain_rounded,
                          OfflineMapLayer.satellite =>
                            Icons.satellite_alt_rounded,
                        }, color: layer.supportsBulkDownload ? _blue : _muted),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Zoom levels $offlineMinZoom–$offlineMaxZoom cover the whole '
                'province, from overview down to street level. Satellite is '
                'cached only for areas you open while online.',
                style: TextStyle(
                  color: _secondaryTextColor(context),
                  fontSize: 10,
                  height: 1.45,
                ),
              ),
              const SizedBox(height: 18),
              if (_isDownloading) ...[
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(15),
                  decoration: BoxDecoration(
                    color: _surfaceColor(context),
                    borderRadius: BorderRadius.circular(18),
                    border:
                        _glassBorder(context) ??
                        Border.all(
                          color: _isDarkMode(context)
                              ? const Color(0xFF344451)
                              : const Color(0xFFE2ECF4),
                        ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              'Downloading… $percent%',
                              style: TextStyle(
                                color: _primaryTextColor(context),
                                fontSize: 12,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                          Text(
                            '${progress.completed}/${progress.total}',
                            style: TextStyle(
                              color: _secondaryTextColor(context),
                              fontSize: 10,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: LinearProgressIndicator(
                          value: progress.total == 0 ? null : progress.fraction,
                          minHeight: 7,
                          backgroundColor: _isDarkMode(context)
                              ? const Color(0xFF2C3B47)
                              : const Color(0xFFE4EDF5),
                          color: _blue,
                        ),
                      ),
                      const SizedBox(height: 9),
                      Text(
                        '${_formatBytesShort(progress.bytes)} · '
                        '${progress.failed} failed',
                        style: TextStyle(
                          color: _secondaryTextColor(context),
                          fontSize: 9,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
              ],
              SizedBox(
                width: double.infinity,
                child: _isDownloading
                    ? OutlinedButton.icon(
                        key: const ValueKey('offline-maps-cancel'),
                        onPressed: () =>
                            setState(() => _cancelRequested = true),
                        icon: const Icon(Icons.stop_rounded),
                        label: const Text('Cancel download'),
                      )
                    : FilledButton.icon(
                        key: const ValueKey('offline-maps-download'),
                        onPressed: _layers.isEmpty ? null : _startDownload,
                        style: FilledButton.styleFrom(
                          backgroundColor: _blue,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                        icon: const Icon(Icons.download_rounded),
                        label: Text(
                          'Download Eastern Samar '
                          '(${OfflineMapsService.tileCountFor(_layers)} tiles)',
                        ),
                      ),
              ),
              if (_statusMessage != null) ...[
                const SizedBox(height: 10),
                Text(
                  _statusMessage!,
                  style: TextStyle(
                    color: _secondaryTextColor(context),
                    fontSize: 10,
                    height: 1.4,
                  ),
                ),
              ],
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  key: const ValueKey('offline-maps-delete'),
                  onPressed: _isDownloading ? null : _clearCache,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFFC2413B),
                    side: const BorderSide(color: Color(0xFFE9C3C0)),
                    padding: const EdgeInsets.symmetric(vertical: 13),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  icon: const Icon(Icons.delete_outline_rounded),
                  label: const Text('Delete cached maps'),
                ),
              ),
              const SizedBox(height: 16),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(13),
                decoration: BoxDecoration(
                  color: _isDarkMode(context)
                      ? const Color(0xFF202F3A)
                      : const Color(0xFFF1F7FC),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Text(
                  'Map data © OpenStreetMap contributors, HOT, and OpenTopoMap. '
                  'Please download responsibly and follow each provider\'s tile '
                  'usage policy. Forecasts, place search, and weather overlays '
                  'still need a connection.',
                  style: TextStyle(
                    color: _secondaryTextColor(context),
                    fontSize: 9,
                    height: 1.45,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TripTrackingPage extends StatefulWidget {
  const _TripTrackingPage({required this.initialLocation});

  final LatLng initialLocation;

  @override
  State<_TripTrackingPage> createState() => _TripTrackingPageState();
}

class _TripTrackingPageState extends State<_TripTrackingPage> {
  final _recorder = TripRecorder();
  final _mapController = MapController();
  StreamSubscription<List<TripPoint>>? _updatesSubscription;
  Timer? _ticker;
  List<TripPoint> _livePoints = [];
  List<SavedTrip> _savedTrips = [];
  bool _followUser = true;
  bool _ignoreCameraChange = false;

  @override
  void initState() {
    super.initState();
    _updatesSubscription = _recorder.updates.listen((points) {
      if (!mounted) return;
      setState(() => _livePoints = points);
      if (_followUser && points.isNotEmpty) {
        _centerOn(points.last.location);
      }
    });
    _loadTrips();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _updatesSubscription?.cancel();
    _recorder.dispose();
    _mapController.dispose();
    super.dispose();
  }

  Future<void> _loadTrips() async {
    final trips = await TripStorage.load();
    if (!mounted) return;
    setState(() => _savedTrips = trips);
  }

  void _centerOn(LatLng location) {
    _ignoreCameraChange = true;
    try {
      final zoom = _mapController.camera.zoom;
      _mapController.move(location, zoom < 14 ? 14 : zoom);
    } catch (_) {
      // The map may not be attached yet; the next GPS update will retry.
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _ignoreCameraChange = false;
    });
  }

  Future<void> _startTracking() async {
    final messenger = ScaffoldMessenger.of(context);
    final error = await _recorder.start();
    if (!mounted) return;
    if (error != null) {
      messenger.showSnackBar(SnackBar(content: Text(error)));
      return;
    }
    setState(() {
      _livePoints = _recorder.points;
      _followUser = true;
    });
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _recorder.isRecording) setState(() {});
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final location = _recorder.lastLocation;
      if (location != null) _centerOn(location);
    });
  }

  Future<void> _stopTracking() async {
    final messenger = ScaffoldMessenger.of(context);
    final trip = await _recorder.stop();
    _ticker?.cancel();
    _ticker = null;
    if (!mounted) return;
    setState(() => _livePoints = _recorder.points);
    if (trip == null) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Move around a little before stopping to save a trip.'),
        ),
      );
      return;
    }
    await TripStorage.add(trip);
    await _loadTrips();
    if (!mounted) return;
    messenger.showSnackBar(
      const SnackBar(content: Text('Trip saved on this device.')),
    );
  }

  Future<void> _deleteTrip(SavedTrip trip) async {
    await TripStorage.delete(trip.id);
    await _loadTrips();
  }

  @override
  Widget build(BuildContext context) {
    final isRecording = _recorder.isRecording;
    final points = _livePoints;
    final distanceKm = _recorder.distanceMeters / 1000;
    final speedKph = _recorder.currentSpeedMetersPerSecond * 3.6;
    final elapsed = _recorder.elapsed;
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: SafeArea(
        child: _PageScroll(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _PageHeader(
                title: 'GPS Trip Tracking',
                subtitle: 'Records with GPS only — no mobile data needed.',
                leading: IconButton(
                  key: const ValueKey('trip-tracking-back'),
                  tooltip: 'Back',
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.arrow_back_rounded),
                ),
              ),
              ClipRRect(
                borderRadius: BorderRadius.circular(22),
                child: SizedBox(
                  height: 300,
                  child: Stack(
                    children: [
                      FlutterMap(
                        mapController: _mapController,
                        options: MapOptions(
                          initialCenter: widget.initialLocation,
                          initialZoom: 11,
                          minZoom: 5,
                          maxZoom: 18,
                          onPositionChanged: (_, _) {
                            if (_ignoreCameraChange) return;
                            if (_followUser) {
                              setState(() => _followUser = false);
                            }
                          },
                        ),
                        children: [
                          TileLayer(
                            urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                            userAgentPackageName: 'com.example.banog',
                            maxNativeZoom: 19,
                          ),
                          if (points.length > 1)
                            PolylineLayer(
                              polylines: [
                                Polyline(
                                  points: points
                                      .map((point) => point.location)
                                      .toList(),
                                  strokeWidth: 5,
                                  color: _blue,
                                ),
                              ],
                            ),
                          if (points.isNotEmpty)
                            MarkerLayer(
                              markers: [
                                Marker(
                                  point: points.last.location,
                                  width: 40,
                                  height: 40,
                                  child: Container(
                                    decoration: BoxDecoration(
                                      color: Colors.white,
                                      shape: BoxShape.circle,
                                      border: Border.all(
                                        color: _blue,
                                        width: 3,
                                      ),
                                      boxShadow: const [
                                        BoxShadow(
                                          color: Colors.black26,
                                          blurRadius: 6,
                                        ),
                                      ],
                                    ),
                                    child: const Icon(
                                      Icons.navigation_rounded,
                                      color: _blue,
                                      size: 20,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                        ],
                      ),
                      Positioned(
                        right: 10,
                        bottom: 10,
                        child: FloatingActionButton.small(
                          heroTag: 'trip-recenter',
                          tooltip: 'Follow my location',
                          onPressed: () {
                            setState(() => _followUser = true);
                            final location = _recorder.lastLocation;
                            if (location != null) _centerOn(location);
                          },
                          backgroundColor: _surfaceColor(context),
                          foregroundColor: _blue,
                          child: const Icon(Icons.my_location_rounded),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 15),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(15),
                decoration: BoxDecoration(
                  color: _surfaceColor(context),
                  borderRadius: BorderRadius.circular(20),
                  border:
                      _glassBorder(context) ??
                      Border.all(
                        color: _isDarkMode(context)
                            ? const Color(0xFF344451)
                            : const Color(0xFFE4EDF5),
                      ),
                ),
                child: Row(
                  children: [
                    _TripStat(
                      label: 'Distance',
                      value: '${distanceKm.toStringAsFixed(2)} km',
                    ),
                    _TripStat(
                      label: 'Time',
                      value: _formatTripDuration(elapsed),
                    ),
                    _TripStat(
                      label: 'Speed',
                      value: '${speedKph.toStringAsFixed(0)} km/h',
                    ),
                    _TripStat(label: 'Points', value: '${points.length}'),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: isRecording
                    ? FilledButton.icon(
                        key: const ValueKey('trip-tracking-stop'),
                        onPressed: _stopTracking,
                        style: FilledButton.styleFrom(
                          backgroundColor: const Color(0xFFC2413B),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                        icon: const Icon(Icons.stop_rounded),
                        label: const Text('Stop and save trip'),
                      )
                    : FilledButton.icon(
                        key: const ValueKey('trip-tracking-start'),
                        onPressed: _startTracking,
                        style: FilledButton.styleFrom(
                          backgroundColor: _blue,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                        icon: const Icon(Icons.play_arrow_rounded),
                        label: const Text('Start GPS tracking'),
                      ),
              ),
              const SizedBox(height: 8),
              Text(
                isRecording
                    ? 'Recording your GPS track. Keep this screen open while '
                          'moving. The track is stored on this device.'
                    : 'Your position comes from the GPS hardware, so tracking '
                          'works without mobile data. Close this screen to stop.',
                style: TextStyle(
                  color: _secondaryTextColor(context),
                  fontSize: 10,
                  height: 1.45,
                ),
              ),
              const SizedBox(height: 22),
              Row(
                children: [
                  Text(
                    'SAVED TRIPS',
                    style: TextStyle(
                      color: _secondaryTextColor(context),
                      fontSize: 10,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.2,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    '${_savedTrips.length}',
                    style: TextStyle(
                      color: _secondaryTextColor(context),
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 9),
              if (_savedTrips.isEmpty)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 26,
                  ),
                  decoration: BoxDecoration(
                    color: _surfaceColor(context),
                    borderRadius: BorderRadius.circular(20),
                    border:
                        _glassBorder(context) ??
                        Border.all(
                          color: _isDarkMode(context)
                              ? const Color(0xFF344451)
                              : const Color(0xFFE4EDF5),
                        ),
                  ),
                  child: Column(
                    children: [
                      Icon(
                        Icons.route_outlined,
                        color: _secondaryTextColor(context),
                        size: 30,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'No saved trips yet',
                        style: TextStyle(
                          color: _primaryTextColor(context),
                          fontSize: 13,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Start tracking, then tap stop to save a trip.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: _secondaryTextColor(context),
                          fontSize: 10,
                        ),
                      ),
                    ],
                  ),
                )
              else
                for (final trip in _savedTrips)
                  Container(
                    margin: const EdgeInsets.only(bottom: 9),
                    decoration: BoxDecoration(
                      color: _surfaceColor(context),
                      borderRadius: BorderRadius.circular(17),
                      border:
                          _glassBorder(context) ??
                          Border.all(
                            color: _isDarkMode(context)
                                ? const Color(0xFF344451)
                                : const Color(0xFFE4EDF5),
                          ),
                    ),
                    child: ListTile(
                      leading: const Icon(Icons.route_rounded, color: _blue),
                      title: Text(
                        _formatTimestamp(trip.startedAt),
                        style: TextStyle(
                          color: _primaryTextColor(context),
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      subtitle: Text(
                        '${(trip.distanceMeters / 1000).toStringAsFixed(2)} km · '
                        '${_formatTripDuration(trip.duration)} · '
                        '${trip.points.length} points',
                        style: TextStyle(
                          color: _secondaryTextColor(context),
                          fontSize: 10,
                        ),
                      ),
                      trailing: IconButton(
                        key: ValueKey('trip-delete-${trip.id}'),
                        tooltip: 'Delete trip',
                        onPressed: () => _deleteTrip(trip),
                        icon: const Icon(
                          Icons.delete_outline_rounded,
                          size: 20,
                        ),
                      ),
                    ),
                  ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TripStat extends StatelessWidget {
  const _TripStat({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        children: [
          Text(
            value,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: _primaryTextColor(context),
              fontSize: 12,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: TextStyle(color: _secondaryTextColor(context), fontSize: 9),
          ),
        ],
      ),
    );
  }
}
