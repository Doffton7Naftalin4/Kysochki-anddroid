# Read-only HELLDIVERS path discovery. Dot-source; this file performs no action.
# Get-HDSteamRoots is replaceable by fixture tests before calling the resolver.
function Get-HDSteamRoots {
    $roots = New-Object 'System.Collections.Generic.List[string]'
    foreach ($key in @('HKCU:\Software\Valve\Steam', 'HKLM:\Software\Valve\Steam',
                      'HKLM:\Software\WOW6432Node\Valve\Steam')) {
        $entry = Get-ItemProperty -LiteralPath $key -ErrorAction SilentlyContinue
        if ($null -eq $entry) { continue }
        foreach ($name in @('SteamPath', 'InstallPath')) {
            $property = $entry.PSObject.Properties[$name]
            $value = if ($null -ne $property) { $property.Value } else { $null }
            if ($value -is [string] -and -not [string]::IsNullOrWhiteSpace($value)) { $roots.Add($value) }
        }
        $property = $entry.PSObject.Properties['SteamExe']
        $executable = if ($null -ne $property) { $property.Value } else { $null }
        if ($executable -is [string] -and -not [string]::IsNullOrWhiteSpace($executable)) {
            $roots.Add([IO.Path]::GetDirectoryName($executable))
        }
    }
    $programFiles = [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFilesX86)
    if (-not [string]::IsNullOrWhiteSpace($programFiles)) { $roots.Add((Join-Path $programFiles 'Steam')) }
    return $roots.ToArray()
}

function Read-HDVdfNode {
    param([hashtable]$Cursor, [bool]$Nested)
    $node = @{}
    while ($Cursor.Index -lt $Cursor.Tokens.Count) {
        $token = $Cursor.Tokens[$Cursor.Index]
        if ($token.Kind -eq 'Close') {
            if (-not $Nested) { throw 'VDF no valido: cierre inesperado.' }
            $Cursor.Index++
            return ,$node
        }
        if ($token.Kind -ne 'Text') { throw 'VDF no valido: falta una clave.' }
        $key = $token.Value; $Cursor.Index++
        if ($node.ContainsKey($key) -or $Cursor.Index -ge $Cursor.Tokens.Count) {
            throw 'VDF no valido: clave repetida o valor incompleto.'
        }
        $value = $Cursor.Tokens[$Cursor.Index]; $Cursor.Index++
        if ($value.Kind -eq 'Open') { $node[$key] = Read-HDVdfNode $Cursor $true }
        elseif ($value.Kind -eq 'Text') { $node[$key] = $value.Value }
        else { throw 'VDF no valido: falta un valor.' }
    }
    if ($Nested) { throw 'VDF no valido: bloque sin cerrar.' }
    return ,$node
}

function ConvertFrom-HDVdf {
    param([string]$Text)
    $tokens = New-Object 'System.Collections.Generic.List[object]'
    $pattern = '"(?<Text>(?:\\.|[^"\\])*)"|(?<Open>\{)|(?<Close>\})|(?<Comment>//[^\r\n]*)|(?<Invalid>\S)'
    foreach ($match in [regex]::Matches($Text, $pattern)) {
        if ($match.Groups['Comment'].Success) { continue }
        if ($match.Groups['Invalid'].Success) { throw 'VDF no valido: texto inesperado.' }
        if ($match.Groups['Text'].Success) {
            $value = [regex]::Replace($match.Groups['Text'].Value, '\\([\\"])', '$1')
            $tokens.Add(@{Kind='Text';Value=$value})
        } elseif ($match.Groups['Open'].Success) { $tokens.Add(@{Kind='Open'}) }
        else { $tokens.Add(@{Kind='Close'}) }
    }
    return Read-HDVdfNode @{Tokens=$tokens;Index=0} $false
}

function Read-HDLibraryPaths {
    param([string]$SteamRoot)
    $paths = New-Object 'System.Collections.Generic.List[string]'
    $paths.Add($SteamRoot)
    $file = Join-Path $SteamRoot 'steamapps\libraryfolders.vdf'
    if (-not [IO.File]::Exists($file)) { return $paths.ToArray() }
    $document = ConvertFrom-HDVdf ([IO.File]::ReadAllText($file, [Text.Encoding]::UTF8))
    $libraries = $document['libraryfolders']
    if ($libraries -isnot [hashtable]) { throw "VDF de bibliotecas no valido: $file" }
    foreach ($key in $libraries.Keys) {
        if ($key -notmatch '^\d+$') { continue }
        $value = $libraries[$key]
        $path = if ($value -is [hashtable]) { $value['path'] } else { $value }
        if ($path -isnot [string] -or [string]::IsNullOrWhiteSpace($path) -or -not [IO.Path]::IsPathRooted($path)) {
            throw "VDF de bibliotecas contiene una ruta no valida: $file" 
        }
        $paths.Add($path)
    }
    return $paths.ToArray()
}

