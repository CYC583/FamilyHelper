// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
import 'package:geolocator/geolocator.dart';
import '../common/firebase_service.dart';

class SosService {
  final FirebaseService api;
  SosService(this.api);
  Future<Map<String, dynamic>> send(String type) async {
    Map<String, dynamic>? location;
    if (type == 'sos') {
      // SOS is not blocked by a denied, disabled or slow location provider.
      // Permission is configured beforehand; never delay an SOS with a prompt.
      try {
        final permission = await Geolocator.checkPermission();
        if (permission == LocationPermission.whileInUse ||
            permission == LocationPermission.always) {
          final point = await Geolocator.getCurrentPosition(
            locationSettings: const LocationSettings(
              accuracy: LocationAccuracy.high,
              timeLimit: Duration(seconds: 6),
            ),
          );
          if (DateTime.now().difference(point.timestamp).inSeconds.abs() <=
              120) {
            location = {
              'lat': point.latitude,
              'lng': point.longitude,
              'accuracy': point.accuracy,
              'time': point.timestamp.millisecondsSinceEpoch,
            };
          }
        }
      } catch (_) {
        /* An alert without location is still sent. */
      }
    }
    return api.call('sendAlert', {
      'type': type,
      // Grandma's own press: ring the family and open a call (呼叫 also shares the screen).
      'withCall': true,
      if (location != null) 'location': location,
    });
  }
}
