<#
.SYNOPSIS
    Installe une imprimante reseau (TCP/IP ou IPP) a partir d'un pilote universel.
    Si le pilote n'est pas present localement, il est telecharge automatiquement
    depuis le cloud (ZIP) puis extrait dans C:\Windows\Temp\Deessi\PrintersDrivers\<DriverName>.

.DESCRIPTION
    Ce script automatise l'ensemble du processus d'installation d'une imprimante :
      - Elevation automatique des privileges administrateur (UAC) si necessaire.
      - Verification des parametres obligatoires fournis par l'appelant.
      - Telechargement automatique du ZIP du pilote depuis le cloud si absent en local.
      - Extraction du ZIP dans le dossier de pilotes.
      - Localisation et injection du pilote dans le magasin de pilotes Windows.
      - Detection automatique du nom exact du pilote dans le fichier .inf.
      - Creation ou reutilisation du port d'impression (TCP/IP ou IPP).
      - Creation (ou mise a jour) de l'imprimante dans le spouleur Windows.

    Le script est concu pour fonctionner de maniere non interactive afin de pouvoir
    etre execute sur des postes automatises (deploiement, GPO, tache planifiee...).

.PARAMETER IP
    Adresse IP (ou nom DNS) de l'imprimante cible.
    Pour le type IPP, une URL complete (https://.../ipp/print) peut egalement etre fournie.

.PARAMETER Type
    Protocole de connexion : TCPIP (port RAW 9100) ou IPP (impression via HTTP).

.PARAMETER DriverName
    Nom du sous-dossier du pilote dans C:\Windows\Temp\Deessi\PrintersDrivers.
    Ce nom sert egalement a construire l'URL de telechargement du ZIP :
        <BaseURL><DriverName>.zip
    Le nom reel du pilote (tel qu'attendu par Windows) est detecte automatiquement
    a partir du fichier .inf, independamment du nom du dossier.

.PARAMETER PrinterName
    Nom attribue a l'imprimante dans Windows.

.PARAMETER Mode
    Create (defaut) : cree l'imprimante si elle n'existe pas ; sinon, ne fait rien (skip).
    Update          : si l'imprimante existe deja, la supprime puis la recree (mise a jour).

.PARAMETER DriversRoot
    Repertoire racine contenant les sous-dossiers de pilotes.
    Valeur par defaut : C:\Windows\Temp\Deessi\PrintersDrivers.

.PARAMETER BaseURL
    URL de base du cloud contenant les ZIP de pilotes. Le lien complet est
    construit ainsi : <BaseURL><DriverName>.zip
    Valeur par defaut : cloud DEESSI / FichiersZIP.

.PARAMETER Force
    Force la suppression et la recreation du port s'il existe deja.
    Force egalement le re-telechargement du ZIP meme si le dossier existe deja.

.EXAMPLE
    .\InstallPrinter.ps1 -IP 192.168.1.50 -Type TCPIP -DriverName "RICOH_PCL6_UniversalDriver_V4.44" -PrinterName "Ricoh Compta"

.EXAMPLE
    .\InstallPrinter.ps1 -IP 10.2.8.113 -Type TCPIP -DriverName "EPSON_Universal_Print_Driver" -PrinterName "Epson Accueil"

.NOTES
    Prerequis : droits administrateur, acces reseau au cloud des pilotes.

    CODES DE SORTIE (suivent l'ordre d'execution du script) :
       0  = Succes (imprimante installee, ou deja existante en mode Create).
       1  = Elevation UAC refusee ou annulee.
       2  = Parametre(s) obligatoire(s) manquant(s).
       3  = Dossier du pilote introuvable (apres tentative de telechargement).
       4  = Aucun fichier .inf trouve dans le dossier du pilote.
       5  = Nom du pilote impossible a detecter.
       6  = Erreur lors de l'installation (ajout pilote, port ou imprimante).
       7  = Echec du telechargement du ZIP du pilote.
       8  = Echec de l'extraction du ZIP du pilote.
#>

[CmdletBinding()]
param(
    # Parametres fonctionnels (verifies manuellement plus bas pour eviter les
    # invites de saisie interactives sur les postes automatises).
    [string]$IP,
    [ValidateSet('TCPIP','IPP')][string]$Type,
    [string]$DriverName,
    [string]$PrinterName,
    [ValidateSet('Create','Update')][string]$Mode = 'Create',
    [string]$DriversRoot = 'C:\Windows\Temp\Deessi\PrintersDrivers',

    # URL de base du cloud des pilotes. Le ZIP est suppose se nommer
    # exactement comme le DriverName, avec l'extension .zip.
    [string]$BaseURL = 'https://cloud.deessi.net/public.php/dav/files/o3Zn9Pz7ep9gzTY/FichiersZIP/',

    [switch]$Force,

    # Commutateur interne : positionne automatiquement lors de la relance avec
    # elevation UAC. Permet de garder la fenetre ouverte a la fin pour lire la sortie.
    [switch]$Elevated
)

# =========================================================================
# DEFINITION DES CODES DE SORTIE
# Centralises ici pour faciliter la lecture et la maintenance. Les valeurs
# suivent l'ordre d'execution du script : plus le code est eleve, plus
# l'erreur survient tard dans le deroulement.
# =========================================================================
$EXIT_SUCCESS         = 0   # Tout s'est bien passe
$EXIT_UAC_REFUSED     = 1   # Elevation administrateur refusee
$EXIT_MISSING_PARAM   = 2   # Parametre obligatoire manquant
$EXIT_DRIVER_NOTFOUND = 3   # Dossier du pilote introuvable
$EXIT_NO_INF          = 4   # Aucun fichier .inf trouve
$EXIT_NAME_UNDETECTED = 5   # Nom du pilote non detecte
$EXIT_INSTALL_ERROR   = 6   # Erreur lors de l'installation
$EXIT_DOWNLOAD_ERROR  = 7   # Echec du telechargement du ZIP
$EXIT_EXTRACT_ERROR   = 8   # Echec de l'extraction du ZIP

# Description lisible de chaque code, affichee a l'utilisateur en fin d'execution.
$EXIT_MESSAGES = @{
    0 = 'Succes : imprimante installee (ou deja existante en mode Create).'
    1 = 'Elevation administrateur (UAC) refusee ou annulee.'
    2 = 'Parametre obligatoire manquant.'
    3 = 'Dossier du pilote introuvable.'
    4 = 'Aucun fichier .inf trouve dans le dossier du pilote.'
    5 = 'Nom du pilote impossible a detecter.'
    6 = 'Erreur lors de l''installation (pilote, port ou imprimante).'
    7 = 'Echec du telechargement du ZIP du pilote.'
    8 = 'Echec de l''extraction du ZIP du pilote.'
}

# =========================================================================
# AUTO-ELEVATION UAC
# Verifie si le script s'execute avec les privileges administrateur. Sinon,
# il se relance automatiquement dans une nouvelle fenetre elevee en transmettant
# tous les parametres d'origine, puis termine la session courante.
# =========================================================================
$currentUser = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $currentUser.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Privileges administrateur requis. Relance avec elevation UAC..." -ForegroundColor Yellow

    # Reconstruction de la ligne de commande pour la relance elevee.
    # -NoExit garde la fenetre elevee ouverte pour lire le resultat sans
    # imposer de pause interactive (Read-Host). Pour une execution 100%
    # silencieuse sur machine, retirer '-NoExit' ci-dessous.
    $argList = @('-NoProfile','-NoExit','-ExecutionPolicy','Bypass','-File',"`"$($MyInvocation.MyCommand.Path)`"",'-Elevated')
    foreach ($key in $PSBoundParameters.Keys) {
        if ($key -eq 'Elevated') { continue }   # ne pas re-transmettre le commutateur interne
        $value = $PSBoundParameters[$key]
        if ($value -is [switch]) {
            # Les commutateurs (switch) sont transmis sans valeur.
            if ($value.IsPresent) { $argList += "-$key" }
        }
        else {
            # Les autres parametres sont transmis avec leur valeur, guillemets echappes.
            $argList += "-$key"; $argList += "`"$($value -replace '"','\"')`""
        }
    }

    # Lancement de la fenetre elevee (declenche l'invite UAC).
    try { Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -Verb RunAs -ErrorAction Stop }
    catch {
        Write-Error "Elevation refusee : $($_.Exception.Message)"
        exit $EXIT_UAC_REFUSED
    }
    exit $EXIT_SUCCESS
}