function Test-HDGameRoot {
    param([string]$Path)
    return ([IO.File]::Exists((Join-Path $Path 'contents\9e13b2414b41b842')) -and
            [IO.File]::Exists((Join-Path $Path 'binaries\x64\helldivers.exe')))
}

function Get-HDCanonicalGameRoot {
    param([string]$Path, [string]$Description)
    try {
        $resolved = Resolve-Path -LiteralPath $Path -ErrorAction Stop
        if ($resolved.Provider.Name -ne 'FileSystem') { throw 'Not a filesystem path' }
        $full = [IO.Path]::GetFullPath($resolved.ProviderPath)
        if ($full.Length -gt [IO.Path]::GetPathRoot($full).Length) { $full = $full.TrimEnd('\', '/') }
        if (-not (Test-HDGameRoot $full)) { throw 'Missing game markers' }
        return $full
    } catch {
        throw "La ruta $Description de HELLDIVERS no es valida: $Path. Debe contener contents\9e13b2414b41b842 y binaries\x64\helldivers.exe."
    }
}

function Get-HDLibraryCandidates {
    param([string]$Library)
    $common = [IO.Path]::GetFullPath((Join-Path $Library 'steamapps\common'))
    $manifest = Join-Path $Library 'steamapps\appmanifest_394510.acf'
    if ([IO.File]::Exists($manifest)) {
        $document = ConvertFrom-HDVdf ([IO.File]::ReadAllText($manifest, [Text.Encoding]::UTF8))
        $app = $document['AppState']
        if ($app -isnot [hashtable]) { throw "VDF appmanifest no valido: $manifest" }
        if ($app.ContainsKey('installdir')) {
            $directory = $app['installdir']
            if ($directory -isnot [string] -or [string]::IsNullOrWhiteSpace($directory) -or [IO.Path]::IsPathRooted($directory)) {
                throw "installdir no valido en: $manifest"
            }
            $candidate = [IO.Path]::GetFullPath((Join-Path $common $directory))
            if (-not $candidate.StartsWith(($common.TrimEnd('\') + '\'), [StringComparison]::OrdinalIgnoreCase)) {
                throw "installdir sale de steamapps\common: $manifest"
            }
            Write-Output $candidate
        }
    }
    Write-Output (Join-Path $common 'Helldivers')
}

function Resolve-HDGamePath {
    param([string]$ExplicitGame, [string]$StateFolder)
    $recorded = $null
    if (-not [string]::IsNullOrWhiteSpace($StateFolder)) {
        $receipt = Join-Path $StateFolder 'receipt.json'
        if (Test-Path -LiteralPath $receipt) {
            try {
                if (-not [IO.File]::Exists($receipt)) { throw 'Receipt is not a file' }
                $data = [IO.File]::ReadAllText($receipt, [Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop
                if ($null -eq $data -or $data -is [array] -or $data.game_dir -isnot [string] -or
                    [string]::IsNullOrWhiteSpace($data.game_dir) -or
                    $data.game_dir -notmatch '^(?:[A-Za-z]:[\\/]|[\\/]{2}[^\\/]+[\\/][^\\/]+(?:[\\/]|$))') {
                    throw 'Missing or non-absolute game_dir'
                }
                $recorded = Get-HDCanonicalGameRoot $data.game_dir 'del recibo'
            } catch { throw "No se puede usar el recibo $receipt. Conserva state y especifica el destino registrado; no se buscara otro juego. $($_.Exception.Message)" }
        }
    }
    $explicit = $null
    if (-not [string]::IsNullOrWhiteSpace($ExplicitGame)) { $explicit = Get-HDCanonicalGameRoot $ExplicitGame 'explicita' }
    if ($recorded) {
        if ($explicit -and -not $explicit.Equals($recorded, [StringComparison]::OrdinalIgnoreCase)) {
            throw "La ruta explicita no coincide con el recibo de esta version: $recorded. Usa la misma carpeta para restaurar."
        }
        return $recorded
    }
    if ($explicit) { return $explicit }
    $found = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($steam in @(Get-HDSteamRoots)) {
        if ([string]::IsNullOrWhiteSpace($steam) -or -not [IO.Directory]::Exists($steam)) { continue }
        foreach ($library in @(Read-HDLibraryPaths $steam)) {
            foreach ($candidate in @(Get-HDLibraryCandidates $library)) {
                if (Test-HDGameRoot $candidate) {
                    $canonical = Get-HDCanonicalGameRoot $candidate 'detectada'
                    $found[$canonical] = $canonical
                }
            }
        }
    }
    if ($found.Count -eq 1) { return (@($found.Values)[0]) }
    if ($found.Count -gt 1) {
        throw ("Varias instalaciones validas de HELLDIVERS. Pasa la ruta explicita de la que quieres usar: " + ((@($found.Values) | Sort-Object) -join '; '))
    }
    throw 'No se encontro HELLDIVERS original en Steam. Pasa la ruta de su carpeta (la que contiene contents y binaries).'
}
