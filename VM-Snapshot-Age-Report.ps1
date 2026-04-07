<#
.SYNOPSIS
    VMware VM Snapshot Age Report

.DESCRIPTION
    Connects to a VMware vCenter/ESXi host and identifies all VMs with snapshots
    older than a defined threshold. Exports a report to CSV and sends an email
    alert for review and cleanup action.

.AUTHOR
    Dayana Ann V M

.VERSION
    1.0

.NOTES
    Requirements:
    - VMware PowerCLI (Install-Module VMware.PowerCLI)
    - vCenter or ESXi host access
    - SMTP access for alerts
#>

# -----------------------------------------------
# CONFIGURATION
# -----------------------------------------------
$vCenterServer      = "vcenter.yourdomain.com"
$vCenterUser        = "administrator@vsphere.local"
$vCenterPassword    = "yourpassword"   # Use credential store in production
$SnapshotAgeDays    = 7                # Flag snapshots older than this
$LogDirectory       = "C:\Logs\SnapshotReport"
$SMTPServer         = "smtp.yourdomain.com"
$SMTPPort           = 25
$AlertFrom          = "vmware-monitor@yourdomain.com"
$AlertTo            = "infra-team@yourdomain.com"
$AlertSubject       = "VMware Snapshot Age Report - $(Get-Date -Format 'yyyy-MM-dd')"

# -----------------------------------------------
# INITIALISE
# -----------------------------------------------
$Timestamp  = Get-Date -Format "yyyyMMdd_HHmm"
$LogFile    = "$LogDirectory\SnapshotReport_$Timestamp.csv"
$Results    = @()
$SendAlert  = $false

if (-not (Test-Path $LogDirectory)) {
    New-Item -ItemType Directory -Path $LogDirectory | Out-Null
}

# -----------------------------------------------
# CONNECT TO VCENTER
# -----------------------------------------------
try {
    Import-Module VMware.PowerCLI -ErrorAction Stop
    Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false | Out-Null
    Connect-VIServer -Server $vCenterServer -User $vCenterUser -Password $vCenterPassword -ErrorAction Stop
    Write-Host "[INFO] Connected to vCenter: $vCenterServer" -ForegroundColor Green
} catch {
    Write-Error "[ERROR] Failed to connect to vCenter: $_"
    exit 1
}

# -----------------------------------------------
# RETRIEVE SNAPSHOTS
# -----------------------------------------------
Write-Host "[INFO] Retrieving all VM snapshots..." -ForegroundColor Cyan

$AllVMs = Get-VM
$Cutoff = (Get-Date).AddDays(-$SnapshotAgeDays)

foreach ($VM in $AllVMs) {
    $Snapshots = Get-Snapshot -VM $VM -ErrorAction SilentlyContinue

    foreach ($Snap in $Snapshots) {
        $AgeDays = ((Get-Date) - $Snap.Created).Days
        $Status  = if ($Snap.Created -lt $Cutoff) { "REVIEW REQUIRED" } else { "OK" }

        if ($Status -eq "REVIEW REQUIRED") {
            $SendAlert = $true
            Write-Host "[REVIEW] $($VM.Name) | Snapshot: $($Snap.Name) | Age: $AgeDays days | Size: $([math]::Round($Snap.SizeGB,2)) GB" -ForegroundColor Red
        } else {
            Write-Host "[OK] $($VM.Name) | Snapshot: $($Snap.Name) | Age: $AgeDays days" -ForegroundColor Green
        }

        $Results += [PSCustomObject]@{
            VMName        = $VM.Name
            SnapshotName  = $Snap.Name
            Description   = $Snap.Description
            Created       = $Snap.Created
            AgeDays       = $AgeDays
            SizeGB        = [math]::Round($Snap.SizeGB, 2)
            PowerState    = $VM.PowerState
            Status        = $Status
            ReportedAt    = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        }
    }
}

# -----------------------------------------------
# EXPORT CSV
# -----------------------------------------------
if ($Results.Count -gt 0) {
    $Results | Export-Csv -Path $LogFile -NoTypeInformation -Encoding UTF8
    Write-Host "[INFO] Report exported: $LogFile"
} else {
    Write-Host "[INFO] No snapshots found in the environment." -ForegroundColor Green
}

# -----------------------------------------------
# SUMMARY
# -----------------------------------------------
$ReviewCount = ($Results | Where-Object { $_.Status -eq "REVIEW REQUIRED" }).Count
$TotalSnaps  = $Results.Count

Write-Host ""
Write-Host "===== SNAPSHOT SUMMARY =====" -ForegroundColor Cyan
Write-Host "Total Snapshots  : $TotalSnaps"
Write-Host "Review Required  : $ReviewCount" -ForegroundColor $(if ($ReviewCount -gt 0) { "Red" } else { "Green" })
Write-Host "============================" -ForegroundColor Cyan

# -----------------------------------------------
# EMAIL ALERT
# -----------------------------------------------
if ($SendAlert) {
    $Body = @"
VMware Snapshot Age Report
===========================
Date/Time        : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
Total Snapshots  : $TotalSnaps
Review Required  : $ReviewCount (older than $SnapshotAgeDays days)

Please review and clean up old snapshots to avoid storage impact.
Full report attached.
"@

    try {
        Send-MailMessage `
            -From $AlertFrom `
            -To $AlertTo `
            -Subject $AlertSubject `
            -Body $Body `
            -SmtpServer $SMTPServer `
            -Port $SMTPPort `
            -Attachments $LogFile

        Write-Host "[INFO] Alert sent to $AlertTo" -ForegroundColor Yellow
    } catch {
        Write-Error "[ERROR] Failed to send email: $_"
    }
}

# -----------------------------------------------
# DISCONNECT
# -----------------------------------------------
Disconnect-VIServer -Server $vCenterServer -Confirm:$false
Write-Host "[INFO] Disconnected from vCenter."
