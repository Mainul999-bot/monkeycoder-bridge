# MonkeyCoder Bridge - one-command auto-setup
# Fills config.json (prompts for your keys), starts the bridge, and configures
# popular AI agents. Run from the project folder:
#
#   powershell -ExecutionPolicy Bypass -File setup.ps1
#   powershell -ExecutionPolicy Bypass -File setup.ps1 -RegisterAutoStart   # start bridge on login

param(
  [switch]$RegisterAutoStart
)

$ErrorActionPreference = 'Stop'
$here       = Split-Path -Parent $MyInvocation.MyCommand.Path
$bridgeBase = 'http://127.0.0.1:8787'
$bridgeUrl  = "$bridgeBase/v1"
$dummyKey   = 'bridge-dummy'

Write-Host ''
Write-Host '=============================================' -ForegroundColor Cyan
Write-Host '  MonkeyCoder Bridge - auto setup'             -ForegroundColor Cyan
Write-Host '=============================================' -ForegroundColor Cyan

# ---------------- 1. config.json (keys) ----------------
$configPath = Join-Path $here 'config.json'
if (-not (Test-Path -LiteralPath $configPath)) {
  $example = Join-Path $here 'config.example.json'
  if (-not (Test-Path -LiteralPath $example)) {
    Write-Host '[FAIL] config.example.json not found next to setup.ps1' -ForegroundColor Red
    exit 1
  }
  Copy-Item -LiteralPath $example -Destination $configPath
  $cfg = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
  $ak = Read-Host 'Paste your api_key (starts with oma_)'
  $sk = Read-Host 'Paste your signing_secret (starts with omas_)'
  $cfg.apiKey        = $ak.Trim()
  $cfg.signingSecret = $sk.Trim()
  $cfg | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $configPath -Encoding UTF8
  Write-Host '[ok] config.json created with your keys' -ForegroundColor Green
} else {
  $cfg = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
  if (-not $cfg.apiKey -or $cfg.apiKey -eq 'oma_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx') {
    Write-Host '[FAIL] config.json exists but apiKey is still a placeholder. Edit it (or delete it and rerun).' -ForegroundColor Red
    exit 1
  }
  Write-Host '[ok] config.json found - keeping it' -ForegroundColor Green
}

$modelIds = @()
if ($cfg.modelName) {
  $modelIds = @($cfg.modelName)
} else {
  $modelIds = @($cfg.models | ForEach-Object { $_.id })
}
if ($modelIds.Count -eq 0) {
  Write-Host '[FAIL] no models defined in config.json (set "models" or "modelName")' -ForegroundColor Red
  exit 1
}

# ---------------- 2. start the bridge ----------------
function Test-Healthz {
  try { $null = Invoke-RestMethod -Uri "$bridgeBase/healthz" -TimeoutSec 2; return $true }
  catch { return $false }
}
if (-not (Test-Healthz)) {
  Write-Host '[..] starting bridge...' -ForegroundColor Yellow
  Start-Process -FilePath 'node' -ArgumentList 'server.js' -WorkingDirectory $here -WindowStyle Hidden
  for ($i = 0; $i -lt 10 -and -not (Test-Healthz); $i++) { Start-Sleep -Seconds 1 }
}
if (Test-Healthz) {
  Write-Host '[ok] bridge is running at ' $bridgeBase -ForegroundColor Green
} else {
  Write-Host '[FAIL] bridge did not become healthy. Run "node server.js" manually and check config.json.' -ForegroundColor Red
}

# ---------------- helpers ----------------
function Read-JsonFile([string]$path) {
  if (Test-Path -LiteralPath $path) {
    return (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json)
  }
  return $null
}
function Write-JsonFile([string]$path, $obj) {
  $dir = Split-Path -Parent $path
  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  $obj | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $path -Encoding UTF8
}

# ---------------- 3. opencode (fully automated) ----------------
try {
  $ocPath = Join-Path $env:USERPROFILE '.config\opencode\opencode.json'
  $oc = Read-JsonFile $ocPath
  if (-not $oc) { $oc = [pscustomobject]@{ provider = [ordered]@{} } }
  if (-not $oc.provider) { $oc | Add-Member -NotePropertyName provider -NotePropertyValue ([ordered]@{}) -Force }
  $modelsObj = [ordered]@{}
  foreach ($m in $cfg.models) { $modelsObj[$m.id] = [ordered]@{ name = $m.name } }
  $oc.provider | Add-Member -NotePropertyName monkeycode -NotePropertyValue ([ordered]@{
    npm     = '@ai-sdk/anthropic'
    name    = 'MonkeyCode Bridge'
    options = [ordered]@{ baseURL = $bridgeUrl; apiKey = $dummyKey }
    models  = $modelsObj
  }) -Force
  Write-JsonFile $ocPath $oc
  Write-Host '[ok] opencode  -> ~/.config/opencode/opencode.json (provider "monkeycode")' -ForegroundColor Green
} catch {
  Write-Host '[warn] opencode setup skipped: ' $_.Exception.Message -ForegroundColor Yellow
}

