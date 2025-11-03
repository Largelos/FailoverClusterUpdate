param (
    [string]$Phase = "pre-reboot"  # pre-reboot | post-reboot | schedule-only
)

# Version 20251103
# ===== SETTINGS =====
$LogPath = "C:\ClusterUpdateLogs"
$TaskName = "ResumeClusterNode"
$LogFile = Join-Path $LogPath "ClusterUpdate_$(Get-Date -Format yyyyMMdd).log"
$StateFile = Join-Path $LogPath "ClusterUpdate_State_$(Get-Date -Format yyyyMMdd).json"

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


function Register-PostRebootTask {
    Log "📝 Creating scheduled post-reboot task: $TaskName"

    # Use the script path determined in script scope ($ScriptFullPath)
    # Make sure the argument contains properly quoted path, and include -NoProfile for cleanliness
    $taskArgument = "-NoProfile -ExecutionPolicy Bypass -File `"$ScriptFullPath`" -Phase post-reboot"

    $TaskAction = New-ScheduledTaskAction -Execute "PowerShell.exe" -Argument $taskArgument
    $TaskTrigger = New-ScheduledTaskTrigger -AtStartup
    $TaskSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew
    $Principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType S4U -RunLevel Highest

    try {
        $existingTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        if ($existingTask) {
            Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop
            Log "🗑 Removed existing scheduled task: $TaskName"
        }
        Register-ScheduledTask -TaskName $TaskName -Action $TaskAction -Trigger $TaskTrigger -Settings $TaskSettings -Principal $Principal -Force
        Log "📅 Scheduled post-reboot task '$TaskName' successfully created"
        Log "   -> Task Argument: $taskArgument"
    } catch {
        Log "❌ Failed to schedule post-reboot task: $($_.Exception.Message)"
    }
}

function Log-CurrentState {
    param([string]$Context)
    
    Log "════════════════════════════════════════════════════════════"
    Log "📊 CURRENT STATE SNAPSHOT - $Context"
    Log "════════════════════════════════════════════════════════════"
    Log "🕐 Timestamp: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    Log "💻 Computer: $env:COMPUTERNAME"
    Log "🔧 Phase: $Phase"
    
    # Cluster Node State
    try {
        $localNode = Get-ClusterNode -Name $env:COMPUTERNAME -ErrorAction Stop
        Log "🖥️ Local Node State: $($localNode.State)"
        Log "   - DrainStatus: $($localNode.DrainStatus)"
        Log "   - DynamicWeight: $($localNode.DynamicWeight)"
        
        # All nodes state
        $allNodes = Get-ClusterNode
        Log "📋 All Cluster Nodes:"
        foreach ($node in $allNodes) {
            Log "   - $($node.Name): State=$($node.State), DrainStatus=$($node.DrainStatus)"
        }
    } catch {
        Log "⚠️ Failed to get cluster node state: $($_.Exception.Message)"
    }
    
    # Cluster Groups
    try {
        $groups = Get-ClusterGroup
        Log "🔷 Cluster Groups on this node:"
        $localGroups = $groups | Where-Object { $_.OwnerNode -eq $env:COMPUTERNAME }
        if ($localGroups.Count -gt 0) {
            foreach ($g in $localGroups) {
                Log "   - $($g.Name): State=$($g.State), OwnerNode=$($g.OwnerNode)"
            }
        } else {
            Log "   - No groups owned by this node"
        }
    } catch {
        Log "⚠️ Failed to get cluster groups: $($_.Exception.Message)"
    }
    
    # CSV State
    try {
        $csvs = Get-ClusterSharedVolume
        Log "💾 Cluster Shared Volumes:"
        $localCSVs = $csvs | Where-Object { $_.OwnerNode -eq $env:COMPUTERNAME }
        if ($localCSVs.Count -gt 0) {
            foreach ($csv in $localCSVs) {
                Log "   - $($csv.Name): OwnerNode=$($csv.OwnerNode), State=$($csv.State)"
            }
        } else {
            Log "   - No CSVs owned by this node"
        }
    } catch {
        Log "⚠️ Failed to get CSV state: $($_.Exception.Message)"
    }
    
    # Scheduled Task State
    try {
        $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        if ($task) {
            Log "📅 Scheduled Task '$TaskName': State=$($task.State), Enabled=$($task.Settings.Enabled)"
        } else {
            Log "📅 Scheduled Task '$TaskName': Not found"
        }
    } catch {
        Log "⚠️ Failed to check scheduled task: $($_.Exception.Message)"
    }
    
    # Pending Reboot State
    $pendingReboot = Test-PendingReboot
    Log "🔄 Pending Reboot: $pendingReboot"
       
    Log "════════════════════════════════════════════════════════════"
}

function Test-PendingReboot {
    $pending = $false

    # Component-Based Servicing
    if (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending") {
        $pending = $true
        Log "   - Component-Based Servicing reboot pending detected"
    }

    # Windows Update
    if (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired") {
        $pending = $true
        Log "   - Windows Update reboot pending detected"
    }

    # Pending Computer Rename
    if ((Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName").ComputerName -ne `
        (Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName").ComputerName) {
        $pending = $true
        Log "   - Computer rename pending detected"
    }

    # Pending file rename operations
    $pendingRenames = Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager" -Name "PendingFileRenameOperations" -ErrorAction SilentlyContinue
    if ($pendingRenames -ne $null) {
        $pending = $true
        Log "   - Pending file rename operations detected"
    }

    return $pending
}

