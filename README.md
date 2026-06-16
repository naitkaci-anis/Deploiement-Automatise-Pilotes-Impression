# Déploiement automatisé des pilotes d'impression générique

Outil PowerShell permettant d'installer une imprimante réseau de façon **entièrement automatisée**, à partir d'un pilote d'impression générique (universel).

Au lancement, le script vérifie si le pilote demandé est présent en local. Si ce n'est pas le cas, **il le télécharge automatiquement depuis ce dépôt GitHub**, le décompresse, puis installe l'imprimante (pilote + port réseau + spouleur). Aucune manipulation manuelle des fichiers n'est nécessaire.

---

## Fonctionnement en bref

À partir d'une simple commande indiquant l'**adresse IP** de l'imprimante et le **nom du pilote**, le script :

1. Vérifie / crée le dossier de travail `C:\PrinterDrivers`.
2. Cherche le pilote en local ; s'il est absent, **télécharge le ZIP depuis GitHub**.
3. Décompresse l'archive dans `C:\PrinterDrivers\<NomDuPilote>`.
4. Détecte automatiquement le vrai nom du pilote.
5. Crée le port réseau et installe l'imprimante.

> **Source des pilotes** : dossier [`ZIP/`](./ZIP) de ce dépôt
> **Destination sur le poste** : `C:\PrinterDrivers`

---

## Contenu du dépôt

| Élément | Rôle |
|---------|------|
| `InstallPrinter.ps1` | Script principal : télécharge le pilote (si besoin) et installe l'imprimante. |
| `ZIP/` | Archives ZIP des pilotes universels (une par constructeur). |
| `Guide_Installation.pdf` | Guide d'installation pas à pas. |
| `Rapport_Projet.docx` | Rapport de projet (contexte, fonctionnement, utilisation). |

---

## Démarrage rapide

1. Récupérer le script `InstallPrinter.ps1` (cloner le dépôt, ou télécharger le seul fichier).
2. Ouvrir **PowerShell en administrateur**.
3. Débloquer le script (fichier issu d'Internet) :
   ```powershell
   Unblock-File -Path .\InstallPrinter.ps1
   ```
4. Lancer l'installation (exemple EPSON) :
   ```powershell
   .\InstallPrinter.ps1 -IP 10.2.8.113 -Type TCPIP -DriverName "EPSON_Universal_Print_Driver" -PrinterName "Epson Accueil"
   ```
   Le pilote est téléchargé depuis GitHub vers `C:\PrinterDrivers`, décompressé, puis installé.
5. Tester l'impression :
   ```powershell
   "Test impression" | Out-Printer -Name "Epson Accueil"
   ```

Le détail complet figure dans **`Guide_Installation.pdf`**.

---

## Pilotes disponibles

Le nom à passer en `-DriverName` correspond au nom de l'archive ZIP (sans `.zip`).

| Constructeur | `-DriverName` |
|--------------|---------------|
| Brother | `Brother_Universal_Printer_(Inkjet)` |
| Canon | `Canon_Generic_Plus_UFR_II` |
| EPSON | `EPSON_Universal_Print_Driver` |
| HP | `HP_Universal_Printing_PCL_6_(v7.9.0)` |
| Konica Minolta | `KONICA_MINOLTA_Universal_PCL_v3.9.13` |
| Kyocera | `KX_DRIVER_for_Universal_Printing` |
| Lexmark | `Lexmark_Universa_lv2_XL` |
| OKI | `OKI_Universal_PCL_5` |
| RICOH | `RICOH_PCL6_UniversalDriver_V4.44` |
| Samsung | `Samsung_Universal_Print_V3.00.16.00` |
| Sharp | `SHARP_UD3_PCL6` |
| Toshiba | `TOSHIBA_Universal_Printer_2` |
| Xerox | `Xerox_GPD_PCL6_V5.887.3.0` |

---

## Paramètres de `InstallPrinter.ps1`

| Paramètre | Obligatoire | Description |
|-----------|:-----------:|-------------|
| `-IP` | Oui | Adresse IP (ou nom DNS) de l'imprimante. |
| `-Type` | Oui | `TCPIP` (port RAW 9100) ou `IPP` (via HTTP). |
| `-DriverName` | Oui | Nom du pilote (= nom de l'archive ZIP). |
| `-PrinterName` | Oui | Nom attribué à l'imprimante dans Windows. |
| `-Mode` | Non | `Create` (défaut) ou `Update` (recrée si l'imprimante existe). |
| `-DriversRoot` | Non | Dossier de destination. Défaut : `C:\PrinterDrivers`. |
| `-BaseURL` | Non | URL de base des pilotes. Défaut : dossier `ZIP/` de ce dépôt. |
| `-Force` | Non | Force le re-téléchargement du ZIP et la recréation du port. |

---

## Codes de sortie

| Code | Signification |
|:----:|---------------|
| 0 | Succès (installée ou déjà existante en mode Create). |
| 1 | Élévation administrateur (UAC) refusée. |
| 2 | Paramètre obligatoire manquant. |
| 3 | Dossier du pilote introuvable. |
| 4 | Aucun fichier `.inf` trouvé. |
| 5 | Nom du pilote impossible à détecter. |
| 6 | Erreur lors de l'installation. |
| 7 | Échec du téléchargement du ZIP. |
| 8 | Échec de l'extraction du ZIP. |

---

## Prérequis

- Windows 10 / 11, PowerShell 5.1 ou supérieur.
- Droits administrateur (gérés automatiquement via élévation UAC).
- Accès Internet vers GitHub (pour le téléchargement des pilotes).
- Connectivité réseau vers l'imprimante (port 9100 pour le TCP/IP).

---

## Contexte

Projet réalisé chez **DEESSI** (groupe iVision) dans le cadre d'un stage en support infogérance, pour l'automatisation du déploiement des pilotes d'impression sur le parc interne et chez les clients.

## Auteurs

- **Hichem HAROUNI** — Chef de projet technique / Responsable Industrialisation — *DEESSI, GRC2I / Industrialisation*
- **Anis NAIT KACI** — Stagiaire en Support infogérance — *DEESSI*
