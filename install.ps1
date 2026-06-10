<#
.SYNOPSIS
    Install, upgrade, or uninstall Ciklet Desktop on Windows.

.DESCRIPTION
    Downloads and installs Ciklet.

    Quick install:

        irm https://ciklet.xyz/install.ps1 | iex

    Specific version:

        $env:CIKLET_VERSION="1.1.17"; irm https://ciklet.xyz/install.ps1 | iex

    Custom install directory:

        $env:CIKLET_INSTALL_DIR="D:\Ciklet"; irm https://ciklet.xyz/install.ps1 | iex

    Uninstall:

        $env:CIKLET_UNINSTALL=1; irm https://ciklet.xyz/install.ps1 | iex

    Environment variables:

        CIKLET_VERSION       Target version (default: latest stable)
        CIKLET_INSTALL_DIR   Custom install directory
        CIKLET_UNINSTALL     Set to 1 to uninstall Ciklet
        CIKLET_DEBUG         Enable verbose output

.EXAMPLE
    irm https://ciklet.xyz/install.ps1 | iex

.EXAMPLE
    $env:CIKLET_VERSION = "1.1.17"; irm https://ciklet.xyz/install.ps1 | iex
#>

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# --------------------------------------------------------------------------
# Configuration from environment variables
# --------------------------------------------------------------------------

$Version      = if ($env:CIKLET_VERSION) { $env:CIKLET_VERSION } else { "" }
$InstallDir   = if ($env:CIKLET_INSTALL_DIR) { $env:CIKLET_INSTALL_DIR } else { "" }
$Uninstall    = $env:CIKLET_UNINSTALL -eq "1"
$DebugInstall = [bool]$env:CIKLET_DEBUG

# --------------------------------------------------------------------------
# Constants
# --------------------------------------------------------------------------

$GithubRepo = "CikletApp/ciklet-desktop-releases"

# --------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------

function Write-Status {
    param([string]$Message)
    if ($DebugInstall) { Write-Host $Message }
}

function Write-Step {
    param([string]$Message)
    if ($DebugInstall) { Write-Host ">>> $Message" -ForegroundColor Cyan }
}

function Find-NsisInstall {
    # Check both HKCU (per-user) and HKLM (per-machine) locations
    $possibleKeys = @(
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall",
        "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall",
        "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall"
    )

    foreach ($key in $possibleKeys) {
        if (Test-Path $key) {
            $subkeys = Get-ChildItem -Path $key -ErrorAction SilentlyContinue
            foreach ($subkey in $subkeys) {
                $displayName = (Get-ItemProperty -Path $subkey.PSPath -Name "DisplayName" -ErrorAction SilentlyContinue).DisplayName
                if ($displayName -match "^Ciklet$") {
                    Write-Status "  Found install at: $($subkey.PSPath)"
                    return $subkey.PSPath
                }
            }
        }
    }
    return $null
}

function Invoke-Download {
    param(
        [string]$Url,
        [string]$OutFile
    )

    Write-Status "  Downloading: $Url"
    try {
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
        $request = [System.Net.HttpWebRequest]::Create($Url)
        $request.AllowAutoRedirect = $true
        # Add basic user agent to prevent GitHub API rejections
        $request.UserAgent = "Ciklet-Installer"
        
        $response = $request.GetResponse()
        $totalBytes = $response.ContentLength
        $stream = $response.GetResponseStream()
        $fileStream = [System.IO.FileStream]::new($OutFile, [System.IO.FileMode]::Create)
        $buffer = [byte[]]::new(65536)
        $totalRead = 0
        $lastUpdate = [DateTime]::MinValue
        $barWidth = 40

        try {
            while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                $fileStream.Write($buffer, 0, $read)
                $totalRead += $read

                $now = [DateTime]::UtcNow
                if (($now - $lastUpdate).TotalMilliseconds -ge 250) {
                    if ($totalBytes -gt 0) {
                        $pct = [math]::Min(100.0, ($totalRead / $totalBytes) * 100)
                        $filled = [math]::Floor($barWidth * $pct / 100)
                        $empty = $barWidth - $filled
                        $bar = ('#' * $filled) + (' ' * $empty)
                        $pctFmt = $pct.ToString("0.0")
                        Write-Host -NoNewline "`r$bar ${pctFmt}%"
                    } else {
                        $sizeMB = [math]::Round($totalRead / 1MB, 1)
                        Write-Host -NoNewline "`r${sizeMB} MB downloaded..."
                    }
                    $lastUpdate = $now
                }
            }

            # Final progress update
            if ($totalBytes -gt 0) {
                $bar = '#' * $barWidth
                Write-Host "`r$bar 100.0%"
            } else {
                $sizeMB = [math]::Round($totalRead / 1MB, 1)
                Write-Host "`r${sizeMB} MB downloaded.          "
            }
        } finally {
            $fileStream.Close()
            $stream.Close()
            $response.Close()
        }
    } catch {
        throw "Download failed for ${Url}: $($_.Exception.Message)"
    }
}

