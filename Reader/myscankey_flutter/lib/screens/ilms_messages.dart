import '../services/ilms_auth_service.dart';
import '../services/ilms_circulation_client.dart';

String ilmsErrorMessage(Object error) {
  if (error is IlmsAuthHttpException) {
    final stage = switch (error.stage) {
      IlmsAuthStage.oauth => 'OAuth application',
      IlmsAuthStage.user => 'Connexion utilisateur',
      IlmsAuthStage.libraries => 'Liste des bibliotheques',
    };
    if (error.redirect != null) {
      final destination = switch (error.redirect!) {
        IlmsAuthRedirect.missing => 'destination non indiquee',
        IlmsAuthRedirect.login => 'page de connexion du gateway',
        IlmsAuthRedirect.sameGateway => 'autre route du gateway',
        IlmsAuthRedirect.otherOrigin => 'autre origine',
        IlmsAuthRedirect.unsafe => 'destination non validee',
      };
      return '$stage : redirection HTTP ${error.status} bloquee ($destination).';
    }
    final message = switch (error.status) {
      401 || 403 => 'Acces refuse (HTTP ${error.status}).',
      404 => 'Route ILMS introuvable (HTTP 404).',
      _ => 'ILMS a refuse la demande (HTTP ${error.status}).',
    };
    return '$stage : $message';
  }
  if (error is! IlmsClientException) return 'Operation impossible.';
  return switch (error.code) {
    'password_change' => 'Changez votre mot de passe dans le portail ILMS.',
    'no_library' => 'Aucune bibliotheque disponible pour ce compte.',
    'network' => 'Connexion interrompue. Aucune confirmation ILMS recue.',
    'storage' => 'Le journal local est indisponible.',
    'scope' =>
      'Le contexte ILMS a change. Recommencez dans la session actuelle.',
    'auth' => 'Session expiree. Reconnectez-vous.',
    'busy' => 'Cette demande est deja en cours de traitement.',
    'capacity' => 'Le journal est plein. Traitez les demandes en attente.',
    'input' => 'Verifiez les champs saisis.',
    'response' => 'La reponse ILMS est invalide. Aucune confirmation recue.',
    'denied' when error.status == 401 => 'Connexion refusee. Reconnectez-vous.',
    'denied' when error.status == 403 => 'Acces refuse par ILMS.',
    'denied' when error.status == 404 => 'Element introuvable dans ILMS.',
    'denied' when error.status == 409 => 'Conflit signale par ILMS.',
    'denied' => 'ILMS a refuse la demande (HTTP ${error.status}).',
    _ => 'Operation impossible.',
  };
}
