#Requires -Version 5.1
<#
.SYNOPSIS
    Extrait tous les fichiers PDF d'une archive ZIP vers Téléchargements\extraction_pdf_<nom de l'archive>.

.DESCRIPTION
    1. L'utilisateur choisit une archive .zip dans une boîte de dialogue Windows.
    2. L'archive est extraite (en lecture seule) dans un dossier éphémère de %TEMP%.
    3. Tous les *.pdf sont recherchés récursivement dans l'extraction.
    4. Ils sont copiés dans Téléchargements\extraction_pdf_<nom de l'archive> (ex. « factures.zip »
       -> « extraction_pdf_factures ») ; un nom déjà pris devient « nom (1).pdf ».
    5. Le dossier temporaire est supprimé dans un bloc finally, puis un bilan s'affiche.

    Traitement 100 % local : aucune connexion réseau, aucun composant tiers.
    Le journal est écrit dans %LOCALAPPDATA%\ZipPdfExtractor\Logs.

.NOTES
    Fichier enregistré en UTF-8 avec BOM : indispensable pour que Windows PowerShell 5.1
    affiche correctement les caractères accentués.
    Lancement recommandé : double-clic sur Extraire-PDF.bat.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# --------------------------------------------------------------------------------------
# Configuration
# --------------------------------------------------------------------------------------

$script:AppName              = 'ZipPdfExtractor'
$script:WindowTitle          = 'Extraction des PDF'
# Le dossier de destination s'appelle <préfixe><nom de l'archive sans .zip>.
$script:OutputFolderPrefix   = 'extraction_pdf_'
$script:MaxArchiveNameLength = 100
$script:TempPrefix           = 'ZipPdfExtractor_'
$script:LogFolder            = Join-Path $env:LOCALAPPDATA "$($script:AppName)\Logs"
$script:MaxLogFiles          = 30
$script:StaleTempAgeHours    = 24
$script:DiskSpaceMarginBytes = 50MB
$script:UiRefreshIntervalMs  = 80

# Codes de sortie lus par Extraire-PDF.bat : seuls les codes inattendus y déclenchent une pause.
$script:ExitCodes = @{
    Success      = 0   # terminé, annulé ou aucun PDF : l'utilisateur a déjà vu un message
    HandledError = 10  # erreur expliquée dans une boîte de dialogue
    Environment  = 20  # interface graphique indisponible : seul le message console est visible
}

# État partagé
$script:LogWriter        = $null
$script:LogPath          = $null
$script:Ui               = $null
$script:CancelRequested  = $false
$script:AllowWindowClose = $false
$script:LastUiUpdate     = 0
$script:Stats            = $null

# --------------------------------------------------------------------------------------
# Journal
# --------------------------------------------------------------------------------------

function Initialize-Log {
    try {
        [void][System.IO.Directory]::CreateDirectory($script:LogFolder)
        $fileName = 'extraction_{0:yyyy-MM-dd_HH-mm-ss}.log' -f (Get-Date)
        $script:LogPath = Join-Path $script:LogFolder $fileName
        # UTF-8 avec BOM pour une lecture correcte dans le Bloc-notes.
        $script:LogWriter = New-Object System.IO.StreamWriter($script:LogPath, $false, (New-Object System.Text.UTF8Encoding($true)))
        $script:LogWriter.AutoFlush = $true

        # Rotation : seuls les journaux les plus récents sont conservés.
        Get-ChildItem -LiteralPath $script:LogFolder -Filter 'extraction_*.log' -File |
            Sort-Object LastWriteTime -Descending |
            Select-Object -Skip $script:MaxLogFiles |
            Remove-Item -Force -ErrorAction SilentlyContinue
    }
    catch {
        $script:LogWriter = $null
        $script:LogPath = $null
        Write-Host "Avertissement : le journal n'a pas pu être créé ($($_.Exception.Message))." -ForegroundColor Yellow
    }
}

function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO', 'OK', 'AVERT', 'ERREUR')][string]$Level = 'INFO',
        # Les lignes fichier par fichier ne vont qu'au journal pour ne pas ralentir la console.
        [switch]$Quiet
    )
    $line = '{0:yyyy-MM-dd HH:mm:ss} [{1,-6}] {2}' -f (Get-Date), $Level, $Message
    if ($script:LogWriter) {
        try { $script:LogWriter.WriteLine($line) } catch { }
    }
    if (-not $Quiet) {
        $color = switch ($Level) { 'OK' { 'Green' } 'AVERT' { 'Yellow' } 'ERREUR' { 'Red' } default { 'Gray' } }
        Write-Host $Message -ForegroundColor $color
    }
}