# A partir d'ici, le script s'execute avec les privileges administrateur.
# Toute erreur non geree interrompt l'execution (capturee par le bloc try/catch).
$ErrorActionPreference = 'Stop'

# =========================================================================
# VERIFICATION DES PARAMETRES OBLIGATOIRES
# Les parametres ne sont pas marques [Mandatory] afin d'eviter que PowerShell
# n'affiche une invite de saisie bloquante. La verification est faite ici :
# si un parametre manque, le script affiche une erreur explicite et s'arrete
# avec le code 2. (Comportement adapte a une execution sur machine.)
# =========================================================================
$missing = @()
if ([string]::IsNullOrWhiteSpace($IP))          { $missing += 'IP' }
if ($Type -notin @('TCPIP','IPP'))              { $missing += 'Type (TCPIP ou IPP)' }
if ([string]::IsNullOrWhiteSpace($DriverName))  { $missing += 'DriverName' }
if ([string]::IsNullOrWhiteSpace($PrinterName)) { $missing += 'PrinterName' }

if ($missing.Count -gt 0) {
    Write-Host ""
    Write-Host "ERREUR : parametre(s) obligatoire(s) manquant(s) :" -ForegroundColor Red
    foreach ($m in $missing) { Write-Host "   - $m" -ForegroundColor Red }
    Write-Host ""
    Write-Host "Exemple d'utilisation :" -ForegroundColor Yellow
    Write-Host '   .\InstallPrinter.ps1 -IP 10.0.0.1 -Type TCPIP -DriverName "EPSON_Universal_Print_Driver" -PrinterName "Test Epson"' -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Exit($EXIT_MISSING_PARAM) : Parametre obligatoire manquant." -ForegroundColor DarkGray
    exit $EXIT_MISSING_PARAM
}

