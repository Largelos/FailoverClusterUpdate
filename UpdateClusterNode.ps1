param (
    [string]$Phase = "pre-reboot"
)


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

if ($Phase -eq "pre-reboot") {
    try {
        Log "===== Starting update on $env:COMPUTERNAME ====="
        Log "➡️ Checking for new updates"

        $hasUpdates = $false
        $needsReboot = $false
        try {
            if (-not (Get-Command Get-WindowsUpdate -ErrorAction SilentlyContinue)) {
                Install-PackageProvider -Name NuGet -Force -Confirm:$false
                Install-Module -Name PSWindowsUpdate -Force -Confirm:$false
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
            return
        }

        # Schedule resume on reboot with self-cleanup
        if ($needsReboot.Count -gt 0) {
            $ScriptFullPath = $MyInvocation.MyCommand.Definition
            $TaskAction = New-ScheduledTaskAction -Execute "PowerShell.exe" -Argument "-ExecutionPolicy Bypass -File `"$ScriptFullPath`" -Phase post-reboot"
            $TaskTrigger = New-ScheduledTaskTrigger -AtStartup
            $Principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType S4U -RunLevel Highest

            Register-ScheduledTask -TaskName $TaskName -Action $TaskAction -Trigger $TaskTrigger -Principal $Principal -Force

            Log "📅 Scheduled post-reboot task: $TaskName"
        }

        Log "🛠 Installing $($updates.Count) update(s)..."
        Install-WindowsUpdate -AcceptAll -AutoReboot -Confirm:$false
        if ($needsReboot.Count -eq 0) {
            try {
                Start-Sleep -Seconds 60
                Resume-ClusterNode -Name $env:COMPUTERNAME -ErrorAction Stop -Failback Immediate
                Log "✅ Node resumed from maintenance"
            } catch {
                Log "❌ Failed to resume node: $($_.Exception.Message)"
                return
            }
        }
    } catch {
        Log "❌ Update failed: $($_.Exception.Message)"
    }
} elseif ($Phase -eq "post-reboot") {
    Log "🔁 Starting post-reboot phase"

    try {
        Start-Sleep -Seconds 60
        Resume-ClusterNode -Name $env:COMPUTERNAME -ErrorAction Stop -Failback Immediate
        Log "✅ Node resumed from maintenance"
    } catch {
        Log "❌ Failed to resume node: $($_.Exception.Message)"
        return
    }

    try {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop
        Log "🗑 Scheduled task '$TaskName' removed"
    } catch {
        Log "⚠️ Failed to remove scheduled task '$TaskName': $($_.Exception.Message)"
    }
}