# ---------------- 4. Claude Code (fully automated) ----------------
try {
  $ccPath = Join-Path $env:USERPROFILE '.claude\settings.json'
  $cc = Read-JsonFile $ccPath
  if (-not $cc) { $cc = [pscustomobject]@{ env = [ordered]@{} } }
  if (-not $cc.env) { $cc | Add-Member -NotePropertyName env -NotePropertyValue ([ordered]@{}) -Force }
  $cc.env | Add-Member -NotePropertyName ANTHROPIC_BASE_URL        -NotePropertyValue $bridgeUrl -Force
  $cc.env | Add-Member -NotePropertyName ANTHROPIC_AUTH_TOKEN      -NotePropertyValue $dummyKey  -Force
  $cc.env | Add-Member -NotePropertyName ANTHROPIC_MODEL           -NotePropertyValue $modelIds[0] -Force
  if ($modelIds.Count -gt 1) {
    $cc.env | Add-Member -NotePropertyName ANTHROPIC_SMALL_FAST_MODEL -NotePropertyValue $modelIds[1] -Force
  }
  Write-JsonFile $ccPath $cc
  Write-Host '[ok] claude code -> ~/.claude/settings.json (env: ANTHROPIC_BASE_URL/AUTH_TOKEN/MODEL)' -ForegroundColor Green
  Write-Host '     (note: this overrides any ANTHROPIC_BASE_URL you had there)' -ForegroundColor DarkGray
} catch {
  Write-Host '[warn] Claude Code setup skipped: ' $_.Exception.Message -ForegroundColor Yellow
}

# ---------------- 5. Continue (fully automated) ----------------
try {
  $ctPath = Join-Path $env:USERPROFILE '.continue\config.json'
  $ct = Read-JsonFile $ctPath
  if (-not $ct) { $ct = [pscustomobject]@{ models = @() } }
  if (-not $ct.models) { $ct | Add-Member -NotePropertyName models -NotePropertyValue @() -Force }
  $existing = @($ct.models | ForEach-Object { $_.title })
  foreach ($m in $cfg.models) {
    if ($existing -notcontains $m.name) {
      $ct.models += [ordered]@{
        title    = $m.name
        provider = 'anthropic'
        model    = $m.id
        apiBase  = $bridgeUrl
        apiKey   = $dummyKey
      }
    }
  }
  Write-JsonFile $ctPath $ct
  Write-Host '[ok] continue    -> ~/.continue/config.json (added ' $modelIds.Count ' model(s))' -ForegroundColor Green
} catch {
  Write-Host '[warn] Continue setup skipped: ' $_.Exception.Message -ForegroundColor Yellow
}

# ---------------- 6. auto-start on login (optional) ----------------
if ($RegisterAutoStart) {
  try {
    $startup  = [Environment]::GetFolderPath('Startup')
    $lnkPath  = Join-Path $startup 'MonkeyCoderBridge.lnk'
    $nodeExe  = (Get-Command node.exe).Source
    $ws       = New-Object -ComObject WScript.Shell
    $shortcut = $ws.CreateShortcut($lnkPath)
    $shortcut.TargetPath       = $nodeExe
    $shortcut.Arguments        = 'server.js'
    $shortcut.WorkingDirectory = $here
    $shortcut.Save()
    Write-Host '[ok] bridge will start automatically on login (startup shortcut created)' -ForegroundColor Green
  } catch {
    Write-Host '[warn] could not create startup shortcut: ' $_.Exception.Message -ForegroundColor Yellow
  }
}

# ---------------- 7. manual-only agents ----------------
Write-Host ''
Write-Host 'Manual setup (open the app and enter these values):' -ForegroundColor Yellow
Write-Host '  Base URL : ' $bridgeUrl
Write-Host '  API key  : ' $dummyKey
Write-Host '  Models   : ' ($modelIds -join ', ')
Write-Host '    Cursor        -> Settings > Models > Override OpenAI base URL'
Write-Host '    Cline         -> provider settings: API provider = OpenAI Compatible'
Write-Host '    Cherry Studio -> Settings > Model provider > Add OpenAI-compatible, set API host to http://127.0.0.1:8787'
Write-Host '    Windsurf      -> Settings > Models, add custom model with the base URL above'
Write-Host ''
Write-Host 'Done. If the bridge did not start, run:  node server.js' -ForegroundColor Cyan
