# Exploitation du catalogue

Les onglets du catalogue donnent accès aux notices incomplètes (titre, auteur,
éditeur, date ou type manquant), aux exemplaires à encoder, aux brouillons de
rétroconversion, à la revue des doublons et à l'import CSV d'ISBN. L'encodage
utilise toujours la station existante.

## Recherche et migration 11

Le texte recherché est normalisé en minuscules, sans accents ni marques
combinées, avec `œ` → `oe`. Les huit critères sont titre, auteur, ISBN,
accession, EPC, sujets, cote et Dewey. Les ISBN valides sont comparés en ISBN-13.
La recherche reste une recherche de sous-chaîne, sans interpréter `%` ou `_`.

Un index inversé de trigrammes SQLite standard sélectionne les candidats à
partir de trois caractères ; `instr` confirme ensuite le texte entier.
Les recherches d'un ou deux caractères parcourent le texte normalisé.
Les index de statut, d'incomplétude, de brouillon et d'ISBN servent aux listes
et à la détection des ISBN déjà présents. La migration additive reconstruit
l'index des livres existants ; les mutations locales et distantes le mettent
à jour dans leur transaction.

`flutter test test/catalogue_search_test.dart` mesure recherche et comptage sur
5 000 livres et vérifie les plans SQLite. Ces temps concernent SQLite FFI sur
le poste de développement, pas une mesure du terminal Android.

## Doublons et historique

Un ISBN-13 commun indique un candidat certain, y compris lorsqu'un ISBN-10
équivalent est stocké. Il peut s'agir de deux exemplaires physiques légitimes.
Pour les probables, ponctuation et accents sont ignorés ; similarité
Levenshtein du titre ≥ 92 % et de l'auteur ≥ 90 %. Des ISBN valides différents,
des tomes différents, ou des différences connues de sous-titre, éditeur, date,
édition ou numéro de collection excluent la paire probable. Une information
absente ne suffit pas à établir qu'il s'agit d'une réédition distincte.

Les décisions « ignorer » sont persistées localement. Leur empreinte comprend
les données bibliographiques ; une correction les remet en revue. La détection
s'exécute dans un isolate pour laisser l'interface disponible.

La fusion reste à faire. `loans.book_id` référence un exemplaire avec suppression
restreinte et un index unique autorise un seul prêt actif par livre.
`activity.book_id` référence aussi le livre ; supprimer une fiche mettrait ce
lien à NULL. Les prêts synchronisés utilisent l'identité serveur du livre.
Une fusion doit résoudre les deux EPC/accessions, les prêts actifs possibles,
l'historique, les identités serveur et les mutations distantes avant de supprimer
une fiche. La revue actuelle ne modifie aucun prêt ni aucune activité.

## Rétroconversion et export

CSV UTF-8, séparateur détecté, première colonne d'ISBN ; en-tête facultatif,
autres colonnes ignorées. Le numéro du rapport est celui de l'enregistrement
CSV (un champ entre guillemets peut contenir plusieurs lignes physiques).
Les lignes vides et les ISBN invalides sont rapportés sans appel réseau.

Le traitement avance par lots de 20 et espace les requêtes HTTP d'un même hôte
d'au moins 300 ms, y compris les requêtes internes SUDOC ISBN→PPN→XML.
Il peut être annulé puis repris ; le journal SQL survit à une fermeture.
Un même fichier retrouve son journal grâce à son empreinte SHA-256.
Le livre et le résultat « trouvé » de sa ligne sont enregistrés atomiquement.
Les erreurs avec un ISBN valide peuvent être réessayées.

Toutes les notices trouvées sont des brouillons `a_encoder` ; aucune n'est
validée ni encodée automatiquement. Si plusieurs éditions sont proposées,
la première est conservée comme proposition et ce choix est signalé dans les
notes. Le formulaire du lot 2 lève le marqueur de brouillon après validation
et enregistrement explicites par le catalogueur.

Les exports du catalogue et du rapport utilisent UTF-8 avec un seul BOM,
des en-têtes français et le séparateur Excel `;`. Le test d'export écrit puis
relit réellement un fichier et vérifie le BOM, les accents et l'échappement.
Aucun nouveau paquet n'est nécessaire.
