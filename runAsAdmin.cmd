@ECHO OFF
REM Pour exécuter les scripts Powershell (ou autre programme) en tant qu'administrateur
REM Gère les chemins UNC
REM do not edit in the repo, copy it before editing and using

CLS
PUSHD "%~dp0"

IF EXIST %SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe (

	REM Chemin du script (%~dp0 = même dossier que ce fichier)

	REM Appel du script
	REM replace <scriptName> and <args>!!!
	PowerShell -NoProfile -ExecutionPolicy Bypass -Command "& {Start-Process PowerShell -ArgumentList '-NoProfile -ExecutionPolicy Bypass -Command """"%~dp0Update-Nginx.ps1"""" ' -Verb RunAs}";

) ELSE (

	CLS
		ECHO Powershell n'est pas pr<70>sent
	PAUSE

)
