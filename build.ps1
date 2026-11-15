param()
$ErrorActionPreference = 'Stop'
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $compiler)) { throw 'Windows .NET Framework 4.x compiler not found.' }
& $compiler /nologo /target:winexe /win32icon:"$PSScriptRoot\app.ico" /platform:x64 /optimize+ /warnaserror+ /r:System.Windows.Forms.dll /r:System.Drawing.dll /out:"$PSScriptRoot\DesktopToggle.exe" "$PSScriptRoot\src\DesktopToggle.cs"
if ($LASTEXITCODE -ne 0) { throw 'Build failed.' }

