import 'dart:io';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:banog/main.dart';
import 'package:banog/services/storm_tracking.dart';

void main() {
  testWidgets('shows swipeable onboarding on first launch', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const BanogWeatherApp());
    await tester.pumpAndSettle();

    expect(find.text('Meet your weather companion'), findsOneWidget);
    expect(find.byKey(const ValueKey('onboarding-art-0')), findsOneWidget);
    expect(find.byKey(const ValueKey('onboarding-page-view')), findsOneWidget);

    await tester.drag(
      find.byKey(const ValueKey('onboarding-page-view')),
      const Offset(-500, 0),
    );
    await tester.pumpAndSettle();
    expect(find.text('Plan with confidence'), findsOneWidget);
    expect(find.byKey(const ValueKey('onboarding-art-1')), findsOneWidget);

    await tester.drag(
      find.byKey(const ValueKey('onboarding-page-view')),
      const Offset(-500, 0),
    );
    await tester.pumpAndSettle();
    expect(find.text('Stay ready for the skies'), findsOneWidget);
    expect(find.byKey(const ValueKey('onboarding-art-2')), findsOneWidget);
    expect(find.byKey(const ValueKey('onboarding-final-logo')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('onboarding-next')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Banog'), findsOneWidget);
    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getBool('hasSeenOnboarding'), isTrue);
  });

  testWidgets('allows first-launch onboarding to be skipped', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const BanogWeatherApp());
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('onboarding-skip')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Banog'), findsOneWidget);
    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getBool('hasSeenOnboarding'), isTrue);
  });

  testWidgets('settings layout does not overflow on a compact screen', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SafeArea(
            bottom: false,
            child: SettingsPage(
              isDarkMode: false,
              isImperial: false,
              enabledAlertTypes: const {'Rain', 'Thunderstorm', 'Wind'},
              savedLocations: const ['General MacArthur, Eastern Samar'],
              emergencyContactName: '',
              emergencyContactNumber: '',
              onDarkModeChanged: (_) {},
              onEmergencyContactChanged: (_, _) {},
              fontStyle: 'Sans',
              backgroundStyle: 'Classic',
              onFontStyleChanged: (_) {},
              onBackgroundStyleChanged: (_) {},
              onImperialChanged: (_) {},
              onAlertTypesChanged: (_) {},
              onSavedLocationsChanged: (_) {},
            ),
          ),
          bottomNavigationBar: const SizedBox(height: 72),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Settings'), findsOneWidget);
    expect(find.byKey(const ValueKey('settings-brand-logo')), findsOneWidget);
  });

  testWidgets('renders hourly forecast data from the weather service', (
    WidgetTester tester,
  ) async {
    final firstHour = DateTime(2026, 1, 1, 10);
    final times = List.generate(
      24,
      (index) => firstHour.add(Duration(hours: index)).toIso8601String(),
    );
    final client = MockClient((request) async {
      expect(request.url.queryParameters['timezone'], 'Asia/Manila');
      return http.Response(
        jsonEncode({
          'current': {'time': times.first, 'temperature_2m': 20},
          'hourly': {
            'time': times,
            'temperature_2m': List.generate(24, (index) => 20 + index),
            'apparent_temperature': List.generate(24, (index) => 22 + index),
            'precipitation_probability': List.generate(
              24,
              (index) => index == 1 ? 15 : 0,
            ),
            'weather_code': List<int>.filled(24, 1),
            'wind_speed_10m': List<int>.filled(24, 10),
          },
        }),
        200,
      );
    });
    addTearDown(client.close);

    await tester.pumpWidget(
      MaterialApp(
        home: HomePage(forecastClient: client, alertClient: client),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('hourly-forecast-list')), findsOneWidget);
    expect(find.text('Now'), findsOneWidget);
    expect(find.text('11 AM'), findsOneWidget);
    expect(find.text('20°'), findsOneWidget);
    expect(find.text('15%'), findsOneWidget);
  });

  testWidgets('shows forecast-based alerts and filters them by hazard', (
    WidgetTester tester,
  ) async {
    final firstHour = DateTime.now();
    final roundedHour = DateTime(
      firstHour.year,
      firstHour.month,
      firstHour.day,
      firstHour.hour,
    );
    final times = List.generate(
      24,
      (index) => roundedHour.add(Duration(hours: index)).toIso8601String(),
    );
    final client = MockClient((_) async {
      return http.Response(
        jsonEncode({
          'current': {'time': times.first, 'temperature_2m': 25},
          'hourly': {
            'time': times,
            'precipitation_probability': List.generate(
              24,
              (index) => index == 2 ? 80 : 0,
            ),
            'weather_code': List.generate(
              24,
              (index) => index == 1 ? 95 : (index == 2 ? 65 : 3),
            ),
            'wind_speed_10m': List.generate(
              24,
              (index) => index == 3 ? 50 : 12,
            ),
            'temperature_2m': List<int>.filled(24, 25),
            'apparent_temperature': List<int>.filled(24, 27),
          },
        }),
        200,
      );
    });
    addTearDown(client.close);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: AlertsPage(client: client)),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Thunderstorm possible'), findsOneWidget);
    expect(find.text('Heavy rain possible'), findsOneWidget);
    expect(find.text('Strong winds possible'), findsOneWidget);
    expect(find.textContaining('not official warnings'), findsOneWidget);
    expect(find.textContaining('Send emergency SMS'), findsOneWidget);

    await tester.tap(find.text('Rain'));
    await tester.pumpAndSettle();
    expect(find.text('Heavy rain possible'), findsOneWidget);
    expect(find.text('Thunderstorm possible'), findsNothing);
    expect(find.text('Strong winds possible'), findsNothing);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AlertsPage(client: client, notificationsEnabled: false),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Send emergency SMS'), findsNothing);
  });

  testWidgets('shows storm risk while identifying unavailable LPA data', (
    WidgetTester tester,
  ) async {
    final client = MockClient((request) async {
      if (request.url.host == 'www.gdacs.org') {
        return http.Response(
          jsonEncode({
            'features': [
              {
                'geometry': {
                  'type': 'Point',
                  'coordinates': [125.6, 11.1],
                },
                'properties': {
                  'eventname': 'Test Cyclone',
                  'alertlevel': 'Red',
                  'country': 'PH',
                  'htmldescription': 'Cyclone near the region',
                  'iscurrent': 'true',
                  'severitydata': {'severity': 130, 'severityunit': 'km/h'},
                },
              },
            ],
          }),
          200,
        );
      }

      if (request.url.queryParameters.containsKey('hourly')) {
        return http.Response(
          jsonEncode({
            'current': {
              'temperature_2m': 28,
              'apparent_temperature': 32,
              'weather_code': 95,
              'wind_speed_10m': 90,
              'pressure_msl': 1008,
            },
            'hourly': {
              'precipitation_probability': List<int>.filled(24, 80),
              'weather_code': List<int>.filled(24, 95),
              'wind_speed_10m': List<int>.filled(24, 90),
            },
          }),
          200,
        );
      }

      return http.Response('Low-pressure feed unavailable', 503);
    });
    addTearDown(client.close);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StormsPage(
            client: client,
            activeLocation: const LatLng(11.1, 125.6),
            emergencyContactName: 'Emergency contact',
            emergencyContactNumber: '09170000000',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Storms & Risk'), findsOneWidget);
    expect(find.text('Test Cyclone'), findsOneWidget);
    expect(find.text('Severe'), findsOneWidget);
    expect(find.text('Low pressure data unavailable'), findsOneWidget);
    expect(find.text('No low pressure area detected'), findsNothing);
    expect(find.text('Send emergency SMS · Emergency contact'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('shows the forecast and switches between weather tabs', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues({'hasSeenOnboarding': true});
    final current = DateTime.now();
    final currentHour = DateTime(
      current.year,
      current.month,
      current.day,
      current.hour,
    );
    final times = List.generate(
      24,
      (index) => currentHour.add(Duration(hours: index)).toIso8601String(),
    );
    final client = MockClient((_) async {
      return http.Response(
        jsonEncode({
          'current': {'time': times.first, 'temperature_2m': 28},
          'hourly': {
            'time': times,
            'temperature_2m': List<int>.filled(24, 28),
            'apparent_temperature': List<int>.filled(24, 32),
            'precipitation_probability': List<int>.filled(24, 0),
            'weather_code': List<int>.filled(24, 1),
            'wind_speed_10m': List<int>.filled(24, 10),
          },
        }),
        200,
      );
    });
    addTearDown(client.close);
    await tester.pumpWidget(
      BanogWeatherApp(forecastClient: client, alertClient: client),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('Banog'), findsOneWidget);
    expect(find.text('28°'), findsWidgets);
    expect(find.text('Hourly Forecast'), findsOneWidget);
    expect(find.byKey(const ValueKey('banog-logo')), findsOneWidget);
    expect(find.byKey(const ValueKey('home-weather-mascot')), findsOneWidget);
    expect(
      Theme.of(tester.element(find.byKey(const ValueKey('home-weather-card'))))
          .brightness,
      Brightness.light,
    );
    await tester.tap(find.byKey(const ValueKey('theme-toggle')));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Switch to light theme'), findsOneWidget);
    expect(
      Theme.of(tester.element(find.byKey(const ValueKey('home-weather-card'))))
          .brightness,
      Brightness.dark,
    );
    await tester.tap(find.byKey(const ValueKey('theme-toggle')));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Switch to dark theme'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('home-settings')));
    await tester.pumpAndSettle();
    expect(find.text('Saved Locations'), findsOneWidget);
    expect(find.byKey(const ValueKey('settings-sheet-close')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('settings-sheet-close')));
    await tester.pumpAndSettle();

    final weatherCard = tester.getRect(
      find.byKey(const ValueKey('home-weather-card')),
    );
    final mascotSlot = tester.getRect(
      find.byKey(const ValueKey('home-mascot-slot')),
    );
    expect(weatherCard.width, greaterThan(300));
    expect(weatherCard.right - mascotSlot.right, lessThan(1));

    await tester.tap(find.text('Map'));
    await tester.pumpAndSettle();
    expect(find.text('Weather Map'), findsOneWidget);
    expect(find.text('General MacArthur, Eastern Samar'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('selected-location-marker-logo')),
      findsOneWidget,
    );
    expect(find.text('Radar'), findsOneWidget);
    expect(find.byTooltip('Layers'), findsOneWidget);

    await tester.tap(find.byTooltip('Layers'));
    await tester.pumpAndSettle();
    expect(find.text('Layers'), findsOneWidget);
    expect(find.text('WEATHER OVERLAY'), findsOneWidget);
    expect(find.text('BASE MAP'), findsOneWidget);
    expect(find.text('Standard'), findsOneWidget);
    expect(find.text('Humanitarian'), findsOneWidget);
    expect(find.text('Topographic'), findsOneWidget);
    expect(find.text('About the Banog weather map'), findsOneWidget);
    expect(find.textContaining('RainViewer'), findsWidgets);

    await tester.tap(find.byKey(const ValueKey('weather-overlay-Rain')));
    await tester.pumpAndSettle();
    expect(find.text('Rain & wind refresh every 15 minutes'), findsOneWidget);

    await tester.tap(find.byTooltip('Layers'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('weather-overlay-Wind')));
    await tester.pumpAndSettle();
    expect(find.text('Rain & wind refresh every 15 minutes'), findsOneWidget);

    await tester.tap(find.byTooltip('Layers'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('weather-overlay-Satellite')));
    await tester.pumpAndSettle();
    expect(find.text('Satellite imagery · Esri'), findsOneWidget);

    await tester.tap(find.byTooltip('Layers'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Topographic'));
    await tester.tap(find.text('Topographic'));
    await tester.pumpAndSettle();
    expect(find.text('Weather Map'), findsOneWidget);

    await tester.tap(find.text('Alerts'));
    await tester.pumpAndSettle();
    expect(find.text('Weather Alerts'), findsOneWidget);
    expect(
      find.textContaining('No significant rain, thunderstorm, or strong wind'),
      findsOneWidget,
    );

    await tester.tap(find.text('Thunderstorm'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('No significant rain, thunderstorm, or strong wind'),
      findsOneWidget,
    );

    await tester.tap(find.text('Home'));
    await tester.pumpAndSettle();
    expect(find.byType(BottomAppBar), findsOneWidget);
    expect(
      tester.widget<BottomAppBar>(find.byType(BottomAppBar)).shape,
      isA<CircularNotchedRectangle>(),
    );
    await tester.tap(find.byKey(const ValueKey('bottom-nav-add')));
    await tester.pumpAndSettle();
    expect(find.text('Quick actions'), findsOneWidget);
    expect(find.text('Ebakwet Chat AI'), findsOneWidget);
    expect(find.text('Emergency Help'), findsOneWidget);
    expect(find.text('SafeTrack'), findsOneWidget);
    expect(find.text('Evacuation Guide'), findsOneWidget);
    expect(find.text('Safety Checklist'), findsOneWidget);
    expect(
      tester
          .widget<Image>(
            find.byKey(const ValueKey('quick-action-ebakwet-image')),
          )
          .image,
      isA<AssetImage>(),
    );

    await tester.tap(find.byKey(const ValueKey('quick-action-safetrack')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('SafeTrack'), findsOneWidget);
    expect(
      find.textContaining('Route to a nearby mapped evacuation point'),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('safetrack-destination-image')),
        matching: find.byIcon(Icons.location_city_rounded),
      ),
      findsOneWidget,
    );
    expect(
      tester
          .getSize(find.byKey(const ValueKey('safetrack-destination-image')))
          .height,
      150,
    );
    expect(
      find.text('Choose a point on the map or search nearby'),
      findsOneWidget,
    );
    final collapsedSheetHeight = tester
        .getSize(find.byKey(const ValueKey('safetrack-sheet-panel')))
        .height;
    await tester.drag(
      find.byKey(const ValueKey('safetrack-sheet-handle')),
      const Offset(0, -220),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    final expandedSheetHeight = tester
        .getSize(find.byKey(const ValueKey('safetrack-sheet-panel')))
        .height;
    expect(expandedSheetHeight, greaterThan(collapsedSheetHeight));
    await tester.drag(
      find.byKey(const ValueKey('safetrack-sheet-handle')),
      const Offset(0, 250),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(
      tester
          .getSize(find.byKey(const ValueKey('safetrack-sheet-panel')))
          .height,
      lessThan(expandedSheetHeight),
    );
    await tester.drag(
      find.byKey(const ValueKey('safetrack-sheet-handle')),
      const Offset(0, -180),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byKey(const ValueKey('safetrack-search')), findsOneWidget);
    await tester.ensureVisible(find.byKey(const ValueKey('safetrack-search')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('safetrack-search')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(
      find.byKey(const ValueKey('safetrack-search-field')),
      findsOneWidget,
    );
    await tester.enterText(
      find.byKey(const ValueKey('safetrack-search-field')),
      'General MacArthur',
    );
    await tester.pump();
    expect(
      tester
          .widget<TextField>(
            find.byKey(const ValueKey('safetrack-search-field')),
          )
          .controller!
          .text,
      'General MacArthur',
    );
    await tester.tap(find.text('Close'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.tap(find.byKey(const ValueKey('safetrack-back')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('bottom-nav-add')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('quick-action-ebakwet')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('ebakwet-chat-avatar')), findsOneWidget);
    expect(
      tester
          .widget<Image>(find.byKey(const ValueKey('ebakwet-chat-avatar')))
          .image,
      isA<AssetImage>(),
    );
    expect(
      find.text(
        'Guided answers are available now. An AI model is not '
        'connected yet; for urgent danger, call 911.',
      ),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('quick-action-back')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('bottom-nav-add')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('quick-action-emergency')));
    await tester.pumpAndSettle();
    expect(find.text('Emergency Help'), findsOneWidget);
    expect(find.byKey(const ValueKey('emergency-call-911')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('quick-action-back')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('bottom-nav-add')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('quick-action-evacuation')));
    await tester.pumpAndSettle();
    expect(find.text('Evacuation Guide'), findsOneWidget);
    expect(find.text('Before you leave'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('quick-action-back')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('bottom-nav-add')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('quick-action-checklist')));
    await tester.pumpAndSettle();
    expect(find.text('Safety Checklist'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('safety-check-0')));
    await tester.pumpAndSettle();
    expect(find.text('1 of 7 items ready'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('quick-action-back')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('home-settings')));
    await tester.pumpAndSettle();
    expect(find.text('Saved Locations'), findsOneWidget);
    expect(find.text('General settings'), findsOneWidget);
    expect(find.text('Location & GPS'), findsOneWidget);
    expect(find.text('Offline & data management'), findsOneWidget);
    expect(find.text('AI configuration'), findsOneWidget);
    expect(find.text('Privacy & security'), findsOneWidget);
    expect(find.text('About Banog'), findsOneWidget);
    expect(find.byKey(const ValueKey('settings-brand-logo')), findsOneWidget);
    expect(
      tester.widget<Icon>(
        find.byKey(const ValueKey('settings-category-icon-General settings')),
      ),
      isA<Icon>(),
    );
    expect(
      tester.widget<Icon>(
        find.byKey(const ValueKey('settings-row-icon-Saved Locations')),
      ),
      isA<Icon>(),
    );
    await tester.ensureVisible(
      find.byKey(const ValueKey('settings-notifications-toggle')),
    );
    await tester.tap(
      find.byKey(const ValueKey('settings-notifications-toggle')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Forecast alerts are hidden in Banog'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey('settings-notifications-toggle')),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Saved Locations'));
    await tester.tap(find.text('Saved Locations'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('saved-locations-back')), findsOneWidget);
    expect(find.text('YOUR PLACES'), findsOneWidget);
    expect(find.text('1 place saved'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('saved-location-input')),
      'Tacloban City',
    );
    await tester.ensureVisible(
      find.byKey(const ValueKey('add-saved-location')),
    );
    await tester.tap(find.byKey(const ValueKey('add-saved-location')));
    await tester.pumpAndSettle();
    expect(find.text('Tacloban City'), findsOneWidget);
    expect(find.text('2 places saved'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('saved-locations-back')));
    await tester.pumpAndSettle();
    expect(find.textContaining('2 saved ·'), findsOneWidget);

    await tester.ensureVisible(find.text('Temperature & wind units'));
    await tester.tap(find.text('Temperature & wind units'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('imperial-units')));
    await tester.pumpAndSettle();
    expect(find.text('°F, mph, in'), findsOneWidget);

    await tester.ensureVisible(find.text('Time format'));
    await tester.tap(find.text('Time format'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('time-format-24-hour')));
    await tester.pumpAndSettle();
    expect(find.text('24-hour · 14:00'), findsOneWidget);
    await tester.tap(find.text('Time format'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('time-format-12-hour')));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Weather alert preferences'));
    await tester.tap(find.text('Weather alert preferences'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('push notifications are not configured'),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('alert-toggle-Rain')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(find.text('2 alert types enabled'), findsOneWidget);

    await tester.ensureVisible(find.text('Emergency contact'));
    await tester.tap(find.text('Emergency contact'));
    await tester.pumpAndSettle();
    expect(
      find.text(
        'Saved on this device and used to prefill emergency SMS messages.',
      ),
      findsOneWidget,
    );
    await tester.enterText(
      find.byKey(const ValueKey('emergency-contact-name')),
      'Barangay rescue',
    );
    await tester.enterText(
      find.byKey(const ValueKey('emergency-contact-number')),
      '09171234567',
    );
    await tester.tap(find.text('Save contact'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('settings-sheet-close')), findsOneWidget);

    await tester.ensureVisible(find.text('Theme & display'));
    await tester.tap(find.text('Theme & display'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('appearance-back')), findsOneWidget);
    expect(find.text('FONT STYLE'), findsOneWidget);
    expect(find.text('BACKGROUND STYLE'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('appearance-dark-theme')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.byKey(const ValueKey('appearance-font-Serif')),
    );
    await tester.tap(find.byKey(const ValueKey('appearance-font-Serif')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.byKey(const ValueKey('appearance-background-Sky')),
    );
    await tester.tap(find.byKey(const ValueKey('appearance-background-Sky')));
    await tester.pumpAndSettle();
    expect(
      Theme.of(tester.element(find.byKey(const ValueKey('appearance-back'))))
          .scaffoldBackgroundColor,
      const Color(0xFF101C28),
    );
    await tester.ensureVisible(find.byKey(const ValueKey('appearance-back')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('appearance-back')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Dark · Serif · Sky'), findsOneWidget);

    await tester.ensureVisible(find.text('About Banog'));
    await tester.tap(find.text('About Banog'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('about-version')), findsOneWidget);
    expect(find.text('Privacy & data'), findsOneWidget);
    expect(find.text('Weather data and sources'), findsOneWidget);
    expect(find.text('Weather alert disclaimer'), findsOneWidget);
    expect(find.byKey(const ValueKey('about-back')), findsOneWidget);
    final aboutBack = tester.getRect(find.byKey(const ValueKey('about-back')));
    final aboutTitle = tester.getRect(find.text('About Banog').last);
    expect(aboutBack.center.dx, lessThan(aboutTitle.left));
    await tester.tap(find.byKey(const ValueKey('about-back')));
    await tester.pumpAndSettle();
    expect(find.text('Settings'), findsOneWidget);

    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getStringList('savedLocations'), [
      'General MacArthur, Eastern Samar',
      'Tacloban City',
    ]);
    expect(preferences.getBool('imperialUnits'), isTrue);
    expect(preferences.getBool('use24HourTime'), isFalse);
    expect(preferences.getBool('notificationsEnabled'), isTrue);
    expect(preferences.getBool('darkMode'), isTrue);
    expect(preferences.getString('fontStyle'), 'Serif');
    expect(preferences.getString('backgroundStyle'), 'Sky');
    expect(preferences.getStringList('enabledAlertTypes'), [
      'Thunderstorm',
      'Wind',
    ]);
    expect(preferences.getString('emergencyContactName'), 'Barangay rescue');
    expect(preferences.getString('emergencyContactNumber'), '09171234567');

    await tester.tap(find.byKey(const ValueKey('settings-sheet-close')));
    await tester.pumpAndSettle();
    expect(find.text('82°'), findsWidgets);
    expect(find.byTooltip('Feels like 90°'), findsWidgets);
  });

  testWidgets('searching an area highlights its bundled boundary', (
    WidgetTester tester,
  ) async {
    const pathProviderChannel = MethodChannel(
      'plugins.flutter.io/path_provider',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, (call) async {
          if (call.method == 'getApplicationCacheDirectory') {
            return Directory.systemTemp.path;
          }
          throw MissingPluginException('Unexpected method ${call.method}');
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(pathProviderChannel, null),
    );

    final client = MockClient((request) async {
      return http.Response(
        jsonEncode([
          {
            'name': 'Eastern Samar',
            'display_name': 'Eastern Samar, Eastern Visayas, Philippines',
            'addresstype': 'state',
            'lat': '11.73',
            'lon': '125.37',
          },
        ]),
        200,
        headers: const {'content-type': 'application/json'},
      );
    });
    addTearDown(client.close);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MapPage(client: client, useIsolateForBoundaryLookup: false),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'Eastern Samar');
    await tester.tap(find.byTooltip('Search location'));
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();
    await tester.pump();

    final boundaryLayer = tester.widget<PolygonLayer>(
      find.byType(PolygonLayer),
    );
    expect(boundaryLayer.polygons, isNotEmpty);
    expect(boundaryLayer.polygons.first.points.length, greaterThan(3));
    expect(find.byTooltip('Clear highlight'), findsOneWidget);
    expect(find.text('Eastern Samar'), findsWidgets);

    await tester.tap(find.byTooltip('Clear highlight'));
    await tester.pump();
    expect(find.byType(PolygonLayer), findsNothing);
  });

  testWidgets(
    'allows selecting and customizing a custom background style in settings',
    (WidgetTester tester) async {
      SharedPreferences.setMockInitialValues({'hasSeenOnboarding': true});
      final firstHour = DateTime.now();
      final times = List.generate(
        24,
        (index) => firstHour.add(Duration(hours: index)).toIso8601String(),
      );
      final client = MockClient((_) async {
        return http.Response(
          jsonEncode({
            'current': {'time': times.first, 'temperature_2m': 28},
            'hourly': {
              'time': times,
              'temperature_2m': List<int>.filled(24, 28),
              'apparent_temperature': List<int>.filled(24, 32),
              'precipitation_probability': List<int>.filled(24, 0),
              'weather_code': List<int>.filled(24, 1),
              'wind_speed_10m': List<int>.filled(24, 10),
            },
          }),
          200,
        );
      });
      addTearDown(client.close);

      await tester.pumpWidget(
        BanogWeatherApp(forecastClient: client, alertClient: client),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      await tester.tap(find.byKey(const ValueKey('home-settings')));
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.text('Theme & display'));
      await tester.tap(find.text('Theme & display'));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('appearance-back')), findsOneWidget);
      expect(find.text('BACKGROUND STYLE'), findsOneWidget);

      await tester.ensureVisible(
        find.byKey(const ValueKey('appearance-background-Custom')),
      );
      await tester.tap(
        find.byKey(const ValueKey('appearance-background-Custom')),
      );
      await tester.pumpAndSettle();

      expect(find.text('PRESET TINTS'), findsOneWidget);
      expect(find.text('CUSTOM HEX CODE'), findsOneWidget);
      expect(find.byKey(const ValueKey('custom-hex-input')), findsOneWidget);

      await tester.ensureVisible(
        find.byKey(const ValueKey('custom-swatch-D1FAE5')),
      );
      await tester.tap(find.byKey(const ValueKey('custom-swatch-D1FAE5')));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const ValueKey('custom-hex-input')),
        'E0F2FE',
      );
      await tester.tap(find.byKey(const ValueKey('custom-hex-apply')));
      await tester.pumpAndSettle();

      expect(
        Theme.of(tester.element(find.byKey(const ValueKey('appearance-back'))))
            .scaffoldBackgroundColor,
        const Color(0xFFE0F2FE),
      );

      await tester.ensureVisible(find.byKey(const ValueKey('appearance-back')));
      await tester.tap(find.byKey(const ValueKey('appearance-back')));
      await tester.pumpAndSettle();

      expect(find.textContaining('Light · Sans · Custom'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('settings-sheet-close')));
      await tester.pumpAndSettle();

      final preferences = await SharedPreferences.getInstance();
      expect(preferences.getString('backgroundStyle'), 'Custom');
      expect(
        preferences.getInt('customBackgroundColor'),
        const Color(0xFFE0F2FE).toARGB32(),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('hides and restores map chrome in full-screen mode', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues({'hasSeenOnboarding': true});
    final current = DateTime.now();
    final currentHour = DateTime(
      current.year,
      current.month,
      current.day,
      current.hour,
    );
    final times = List.generate(
      24,
      (index) => currentHour.add(Duration(hours: index)).toIso8601String(),
    );
    final client = MockClient((_) async {
      return http.Response(
        jsonEncode({
          'current': {'time': times.first, 'temperature_2m': 28},
          'hourly': {
            'time': times,
            'temperature_2m': List<int>.filled(24, 28),
            'apparent_temperature': List<int>.filled(24, 32),
            'precipitation_probability': List<int>.filled(24, 0),
            'weather_code': List<int>.filled(24, 1),
            'wind_speed_10m': List<int>.filled(24, 10),
          },
        }),
        200,
      );
    });
    addTearDown(client.close);
    await tester.pumpWidget(
      BanogWeatherApp(forecastClient: client, alertClient: client),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    await tester.tap(find.text('Map'));
    await tester.pumpAndSettle();
    expect(find.text('Weather Map'), findsOneWidget);
    expect(find.byKey(const ValueKey('bottom-nav-add')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('map-immersive-toggle')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('bottom-nav-add')), findsNothing);
    expect(find.text('Weather Map'), findsNothing);
    expect(find.byTooltip('Layers'), findsNothing);
    expect(find.byTooltip('Show map controls'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('map-immersive-toggle')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('bottom-nav-add')), findsOneWidget);
    expect(find.text('Weather Map'), findsOneWidget);
    expect(find.byTooltip('Layers'), findsOneWidget);
  });

  testWidgets(
    'allows selecting glass background style and renders translucent settings',
    (WidgetTester tester) async {
      SharedPreferences.setMockInitialValues({'hasSeenOnboarding': true});
      final firstHour = DateTime.now();
      final times = List.generate(
        24,
        (index) => firstHour.add(Duration(hours: index)).toIso8601String(),
      );
      final client = MockClient((_) async {
        return http.Response(
          jsonEncode({
            'current': {'time': times.first, 'temperature_2m': 28},
            'hourly': {
              'time': times,
              'temperature_2m': List<int>.filled(24, 28),
              'apparent_temperature': List<int>.filled(24, 32),
              'precipitation_probability': List<int>.filled(24, 0),
              'weather_code': List<int>.filled(24, 1),
              'wind_speed_10m': List<int>.filled(24, 10),
            },
          }),
          200,
        );
      });
      addTearDown(client.close);

      await tester.pumpWidget(
        BanogWeatherApp(forecastClient: client, alertClient: client),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      await tester.tap(find.byKey(const ValueKey('home-settings')));
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.text('Theme & display'));
      await tester.tap(find.text('Theme & display'));
      await tester.pumpAndSettle();

      await tester.ensureVisible(
        find.byKey(const ValueKey('appearance-background-Glass')),
      );
      await tester.tap(
        find.byKey(const ValueKey('appearance-background-Glass')),
      );
      await tester.pumpAndSettle();

      expect(find.text('Frosted glass over a soft gradient'), findsOneWidget);

      await tester.ensureVisible(find.byKey(const ValueKey('appearance-back')));
      await tester.tap(find.byKey(const ValueKey('appearance-back')));
      await tester.pumpAndSettle();

      expect(find.textContaining('Glass'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('toggles typhoon tracks and PAR boundary in map layers sheet', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues({'hasSeenOnboarding': true});
    final current = DateTime.now();
    final times = List.generate(
      24,
      (index) => current.add(Duration(hours: index)).toIso8601String(),
    );
    final client = MockClient((request) async {
      if (request.url.path.contains('/public/weather-maps.json')) {
        return http.Response(
          jsonEncode({
            'host': 'https://tilecache.rainviewer.com',
            'radar': {
              'past': [
                {
                  'time': current.millisecondsSinceEpoch ~/ 1000,
                  'path': '/v2/radar/now',
                },
              ],
            },
          }),
          200,
        );
      }
      if (request.url.host == 'www.gdacs.org') {
        if (request.url.path.contains('geteventlist')) {
          return http.Response(
            jsonEncode({
              'features': [_widgetStormFeature()],
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
                    'timeline': 'https://www.gdacs.org/gdacsapi/api/export/gettimeline?id=100',
                  },
                },
              },
            }),
            200,
          );
        }
        return http.Response(jsonEncode(_widgetTimeline()), 200);
      }
      return http.Response(
        jsonEncode({
          'current': {'time': times.first, 'temperature_2m': 28},
          'hourly': {
            'time': times,
            'temperature_2m': List<int>.filled(24, 28),
            'apparent_temperature': List<int>.filled(24, 32),
            'precipitation_probability': List<int>.filled(24, 0),
            'weather_code': List<int>.filled(24, 1),
            'wind_speed_10m': List<int>.filled(24, 10),
          },
        }),
        200,
      );
    });
    addTearDown(client.close);

    await tester.pumpWidget(
      BanogWeatherApp(forecastClient: client, alertClient: client),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    await tester.tap(find.text('Map'));
    await tester.pumpAndSettle();

    expect(find.byTooltip('Layers'), findsOneWidget);
    await tester.tap(find.byTooltip('Layers'));
    await tester.pumpAndSettle();

    expect(find.text('TYPHOON TRACK'), findsOneWidget);
    await tester.ensureVisible(
      find.byKey(const ValueKey('typhoon-tracks-toggle')),
    );
    expect(find.byKey(const ValueKey('typhoon-tracks-toggle')), findsOneWidget);
    expect(find.byKey(const ValueKey('par-boundary-toggle')), findsOneWidget);

    // Toggle typhoon tracks on
    await tester.tap(find.byKey(const ValueKey('typhoon-tracks-toggle')));
    await tester.pumpAndSettle();

    // Close layers sheet by tapping outside or dragging down
    await tester.tapAt(const Offset(20, 20));
    await tester.pumpAndSettle();

    // PAR boundary in legend and Typhoon legend should now be visible on map
    expect(find.text('PAR boundary'), findsOneWidget);
    expect(find.text('Typhoon track'), findsOneWidget);

    // Past-track points carry timestamp label markers (every ~24h) plus a
    // dot on each observed point; the current point keeps the storm marker.
    final markerLayers = tester.widgetList<MarkerLayer>(
      find.byType(MarkerLayer),
    );
    final typhoonMarkers = markerLayers
        .map((layer) => layer.markers)
        .expand((markers) => markers)
        .toSet();
    expect(
      typhoonMarkers.any(
        (marker) =>
            marker.point == const LatLng(10.0, 130.0) &&
            marker.width == 68 &&
            marker.alignment == Alignment.bottomCenter,
      ),
      isTrue,
      reason: 'First observed point should have a timestamp label marker.',
    );
    expect(
      typhoonMarkers.any(
        (marker) =>
            marker.point == const LatLng(10.5, 129.0) && marker.width == 160,
      ),
      isTrue,
      reason: 'Current position should keep the labelled cyclone marker.',
    );

    final playButton = find.byKey(const ValueKey('typhoon-playback-toggle'));
    expect(playButton, findsOneWidget);
    expect(
      find.byKey(const ValueKey('typhoon-playback-speed')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('typhoon-playback-slider')),
      findsOneWidget,
    );

    await tester.tap(playButton);
    await tester.pump();
    expect(find.byTooltip('Pause typhoon timeline'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('typhoon-playback-speed')));
    await tester.pump();
    expect(find.text('2x'), findsOneWidget);

    await tester.tap(find.byTooltip('Pause typhoon timeline'));
    await tester.pump();
    expect(find.byTooltip('Play typhoon timeline'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('typhoon-playback-reset')));
    await tester.pump();
    expect(find.byTooltip('Play typhoon timeline'), findsOneWidget);

    final polygonLayers = tester.widgetList<PolygonLayer>(
      find.byType(PolygonLayer),
    );
    expect(
      polygonLayers.any(
        (layer) => layer.polygons.any((p) => p.points == ParBoundary.vertices),
      ),
      isTrue,
    );
    expect(tester.takeException(), isNull);
  });
  testWidgets('previews the last PAR storm when no cyclone is active', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues({'hasSeenOnboarding': true});
    final current = DateTime.now();
    final times = List.generate(
      24,
      (index) => current.add(Duration(hours: index)).toIso8601String(),
    );
    final client = MockClient((request) async {
      if (request.url.path.contains('/public/weather-maps.json')) {
        return http.Response(
          jsonEncode({
            'host': 'https://tilecache.rainviewer.com',
            'radar': {
              'past': [
                {
                  'time': current.millisecondsSinceEpoch ~/ 1000,
                  'path': '/v2/radar/now',
                },
              ],
            },
          }),
          200,
        );
      }
      if (request.url.host == 'www.gdacs.org') {
        if (request.url.path.contains('geteventlist')) {
          return http.Response(
            jsonEncode({
              'features': [
                _widgetStormFeature(
                  isCurrent: false,
                  name: 'Past Cyclone',
                  eventId: 300,
                  episodeId: 400,
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
        return http.Response(jsonEncode(_widgetTimeline()), 200);
      }
      return http.Response(
        jsonEncode({
          'current': {'time': times.first, 'temperature_2m': 28},
          'hourly': {
            'time': times,
            'temperature_2m': List<int>.filled(24, 28),
            'apparent_temperature': List<int>.filled(24, 32),
            'precipitation_probability': List<int>.filled(24, 0),
            'weather_code': List<int>.filled(24, 1),
            'wind_speed_10m': List<int>.filled(24, 10),
          },
        }),
        200,
      );
    });
    addTearDown(client.close);

    await tester.pumpWidget(
      BanogWeatherApp(forecastClient: client, alertClient: client),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    await tester.tap(find.text('Map'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Layers'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.byKey(const ValueKey('typhoon-tracks-toggle')),
    );
    await tester.tap(find.byKey(const ValueKey('typhoon-tracks-toggle')));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(20, 20));
    await tester.pumpAndSettle();

    expect(find.text('No active storm near the PAR.'), findsOneWidget);
    final previewButton = find.byKey(const ValueKey('typhoon-preview-button'));
    expect(previewButton, findsOneWidget);

    await tester.tap(previewButton);
    await tester.pumpAndSettle();

    expect(find.text('Typhoon replay'), findsOneWidget);
    expect(find.byTooltip('Play typhoon timeline'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('typhoon-playback-slider')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('typhoon-playback-toggle')));
    await tester.pump();
    expect(find.byTooltip('Pause typhoon timeline'), findsOneWidget);
    await tester.tap(find.byTooltip('Pause typhoon timeline'));
    await tester.pump();

    expect(tester.takeException(), isNull);
  });
}

Map<String, dynamic> _widgetStormFeature({
  bool isCurrent = true,
  String name = 'Test Cyclone',
  int eventId = 100,
  int episodeId = 200,
}) {
  return {
    'geometry': {
      'type': 'Point',
      'coordinates': [130, 10],
    },
    'properties': {
      'eventid': eventId,
      'episodeid': episodeId,
      'eventname': name,
      'alertlevel': 'Green',
      'country': 'PH',
      'htmldescription': '',
      'iscurrent': isCurrent ? 'true' : 'false',
      'fromdate': isCurrent ? null : '2026-11-01T00:00:00',
      'todate': isCurrent ? null : '2026-11-02T06:00:00',
      'severitydata': {'severity': 100, 'severityunit': 'km/h'},
    },
  };
}

Map<String, dynamic> _widgetTimeline() {
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
          'wind_speed': '20',
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
