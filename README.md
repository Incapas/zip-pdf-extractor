
# Zip PDF Extractor

> Récupérez tous les PDF d'une archive ZIP en un double-clic, sans rien installer et sans que rien ne quitte le poste.

Outil Windows qui ouvre une archive `.zip`, en extrait le contenu dans un dossier temporaire, y recherche tous les fichiers PDF quel que soit leur niveau d'imbrication, puis les rassemble dans `Téléchargements\extraction_pdf_<nom de l'archive>`.

![PowerShell](https://img.shields.io/badge/PowerShell-5.1-5391FE?logo=powershell&logoColor=white)
![Windows](https://img.shields.io/badge/Windows-10%20%7C%2011-0078D4?logo=windows&logoColor=white)
![Droits](https://img.shields.io/badge/droits%20admin-non%20requis-16a34a)
![Recette](https://img.shields.io/badge/recette%20Windows-à%20réaliser-ca8a04)

---

## Le problème

Les PDF reçus en archive — relevés, bulletins, factures, pièces justificatives — sont souvent éparpillés dans plusieurs sous-dossiers. Les récupérer à la main oblige à décompresser, fouiller chaque dossier, copier les fichiers un par un et arbitrer entre deux `releve.pdf` qui s'écrasent. Les services en ligne qui automatisent la tâche imposent d'envoyer des documents parfois sensibles sur un serveur tiers, et les postes sans droits administrateur ne permettent pas d'installer d'outil dédié.

Cet outil fait tout le travail localement, avec les seuls composants déjà présents dans Windows.

## Fonctionnalités

- **Lancement par double-clic** sur `Extraire-PDF.bat`, sans modifier la stratégie d'exécution PowerShell du poste ni demander de droits administrateur.
- **Choix de l'archive dans une fenêtre Windows standard**, ouverte sur le dossier Téléchargements et filtrée sur les `.zip`.
- **Un dossier de destination par archive**, nommé d'après elle : `factures.zip` donne `Téléchargements\extraction_pdf_factures`, `Relevés 2026.zip` donne `Téléchargements\extraction_pdf_Relevés 2026`.
- **Recherche récursive** de tous les `*.pdf`, à toutes les profondeurs, fichiers cachés compris.
- **Aucun écrasement** — si `facture.pdf` existe déjà, le suivant devient `facture (1).pdf`, puis `facture (2).pdf`. Traiter deux fois la même archive réutilise son dossier sans rien perdre.
- **Archive d'origine intacte** — elle est ouverte en lecture seule ; rien n'est déplacé ni modifié.
- **Progression visible** — l'étape en cours (1/3 extraction, 2/3 recherche, 3/3 copie), le fichier traité, une barre et un compteur (`42 / 180 (23 %)`), repris dans la console.
- **Annulation à tout moment** par le bouton *Annuler* ou la croix de la fenêtre ; les PDF déjà copiés sont conservés.
- **Bilan final** — PDF trouvés, copiés, renommés et en erreur, chemin exact du dossier de destination, avec proposition de l'ouvrir.
- **Nettoyage garanti** — le dossier temporaire est supprimé dans un bloc `finally`, même après une erreur ou une annulation ; celui qu'aurait laissé une exécution interrompue brutalement est supprimé au lancement suivant.
- **Erreurs expliquées en clair** — archive corrompue, vide ou protégée par mot de passe, espace disque insuffisant (vérifié avant l'extraction et avant la copie), accès refusé, fichier verrouillé. Un fichier en échec est journalisé sans interrompre le traitement des autres.
- **Journal horodaté** par exécution, les 30 plus récents étant conservés.

### Sécurité et confidentialité

| Garantie | Mise en œuvre |
|---|---|
| Traitement 100 % local | Aucune commande réseau ; uniquement des composants fournis avec Windows. |
| Aucun droit administrateur | `-ExecutionPolicy Bypass` ne vaut que pour le processus lancé ; toutes les écritures ont lieu dans le profil de l'utilisateur. |
| Temporaires éphémères | Extraction dans `%TEMP%\ZipPdfExtractor_<identifiant>`, dossier propre à l'utilisateur, supprimé en fin de traitement. |
| Protection « Zip Slip » | Une entrée qui tenterait d'écrire hors du dossier temporaire (`..\..\`, chemin absolu) est ignorée et signalée. |
| Protection contre les « bombes ZIP » | La taille décompressée est comparée à l'espace libre avant toute extraction. |
| Provenance conservée | Si l'archive vient d'Internet, les PDF copiés en héritent la marque (*Mark of the Web*) et s'ouvrent en mode protégé. |
| Alerte cloud | Si Téléchargements est synchronisé avec OneDrive, l'outil demande confirmation avant de copier. |
| Journal sobre | Noms de fichiers, tailles et erreurs uniquement, jamais le contenu ; le nom du profil Windows y est remplacé par `%USERPROFILE%`. |

## Technologies

| Outil | Rôle |
|---|---|
| [Windows PowerShell 5.1](https://learn.microsoft.com/powershell/scripting/windows-powershell/overview) | Langage, intégré à Windows 10 et 11 |
| [System.IO.Compression](https://learn.microsoft.com/dotnet/api/system.io.compression.zipfile) | Lecture de l'archive entrée par entrée, en lecture seule |
| [Windows Forms](https://learn.microsoft.com/dotnet/desktop/winforms/) | Sélection du fichier, fenêtre de progression, boîtes de dialogue |
| Fichier de commandes (`.bat`) | Lanceur à double-cliquer pour l'utilisateur final |

## Installation

Prérequis : Windows 10 ou 11. Aucune installation ni droit administrateur.

```bash
git clone https://github.com/<compte>/zip-pdf-extractor.git
```

Pour un poste sans Git, il suffit de copier le dossier du projet : `Extraire-PDF.bat` et le dossier `src` doivent rester côte à côte.

## Utilisation

Double-cliquer sur **`Extraire-PDF.bat`**, ou sur un raccourci placé sur le Bureau (clic droit → *Afficher d'autres options* → *Envoyer vers* → *Bureau (créer un raccourci)*).

La fenêtre de sélection s'ouvre sur le dossier Téléchargements. Une fois l'archive choisie, la fenêtre de progression déroule les trois étapes, puis le bilan propose d'ouvrir le dossier `extraction_pdf_<nom de l'archive>`. Si Téléchargements a été déplacé (autre disque, redirection), son emplacement réel est utilisé.

