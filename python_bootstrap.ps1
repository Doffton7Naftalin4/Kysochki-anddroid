# Windows PowerShell 5.1. Only official, pinned Python installers may run.
$ErrorActionPreference = 'Stop'
$script:HDPythonVersion = '3.13.16'
$script:HDInstallers = @{
    amd64 = @{ File = 'python-3.13.16-amd64.exe'; Sha256 = 'fb4f9f5d438b2396da0086dc70b935c530cb578e37adc6d354f7ad2037fee83b' }
    x86 = @{ File = 'python-3.13.16.exe'; Sha256 = '394ca84150ea428db952cb617c1163c49fbc30e47ec53048c26e6ae44265df07' }
    arm64 = @{ File = 'python-3.13.16-arm64.exe'; Sha256 = '696e2226062c6ec3622c13f143d28336a856968518e49cb4f4c62513215a4f5d' }
}

function ConvertTo-HDNativeArgument([string]$Value) {
    # Windows CRT escaping, including quotes and trailing backslashes.
    $text = New-Object System.Text.StringBuilder
    [void]$text.Append('"')
    $slashes = 0
    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq '\') { $slashes++; continue }
        if ($character -eq '"') {
            [void]$text.Append(('\' * (2 * $slashes + 1)))
        } else {
            [void]$text.Append(('\' * $slashes))
        }
        [void]$text.Append($character)
        $slashes = 0
    }
    [void]$text.Append(('\' * (2 * $slashes)))
    [void]$text.Append('"')
    $text.ToString()
}

function Invoke-HDProcess([string]$File, [string[]]$Arguments, [int]$TimeoutMs = 0, [switch]$Capture) {
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $File
    $info.Arguments = (($Arguments | ForEach-Object { ConvertTo-HDNativeArgument $_ }) -join ' ')
    $info.UseShellExecute = $false
    $info.CreateNoWindow = [bool]$Capture
    $info.RedirectStandardOutput = [bool]$Capture
    $info.RedirectStandardError = [bool]$Capture
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $info
    try {
        if (-not $process.Start()) { throw "No se pudo ejecutar: $File" }
        if ($Capture) {
            $stdout = $process.StandardOutput.ReadToEndAsync()
            $stderr = $process.StandardError.ReadToEndAsync()
        }
        if ($TimeoutMs -gt 0) {
            if (-not $process.WaitForExit($TimeoutMs)) {
                $process.Kill()
                $process.WaitForExit()
                throw "Tiempo agotado al comprobar: $File"
            }
        } else { $process.WaitForExit() }
        $output = ''
        if ($Capture) { $output = $stdout.Result; $null = $stderr.Result }
        [pscustomobject]@{ ExitCode = $process.ExitCode; Output = $output }
    } finally { $process.Dispose() }
}

function Invoke-HDProbe([string]$File, [string[]]$Arguments = @()) {
    try {
        $code = 'import sys,json,argparse,hashlib,zlib,ctypes,pathlib,subprocess; print(json.dumps({"ok":sys.version_info >= (3,10),"exe":sys.executable}))'
        $result = Invoke-HDProcess $File (@($Arguments) + @('-I', '-c', $code)) 8000 -Capture
        if ($result.ExitCode -ne 0) { return $null }
        $data = $result.Output.Trim() | ConvertFrom-Json
        if ($data.ok -eq $true -and [IO.Path]::IsPathRooted($data.exe) -and (Test-Path -LiteralPath $data.exe -PathType Leaf)) {
            return [string]$data.exe
        }
    } catch { return $null }
    return $null
}

function Get-HDPythonCandidates {
    # Skip Microsoft Store execution aliases; probing them could open the Store.
    foreach ($name in @('python.exe', 'python3.exe')) {
        foreach ($command in @(Get-Command $name -CommandType Application -All -ErrorAction SilentlyContinue)) {
            if ($command.Source -notmatch '\\WindowsApps\\') {
                [pscustomobject]@{ File = $command.Source; Arguments = @() }
            }
        }
    }
    foreach ($registry in @('HKCU:\Software\Python', 'HKLM:\Software\Python', 'HKLM:\Software\WOW6432Node\Python')) {
        foreach ($company in @(Get-ChildItem -LiteralPath $registry -ErrorAction SilentlyContinue)) {
            foreach ($version in @(Get-ChildItem -LiteralPath $company.PSPath -ErrorAction SilentlyContinue)) {
                try {
                    $install = Get-Item -LiteralPath ($version.PSPath + '\InstallPath') -ErrorAction SilentlyContinue
                    if ($null -ne $install) {
                        $executable = $install.GetValue('ExecutablePath')
                        if (-not $executable) {
                            $directory = $install.GetValue('')
                            if ($directory -isnot [string] -or -not $directory) { continue }
                            $executable = Join-Path $directory 'python.exe'
                        }
                        if ($executable -is [string] -and (Test-Path -LiteralPath $executable -PathType Leaf)) {
                            [pscustomobject]@{ File = $executable; Arguments = @() }
                        }
                    }
                } catch { continue } # Ignore stale or unreadable registry entries.
            }
        }
    }
    # Legacy and modern py both support this inventory command; never ask py to
    # launch a missing version, which could trigger its own automatic install.
    $launcher = Get-Command py.exe -CommandType Application -ErrorAction SilentlyContinue
    if ($launcher) {
        try {
            $listing = Invoke-HDProcess $launcher.Source @('-0p') 8000 -Capture
            foreach ($line in ($listing.Output -split "`r?`n")) {
                if ($line -match '^\s*-.*?\s+([A-Za-z]:\\.*?\.exe)\s*$') {
                    if (Test-Path -LiteralPath $matches[1] -PathType Leaf) {
                        [pscustomobject]@{ File = $matches[1]; Arguments = @() }
                    }
                }
            }
        } catch { }
    }
    if ($env:LOCALAPPDATA) {
        $default = Join-Path $env:LOCALAPPDATA 'Programs\Python\Python313\python.exe'
        if (Test-Path -LiteralPath $default -PathType Leaf) {
            [pscustomobject]@{ File = $default; Arguments = @() }
        }
    }
}

function Find-HDPython {
    $seen = @{}
    foreach ($candidate in @(Get-HDPythonCandidates)) {
        if ($seen.ContainsKey($candidate.File)) { continue }
        $seen[$candidate.File] = $true
        $compatible = Invoke-HDProbe $candidate.File $candidate.Arguments
        if ($compatible) { return $compatible }
    }
    return $null
}

function Get-HDArchitecture {
    $architecture = $env:PROCESSOR_ARCHITEW6432
    if (-not $architecture) { $architecture = $env:PROCESSOR_ARCHITECTURE }
    switch ($architecture.ToUpperInvariant()) {
        'AMD64' { return 'amd64' }
        'ARM64' { return 'arm64' }
        'X86' { return 'x86' }
        default { throw "Arquitectura de Windows no compatible: $architecture" }
    }
}

function Receive-HDInstaller([string]$Url, [string]$Destination) {
    $uri = [Uri]$Url
    if ($uri.Scheme -ne 'https' -or $uri.Host -ne 'www.python.org') { throw 'Origen de Python no permitido.' }
    $previous = [Net.ServicePointManager]::SecurityProtocol
    try {
        [Net.ServicePointManager]::SecurityProtocol = $previous -bor [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $Destination -MaximumRedirection 0 -TimeoutSec 180
    } finally { [Net.ServicePointManager]::SecurityProtocol = $previous }
}

function Assert-HDInstaller([string]$Path, [string]$ExpectedSha256) {
    if ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -ine $ExpectedSha256) {
        throw 'SHA-256 del instalador incorrecto. No se ejecutara.'
    }
    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    if ([string]$signature.Status -ne 'Valid' -or $null -eq $signature.SignerCertificate) {
        throw 'La firma digital de Python no es valida. No se ejecutara.'
    }
    $publisher = $signature.SignerCertificate.GetNameInfo([Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false)
    if ($publisher -cne 'Python Software Foundation') { throw 'El editor del instalador no es Python Software Foundation.' }
}

function Get-HDInstallArguments([string]$Target, [string]$Log) {
    @('/passive', '/norestart', '/log', $Log, 'InstallAllUsers=0', "TargetDir=$Target",
      'Include_launcher=0', 'InstallLauncherAllUsers=0', 'PrependPath=0', 'AppendPath=0',
      'AssociateFiles=0', 'Shortcuts=0', 'Include_test=0', 'Include_doc=0', 'Include_tcltk=0', 'Include_pip=0')
}

function Invoke-HDInstaller([string]$Path, [string]$Target, [string]$Log) {
    (Invoke-HDProcess $Path (Get-HDInstallArguments $Target $Log)).ExitCode
}

function Install-HDPython {
    if (-not $env:LOCALAPPDATA) { throw 'No se encuentra LOCALAPPDATA para instalar Python por usuario.' }
    $artifact = $script:HDInstallers[(Get-HDArchitecture)]
    $downloads = Join-Path $env:LOCALAPPDATA 'HD-Camera\Downloads'
    $null = New-Item -ItemType Directory -Path $downloads -Force
    $identifier = [Guid]::NewGuid().ToString('N')
    $installer = Join-Path $downloads ($identifier + '-' + $artifact.File)
    $log = Join-Path $downloads ($identifier + '-python-install.log')
    $target = Join-Path $env:LOCALAPPDATA 'Programs\Python\Python313'
    Write-Host "No se encontro Python 3.10+. Descargando Python $script:HDPythonVersion desde python.org..."
    Receive-HDInstaller "https://www.python.org/ftp/python/$script:HDPythonVersion/$($artifact.File)" $installer
    Assert-HDInstaller $installer $artifact.Sha256
    Write-Host 'Descarga y firma verificadas. Instalando Python para este usuario...'
    $exitCode = Invoke-HDInstaller $installer $target $log
    if ($exitCode -ne 0 -and $exitCode -ne 3010) {
        throw "Python no se pudo instalar (codigo $exitCode). Registro: $log"
    }
    $python = Invoke-HDProbe (Join-Path $target 'python.exe') @()
    if (-not $python) { throw "Python 3.10+ no quedo utilizable. Registro: $log" }
    return $python
}

function Get-HDPython {
    $python = Find-HDPython
    if ($python) { return $python }
    Install-HDPython
}

function Invoke-HDAction([string]$Action, [string]$Folder, [string]$GamePath) {
    $python = Get-HDPython
    Write-Host "Python compatible: $python"
    $arguments = @('-ES', (Join-Path $Folder 'hd_camera.py'), $Action)
    if ($GamePath) { $arguments += $GamePath }
    (Invoke-HDProcess $python $arguments).ExitCode
}
