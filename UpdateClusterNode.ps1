param (
    [string]$Phase = "pre-reboot"
)

# Version 20250711
# ===== SETTINGS =====
$LogPath = "C:\ClusterUpdateLogs"
$TaskName = "ResumeClusterNode"
$LogFile = Join-Path $LogPath "ClusterUpdate_$(Get-Date -Format yyyyMMdd).log"

#create log file directory
try {
    if (-not (Test-Path -Path $LogPath)) {
        New-Item -Path $LogPath -ItemType Directory -Force -ErrorAction Stop | Out-Null
    }
} catch {
    Write-Error "❌ Failed to create log directory at '$LogPath': $($_.Exception.Message)"
    exit 1
}


function Log {
    param($msg)
    try {
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        "$timestamp :: $msg" | Tee-Object -FilePath $LogFile -Append
    } catch {
        Write-Error "❌ Failed to write to log file '$LogFile': $($_.Exception.Message)"
        exit 1
    }
}

function Test-PendingReboot {
    $pending = $false

    # Component-Based Servicing
    if (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending") {
        $pending = $true
    }

    # Windows Update
    if (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired") {
        $pending = $true
    }

    # Pending Computer Rename
    if ((Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName").ComputerName -ne `
        (Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName").ComputerName) {
        $pending = $true
    }

    # Pending file rename operations
    $pendingRenames = Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager" -Name "PendingFileRenameOperations" -ErrorAction SilentlyContinue
    if ($pendingRenames -ne $null) {
        $pending = $true
    }

    return $pending
}


if ($Phase -eq "pre-reboot") {
    try {
        Log "===== Starting update on $env:COMPUTERNAME ====="
        # Log OS version and patch level
        $osInfo = Get-CimInstance -ClassName Win32_OperatingSystem
    	$reg = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion"
    	$buildFull = "$($reg.CurrentBuild).$($reg.UBR)"
    	Log "🖥 OS Version: $($osInfo.Caption) $($osInfo.Version) | Build: $buildFull"
        $hotfixes = Get-HotFix | Sort-Object InstalledOn -Descending
        foreach ($hf in $hotfixes) {
            Log "📦 HotFix: $($hf.HotFixID) - InstalledOn: $($hf.InstalledOn)"
        }

        # Log cluster group status
        $groups = Get-ClusterGroup
        foreach ($g in $groups) {
            Log "🔷 ClusterGroup: $($g.Name) | Owner: $($g.OwnerNode) | State: $($g.State)"
        }

        # Install defender signatures
        try {
            Log "🔁 Attempting to update Microsoft Defender Antivirus signatures..."
            Update-MpSignature -ErrorAction Stop
            Log "✅ Microsoft Defender signature update completed."
        } catch {
            Log "⚠️ Failed to update Microsoft Defender signature: $($_.Exception.Message)"
        }

        # Install windows updates
        Log "➡️ Checking for new updates"
        $hasUpdates = $false
        $needsReboot = $false
        try {
            if (-not (Get-Command Get-WindowsUpdate -ErrorAction SilentlyContinue)) {
                Install-PackageProvider -Name NuGet -Force -Confirm:$false -ErrorAction Stop
                Install-Module -Name PSWindowsUpdate -Force -Confirm:$false -ErrorAction Stop
            }
            Import-Module PSWindowsUpdate
            $updates = Get-WindowsUpdate -AcceptAll -IgnoreReboot -ErrorAction SilentlyContinue
            
            if ($updates.Count -gt 0) {
                Log "🛠 ${env:COMPUTERNAME} has $($updates.Count) update(s) pending"
                foreach ($update in $updates) {
                    $kb = if ($update.KBArticleIDs) { $update.KBArticleIDs -join ", " } else { "No KB ID" }
                    Log "🔹 $($update.Title) [KB: $kb]"
                }
                $needsReboot = @($updates | Where-Object { $_.RebootRequired -eq $true })
                if ($needsReboot.Count -gt 0) {
                    Log "⚠️ Some updates require a reboot after installation."
                } else {
                    Log "ℹ️ No reboot is required for the pending updates."
                }
                $hasUpdates = $true
            } else {
                Log "✅ No updates found on ${env:COMPUTERNAME}"
            }

        } catch {
            Log "❌ Failed to check updates on ${env:COMPUTERNAME}: $($_.Exception.Message)"
            return
        }

        if (-not $hasUpdates) { return }

        # Validate all nodes are up
        $clusterNodes = Get-ClusterNode
        foreach ($node in $clusterNodes) {
            if ($node.State -ne "Up") {
                throw "❌ Node $($node.Name) is not Up. Current: $($node.State)"
            }
            Log "✅ Node $($node.Name) is Up."
        }

        # Validate Virtual Disks status
        $virtualDisks = Get-VirtualDisk
        foreach ($disk in $virtualDisks) {
            if ($disk.HealthStatus -ne "Healthy") {
                throw "❌ VirtualDisk $($disk.FriendlyName) is not Healthy. Current HealthStatus: $($disk.HealthStatus)"
            }
            if ($disk.OperationalStatus -ne "OK") {
                throw "❌ VirtualDisk $($disk.FriendlyName) is not OK. Current OperationalStatus: $($disk.OperationalStatus)"
            }
            Log "✅ VirtualDisk $($disk.FriendlyName) is Healthy and OperationalStatus is OK."
        }

        # Check Storage Subsystem health
        $s2d = Get-StorageSubSystem -Model "Clustered Windows Storage"
        if ($s2d.HealthStatus -eq "Unhealthy") {
            throw "❌ S2D Health is Unhealthy"
        }
        Log "✅ S2D Health is $($s2d.HealthStatus)."

        # Prepare for update (move cluster shared volumes)
        $partner = Get-ClusterNode | Where-Object { $_.Name -ne $env:COMPUTERNAME -and $_.State -eq "Up" }
        $partner = $partner | Select-Object -First 1
        if (-not $partner) { throw "❌ No partner nodes available" }

        # Move cluster shared volumes to partner node with error handling
        foreach ($csv in Get-ClusterSharedVolume | Where-Object { $_.OwnerNode -eq $env:COMPUTERNAME }) {
            try {
                Move-ClusterSharedVolume -Name $csv.Name -Node $partner.Name -Wait 300 -ErrorAction Stop
                Log "🔁 Moved $($csv.Name) → $($partner.Name)"
            } catch {
                Log "❌ Failed to move Cluster Shared Volume $($csv.Name) to $($partner.Name): $($_.Exception.Message)"
                return
            }
        }

        # Put node into maintenance mode
        try {
            Suspend-ClusterNode -Name $env:COMPUTERNAME -Drain -Wait -ErrorAction Stop
            Log "⏸ Node put in maintenance"
        } catch {
            Log "❌ Failed to put node in maintenance: $($_.Exception.Message)"
            try {
                Start-Sleep -Seconds 60
                Resume-ClusterNode -Name $env:COMPUTERNAME -ErrorAction Stop -Failback Immediate
                Log "✅ Node resumed from maintenance"
            } catch {
                Log "❌ Failed to resume node: $($_.Exception.Message)"
                return
            }
            return
        }

        # Schedule post-reboot task
        $ScriptFullPath = $MyInvocation.MyCommand.Definition
        $TaskAction = New-ScheduledTaskAction -Execute "PowerShell.exe" -Argument "-ExecutionPolicy Bypass -File `"$ScriptFullPath`" -Phase post-reboot"
        $TaskTrigger = New-ScheduledTaskTrigger -AtStartup
        $Principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType S4U -RunLevel Highest
        try {
            Register-ScheduledTask -TaskName $TaskName -Action $TaskAction -Trigger $TaskTrigger -Principal $Principal -Force
            Log "📅 Scheduled post-reboot task: $TaskName"
        } catch {
            Log "❌ Failed to schedule post-reboot task: $($_.Exception.Message)"
        }
        
        # Install updates
        Log "🛠 Installing $($updates.Count) update(s)..."
        try {
            $results = Install-WindowsUpdate -AcceptAll -AutoReboot -Confirm:$false -ErrorAction Stop
            if ($results) {
                foreach ($r in $results) {
                    Log "✅ Installed: $($r.Title)"
                }
            }
            Log "✅ Update installation completed. System may reboot automatically if required."
        } catch {
            Log "❌ Update installation failed: $($_.Exception.Message)"
            return
        }

        # Check if reboot still needed
        $needsReboot = Test-PendingReboot
        if ($needsReboot) {
            Log "⚠️ Reboot is required. Restarting system..."
            Start-Sleep -Seconds 5
            Restart-Computer
        } else {
            Log "ℹ️ No reboot required."
            Start-Sleep -Seconds 60
            $node = Get-ClusterNode -Name $env:COMPUTERNAME
            if ($node.State -eq "Paused") {
                Log "🔄 Attempting to resume cluster node: $env:COMPUTERNAME"
                Resume-ClusterNode -Name $env:COMPUTERNAME -Failback Immediate -ErrorAction Stop
                Log "✅ Node resumed from maintenance"
            } else {
                Log "ℹ️ Node already active, skipping resume"
            }

            try {
                Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop
                Log "🗑 Scheduled task '$TaskName' removed"
            } catch {
                Log "⚠️ Failed to remove scheduled task: $($_.Exception.Message)"
            }
        }
    } catch {
        Log "❌ Update process failed: $($_.Exception.Message)"
    }
}

elseif ($Phase -eq "post-reboot") {
    Log "🔁 Starting post-reboot phase"
    Start-Sleep -Seconds 60
    try {
        $node = Get-ClusterNode -Name $env:COMPUTERNAME
        if ($node.State -eq "Paused") {
            Log "🔄 Attempting to resume cluster node: $env:COMPUTERNAME"
            Resume-ClusterNode -Name $env:COMPUTERNAME -Failback Immediate -ErrorAction Stop
            Log "✅ Node resumed from maintenance"
        } else {
            Log "ℹ️ Node already active, skipping resume"
        }
    } catch {
        Log "❌ Failed to resume cluster node: $($_.Exception.Message)"
        return
    }

    try {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop
        Log "🗑 Scheduled task '$TaskName' removed"
    } catch {
        Log "⚠️ Failed to remove scheduled task: $($_.Exception.Message)"
    }
}