function Close-Log {
    if ($script:LogWriter) {
        try { $script:LogWriter.Dispose() } catch { }
        $script:LogWriter = $null
    }
}

# Masque le nom du profil Windows dans les chemins écrits au journal.
function Protect-Path([string]$Path) {
    if ($env:USERPROFILE -and $Path.StartsWith($env:USERPROFILE, [StringComparison]::OrdinalIgnoreCase)) {
        return '%USERPROFILE%' + $Path.Substring($env:USERPROFILE.Length)
    }
    return $Path
}

# --------------------------------------------------------------------------------------
# Utilitaires
# --------------------------------------------------------------------------------------

function Format-FileSize([long]$Bytes) {
    if ($Bytes -ge 1GB) { return '{0:N2} Go' -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return '{0:N1} Mo' -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return '{0:N0} Ko' -f ($Bytes / 1KB) }
    return "$Bytes octets"
}

# Erreur dont le message est destiné tel quel à l'utilisateur.
function New-UserFacingError([string]$Message) {
    return New-Object System.ApplicationException($Message)
}

# PowerShell enveloppe les exceptions .NET dans MethodInvocationException : on remonte à la cause.
function Get-RootException([Exception]$Exception) {
    $ex = $Exception
    while ($null -ne $ex.InnerException -and (
            $ex -is [System.Management.Automation.MethodInvocationException] -or
            $ex -is [System.Reflection.TargetInvocationException])) {
        $ex = $ex.InnerException
    }
    return $ex
}

function Test-DiskFull([Exception]$Exception) {
    # 39 = ERROR_HANDLE_DISK_FULL, 112 = ERROR_DISK_FULL
    return ($Exception -is [System.IO.IOException]) -and (($Exception.HResult -band 0xFFFF) -in 39, 112)
}

function Get-FriendlyErrorMessage([Exception]$Exception) {
    $ex = Get-RootException $Exception
    if ($ex -is [System.ApplicationException]) { return $ex.Message }
    if (Test-DiskFull $ex) {
        return "Espace disque insuffisant.`n`nLibérez de la place sur le disque (corbeille, anciens téléchargements) puis relancez l'opération."
    }
    if ($ex -is [System.IO.InvalidDataException]) {
        return "Le fichier sélectionné n'est pas une archive ZIP valide, ou il est endommagé (téléchargement incomplet, par exemple).`n`nEssayez de récupérer à nouveau le fichier puis relancez l'opération."
    }
    if ($ex -is [System.UnauthorizedAccessException]) {
        return "Accès refusé.`n`nVous n'avez pas les droits nécessaires sur un fichier ou un dossier utilisé par l'opération. Vérifiez que l'archive n'est pas dans un dossier protégé, puis réessayez."
    }
    if ($ex -is [System.IO.PathTooLongException]) {
        return "Un chemin de fichier est trop long pour Windows.`n`nDéplacez l'archive dans un dossier plus proche de la racine (par exemple Téléchargements) puis réessayez."
    }
    if ($ex -is [System.IO.FileNotFoundException] -or $ex -is [System.IO.DirectoryNotFoundException]) {
        return "Un fichier ou un dossier est introuvable. L'archive a peut-être été déplacée ou supprimée pendant le traitement."
    }
    if ($ex -is [System.IO.IOException] -and ($ex.HResult -band 0xFFFF) -eq 32) {
        return "Un fichier est utilisé par un autre programme.`n`nFermez les documents ouverts puis relancez l'opération."
    }
    return "Une erreur inattendue s'est produite :`n$($ex.Message)"
}

function Get-TempRoot {
    $tempPath = $env:TEMP
    if (-not $tempPath -or -not (Test-Path -LiteralPath $tempPath -PathType Container)) {
        $tempPath = [System.IO.Path]::GetTempPath()
    }
    return [System.IO.Path]::GetFullPath($tempPath)
}

function Get-DownloadsFolder {
    # Le dossier Téléchargements peut avoir été déplacé : on interroge d'abord le Shell.
    try {
        $shell = New-Object -ComObject Shell.Application
        $path = $shell.NameSpace('shell:Downloads').Self.Path
        if ($path -and (Test-Path -LiteralPath $path -PathType Container)) { return $path }
    }
    catch { }
    return Join-Path $env:USERPROFILE 'Downloads'
}

# « Factures 2026.zip » -> « extraction_pdf_Factures 2026 ».
function Get-OutputFolderName([string]$ZipPath) {
    $name = [System.IO.Path]::GetFileNameWithoutExtension($ZipPath)
    foreach ($invalidChar in [System.IO.Path]::GetInvalidFileNameChars()) {
        $name = $name.Replace([string]$invalidChar, '_')
    }
    # Nom tronqué pour rester loin de la limite de 260 caractères des chemins Windows.
    if ($name.Length -gt $script:MaxArchiveNameLength) { $name = $name.Substring(0, $script:MaxArchiveNameLength) }
    # Windows refuse les noms de dossier terminés par un point ou une espace.
    $name = $name.Trim().TrimEnd('.', ' ')
    if (-not $name) { $name = 'archive' }
    return $script:OutputFolderPrefix + $name
}

