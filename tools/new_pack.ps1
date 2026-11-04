# A NEW STORY PACK, ready to play and to edit: a folder with a role for one of your save's cats, a clan event when your
# cat meets it, a short cutscene, and lines it murmurs - every file commented, every key explained in docs\WRITING.md.
#   .\tools\new_pack.ps1 -Name MyFirstStory -Cat Shadowheart [-Out "<game>\Wrc\Binaries\Win64\ue4ss\Mods"]
# -Name: the pack's name (letters / digits; the folder is WaCa<Name>); -Cat: a cat of your save, by its name as the game
# shows it. -Out: where the pack folder goes (default: the current folder). Restart the game (or Clan Life) to load it;
# the story check (Saved\WaCaStoryCheck.txt) proofreads it at once.
param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][string]$Cat,
    [string]$Out = "."
)
$ErrorActionPreference = "Stop"
if ($Name -notmatch '^[A-Za-z][A-Za-z0-9]*$') { throw "-Name: letters and digits only, a letter first (got '$Name')" }
if ($Cat -notmatch '^[A-Za-z][A-Za-z ]*$') { throw "-Cat: a cat's name as the game shows it (got '$Cat')" }
$pack = "WaCa$Name"
$dir = Join-Path $Out $pack
if (Test-Path $dir) { throw "$dir already exists - pick another -Name (nothing was written)" }
$role = "S:" + $Name.ToLower()
$content = Join-Path $dir "content"
New-Item -ItemType Directory -Force $content | Out-Null

# (UTF-8 without a BOM, CRLF - what the game's own ini files are)
function Write-Text([string]$path, [string]$text) {
    $text = ($text -replace "`r`n", "`n") -replace "`n", "`r`n"
    [System.IO.File]::WriteAllText($path, $text, (New-Object System.Text.UTF8Encoding($false)))
}

Write-Text (Join-Path $dir "enabled.txt") "1`n"

Write-Text (Join-Path $dir "README.md") @"
# $pack

A story pack for WaCa Clan Life, made with ``tools\new_pack.ps1``. $Cat plays this pack's role ``$role``.

- ``content\events.ini`` - who plays the role
- ``content\clanevents.ini`` - what happens when your cat meets $Cat
- ``content\cutscenes.ini`` - the scene that plays (needs WaCa Cutscenes)
- ``content\lines.ini`` - what $Cat murmurs around camp

Every key is explained in WaCa Clan Life's docs\WRITING.md. The story check proofreads the pack each time the game
starts: Saved\WaCaStoryCheck.txt.
"@

Write-Text (Join-Path $content "events.ini") @"
; WHO PLAYS THIS PACK'S ROLE (WRITING.md section 4): a cat of your save by its name. Change the name and every line,
; scene and event below follows - they name the role ($role), never the cat.
[Cast]
$role = $Cat
"@

Write-Text (Join-Path $content "clanevents.ini") @"
; WHEN YOUR CAT MEETS $Cat (WRITING.md section 2): When = Reach: <a cat or a place>, within Radius cm; once a day
; (Once = 1: once a save). The steps run in order (section 3): a card, then the cutscene.
[Event.${Name}Meet]
When = Reach: $role
Radius = 400
Step1 = Card: {$role} has been waiting for you.
Step2 = Cutscene: ${Name}Talk
"@

Write-Text (Join-Path $content "cutscenes.ini") @"
; A SHORT SCENE (WRITING.md section 6): two groups facing each other - A = your cat, B = the role's cat. Beats are
; <seconds> <Action>: <who> = <what>. {PLAYER} and {$role} become names; {Leader} names your leader.
[Cutscene.${Name}Talk]
Place = Here
Shape = Facing
A = Player
B = $role
Beat1 = 0 Camera: Two = A1 & B1 ~1
Beat2 = 1 Say: $role = {PLAYER}! I hoped you'd come by.
Beat3 = 6 Say: A1 = What is it, {$role}?
Beat4 = 10 Say: $role = Nothing yet. Tell {Leader} I'll keep watch.
Beat5 = 15 Walk: $role = Away
Beat6 = 15 Camera: Behind = $role ~1
Beat7 = 20 End
"@

Write-Text (Join-Path $content "lines.ini") @"
; WHAT $Cat SAYS AROUND CAMP (WRITING.md section 8): murmur lines for this pack's role - a different one each day.
[Murmur.$Name]
Who = $role
Line1 = Have you seen the sky tonight, {PLAYER}?
Line2 = Someone should tell {Leader} to rest now and then.
Line3 = I keep thinking about the border.
"@

Write-Host "Made $dir"
Write-Host "  role $role = $Cat; event ${Name}Meet (meet $Cat); cutscene ${Name}Talk; murmurs $Name"
Write-Host "  Restart the game to load it; Saved\WaCaStoryCheck.txt proofreads it."