Le journal de chaque exécution est écrit dans `%LOCALAPPDATA%\ZipPdfExtractor\Logs\extraction_<date>_<heure>.log` ; son chemin est rappelé dans chaque message de fin ou d'erreur.

Pièges connus :

- **Avertissement de sécurité au double-clic** — les fichiers ont été téléchargés. Clic droit sur `Extraire-PDF.bat` et sur `src\Extract-PdfFromZip.ps1` → *Propriétés* → cocher *Débloquer*.
- **La console affiche une erreur et reste ouverte** — la stratégie du poste bloque PowerShell (AppLocker, WDAC, mode de langage restreint) ; transmettre une capture de la fenêtre au support informatique.
- **Archive protégée par mot de passe** — non prise en charge par .NET Framework ; l'outil l'indique et explique comment la recréer sans mot de passe.
- **Limites** — les ZIP imbriqués dans l'archive ne sont pas ouverts ; les chemins de plus de 260 caractères sont ignorés et journalisés.

## Tests

Le projet n'a pas encore de tests automatisés, et le script n'a pas encore été exécuté sur Windows : il a été écrit sur macOS, où Windows PowerShell 5.1 et Windows Forms ne sont pas disponibles. Seuls l'encodage des fichiers et l'équilibre des délimiteurs ont été vérifiés.

La recette à mener sur un poste Windows 11 sans droits administrateur couvre au minimum : archive nominale avec sous-dossiers, doublons de noms, archive retraitée une seconde fois, noms accentués, archive corrompue, archive protégée par mot de passe, annulation en cours de traitement, puis contrôle que `%TEMP%` ne contient plus de dossier `ZipPdfExtractor_*`.

Les fonctions du script peuvent être chargées sans lancer le traitement, en vue de tests Pester :

```powershell
. .\src\Extract-PdfFromZip.ps1
```

## Structure du projet

```
Extraire-PDF.bat                Lanceur pour l'utilisateur final (double-clic)
src/
  Extract-PdfFromZip.ps1        Script principal : sélection, extraction, recherche, copie, journal
.gitattributes                  Fins de ligne CRLF imposées sur .bat et .ps1
```

Le lanceur ne contient aucune logique : il appelle Windows PowerShell par son chemin complet et garde la console ouverte seulement si une erreur n'a pas pu être affichée en fenêtre. Le script suit les trois étapes du traitement, chacune dans sa fonction (`Expand-ZipArchive`, `Find-PdfFiles`, `Copy-PdfFiles`), orchestrées par `Invoke-Main`. Les réglages — préfixe du dossier de destination, nombre de journaux conservés, marge d'espace disque — sont regroupés en tête de fichier. Le script doit rester enregistré en **UTF-8 avec BOM** : sans BOM, Windows PowerShell 5.1 affiche mal les accents.

## Contributeurs

### Développeur

Conception, décisions et validation du produit :

- définition du besoin et des contraintes : poste Windows 11 sans droits administrateur, aucune dépendance tierce, traitement 100 % local ;
- définition du traitement : sélection graphique de l'archive, extraction éphémère dans `%TEMP%`, recherche récursive, copie sans déplacement, gestion des doublons, journal, nettoyage garanti, lanceur `.bat` ;
- choix d'ergonomie : barre de progression, message de bilan final, dossier de destination nommé `extraction_pdf_<nom de l'archive>` ;
- choix de structure : nom de dépôt en anglais, README conforme au modèle commun des projets.

### Agent de code — Claude Opus 5.5 via Claude Code (application de bureau)

Réalisation sous la direction du développeur :

- implémentation du script PowerShell et du lanceur `.bat` ;
- ajouts de sécurité au-delà du cahier des charges : protection « Zip Slip », contrôle d'espace disque avant extraction, conservation de la marque de provenance Internet, alerte OneDrive, masquage du profil dans le journal ;
- ajouts de robustesse : annulation, décodage des noms accentués des ZIP de l'Explorateur, détection des archives chiffrées, purge des temporaires orphelins ;
- documentation : commentaires du script et ce README.

Chaque modification a été relue et validée par le développeur avant intégration.

## Licence

GNU GENERAL PUBLIC LICENSE, Version 3, 29 June 2007