function Test-IsCloudSyncedPath([string]$Path) {
    foreach ($variable in 'OneDrive', 'OneDriveCommercial', 'OneDriveConsumer') {
        $root = [Environment]::GetEnvironmentVariable($variable)
        if ($root -and $Path.StartsWith($root.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }
    return $false
}

# Renvoie un chemin libre : « nom.pdf », sinon « nom (1).pdf », « nom (2).pdf »…
function Get-UniqueFilePath([string]$Directory, [string]$FileName) {
    $candidate = [System.IO.Path]::Combine($Directory, $FileName)
    if (-not (Test-Path -LiteralPath $candidate)) { return $candidate }

    $baseName  = [System.IO.Path]::GetFileNameWithoutExtension($FileName)
    $extension = [System.IO.Path]::GetExtension($FileName)
    $index = 1
    do {
        $candidate = [System.IO.Path]::Combine($Directory, "$baseName ($index)$extension")
        $index++
    } while (Test-Path -LiteralPath $candidate)
    return $candidate
}

function Assert-FreeSpace([string]$Path, [long]$RequiredBytes, [string]$Purpose) {
    try {
        $drive = New-Object System.IO.DriveInfo([System.IO.Path]::GetPathRoot($Path))
        $available = $drive.AvailableFreeSpace
    }
    catch {
        Write-Log "Espace libre non vérifiable pour $Purpose (lecteur réseau ?)." -Level AVERT
        return
    }
    if ($available -lt ($RequiredBytes + $script:DiskSpaceMarginBytes)) {
        throw (New-UserFacingError ("Espace disque insuffisant sur le lecteur {0} pour {1}.`n`nNécessaire : {2}`nDisponible : {3}`n`nLibérez de la place puis relancez l'opération." -f `
                    $drive.Name, $Purpose, (Format-FileSize ($RequiredBytes + $script:DiskSpaceMarginBytes)), (Format-FileSize $available)))
    }
}

function Assert-NotCancelled {
    if ($script:UI) { [System.Windows.Forms.Application]::DoEvents() }
    if ($script:CancelRequested) {
        throw (New-Object System.OperationCanceledException("Opération annulée par l'utilisateur."))
    }
}

# --------------------------------------------------------------------------------------
# Dossiers temporaires
# --------------------------------------------------------------------------------------

function New-TempFolder {
    $name = $script:TempPrefix + [Guid]::NewGuid().ToString('N').Substring(0, 12)
    $path = Join-Path (Get-TempRoot) $name
    [void][System.IO.Directory]::CreateDirectory($path)
    return $path
}

function Remove-TempFolder([string]$Path) {
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            if (-not (Test-Path -LiteralPath $Path)) { return $true }
            Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
            return $true
        }
        catch {
            # Un antivirus peut verrouiller brièvement un fichier qui vient d'être écrit.
            Start-Sleep -Milliseconds (500 * $attempt)
        }
    }
    return -not (Test-Path -LiteralPath $Path)
}

# Supprime les dossiers laissés par une exécution interrompue brutalement (fenêtre fermée, coupure).
function Remove-StaleTempFolders {
    try {
        $limit = (Get-Date).AddHours(-$script:StaleTempAgeHours)
        Get-ChildItem -LiteralPath (Get-TempRoot) -Directory -Filter "$($script:TempPrefix)*" -ErrorAction Stop |
            Where-Object { $_.LastWriteTime -lt $limit } |
            ForEach-Object {
                if (Remove-TempFolder $_.FullName) {
                    Write-Log "Dossier temporaire orphelin supprimé : $($_.Name)" -Quiet
                }
            }
    }
    catch {
        Write-Log "Nettoyage des anciens dossiers temporaires impossible : $($_.Exception.Message)" -Level AVERT -Quiet
    }
}

# --------------------------------------------------------------------------------------
# Interface graphique
# --------------------------------------------------------------------------------------

function Show-Message {
    param(
        [Parameter(Mandatory)][string]$Text,
        [string]$Buttons = 'OK',
        [string]$Icon = 'Information'
    )
    # Propriétaire « toujours au premier plan » : la boîte ne se cache pas derrière la console.
    $owner = New-Object System.Windows.Forms.Form
    $owner.TopMost = $true
    $owner.ShowInTaskbar = $false
    try {
        return [System.Windows.Forms.MessageBox]::Show($owner, $Text, $script:WindowTitle,
            [System.Windows.Forms.MessageBoxButtons]$Buttons, [System.Windows.Forms.MessageBoxIcon]$Icon)
    }
    finally {
        $owner.Dispose()
    }
}

function Select-ZipFile {
    $owner = New-Object System.Windows.Forms.Form
    $owner.TopMost = $true
    $owner.ShowInTaskbar = $false
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    try {
        $dialog.Title = "Choisissez l'archive ZIP contenant les PDF"
        $dialog.Filter = 'Archives ZIP (*.zip)|*.zip'
        $dialog.Multiselect = $false
        $dialog.CheckFileExists = $true
        $dialog.RestoreDirectory = $true
        $dialog.InitialDirectory = Get-DownloadsFolder
        if ($dialog.ShowDialog($owner) -eq [System.Windows.Forms.DialogResult]::OK) {
            return $dialog.FileName
        }
        return $null
    }
    finally {
        $dialog.Dispose()
        $owner.Dispose()
    }
}

function New-ProgressWindow {
    $form = New-Object System.Windows.Forms.Form
    $form.Text = $script:WindowTitle
    $form.ClientSize = New-Object System.Drawing.Size(460, 150)
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $form.MaximizeBox = $false
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $form.TopMost = $true
    $form.Font = New-Object System.Drawing.Font('Segoe UI', 9)

    $phase = New-Object System.Windows.Forms.Label
    $phase.Location = New-Object System.Drawing.Point(16, 14)
    $phase.Size = New-Object System.Drawing.Size(428, 22)
    $phase.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
    $phase.Text = 'Préparation…'

    $detail = New-Object System.Windows.Forms.Label
    $detail.Location = New-Object System.Drawing.Point(16, 40)
    $detail.Size = New-Object System.Drawing.Size(428, 20)
    $detail.AutoEllipsis = $true

    $bar = New-Object System.Windows.Forms.ProgressBar
    $bar.Location = New-Object System.Drawing.Point(16, 66)
    $bar.Size = New-Object System.Drawing.Size(428, 22)
    $bar.Minimum = 0
    $bar.Maximum = 100
    $bar.MarqueeAnimationSpeed = 30

    $counter = New-Object System.Windows.Forms.Label
    $counter.Location = New-Object System.Drawing.Point(16, 98)
    $counter.Size = New-Object System.Drawing.Size(320, 20)

    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = 'Annuler'
    $cancel.Location = New-Object System.Drawing.Point(354, 108)
    $cancel.Size = New-Object System.Drawing.Size(90, 28)
    $cancel.Add_Click({
            $script:CancelRequested = $true
            $this.Enabled = $false
            $this.Text = 'Annulation…'
        })

    # La croix de fermeture vaut demande d'annulation : le nettoyage doit toujours aller au bout.
    $form.Add_FormClosing({
            param($sender, $e)
            if (-not $script:AllowWindowClose) {
                $e.Cancel = $true
                $script:CancelRequested = $true
            }
        })

    $form.Controls.AddRange(@($phase, $detail, $bar, $counter, $cancel))
    $form.Show()
    [System.Windows.Forms.Application]::DoEvents()

    return [pscustomobject]@{ Form = $form; Phase = $phase; Detail = $detail; Bar = $bar; Counter = $counter }
}

function Update-Progress {
    param(
        [Parameter(Mandatory)][string]$Phase,
        [string]$Detail = '',
        [int]$Current = 0,
        # 0 = durée inconnue : barre animée en continu.
        [int]$Total = 0,
        [switch]$Force
    )
    $now = [Environment]::TickCount
    if (-not $Force -and [Math]::Abs($now - $script:LastUiUpdate) -lt $script:UiRefreshIntervalMs) { return }
    $script:LastUiUpdate = $now

    $percent = 0
    if ($Total -gt 0) { $percent = [int][Math]::Min(100, [Math]::Floor($Current * 100 / $Total)) }

    if ($script:Ui) {
        $script:Ui.Phase.Text = $Phase
        $script:Ui.Detail.Text = $Detail
        if ($Total -gt 0) {
            $script:Ui.Bar.Style = [System.Windows.Forms.ProgressBarStyle]::Continuous
            $script:Ui.Bar.Value = $percent
            $script:Ui.Counter.Text = "$Current / $Total ($percent %)"
        }
        else {
            $script:Ui.Bar.Style = [System.Windows.Forms.ProgressBarStyle]::Marquee
            $script:Ui.Counter.Text = if ($Current -gt 0) { "$Current élément(s) analysé(s)" } else { '' }
        }
        [System.Windows.Forms.Application]::DoEvents()
    }

    $status = if ($Detail) { $Detail } else { $Phase }
    if ($Total -gt 0) {
        Write-Progress -Activity $Phase -Status "$Current / $Total — $status" -PercentComplete $percent
    }
    else {
        Write-Progress -Activity $Phase -Status $status
    }
}

function Close-ProgressWindow {
    Write-Progress -Activity $script:WindowTitle -Completed
    if ($script:Ui) {
        $script:AllowWindowClose = $true
        try {
            $script:Ui.Form.Close()
            $script:Ui.Form.Dispose()
        }
        catch { }
        $script:Ui = $null
    }
}

# --------------------------------------------------------------------------------------
# Étape 1 : extraction
# --------------------------------------------------------------------------------------

function Open-ZipArchive([string]$Path) {
    # Les ZIP créés par l'Explorateur Windows codent les noms dans la page de code OEM (CP850 en
    # français) ; les entrées marquées UTF-8 restent décodées en UTF-8 par .NET.
    $oemEncoding = [System.Text.Encoding]::GetEncoding([System.Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage)
    # Ouverture en lecture seule : l'archive d'origine n'est jamais modifiée.
    return [System.IO.Compression.ZipFile]::Open($Path, [System.IO.Compression.ZipArchiveMode]::Read, $oemEncoding)
}

# .NET Framework n'expose pas le bit « chiffré » (IsEncrypted n'existe qu'à partir de .NET 7) ;
# on le lit par réflexion et on renonce silencieusement si le champ interne est introuvable.
$script:ZipFlagField = $null

function Test-EntryEncrypted($Entry) {
    if (-not $script:ZipFlagField) {
        $script:ZipFlagField = [System.IO.Compression.ZipArchiveEntry].GetField('_generalPurposeBitFlag',
            [System.Reflection.BindingFlags]'NonPublic, Instance')
        if (-not $script:ZipFlagField) { return $false }
    }
    try { return ([int]$script:ZipFlagField.GetValue($Entry) -band 1) -eq 1 } catch { return $false }
}

function Expand-ZipArchive($Archive, [string]$Destination) {
    $phase = "Étape 1/3 — Extraction de l'archive"
    $destinationRoot = [System.IO.Path]::GetFullPath($Destination).TrimEnd('\') + '\'
    $entries = @($Archive.Entries)
    $total = $entries.Count
    $script:Stats.Entries = $total

    if ($total -eq 0) { throw (New-UserFacingError "L'archive sélectionnée est vide.") }

    $uncompressedSize = [long]($entries | Measure-Object -Property Length -Sum).Sum
    Write-Log ("{0} élément(s) dans l'archive, {1} une fois décompressé(s)." -f $total, (Format-FileSize $uncompressedSize))
    # Protège aussi contre les « bombes ZIP » qui rempliraient le disque.
    Assert-FreeSpace -Path $destinationRoot -RequiredBytes $uncompressedSize -Purpose "l'extraction temporaire"

    $encryptedCount = 0
    $index = 0
    foreach ($entry in $entries) {
        $index++
        Assert-NotCancelled
        Update-Progress -Phase $phase -Detail $entry.Name -Current $index -Total $total

        $relativeName = $entry.FullName.Replace('/', '\')
        try {
            $target = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($destinationRoot, $relativeName))

            # Protection « Zip Slip » : rien ne doit être écrit hors du dossier temporaire.
            if (-not $target.StartsWith($destinationRoot, [StringComparison]::OrdinalIgnoreCase)) {
                $script:Stats.ExtractErrors++
                Write-Log "Élément ignoré (chemin hors de l'archive, potentiellement malveillant) : $relativeName" -Level AVERT -Quiet
                continue
            }

            if ($relativeName.EndsWith('\')) {
                [void][System.IO.Directory]::CreateDirectory($target)
                continue
            }

            if (Test-EntryEncrypted $entry) {
                $encryptedCount++
                $script:Stats.ExtractErrors++
                Write-Log "Élément protégé par mot de passe, non extrait : $relativeName" -Level ERREUR -Quiet
                continue
            }

            [void][System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($target))
            # Deux entrées peuvent ne différer que par la casse (« A.pdf » / « a.pdf ») : aucune ne doit écraser l'autre.
            $target = Get-UniqueFilePath ([System.IO.Path]::GetDirectoryName($target)) ([System.IO.Path]::GetFileName($target))
            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $false)
            $script:Stats.Extracted++
        }
        catch {
            $root = Get-RootException $_.Exception
            if (Test-DiskFull $root) { throw }
            $script:Stats.ExtractErrors++
            Write-Log ("Extraction impossible : {0} — {1}" -f $relativeName, $root.Message) -Level ERREUR -Quiet
        }
    }
    Update-Progress -Phase $phase -Detail 'Terminé' -Current $total -Total $total -Force

    if ($script:Stats.Extracted -eq 0 -and $script:Stats.ExtractErrors -gt 0) {
        if ($encryptedCount -gt 0) {
            throw (New-UserFacingError "L'archive est protégée par un mot de passe.`n`nCe type d'archive n'est pas pris en charge : ouvrez-la avec l'Explorateur Windows, saisissez le mot de passe, puis recréez une archive sans mot de passe.")
        }
        throw (New-UserFacingError "Aucun fichier n'a pu être extrait : l'archive est probablement endommagée.`n`nConsultez le journal pour le détail.")
    }
    $level = if ($script:Stats.ExtractErrors -gt 0) { 'AVERT' } else { 'OK' }
    Write-Log ("Extraction terminée : {0} fichier(s) extrait(s), {1} en erreur." -f $script:Stats.Extracted, $script:Stats.ExtractErrors) -Level $level
}

# --------------------------------------------------------------------------------------
# Étape 2 : recherche des PDF
# --------------------------------------------------------------------------------------

function Find-PdfFiles([string]$Root) {
    $phase = 'Étape 2/3 — Recherche des fichiers PDF'
    $script:scanned = 0
    $searchErrors = $null

    Update-Progress -Phase $phase -Detail 'Analyse des dossiers…' -Force
    $files = @(
        Get-ChildItem -LiteralPath $Root -Recurse -File -Force -Filter '*.pdf' -ErrorAction SilentlyContinue -ErrorVariable searchErrors |
            ForEach-Object {
                $script:scanned++
                Assert-NotCancelled
                Update-Progress -Phase $phase -Detail $_.Name -Current $script:scanned
                $_
            } |
            # Le filtre Windows « *.pdf » accepte aussi « .pdfx » (héritage des noms courts 8.3).
            Where-Object { $_.Extension -eq '.pdf' } |
            Sort-Object FullName
    )

    foreach ($searchError in @($searchErrors)) {
        $script:Stats.SearchErrors++
        Write-Log "Dossier ou fichier illisible pendant la recherche : $($searchError.Exception.Message)" -Level AVERT -Quiet
    }

    $script:Stats.PdfFound = $files.Count
    Write-Log "$($files.Count) fichier(s) PDF trouvé(s)." -Level $(if ($files.Count -gt 0) { 'OK' } else { 'AVERT' })
    return $files
}

# --------------------------------------------------------------------------------------
# Étape 3 : copie
# --------------------------------------------------------------------------------------

# Marque de provenance Internet (Mark of the Web) de l'archive, si elle en porte une.
function Get-ZoneIdentifier([string]$Path) {
    try {
        $content = Get-Content -LiteralPath $Path -Stream 'Zone.Identifier' -Raw -ErrorAction Stop
        if ($content -match 'ZoneId\s*=\s*[34]') { return $content.TrimEnd() }
    }
    catch { }
    return $null
}

function Copy-PdfFiles([object[]]$Files, [string]$SourceRoot, [string]$Destination, [string]$ZoneIdentifier) {
    $phase = 'Étape 3/3 — Copie des PDF'
    $total = $Files.Count
    $sourcePrefix = $SourceRoot.TrimEnd('\') + '\'

    $totalSize = [long]($Files | Measure-Object -Property Length -Sum).Sum
    Assert-FreeSpace -Path $Destination -RequiredBytes $totalSize -Purpose 'la copie des PDF'

    if ($ZoneIdentifier) {
        Write-Log "L'archive provient d'Internet : les PDF copiés conservent cette marque (ouverture en mode protégé)." -Quiet
    }

    $index = 0
    foreach ($file in $Files) {
        $index++
        Assert-NotCancelled
        Update-Progress -Phase $phase -Detail $file.Name -Current $index -Total $total

        $relativePath = if ($file.FullName.StartsWith($sourcePrefix, [StringComparison]::OrdinalIgnoreCase)) {
            $file.FullName.Substring($sourcePrefix.Length)
        } else { $file.Name }

        try {
            $target = Get-UniqueFilePath $Destination $file.Name
            # Copie sans écrasement : si un fichier du même nom apparaît entre-temps, File.Copy échoue.
            [System.IO.File]::Copy($file.FullName, $target, $false)
            $script:Stats.Copied++

            $targetName = [System.IO.Path]::GetFileName($target)
            if ($targetName -ne $file.Name) {
                $script:Stats.Renamed++
                Write-Log "Doublon : $relativePath -> copié sous « $targetName »" -Level AVERT -Quiet
            }
            else {
                Write-Log "Copié : $relativePath" -Level OK -Quiet
            }

            if ($ZoneIdentifier) {
                try { Set-Content -LiteralPath $target -Stream 'Zone.Identifier' -Value $ZoneIdentifier -ErrorAction Stop }
                catch { Write-Log "Marque de provenance non appliquée à $targetName (disque FAT/exFAT ?)." -Level AVERT -Quiet }
            }
        }
        catch {
            $root = Get-RootException $_.Exception
            if (Test-DiskFull $root) { throw }
            $script:Stats.CopyErrors++
            Write-Log ("Copie impossible : {0} — {1}" -f $relativePath, $root.Message) -Level ERREUR -Quiet
        }
    }
    Update-Progress -Phase $phase -Detail 'Terminé' -Current $total -Total $total -Force

    $level = if ($script:Stats.CopyErrors -gt 0) { 'AVERT' } else { 'OK' }
    Write-Log ("Copie terminée : {0} PDF copié(s) dont {1} renommé(s), {2} en erreur." -f `
            $script:Stats.Copied, $script:Stats.Renamed, $script:Stats.CopyErrors) -Level $level
}

# --------------------------------------------------------------------------------------
# Programme principal
# --------------------------------------------------------------------------------------

function Invoke-Main {
    $script:Stats = @{
        Entries = 0; Extracted = 0; ExtractErrors = 0; SearchErrors = 0
        PdfFound = 0; Copied = 0; Renamed = 0; CopyErrors = 0
    }
    $status = 'Success'
    $errorMessage = $null
    $tempDir = $null
    $archive = $null
    $tempRemoved = $true

    Initialize-Log
    Write-Log "Démarrage — Windows $([Environment]::OSVersion.Version), PowerShell $($PSVersionTable.PSVersion)" -Quiet
    Write-Host 'Sélectionnez l''archive ZIP dans la fenêtre qui vient de s''ouvrir…'
    Remove-StaleTempFolders

    $zipPath = Select-ZipFile
    if (-not $zipPath) {
        Write-Log 'Aucune archive sélectionnée : opération abandonnée.'
        return $script:ExitCodes.Success
    }

    $destinationDir = Join-Path (Get-DownloadsFolder) (Get-OutputFolderName $zipPath)

    if (Test-IsCloudSyncedPath $destinationDir) {
        Write-Log "Le dossier de destination est synchronisé avec OneDrive : $(Protect-Path $destinationDir)" -Level AVERT
        $answer = Show-Message -Buttons 'YesNo' -Icon 'Warning' -Text (
            "Votre dossier Téléchargements est synchronisé avec OneDrive :`n$destinationDir`n`n" +
            "Les PDF copiés seront donc envoyés dans le cloud.`n`nVoulez-vous continuer ?")
        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) {
            Write-Log 'Opération abandonnée par l''utilisateur (dossier synchronisé).'
            return $script:ExitCodes.Success
        }
    }

    try {
        $zipItem = Get-Item -LiteralPath $zipPath
        Write-Log ("Archive : {0} ({1})" -f $zipItem.Name, (Format-FileSize $zipItem.Length))
        Write-Log "Destination : $(Protect-Path $destinationDir)" -Quiet

        [void][System.IO.Directory]::CreateDirectory($destinationDir)
        $tempDir = New-TempFolder
        Write-Log "Dossier temporaire : $(Protect-Path $tempDir)" -Quiet

        $script:Ui = New-ProgressWindow

        $archive = Open-ZipArchive $zipPath
        Expand-ZipArchive -Archive $archive -Destination $tempDir
        $archive.Dispose()
        $archive = $null

        $pdfFiles = @(Find-PdfFiles -Root $tempDir)
        if ($pdfFiles.Count -eq 0) {
            $status = 'NoPdf'
        }
        else {
            Copy-PdfFiles -Files $pdfFiles -SourceRoot $tempDir -Destination $destinationDir -ZoneIdentifier (Get-ZoneIdentifier $zipPath)
        }
    }
    catch {
        $root = Get-RootException $_.Exception
        if ($root -is [System.OperationCanceledException]) {
            $status = 'Cancelled'
            Write-Log "Opération annulée par l'utilisateur." -Level AVERT
        }
        else {
            $status = 'Error'
            $errorMessage = Get-FriendlyErrorMessage $root
            Write-Log ("Erreur bloquante : {0} [{1}]" -f $root.Message, $root.GetType().FullName) -Level ERREUR
        }
    }
    finally {
        if ($archive) { $archive.Dispose() }
        Close-ProgressWindow
        if ($tempDir) {
            Write-Host 'Suppression des fichiers temporaires…'
            $tempRemoved = Remove-TempFolder $tempDir
            if ($tempRemoved) { Write-Log 'Fichiers temporaires supprimés.' -Level OK }
            else { Write-Log "Le dossier temporaire n'a pas pu être entièrement supprimé : $(Protect-Path $tempDir)" -Level ERREUR }
        }
    }

    $s = $script:Stats
    Write-Log ("Bilan — éléments : {0}, extraits : {1}, PDF trouvés : {2}, copiés : {3}, renommés : {4}, erreurs : {5}" -f `
            $s.Entries, $s.Extracted, $s.PdfFound, $s.Copied, $s.Renamed, ($s.ExtractErrors + $s.SearchErrors + $s.CopyErrors))

    $logLine = if ($script:LogPath) { "`n`nJournal détaillé :`n$($script:LogPath)" } else { '' }
    $tempWarning = if ($tempRemoved) { '' } else {
        "`n`nAttention : certains fichiers temporaires n'ont pas pu être supprimés. Ils le seront automatiquement au prochain lancement."
    }

    switch ($status) {
        'Error' {
            [void](Show-Message -Icon 'Error' -Text ("L'opération n'a pas pu aboutir.`n`n$errorMessage" + $tempWarning + $logLine))
            return $script:ExitCodes.HandledError
        }
        'Cancelled' {
            $done = if ($s.Copied -gt 0) { "`n`n$($s.Copied) PDF avaient déjà été copiés dans :`n$destinationDir" } else { '' }
            [void](Show-Message -Icon 'Warning' -Text ("Opération annulée." + $done + $tempWarning))
            return $script:ExitCodes.Success
        }
        'NoPdf' {
            [void](Show-Message -Icon 'Information' -Text ("Aucun fichier PDF n'a été trouvé dans l'archive « $([System.IO.Path]::GetFileName($zipPath)) »." + $tempWarning + $logLine))
            return $script:ExitCodes.Success
        }
    }

    $errors = $s.ExtractErrors + $s.SearchErrors + $s.CopyErrors
    $lines = @(
        'Traitement terminé.'
        ''
        "PDF trouvés : $($s.PdfFound)"
        "PDF copiés : $($s.Copied)"
    )
    if ($s.Renamed -gt 0) { $lines += "   dont $($s.Renamed) renommé(s) pour éviter un doublon, par exemple « nom (1).pdf »" }
    if ($errors -gt 0) { $lines += "Fichiers en erreur : $errors (voir le journal)" }
    $lines += @('', 'Dossier de destination :', $destinationDir, '', 'Voulez-vous ouvrir ce dossier maintenant ?')

    $icon = if ($errors -gt 0) { 'Warning' } else { 'Information' }
    $answer = Show-Message -Buttons 'YesNo' -Icon $icon -Text (($lines -join "`n") + $tempWarning + $logLine)
    if ($answer -eq [System.Windows.Forms.DialogResult]::Yes) {
        Start-Process -FilePath 'explorer.exe' -ArgumentList "`"$destinationDir`""
    }
    return $script:ExitCodes.Success
}

# --------------------------------------------------------------------------------------
# Point d'entrée
# --------------------------------------------------------------------------------------

# Chargé par « . .\Extract-PdfFromZip.ps1 » (tests) : on expose les fonctions sans rien exécuter.
if ($MyInvocation.InvocationName -eq '.') { return }

# Un poste verrouillé (AppLocker / WDAC) impose le mode de langage restreint, incompatible avec
# les boîtes de dialogue Windows Forms.
if ($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') {
    Write-Host "Ce poste restreint l'exécution de PowerShell (mode $($ExecutionContext.SessionState.LanguageMode))." -ForegroundColor Red
    Write-Host "L'outil ne peut pas fonctionner : contactez votre support informatique." -ForegroundColor Red
    exit $script:ExitCodes.Environment
}

try {
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing, System.IO.Compression, System.IO.Compression.FileSystem
    [System.Windows.Forms.Application]::EnableVisualStyles()
}
catch {
    Write-Host "Impossible de charger les composants Windows nécessaires : $($_.Exception.Message)" -ForegroundColor Red
    exit $script:ExitCodes.Environment
}

$exitCode = $script:ExitCodes.HandledError
try {
    $exitCode = Invoke-Main
}
catch {
    # Filet de sécurité : une erreur non prévue ne doit jamais se terminer sans explication.
    Write-Log "Erreur non gérée : $($_.Exception.Message)" -Level ERREUR
    try { [void](Show-Message -Icon 'Error' -Text ("Une erreur inattendue s'est produite :`n$($_.Exception.Message)")) } catch { }
    $exitCode = $script:ExitCodes.HandledError
}
finally {
    Close-Log
}
exit $exitCode