# ===== Determine script full path reliably =====
try {
    if ($PSCommandPath) {
        # Preferred when script is run from file (PowerShell 3+)
        $ScriptFullPath = $PSCommandPath
    } elseif ($MyInvocation.MyCommand.Path -and (Test-Path $MyInvocation.MyCommand.Path)) {
        $ScriptFullPath = $MyInvocation.MyCommand.Path
    } elseif ($MyInvocation.MyCommand.Definition -and (Test-Path $MyInvocation.MyCommand.Definition)) {
        $ScriptFullPath = $MyInvocation.MyCommand.Definition
    } else {
        throw "Unable to determine script file path. Please run the script from a .ps1 file."
    }
} catch {
    Write-Error "❌ Cannot determine script path: $($_.Exception.Message)"
    exit 1
}

if ($Phase -eq "pre-reboot") {
    try {
        Log "===== Starting update on $env:COMPUTERNAME ====="
        
        # Log initial state
        Log-CurrentState "Pre-Update Initial State"
        
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

        Log-CurrentState "Before Moving CSVs"

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

        Log-CurrentState "After Moving CSVs"

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

        Log-CurrentState "After Suspending Node"

        # Schedule post-reboot task
        Register-PostRebootTask
        
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
        Log "🔍 Checking if reboot is required..."
        $needsReboot = Test-PendingReboot
        if ($needsReboot) {
            Log "⚠️ Reboot is required. Restarting system..."
            Log-CurrentState "Before Reboot"
			# Run quser and capture output
			$quserOutput = quser 2>&1
			# Skip header line
			$lines = $quserOutput | Select-Object -Skip 1

			foreach ($line in $lines) {
				# Remove leading/trailing spaces
				$line = $line.Trim()
				if ($line -eq '') { continue }

				# Split by spaces (multiple spaces)
				$parts = $line -split '\s+'
				
				# Format: USERNAME SESSIONNAME ID STATE ... (quser output)
				$username = $parts[0]
				$sessionId = $parts[2]

				# Skip current user and SYSTEM
				if ($username -eq "SYSTEM") {
					log "Skipping session for $username"
					continue
				}

				# Log the action
				log "Logging off user $username (Session ID: $sessionId)..."

				# Execute logoff
				try {
					logoff $sessionId /V
				} catch {
					log "WARNING: Could not log off $username (Session ID: $sessionId). $_"
				}
			}

			# Pause briefly to ensure sessions terminate
			Start-Sleep -Seconds 60

			# Restart the computer
			Restart-Computer -ErrorAction Stop -verbose
        } else {
            Log "ℹ️ No reboot required. Resuming node immediately..."
            Start-Sleep -Seconds 60
            Log-CurrentState "Before resume node"
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
            
            Log-CurrentState "Final State (No Reboot)"
        }
    } catch {
        Log "❌ Update process failed: $($_.Exception.Message)"
        Log-CurrentState "Error State"
    }
}

elseif ($Phase -eq "post-reboot") {
    Log "🔁 Starting post-reboot phase"
    
    Log-CurrentState "Post-Reboot Initial State"
    
    # Wait for cluster service to be fully ready
    Log "⏳ Waiting 60 seconds for cluster service to stabilize..."
    Start-Sleep -Seconds 60
    
    Log-CurrentState "After 60 Second Wait"
    
    try {
        $node = Get-ClusterNode -Name $env:COMPUTERNAME
        Log "📊 Current node state: $($node.State), DrainStatus: $($node.DrainStatus)"
        
        if ($node.State -eq "Paused") {
            Log "🔄 Attempting to resume cluster node: $env:COMPUTERNAME"
            Resume-ClusterNode -Name $env:COMPUTERNAME -Failback Immediate -ErrorAction Stop
            Log "✅ Node resumed from maintenance"
            
            # Verify resume was successful
            Start-Sleep -Seconds 10
            $node = Get-ClusterNode -Name $env:COMPUTERNAME
            Log "📊 Node state after resume: $($node.State), DrainStatus: $($node.DrainStatus)"
        } else {
            Log "ℹ️ Node state is $($node.State), skipping resume"
        }
    } catch {
        Log "❌ Failed to resume cluster node: $($_.Exception.Message)"
    }

    Log-CurrentState "After Resume Attempt"

    try {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop
        Log "🗑 Scheduled task '$TaskName' removed"
    } catch {
        Log "⚠️ Failed to remove scheduled task: $($_.Exception.Message)"
    }
    
    Log-CurrentState "Post-Reboot Final State"
}
elseif ($Phase -eq "schedule-only") {
    Log "===== Schedule-only mode: only creating post-reboot task ====="
    Register-PostRebootTask
    Log-CurrentState "After schedule-only task creation"
}
