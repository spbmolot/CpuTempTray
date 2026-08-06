$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class CpuTempNative {
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool DestroyIcon(IntPtr hIcon);
}
'@

$script:appDir = $PSScriptRoot
$script:computer = $null
$script:notify = $null
$script:timer = $null
$script:currentIcon = $null
$script:lastTemp = [int]::MinValue
$script:lastSource = ''

$createdNew = $false
$mutex = [System.Threading.Mutex]::new($true, 'Local\CpuTempTray.Hardware.Sensor.v3', [ref]$createdNew)
if (-not $createdNew) {
    $mutex.Dispose()
    exit
}

function Test-PawnIOInstalled {
    return (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\PawnIO') -or
           (Test-Path 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\PawnIO')
}

function Install-PawnIOIfNeeded {
    if (Test-PawnIOInstalled) { return }

    $installer = Join-Path $script:appDir 'PawnIO_setup.exe'
    if (-not (Test-Path $installer)) { return }

    $text = "Real Intel CPU temperature requires PawnIO. It only needs to be installed once.`r`n`r`n" +
            "PawnIO is included with official LibreHardwareMonitor 0.9.6. Continue?"
    $answer = [System.Windows.Forms.MessageBox]::Show(
        $text, 'CPU Temp Tray',
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Information)

    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }

    try {
        Start-Process -FilePath $installer -ArgumentList '-install' -Verb RunAs -Wait
    } catch {
        # UAC was cancelled or installation failed. Tray stays active and shows "--".
    }
}

function New-TemperatureIcon([int]$temperature) {
    if ($temperature -lt 0) {
        $background = [System.Drawing.Color]::FromArgb(91, 99, 112)
    } elseif ($temperature -lt 60) {
        $background = [System.Drawing.Color]::FromArgb(20, 184, 99)
    } elseif ($temperature -lt 80) {
        $background = [System.Drawing.Color]::FromArgb(245, 158, 11)
    } else {
        $background = [System.Drawing.Color]::FromArgb(239, 68, 68)
    }

    $bitmap = [System.Drawing.Bitmap]::new(32, 32)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $brush = [System.Drawing.SolidBrush]::new($background)
    $fontSize = if ($temperature -ge 100) { 12 } else { 14 }
    $font = [System.Drawing.Font]::new('Segoe UI', [single]$fontSize, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
    try {
        $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
        $graphics.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
        $graphics.FillRectangle($brush, 0, 0, 32, 32)
        $text = if ($temperature -lt 0) { '--' } else { [string]$temperature }
        $size = $graphics.MeasureString($text, $font)
        $graphics.DrawString($text, $font, [System.Drawing.Brushes]::White,
            ((32 - $size.Width) / 2), ((32 - $size.Height) / 2 - 1))

        $handle = $bitmap.GetHicon()
        try {
            $temporary = [System.Drawing.Icon]::FromHandle($handle)
            return $temporary.Clone()
        } finally {
            [void][CpuTempNative]::DestroyIcon($handle)
        }
    } finally {
        $font.Dispose()
        $brush.Dispose()
        $graphics.Dispose()
        $bitmap.Dispose()
    }
}

function Set-TrayValue([int]$temperature, [string]$source) {
    if ($temperature -eq $script:lastTemp -and $source -eq $script:lastSource) { return }

    $next = New-TemperatureIcon $temperature
    $previous = $script:currentIcon
    $script:currentIcon = $next
    $script:notify.Icon = $next
    if ($temperature -lt 0) {
        $script:notify.Text = 'CPU: -- [PawnIO sensor unavailable]'
    } else {
        $degree = [char]176
        $script:notify.Text = "CPU: ${temperature}${degree}C [$source]"
    }
    if ($null -ne $previous) { $previous.Dispose() }

    $script:lastTemp = $temperature
    $script:lastSource = $source
}

function Update-Temperature {
    $temperature = -1
    $source = 'hardware sensor unavailable'
    try {
        $cpu = @($script:computer.Hardware | Where-Object { $_.HardwareType.ToString() -eq 'Cpu' })
        foreach ($hardware in $cpu) { $hardware.Update() }

        $sensor = $null
        foreach ($wanted in @('Core Max', 'CPU Package')) {
            $sensor = $cpu.Sensors | Where-Object {
                $_.SensorType.ToString() -eq 'Temperature' -and $_.Name -eq $wanted -and $null -ne $_.Value
            } | Select-Object -First 1
            if ($null -ne $sensor) { break }
        }

        if ($null -ne $sensor) {
            $value = [double]$sensor.Value
            if ($value -ge 0 -and $value -le 125) {
                $temperature = [int][Math]::Round($value, [MidpointRounding]::AwayFromZero)
                $source = $sensor.Name
            }
        }
    } catch {
        $temperature = -1
        $source = 'hardware sensor unavailable'
    }
    Set-TrayValue $temperature $source
}

function Test-Autostart {
    try {
        $v = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'CpuTempTray' -ErrorAction SilentlyContinue).CpuTempTray
        return -not [string]::IsNullOrWhiteSpace($v)
    } catch { return $false }
}

try {
    Install-PawnIOIfNeeded

    $lib = Join-Path $script:appDir 'LibreHardwareMonitorLib.dll'
    [void][Reflection.Assembly]::LoadFrom($lib)

    $script:computer = [LibreHardwareMonitor.Hardware.Computer]::new()
    $script:computer.IsCpuEnabled = $true
    $script:computer.Open()

    $menu = [System.Windows.Forms.ContextMenuStrip]::new()
    $autostart = [System.Windows.Forms.ToolStripMenuItem]::new('Start with Windows')
    $autostart.Checked = Test-Autostart
    [void]$menu.Items.Add($autostart)
    [void]$menu.Items.Add([System.Windows.Forms.ToolStripSeparator]::new())
    $exitItem = [System.Windows.Forms.ToolStripMenuItem]::new('Exit')
    [void]$menu.Items.Add($exitItem)

    $script:notify = [System.Windows.Forms.NotifyIcon]::new()
    $script:notify.ContextMenuStrip = $menu
    $script:notify.Text = 'CPU: --'
    $script:notify.Visible = $true
    Set-TrayValue -1 'hardware sensor unavailable'

    $autostart.Add_Click({
        try {
            $runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
            if (Test-Autostart) {
                Remove-ItemProperty $runKey -Name 'CpuTempTray' -ErrorAction SilentlyContinue
                $autostart.Checked = $false
            } else {
                $exe = Join-Path $script:appDir 'CpuTempTray.exe'
                Set-ItemProperty $runKey -Name 'CpuTempTray' -Value ('"' + $exe + '"')
                $autostart.Checked = $true
            }
        } catch { }
    })

    $exitItem.Add_Click({ [System.Windows.Forms.Application]::Exit() })

    $script:timer = [System.Windows.Forms.Timer]::new()
    $script:timer.Interval = 2000
    $script:timer.Add_Tick({ Update-Temperature })
    Update-Temperature
    $script:timer.Start()

    [System.Windows.Forms.Application]::Run()
} catch {
    [System.Windows.Forms.MessageBox]::Show(
        "Hardware CPU sensor failed to start.`r`n`r`n$($_.Exception.Message)",
        'CPU Temp Tray',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
} finally {
    if ($null -ne $script:timer) { $script:timer.Stop(); $script:timer.Dispose() }
    if ($null -ne $script:notify) { $script:notify.Visible = $false; $script:notify.Dispose() }
    if ($null -ne $script:currentIcon) { $script:currentIcon.Dispose() }
    if ($null -ne $script:computer) { try { $script:computer.Close() } catch { } }
    if ($null -ne $mutex) { $mutex.ReleaseMutex(); $mutex.Dispose() }
}
