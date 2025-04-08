# FailoverClusterUpdate

This PowerShell script automates Windows Update installation for a Failover Cluster node setup 
in a workgroup without active directory and Cluster-Aware update. It includes full health checks,
draining maintenance mode, automatic reboot and resumption with roles failback.

Features
--------

- Validates cluster node and S2D subsystem health.
- Ensures all Virtual Disks are healthy and operational.
- Moves Cluster Shared Volumes (CSVs) away from the node.
- Puts the node into maintenance mode (draining).
- Installs all available Windows Updates (via PSWindowsUpdate).
- Automatically reboots if required.
- Uses Task Scheduler to resume the cluster node after reboot.
- Automatically deletes the scheduled task after completion.
- Logs every action and error to a dedicated log file.

Usage
-----

Run the script **locally** on each cluster node via Task Scheduler:
 
1. Copy the script to each cluster node.
2. Create a Task Scheduler task with the following properties:
   - **Trigger**: As required (e.g., one-time or recurring)
   - **Action**: `powershell.exe -ExecutionPolicy Bypass -File "C:\Path\To\UpdateClusterNode.ps1"`
   - **Run with highest privileges**
   - **Run whether user is logged on or not**
