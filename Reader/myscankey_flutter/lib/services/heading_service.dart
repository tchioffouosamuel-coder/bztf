import 'package:flutter/services.dart';

/// Cap du terminal (boussole Android), en degrés depuis le nord. Le flux
/// n'écoute les capteurs que pendant qu'il est suivi (écran de localisation).
class HeadingService {
  static const _events = EventChannel(
    'com.bibliorfid.myscankey_flutter/heading',
  );

  Stream<double> get headings {
    // Hors application (tests, isolat de fond) : pas de canal natif. L'erreur
    // passe par le flux, où l'appelant la traite, et non par la zone.
    try {
      ServicesBinding.instance;
    } catch (_) {
      return Stream.error(StateError('Boussole indisponible.'));
    }
    return _events.receiveBroadcastStream().map(
      (value) => (value as num).toDouble(),
    );
  }
}
