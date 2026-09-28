@echo off
rem ---------------------------------------------------------------------------
rem  Lanceur de Extract-PdfFromZip.ps1 : un double-clic suffit.
rem  -ExecutionPolicy Bypass ne vaut que pour ce processus : aucun parametre
rem  systeme n'est modifie et aucun droit administrateur n'est requis.
rem  (Fichier volontairement sans accents : cmd.exe ne lit pas l'UTF-8.)
rem ---------------------------------------------------------------------------
setlocal
title Extraction des PDF d'une archive ZIP

set "SCRIPT=%~dp0src\Extract-PdfFromZip.ps1"
if not exist "%SCRIPT%" (
    echo Fichier introuvable : "%SCRIPT%"
    echo Verifiez que le dossier "src" est bien a cote de ce fichier.
    pause
    exit /b 1
)

rem Chemin complet de Windows PowerShell 5.1 : insensible a un PATH modifie.
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -STA -File "%SCRIPT%"
set "EXITCODE=%ERRORLEVEL%"

rem 0 et 10 : l'utilisateur a deja vu un message dans une fenetre.
rem Tout autre code : on garde la console ouverte pour qu'il puisse lire l'erreur.
if "%EXITCODE%"=="0" exit /b 0
if "%EXITCODE%"=="10" exit /b 10
echo.
echo Le traitement ne s'est pas termine normalement (code %EXITCODE%).
echo Faites une capture de cette fenetre pour votre support informatique.
pause
exit /b %EXITCODE%
