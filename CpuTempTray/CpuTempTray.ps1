# -NoElevate: set by our own elevated relaunch so it never tries to elevate again.
# -WaitForPrevious: the relaunch waits for the instance that started it to exit.
param(
    [switch]$NoElevate,
    [switch]$WaitForPrevious
)

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

function Test-Elevated {
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [System.Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Relaunches this script elevated. Returns $false if UAC was cancelled.
function Start-Elevated([switch]$WaitForPrevious) {
    $arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" -NoElevate"
    if ($WaitForPrevious) { $arguments += ' -WaitForPrevious' }
    try {
        Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList $arguments -Verb RunAs -WindowStyle Hidden
        return $true
    } catch {
        return $false
    }
}

# Reading the CPU temperature needs admin rights (PawnIO), so ask for them up
# front. If UAC is cancelled, keep running unelevated: the tray shows "--" and
# offers "Restart as administrator".
if (-not $NoElevate -and -not (Test-Elevated)) {
    if (Start-Elevated) { exit }
}

$mutex = $null
$ownsMutex = $false
try {
    $mutex = [System.Threading.Mutex]::new($false, 'Local\CpuTempTray.Hardware.Sensor.v3')
    $timeout = if ($WaitForPrevious) { 10000 } else { 0 }
    try {
        $ownsMutex = $mutex.WaitOne($timeout)
    } catch [System.Threading.AbandonedMutexException] {
        $ownsMutex = $true
    }
} catch {
    # An unelevated process cannot open the mutex of an elevated instance;
    # either way another instance is already running.
}
if (-not $ownsMutex) {
    if ($null -ne $mutex) { $mutex.Dispose() }
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

# Autostart runs through Task Scheduler, not the HKCU Run key: reading the CPU
# temperature needs the PawnIO driver, and PawnIO requires elevation. A Run-key
# entry starts unelevated, so the tray would always show "--".
$script:taskName = 'CpuTempTray'
$script:exePath = Join-Path $script:appDir 'CpuTempTray.exe'

# Owner of the desktop (explorer.exe) in this session. Differs from the process
# user when elevation was done with another administrator's credentials.
function Get-SessionUser {
    try {
        $sessionId = (Get-Process -Id $PID).SessionId
        $explorer = Get-CimInstance Win32_Process -Filter "Name = 'explorer.exe' AND SessionId = $sessionId" |
            Select-Object -First 1
        if ($null -ne $explorer) {
            $owner = Invoke-CimMethod -InputObject $explorer -MethodName GetOwner
            if ($owner.ReturnValue -eq 0) { return "$($owner.Domain)\$($owner.User)" }
        }
    } catch { }
    return $null
}

# True only if the task exists, is enabled and still points at this copy of
# the program (the folder may have been moved since the task was created).
function Test-Autostart {
    try {
        $task = Get-ScheduledTask -TaskName $script:taskName -ErrorAction SilentlyContinue
        if ($null -eq $task -or $task.State -eq 'Disabled') { return $false }
        $matching = @($task.Actions | Where-Object { $_.Execute -and $_.Execute.Trim('"') -eq $script:exePath })
        return $matching.Count -gt 0
    } catch { return $false }
}

function Enable-Autostart {
    $user = "$env:USERDOMAIN\$env:USERNAME"
    $sessionUser = Get-SessionUser
    if ($null -ne $sessionUser -and $sessionUser -ne $user) {
        throw "CPU Temp Tray is elevated as '$user', but you are signed in as '$sessionUser'. " +
              "An elevated logon task only works for an account that is itself an administrator; " +
              "sign in with an administrator account to enable autostart."
    }

    $exe = $script:exePath
    $action = New-ScheduledTaskAction -Execute $exe -WorkingDirectory $script:appDir
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
    # Interactive logon type is required: a tray icon needs a desktop session.
    $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -DontStopOnIdleEnd -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::Zero) `
        -MultipleInstances IgnoreNew

    # -Force replaces an existing task in one step, so a failure never leaves
    # the user without the previous autostart entry.
    [void](Register-ScheduledTask -TaskName $script:taskName -Force `
        -Description 'CPU Temp Tray - real CPU temperature in the notification area (needs admin for PawnIO MSR access)' `
        -Action $action -Trigger $trigger -Principal $principal -Settings $settings)

    # Drop the legacy Run-key entry so autostart has exactly one owner.
    Remove-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' `
        -Name 'CpuTempTray' -ErrorAction SilentlyContinue
}

function Disable-Autostart {
    if (Get-ScheduledTask -TaskName $script:taskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $script:taskName -Confirm:$false
    }
    Remove-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' `
        -Name 'CpuTempTray' -ErrorAction SilentlyContinue
}

# Hands over to an elevated copy; it waits for this one to release the mutex.
function Restart-Elevated {
    if (Start-Elevated -WaitForPrevious) { [System.Windows.Forms.Application]::Exit() }
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
    if (-not (Test-Elevated)) {
        $restartItem = [System.Windows.Forms.ToolStripMenuItem]::new('Restart as administrator')
        $restartItem.Add_Click({ Restart-Elevated })
        [void]$menu.Items.Add($restartItem)
    }
    [void]$menu.Items.Add([System.Windows.Forms.ToolStripSeparator]::new())
    $exitItem = [System.Windows.Forms.ToolStripMenuItem]::new('Exit')
    [void]$menu.Items.Add($exitItem)

    $script:notify = [System.Windows.Forms.NotifyIcon]::new()
    $script:notify.ContextMenuStrip = $menu
    $script:notify.Text = 'CPU: --'
    $script:notify.Visible = $true
    Set-TrayValue -1 'hardware sensor unavailable'

    $autostart.Add_Click({
        if (-not (Test-Elevated)) {
            $answer = [System.Windows.Forms.MessageBox]::Show(
                "Changing autostart requires administrator rights, because the scheduled task must be allowed to run elevated.`r`n`r`nRestart CPU Temp Tray as administrator now?",
                'CPU Temp Tray',
                [System.Windows.Forms.MessageBoxButtons]::YesNo,
                [System.Windows.Forms.MessageBoxIcon]::Information)
            if ($answer -eq [System.Windows.Forms.DialogResult]::Yes) { Restart-Elevated }
            $autostart.Checked = Test-Autostart
            return
        }
        try {
            if (Test-Autostart) { Disable-Autostart } else { Enable-Autostart }
        } catch {
            [void][System.Windows.Forms.MessageBox]::Show(
                "Could not change autostart.`r`n`r`n$($_.Exception.Message)",
                'CPU Temp Tray',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error)
        }
        $autostart.Checked = Test-Autostart
    })

    $exitItem.Add_Click({ [System.Windows.Forms.Application]::Exit() })

    $script:timer = [System.Windows.Forms.Timer]::new()
    $script:timer.Interval = 2000
    # An exception escaping a timer tick would take the whole tray down.
    $script:timer.Add_Tick({ try { Update-Temperature } catch { } })
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
    if ($ownsMutex) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
