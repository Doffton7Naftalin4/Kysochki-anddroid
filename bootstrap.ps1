param(
    [ValidateSet('install', 'restore')][string]$Action = 'install',
    [switch]$CheckPython,
    [switch]$CheckGame
)
$ErrorActionPreference = 'Stop'
try {
    . (Join-Path $PSScriptRoot 'python_bootstrap.ps1')
    if ($CheckPython) {
        # Diagnostic only: never download, install Python or touch the game.
        $python = Find-HDPython
        if (-not $python) { throw 'No se encontro Python 3.10+.' }
        Write-Host "Python compatible: $python"
        exit 0
    }
    . (Join-Path $PSScriptRoot 'game_bootstrap.ps1')
    $game = Resolve-HDGamePath $env:HD_CAMERA_GAME (Join-Path $PSScriptRoot 'state')
    Write-Host "HELLDIVERS: $game"
    if ($CheckGame) { exit 0 }
    $code = Invoke-HDAction $Action $PSScriptRoot $game
    if ($code -ne 0) { exit 2 }
    exit 0
} catch {
    Write-Host ('No se pudo continuar: ' + $_.Exception.Message) -ForegroundColor Red
    Write-Host 'Conserva el error y la carpeta del mod para revisarlos.'
    exit 2
}
