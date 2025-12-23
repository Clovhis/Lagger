param(
    [int]$StepSeconds = 30
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$policyName = "LagGenerator"
$blockRuleName = "LagGeneratorBlock"
$rates = @(
    @{ BitsPerSecond = 8 * 1024 * 1024; Label = "8 Mbps" },
    @{ BitsPerSecond = 4 * 1024 * 1024; Label = "4 Mbps" },
    @{ BitsPerSecond = 2 * 1024 * 1024; Label = "2 Mbps" },
    @{ BitsPerSecond = 1 * 1024 * 1024; Label = "1 Mbps" },
    @{ BitsPerSecond = 512 * 1024; Label = "512 Kbps" },
    @{ BitsPerSecond = 256 * 1024; Label = "256 Kbps" },
    @{ BitsPerSecond = 128 * 1024; Label = "128 Kbps" },
    @{ BitsPerSecond = 64 * 1024; Label = "64 Kbps" },
    @{ BitsPerSecond = 32 * 1024; Label = "32 Kbps" }
)
$targetPorts = @()
$noiseEnabled = $true
$lossEnabled = $true
$jitterEnabled = $true
$noiseTickMs = 1200
$lossChancePercent = 35
$lossDurationMinMs = 120
$lossDurationMaxMs = 600
$jitterPercent = 0.35

function Test-Admin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-NetQos {
    return $null -ne (Get-Command -Name Get-NetQosPolicy -ErrorAction SilentlyContinue)
}

function Apply-Throttle([long]$bps) {
    $existing = Get-NetQosPolicy -Name $policyName -ErrorAction SilentlyContinue
    if ($null -eq $existing) {
        New-NetQosPolicy -Name $policyName -Default -ThrottleRateActionBitsPerSecond $bps | Out-Null
    } else {
        Set-NetQosPolicy -Name $policyName -ThrottleRateActionBitsPerSecond $bps | Out-Null
    }
}

function Ensure-BlockRule {
    Remove-NetFirewallRule -DisplayName $blockRuleName -ErrorAction SilentlyContinue | Out-Null
    $ruleParams = @{
        DisplayName = $blockRuleName
        Direction   = "Outbound"
        Action      = "Block"
        Enabled     = "False"
        Profile     = "Any"
        Protocol    = "Any"
    }
    if ($targetPorts.Count -gt 0) {
        $ruleParams.RemotePort = ($targetPorts -join ",")
    }
    New-NetFirewallRule @ruleParams | Out-Null
}

function Set-BlockRule([bool]$enabled) {
    $state = if ($enabled) { "True" } else { "False" }
    Set-NetFirewallRule -DisplayName $blockRuleName -Enabled $state -ErrorAction SilentlyContinue | Out-Null
}

function Stop-Lag {
    try {
        Remove-NetQosPolicy -Name $policyName -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
        Remove-NetFirewallRule -DisplayName $blockRuleName -ErrorAction SilentlyContinue | Out-Null
    } catch {
        # Best effort cleanup
    }
}

$form = New-Object Windows.Forms.Form
$form.Text = "Lagger"
$form.Size = New-Object Drawing.Size(360, 200)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = "FixedDialog"
$form.MaximizeBox = $false

$btnToggle = New-Object Windows.Forms.Button
$btnToggle.Text = "Generar lag"
$btnToggle.Size = New-Object Drawing.Size(200, 45)
$btnToggle.Location = New-Object Drawing.Point(75, 35)
$btnToggle.Font = New-Object Drawing.Font("Segoe UI", 12, [Drawing.FontStyle]::Bold)

$lblStatus = New-Object Windows.Forms.Label
$lblStatus.Text = "Estado: detenido"
$lblStatus.AutoSize = $true
$lblStatus.Location = New-Object Drawing.Point(20, 100)
$lblStatus.Font = New-Object Drawing.Font("Segoe UI", 10, [Drawing.FontStyle]::Regular)

$form.Controls.Add($btnToggle)
$form.Controls.Add($lblStatus)

$timer = New-Object Windows.Forms.Timer
$timer.Interval = $StepSeconds * 1000
$noiseTimer = New-Object Windows.Forms.Timer
$noiseTimer.Interval = $noiseTickMs
$lossTimer = New-Object Windows.Forms.Timer
$lossTimer.Interval = 200

$running = $false
$stepIndex = 0
$baseRateBps = 0
$lossActive = $false

function Update-Status {
    $rateLabel = $rates[$stepIndex].Label
    $lblStatus.Text = "Estado: degradando ($rateLabel)"
}

function Apply-Jitter {
    if (-not $jitterEnabled) {
        return
    }
    if ($baseRateBps -le 0) {
        return
    }
    $delta = Get-Random -Minimum 0.0 -Maximum $jitterPercent
    $factor = 1.0 - $delta
    $rate = [int64][Math]::Max(1, [Math]::Round($baseRateBps * $factor))
    Apply-Throttle $rate
}

$timer.Add_Tick({
    try {
        $stepIndex++
        if ($stepIndex -ge $rates.Count) {
            $timer.Stop()
            $lblStatus.Text = "Estado: degradado al maximo"
            return
        }
        $baseRateBps = $rates[$stepIndex].BitsPerSecond
        Apply-Throttle $baseRateBps
        Update-Status
    } catch {
        [System.Windows.Forms.MessageBox]::Show(
            "Error aplicando QoS. Requiere admin y NetQos.",
            "Lagger",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
        $running = $false
        $timer.Stop()
        $noiseTimer.Stop()
        $lossTimer.Stop()
        Stop-Lag
        $btnToggle.Text = "Generar lag"
        $lblStatus.Text = "Estado: detenido"
    }
})

$noiseTimer.Add_Tick({
    try {
        if (-not $running) {
            return
        }
        if ($noiseEnabled) {
            Apply-Jitter
        }
        if ($lossEnabled -and -not $lossActive) {
            $roll = Get-Random -Minimum 1 -Maximum 101
            if ($roll -le $lossChancePercent) {
                $lossActive = $true
                Set-BlockRule $true
                $lossTimer.Interval = Get-Random -Minimum $lossDurationMinMs -Maximum ($lossDurationMaxMs + 1)
                $lossTimer.Start()
            }
        }
    } catch {
        $running = $false
        $timer.Stop()
        $noiseTimer.Stop()
        $lossTimer.Stop()
        Stop-Lag
        $btnToggle.Text = "Generar lag"
        $lblStatus.Text = "Estado: detenido"
    }
})

$lossTimer.Add_Tick({
    $lossTimer.Stop()
    if ($lossActive) {
        Set-BlockRule $false
        $lossActive = $false
    }
})

$btnToggle.Add_Click({
    if (-not $running) {
        if (-not (Test-Admin)) {
            [System.Windows.Forms.MessageBox]::Show(
                "Ejecuta como Administrador.",
                "Lagger",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            ) | Out-Null
            return
        }
        if (-not (Test-NetQos)) {
            [System.Windows.Forms.MessageBox]::Show(
                "No se encontro NetQos. Windows necesita el modulo NetQos.",
                "Lagger",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error
            ) | Out-Null
            return
        }

        try {
            $running = $true
            $stepIndex = 0
            $baseRateBps = $rates[$stepIndex].BitsPerSecond
            Apply-Throttle $baseRateBps
            Ensure-BlockRule
            Update-Status
            if ($rates.Count -gt 1) {
                $timer.Start()
            }
            if ($noiseEnabled) {
                $noiseTimer.Start()
            }
            $btnToggle.Text = "Detener"
        } catch {
            [System.Windows.Forms.MessageBox]::Show(
                "Error inicializando QoS.",
                "Lagger",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error
            ) | Out-Null
            $running = $false
            Stop-Lag
            $btnToggle.Text = "Generar lag"
            $lblStatus.Text = "Estado: detenido"
        }
    } else {
        $running = $false
        $timer.Stop()
        $noiseTimer.Stop()
        $lossTimer.Stop()
        Stop-Lag
        $btnToggle.Text = "Generar lag"
        $lblStatus.Text = "Estado: detenido"
    }
})

$form.Add_FormClosing({
    $timer.Stop()
    $noiseTimer.Stop()
    $lossTimer.Stop()
    Stop-Lag
})

[System.Windows.Forms.Application]::Run($form)