# Securite : si le mode fourni est invalide, on retombe sur Create par defaut.
if ($Mode -notin @('Create','Update')) { $Mode = 'Create' }

# -------------------------------------------------------------------------
# Fonction utilitaire : affiche le code de sortie et sa signification.
# Aucune pause interactive : le script doit pouvoir s'executer sans
# utilisateur present (machine automatisee, deploiement, GPO...).
# -------------------------------------------------------------------------
function Invoke-EndPause {
    param([int]$Code)
    Write-Host ""
    $desc = $EXIT_MESSAGES[$Code]
    Write-Host "Exit($Code) : $desc" -ForegroundColor DarkGray
}

# =========================================================================
# FONCTION : Get-DriverNameFromInf
# Lit un fichier .inf et tente d'en extraire le nom exact du pilote.
# Chaque constructeur structurant son .inf differemment, quatre formats sont
# pris en charge successivement jusqu'a ce qu'un nom soit trouve.
# Retourne le nom du pilote, ou $null si aucun format ne correspond.
# =========================================================================
function Get-DriverNameFromInf {
    param([string]$InfPath)
    $content = Get-Content $InfPath -ErrorAction SilentlyContinue
    if (-not $content) { return $null }

    # --- Format 1 : nom situe APRES le signe '=' (cle DrvName ou CoDrvName).
    #     Exemple : CoDrvName = "RICOH PCL6 UniversalDriver V4.44"
    #     Utilise par : Ricoh, HP, Samsung...
    $line = $content | Where-Object { $_ -match '^\s*(DrvName|CoDrvName)\s*=\s*"(.+)"' } | Select-Object -Last 1
    if ($line -and $line -match '"([^"]+)"') { return $matches[1].Trim() }

    # --- Format 2 : nom situe AVANT le signe '=', en debut de ligne, a
    #     l'interieur d'une section dediee a l'architecture 64 bits (NTamd64).
    #     Exemple : "Brother Universal Printer (Inkjet)" = BRSUJ.DSI_64,...
    #     Utilise par : Brother, Canon, Epson, Konica, Lexmark, OKI, Toshiba...
    $inSection = $false
    foreach ($l in $content) {
        if ($l -match '^\[.*(NTamd64|NTx64|NT\.6).*\]') { $inSection = $true; continue }
        if ($inSection) {
            if ($l -match '^\[') { $inSection = $false; continue }   # fin de section
            if ($l -match '^"([^"]+)"\s*=') { return $matches[1].Trim() }
        }
    }

    # --- Format 3 : nom declare explicitement via DriverPackageDisplayName.
    #     Exemple : DriverPackageDisplayName = "..."
    $line = $content | Where-Object { $_ -match '^\s*DriverPackageDisplayName\s*=\s*"([^"]+)"' } | Select-Object -First 1
    if ($line -and $line -match '"([^"]+)"') { return $matches[1].Trim() }

    # --- Format 4 : nom reference par une variable (ex. %Model1%) dont la
    #     valeur reelle est definie dans la section [Strings]. Utilise par Sharp.
    #     Etape 1 : construire un dictionnaire des variables de [Strings].
    $variables = @{}
    $inStrings = $false
    foreach ($l in $content) {
        if ($l -match '^\[Strings\]') { $inStrings = $true; continue }
        if ($inStrings) {
            if ($l -match '^\[') { $inStrings = $false; continue }
            if ($l -match '^\s*(\w+)\s*=\s*"([^"]+)"') { $variables[$matches[1]] = $matches[2] }
        }
    }
    #     Etape 2 : reperer %Variable% dans une section NTamd64 et la resoudre.
    $inSection = $false
    foreach ($l in $content) {
        if ($l -match '^\[.*(NTamd64|NTx64).*\]') { $inSection = $true; continue }
        if ($inSection) {
            if ($l -match '^\[') { $inSection = $false; continue }
            if ($l -match '^%(\w+)%\s*=') {
                $varName = $matches[1]
                if ($variables.ContainsKey($varName)) { return $variables[$varName].Trim() }
            }
        }
    }

    # Aucun format reconnu.
    return $null
}