# --------------------------------------------------------------------------
# Uninstall
# --------------------------------------------------------------------------

function Invoke-Uninstall {
    Write-Step "Uninstalling Ciklet"

    $regKey = Find-NsisInstall
    if (-not $regKey) {
        Write-Host ">>> Ciklet is not installed."
        return
    }

    $uninstallString = (Get-ItemProperty -Path $regKey -ErrorAction SilentlyContinue).QuietUninstallString
    if (-not $uninstallString) {
        $uninstallString = (Get-ItemProperty -Path $regKey -ErrorAction SilentlyContinue).UninstallString
    }

    if (-not $uninstallString) {
        Write-Warning "No uninstall string found in registry"
        return
    }

    # Strip quotes if present
    $uninstallExe = $uninstallString -replace '"', ''
    Write-Status "  Uninstaller: $uninstallExe"

    if (-not (Test-Path $uninstallExe)) {
        # Try extracting the actual exe path if it has arguments
        $uninstallExe = ($uninstallString -split ' ')[0] -replace '"', ''
        if (-not (Test-Path $uninstallExe)) {
            Write-Warning "Uninstaller not found at: $uninstallExe"
            return
        }
    }

    Write-Host ">>> Launching uninstaller..."
    Start-Process -FilePath $uninstallExe -ArgumentList "/S" -Wait

    # Verify removal
    if (Find-NsisInstall) {
        Write-Warning "Uninstall may not have completed"
    } else {
        Write-Host ">>> Ciklet has been uninstalled."
    }
}

# --------------------------------------------------------------------------
# Install
# --------------------------------------------------------------------------

function Invoke-Install {
    Write-Step "Fetching latest release info for Ciklet"
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12

    $installerUrl = ""

    try {
        if ($Version) {
            $apiUrl = "https://api.github.com/repos/$GithubRepo/releases/tags/v$Version"
            # Some versions might not have 'v' prefix
            try {
                $releaseInfo = Invoke-RestMethod -Uri $apiUrl -Headers @{ "User-Agent" = "Ciklet-Installer" }
            } catch {
                $apiUrl = "https://api.github.com/repos/$GithubRepo/releases/tags/$Version"
                $releaseInfo = Invoke-RestMethod -Uri $apiUrl -Headers @{ "User-Agent" = "Ciklet-Installer" }
            }
        } else {
            $apiUrl = "https://api.github.com/repos/$GithubRepo/releases/latest"
            $releaseInfo = Invoke-RestMethod -Uri $apiUrl -Headers @{ "User-Agent" = "Ciklet-Installer" }
        }

        $exeAsset = $releaseInfo.assets | Where-Object { $_.name -like "*.exe" } | Select-Object -First 1
        
        if ($exeAsset) {
            $installerUrl = $exeAsset.browser_download_url
            Write-Status "  Found installer: $installerUrl"
        } else {
            throw "No .exe installer found in the release."
        }
    } catch {
        Write-Host ">>> Failed to fetch release info from GitHub."
        throw $_
    }

    # Download installer
    Write-Step "Downloading Ciklet"
    if (-not $DebugInstall) {
        Write-Host ">>> Downloading Ciklet for Windows..."
    }

    $tempInstaller = Join-Path $env:TEMP "CikletSetup.exe"
    Invoke-Download -Url $installerUrl -OutFile $tempInstaller

    # Build installer arguments
    $installerArgs = "/S"
    if ($InstallDir) {
        # NSIS target directory arg
        $installerArgs += " /D=$InstallDir"
    }
    Write-Status "  Installer args: $installerArgs"

    # Run installer
    Write-Step "Installing Ciklet"
    if (-not $DebugInstall) {
        Write-Host ">>> Installing Ciklet..."
    }

    # Start installer and wait
    $proc = Start-Process -FilePath $tempInstaller `
        -ArgumentList $installerArgs `
        -PassThru
    $proc.WaitForExit()

    if ($proc.ExitCode -ne 0) {
        Remove-Item $tempInstaller -Force -ErrorAction SilentlyContinue
        throw "Installation failed with exit code $($proc.ExitCode)"
    }

    # Cleanup
    Remove-Item $tempInstaller -Force -ErrorAction SilentlyContinue

    Write-Host ">>> Install complete. You can now launch Ciklet from your Start Menu or Desktop."
}

# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------

if ($Uninstall) {
    Invoke-Uninstall
} else {
    Invoke-Install
}
