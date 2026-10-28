# Builds the WaCa content pak (rain / snow look + rain sound) with Unreal Engine 5.7.4 - headless, no editor window:
#   1. content\scripts\make_sources.py      the source mesh / sound (generated, no third-party files)
#   2. content\scripts\build_assets.py      the assets in the content project content\Wrc (UnrealEditor-Cmd)
#   3. BuildCookRun (cook + IoStore)        the assets' chunk 7701 = its own container
#   4. -> dist\content\WaCaClanLife_P.pak/.utoc/.ucas  (installed into the game's Content\Paks\~mods)
# Needs UE 5.7.4 (the game's version) - -Engine or $env:WACA_UE_DIR, default the Epic launcher's install folder.
# Also needs the game (its renderer settings: -Game or $env:WACA_GAME_DIR) and .NET for tools\AssetDump.
param([string]$Engine = $(if ($env:WACA_UE_DIR) { $env:WACA_UE_DIR } else { "C:\Program Files\Epic Games\UE_5.7" }),
      [string]$Game = $(if ($env:WACA_GAME_DIR) { $env:WACA_GAME_DIR } else { "Z:\Warrior Cats Clans of the Forest" }))
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$project = Join-Path $root "content\Wrc\Wrc.uproject"
$saved = Join-Path $root "content\Wrc\Saved"
$logs = Join-Path $saved "WaCaContentLogs"
New-Item -ItemType Directory -Force $logs | Out-Null

Write-Host "0/4 the game's renderer settings"
# materials must be compiled under the game's renderer settings, or their shaders don't fit it (a GPU device crash
# the moment one draws): its [/Script/Engine.RendererSettings] goes into the project's DefaultEngine.ini
$gameIni = Join-Path $logs "GameDefaultEngine.ini"
$ErrorActionPreference = "Continue"       # (its progress goes to stderr - Windows PowerShell would call that an error)
dotnet run -c Release --project (Join-Path $root "tools\AssetDump") -- (Join-Path $Game "Wrc\Content\Paks") GAME_UE5_7 raw `
    "Wrc/Config/DefaultEngine.ini" $gameIni *> (Join-Path $logs "assetdump.log")
$ErrorActionPreference = "Stop"
if (-not (Test-Path $gameIni)) { throw "couldn't read the game's DefaultEngine.ini from $Game (see $logs\assetdump.log)" }
$section = [regex]::Match((Get-Content $gameIni -Raw), '(?ms)^\[/Script/Engine\.RendererSettings\]\r?\n.*?(?=^\[|\z)').Value
if (-not $section) { throw "the game's DefaultEngine.ini has no [/Script/Engine.RendererSettings]" }
$template = Get-Content (Join-Path $root "content\Wrc\Config\DefaultEngine.template.ini") -Raw
Set-Content (Join-Path $root "content\Wrc\Config\DefaultEngine.ini") ($template + "`r`n; --- from the game ---`r`n" + $section) -Encoding utf8

Write-Host "1/4 sources"
python (Join-Path $root "content\scripts\make_sources.py")
if ($LASTEXITCODE -ne 0) { throw "make_sources.py failed" }

Write-Host "2/4 assets"
$editor = Join-Path $Engine "Engine\Binaries\Win64\UnrealEditor-Cmd.exe"
$assetLog = Join-Path $logs "build_assets.log"
& $editor $project -run=pythonscript "-script=$(Join-Path $root 'content\scripts\build_assets.py')" -unattended -nop4 `
    -nosplash -nullrhi -stdout -FullStdOutLogOutput *> $assetLog
# (the commandlet's exit code also counts the engine's own handled ensures - the script's last line is the verdict)
if (-not (Select-String -Path $assetLog -Pattern "\[WaCaContent\] done" -Quiet)) { throw "build_assets.py failed - see $assetLog" }

Write-Host "3/4 cook + IoStore (a few minutes the first time: shaders)"
$staged = Join-Path $saved "StagedBuilds"
$cookLog = Join-Path $logs "cook.log"
& (Join-Path $Engine "Engine\Build\BatchFiles\RunUAT.bat") BuildCookRun "-project=$project" -noP4 -platform=Win64 `
    -clientconfig=Shipping -cook -stage -pak -iostore -skipbuild -nocompileeditor -unattended -utf8output `
    "-stagingdirectory=$staged" *> $cookLog
if ($LASTEXITCODE -ne 0) { throw "BuildCookRun failed ($LASTEXITCODE) - see $cookLog" }

Write-Host "4/4 the mod's container"
$out = Join-Path $root "dist\content"
New-Item -ItemType Directory -Force $out | Out-Null
foreach ($ext in "pak", "utoc", "ucas") {
    $file = Get-ChildItem $staged -Recurse -Filter "pakchunk7701-Windows.$ext" | Select-Object -First 1
    if (-not $file) { throw "no pakchunk7701-Windows.$ext in $staged (is Label_WaCaContent's chunk set?)" }
    Copy-Item $file.FullName (Join-Path $out "WaCaClanLife_P.$ext") -Force
}
Get-ChildItem $out | Format-Table Name, Length