# =========================================================================
# CORPS PRINCIPAL DU SCRIPT
# Encapsule dans un try/catch : toute erreur metier leve une exception
# personnalisee dont le code est ensuite renvoye en sortie.
# =========================================================================
try {
    # =====================================================================
    # ETAPE 0 : TELECHARGEMENT + EXTRACTION DU PILOTE (si absent en local)
    # Le nom du ZIP correspond exactement au DriverName. L'URL complete est
    # construite par concatenation : <BaseURL><DriverName>.zip
    # Si le dossier du pilote existe deja (et que -Force n'est pas utilise),
    # cette etape est ignoree pour gagner du temps.
    # =====================================================================
    $driverPath = Join-Path $DriversRoot $DriverName

    if ((Test-Path $driverPath) -and (-not $Force)) {
        Write-Host "Pilote deja present en local, telechargement ignore : $driverPath" -ForegroundColor DarkGray
    }
    else {
        # --- Construction de l'URL complete a partir du nom de pilote souhaite.
        #     Le BaseURL doit se terminer par '/'. On le garantit ici par securite.
        if (-not $BaseURL.EndsWith('/')) { $BaseURL += '/' }
        $downloadLink = "$BaseURL$DriverName.zip"
        $zipPath      = Join-Path $DriversRoot "$DriverName.zip"

        Write-Host "=== Telechargement du pilote ===" -ForegroundColor Cyan
        Write-Host "URL  : $downloadLink"
        Write-Host "Vers : $zipPath"

        # S'assurer que le dossier racine existe avant d'y telecharger.
        if (-not (Test-Path $DriversRoot)) {
            New-Item -ItemType Directory -Path $DriversRoot -Force | Out-Null
        }

        # --- Telechargement du ZIP.
        #     TLS 1.2 force pour eviter les echecs sur certains serveurs HTTPS.
        #     ProgressPreference desactive pour accelerer Invoke-WebRequest.
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            $oldProgress = $ProgressPreference
            $ProgressPreference = 'SilentlyContinue'
            Invoke-WebRequest -Uri $downloadLink -OutFile $zipPath -UseBasicParsing -ErrorAction Stop
            $ProgressPreference = $oldProgress
            Write-Host "Telechargement termine." -ForegroundColor Green
        }
        catch {
            Write-Host "ECHEC : Telechargement impossible depuis $downloadLink" -ForegroundColor Red
            Write-Host "Detail : $($_.Exception.Message)" -ForegroundColor Red
            # Nettoyage d'un eventuel ZIP partiel/corrompu pour ne pas gener une relance.
            Remove-Item -Path $zipPath -Force -ErrorAction SilentlyContinue
            Invoke-EndPause -Code $EXIT_DOWNLOAD_ERROR
            exit $EXIT_DOWNLOAD_ERROR
        }

        # --- Extraction du ZIP.
        #     En mode -Force, on supprime un eventuel ancien dossier pour repartir propre.
        try {
            if ((Test-Path $driverPath) -and $Force) {
                Remove-Item -Path $driverPath -Recurse -Force -ErrorAction SilentlyContinue
            }
            Write-Host "Extraction vers : $driverPath"
            Expand-Archive -Path $zipPath -DestinationPath $driverPath -Force -ErrorAction Stop
            Write-Host "Extraction terminee." -ForegroundColor Green
        }
        catch {
            Write-Host "ECHEC : Extraction impossible du fichier $zipPath" -ForegroundColor Red
            Write-Host "Detail : $($_.Exception.Message)" -ForegroundColor Red
            Invoke-EndPause -Code $EXIT_EXTRACT_ERROR
            exit $EXIT_EXTRACT_ERROR
        }

        # --- Nettoyage : suppression du ZIP apres extraction (optionnel).
        Remove-Item -Path $zipPath -Force -ErrorAction SilentlyContinue
        Write-Host ""
    }

    # =====================================================================
    # ETAPE 1 : LOCALISATION DU PILOTE
    # Verifie l'existence du dossier du pilote (code 3) et recherche les
    # fichiers .inf, y compris dans les sous-dossiers (code 4 si absent).
    # =====================================================================
    if (-not (Test-Path $driverPath)) {
        Write-Host "ECHEC : Dossier du pilote introuvable : $driverPath" -ForegroundColor Red
        Invoke-EndPause -Code $EXIT_DRIVER_NOTFOUND
        exit $EXIT_DRIVER_NOTFOUND
    }

    $infFiles = Get-ChildItem -Path $driverPath -Filter *.inf -Recurse
    if (-not $infFiles) {
        Write-Host "ECHEC : Aucun fichier .inf trouve dans $driverPath" -ForegroundColor Red
        Invoke-EndPause -Code $EXIT_NO_INF
        exit $EXIT_NO_INF
    }

    # Nom par defaut si aucun nom d'imprimante n'a ete fourni (securite).
    if (-not $PrinterName) { $PrinterName = "$DriverName ($IP)" }

    # Affichage du recapitulatif de l'operation.
    Write-Host "=== Installation de '$PrinterName' ===" -ForegroundColor Cyan
    Write-Host "Dossier    : $driverPath"
    Write-Host "Type       : $Type"
    Write-Host "Cible      : $IP"
    Write-Host "Mode       : $Mode"
    Write-Host ""

    # =====================================================================
    # ETAPE 2 : INJECTION DES .INF + DETECTION DU VRAI NOM DU PILOTE
    # On releve la liste des pilotes avant injection, on injecte tous les .inf
    # via pnputil, puis on compare la liste apres injection : tout pilote
    # nouvellement apparu est un candidat fiable pour le nom reel.
    # =====================================================================

    # Liste des pilotes presents AVANT injection.
    $driversBefore = Get-PrinterDriver -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name

    # Injection de chaque fichier .inf dans le magasin de pilotes Windows.
    foreach ($inf in $infFiles) {
        Write-Host "pnputil /add-driver `"$($inf.FullName)`"" -ForegroundColor DarkGray
        & pnputil.exe /add-driver $inf.FullName /install 2>&1 | Out-Null
    }

    # Liste des pilotes presents APRES injection, puis difference.
    $driversAfter = Get-PrinterDriver -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name
    $newDrivers = $driversAfter | Where-Object { $driversBefore -notcontains $_ }

    # -----------------------------------------------------------------
    # Choix intelligent du pilote.
    # Lorsqu'un dossier contient plusieurs .inf, plusieurs noms candidats
    # peuvent exister. On compare chaque candidat au nom du dossier et on
    # retient celui qui partage le plus de mots-cles, afin d'eviter de
    # selectionner un pilote secondaire.
    # Exemple : pour "HP_Universal_Printing_PCL_6", on prefere
    # "HP Universal Printing PCL 6" plutot que "HP Printer (BIDI)".
    # -----------------------------------------------------------------

    # Decoupe le nom du dossier en mots-cles significatifs (longueur > 2).
    $folderWords = $DriverName -replace '[_\-\(\)\.]', ' ' -split '\s+' |
        Where-Object { $_.Length -gt 2 }

    # Calcule un score = nombre de mots-cles du dossier presents dans le candidat.
    function Get-MatchScore {
        param([string]$Candidate)
        if (-not $Candidate) { return -1 }
        ($folderWords | Where-Object { $Candidate -like "*$_*" }).Count
    }

    # Rassemble tous les candidats : pilotes nouvellement injectes + noms lus
    # dans chaque fichier .inf via la fonction Get-DriverNameFromInf.
    $candidates = @()
    $candidates += $newDrivers
    foreach ($inf in $infFiles) {
        $n = Get-DriverNameFromInf -InfPath $inf.FullName
        if ($n) { $candidates += $n }
    }
    $candidates = $candidates | Where-Object { $_ } | Select-Object -Unique

    # Selection du meilleur candidat (score le plus eleve).
    $realDriverName = $null
    if ($candidates) {
        $realDriverName = $candidates |
            Sort-Object { Get-MatchScore $_ } -Descending |
            Select-Object -First 1
        Write-Host "Pilote detecte : $realDriverName" -ForegroundColor Green
    }

    # Dernier recours : recherche approximative parmi tous les pilotes du
    # spouleur (utile si le pilote etait deja installe avant ce script).
    if (-not $realDriverName) {
        $realDriverName = $driversAfter |
            Sort-Object { Get-MatchScore $_ } -Descending |
            Where-Object { (Get-MatchScore $_) -ge 2 } |
            Select-Object -First 1
        if ($realDriverName) { Write-Host "Pilote detecte (fuzzy) : $realDriverName" -ForegroundColor Yellow }
    }

    # Si aucun nom n'a pu etre determine, l'installation ne peut pas continuer (code 5).
    if (-not $realDriverName) {
        Write-Host "ECHEC : Impossible de detecter le nom du pilote. Verifiez que le dossier contient un .inf valide." -ForegroundColor Red
        Invoke-EndPause -Code $EXIT_NAME_UNDETECTED
        exit $EXIT_NAME_UNDETECTED
    }

    # =====================================================================
    # ETAPE 3 : AJOUT DU PILOTE AU SPOULEUR D'IMPRESSION
    # Le pilote est enregistre dans le spouleur s'il n'y figure pas deja.
    # =====================================================================
    if (Get-PrinterDriver -Name $realDriverName -ErrorAction SilentlyContinue) {
        Write-Host "Pilote deja present dans le spouleur : $realDriverName"
    }
    else {
        Write-Host "Ajout du pilote au spouleur : $realDriverName"
        Add-PrinterDriver -Name $realDriverName
    }

    # =====================================================================
    # ETAPE 4 : GESTION DU MODE (Create / Update)
    # Determine le comportement a adopter si une imprimante du meme nom existe.
    # =====================================================================
    $printerExists = Get-Printer -Name $PrinterName -ErrorAction SilentlyContinue

    if ($printerExists) {
        if ($Mode -eq 'Update') {
            # Mode Update : suppression de l'imprimante existante pour la recreer
            # avec les parametres a jour (nouveau pilote, nouvelle IP, etc.).
            Write-Warning "Mode UPDATE : l'imprimante '$PrinterName' existe. Suppression pour mise a jour..."
            Remove-Printer -Name $PrinterName -Confirm:$false
        }
        else {
            # Mode Create (defaut) : l'imprimante existe deja, aucune action.
            Write-Host "Mode CREATE : l'imprimante '$PrinterName' existe deja. Aucune action (skip)." -ForegroundColor Yellow
            Get-Printer -Name $PrinterName | Format-List Name, DriverName, PortName, Shared, Published
            Invoke-EndPause -Code $EXIT_SUCCESS
            exit $EXIT_SUCCESS
        }
    }

    # =====================================================================
    # ETAPE 5 : CREATION (OU REUTILISATION) DU PORT
    # Le nom et les parametres du port dependent du protocole choisi.
    #   - TCPIP : port RAW nomme "IP_<adresse>" (port reseau 9100 par defaut).
    #   - IPP   : port HTTP nomme "http://<adresse>/ipp/print".
    # =====================================================================
    switch ($Type) {
        'TCPIP' {
            $portName = "IP_$IP"
            $portParams = @{ Name = $portName; PrinterHostAddress = $IP }
        }
        'IPP' {
            # Si l'appelant a fourni une URL complete, on la conserve telle quelle ;
            # sinon, on construit l'URL IPP standard a partir de l'adresse IP.
            $ippUrl = if ($IP -match '^https?://') { $IP } else { "http://$IP/ipp/print" }
            $portName = $ippUrl
            $portParams = @{ Name = $portName; PrinterHostAddress = $ippUrl }
        }
    }

    # Verifie si le port existe deja.
    $existingPort = Get-PrinterPort -Name $portName -ErrorAction SilentlyContinue

    # Avec -Force, on supprime le port existant pour le recreer proprement.
    if ($existingPort -and $Force) {
        Write-Host "Suppression du port existant (mode -Force) : $portName"
        try { Remove-PrinterPort -Name $portName -ErrorAction Stop; $existingPort = $null }
        catch { Write-Warning "Impossible de supprimer le port, reutilise tel quel." }
    }

    # Reutilisation si le port existe, creation sinon (operation idempotente).
    if ($existingPort) { Write-Host "Port deja existant, reutilise : $portName" }
    else { Write-Host "Creation du port $Type : $portName"; Add-PrinterPort @portParams }

    # =====================================================================
    # ETAPE 6 : INSTALLATION DE L'IMPRIMANTE
    # Cree l'imprimante dans le spouleur en associant le pilote et le port.
    # =====================================================================
    Write-Host "Ajout de l'imprimante : $PrinterName"
    Add-Printer -Name $PrinterName -DriverName $realDriverName -PortName $portName

    # Confirmation et affichage des proprietes finales de l'imprimante.
    Write-Host ""
    Write-Host "=== Imprimante installee avec succes ===" -ForegroundColor Green
    Get-Printer -Name $PrinterName | Format-List Name, DriverName, PortName, Shared, Published

    Invoke-EndPause -Code $EXIT_SUCCESS
    exit $EXIT_SUCCESS
}
catch {
    # Gestion centralisee des erreurs survenant pendant les etapes 3 a 6
    # (ajout du pilote, creation du port, installation de l'imprimante).
    Write-Host ""
    Write-Host "ECHEC : $($_.Exception.Message)" -ForegroundColor Red
    Invoke-EndPause -Code $EXIT_INSTALL_ERROR
    exit $EXIT_INSTALL_ERROR
}
