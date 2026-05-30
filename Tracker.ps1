#Requires -Version 5.1
# ==========================================================
#   DualShock Battery Tracker (Made for modded DS4 Battery)
#   Version: v0.28
#   Authors: cyanojar
# ==========================================================

try {
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue

    # ==========================================================
    # PART 1: THE BRAIN (State & Initialization)
    # ==========================================================
    $script:CurrentVersion = 0.28
    $script:TrackerFolder  = $PSScriptRoot
    $script:DataFile       = "$script:TrackerFolder\Tracker_Data.json"
    $script:SettingsFile   = "$script:TrackerFolder\config.json"
    $script:BtBlacklist    = "(?i)Enumerator|Adapter|AVRCP|Protocol|GATT|LE Generic|Hands-Free|Intel.*Bluetooth|Realtek.*Bluetooth|Qualcomm.*Bluetooth|MediaTek.*Bluetooth|Microsoft.*Bluetooth"
    $script:DS4Process     = $null

    # UI State Memory (Persists between menu loads)
    $script:lastConnectedStatus  = $null
    $script:lastFiredToastCtrlID = ""

    if (-not (Test-Path $script:TrackerFolder)) {
        New-Item -ItemType Directory -Path $script:TrackerFolder -Force | Out-Null
    }

    # ==========================================================
    # PART 2: THE TOOLBELT (Helper Functions)
    # ==========================================================
    
    function Check-OTAUpdate {
        $VersionUrl = "https://raw.githubusercontent.com/cyanojar/DualShock-Battery-Tracker/main/version.txt"
        $ScriptUrl = "https://raw.githubusercontent.com/cyanojar/DualShock-Battery-Tracker/main/Tracker.ps1"
        try {
            $OnlineVersionStr = (Invoke-RestMethod -Uri $VersionUrl -UseBasicParsing -TimeoutSec 3).Trim()
            $OnlineVersion = [double]$OnlineVersionStr

            if ($OnlineVersion -gt $script:CurrentVersion) {
                Clear-Host
                Write-Host "=========================================" -ForegroundColor Cyan
                Write-Host " UPDATE AVAILABLE!" -ForegroundColor Green
                Write-Host " You are running v$script:CurrentVersion, but v$OnlineVersion is out." -ForegroundColor White
                Write-Host "=========================================" -ForegroundColor Cyan
                Write-Host ""
                $ans = Read-Host "Would you like to auto-update right now? (Y/N) -> "
                
                if ($ans.Trim().ToUpper() -eq 'Y') {
                    Write-Host "Downloading the new version..." -ForegroundColor Yellow
                    $NewScriptPath = "$PSScriptRoot\Tracker_New.ps1"
                    Invoke-WebRequest -Uri $ScriptUrl -OutFile $NewScriptPath -UseBasicParsing
                    
                    if (Test-Path $NewScriptPath) {
                        Write-Host "Installing and restarting..." -ForegroundColor Green
                        $UpdateCmd = "Start-Sleep -Seconds 2; Remove-Item `"$PSCommandPath`" -Force; Rename-Item `"$NewScriptPath`" -NewName `"$($MyInvocation.MyCommand.Name)`"; powershell.exe -ExecutionPolicy Bypass -File `"$PSCommandPath`""
                        Start-Process powershell.exe -ArgumentList "-WindowStyle Hidden -Command & {$UpdateCmd}"
                        exit
                    }
                }
            }
        } catch { } # Silently bypass if no internet
    }

    function Get-ShortHWID ($fullID) {
        if ($null -eq $fullID -or $fullID -eq "") { return "UNKNOWN" }
        if ($fullID -match 'DEV_([A-Z0-9]+)') {
            return "DEV_" + $matches[1]
        } else {
            return ($fullID -replace '[^a-zA-Z0-9]','').Substring(0, [math]::Min(($fullID -replace '[^a-zA-Z0-9]','').Length, 15))
        }
    }

    function Save-AtomicJson ($path, $dataObj) {
        $tempPath = "$path.tmp"
        $dataObj | ConvertTo-Json -Depth 5 | Set-Content $tempPath -Force
        if (Test-Path $tempPath) { Move-Item $tempPath $path -Force }
    }

    function Show-Toast ($title, $msg) {
        try {
            $notify = New-Object System.Windows.Forms.NotifyIcon
            $notify.Icon = [System.Drawing.SystemIcons]::Information
            $notify.Visible = $true
            $notify.ShowBalloonTip(5000, $title, $msg, [System.Windows.Forms.ToolTipIcon]::Info)
            Start-Sleep -Seconds 1
            $notify.Dispose()
        } catch {}
    }

    function Exit-App {
        Write-Host ""
        Write-Host "Logs and settings automatically saved." -ForegroundColor Green
        
        if (Test-Path $script:SettingsFile) {
            $ExitSettings = Get-Content $script:SettingsFile -Raw | ConvertFrom-Json
            if ($ExitSettings.AutoCloseDS4 -eq $true -and $null -ne $script:DS4Process) {
                Write-Host "Closing DS4Windows..." -ForegroundColor Yellow
                $script:DS4Process | Stop-Process -Force -ErrorAction SilentlyContinue
            }
        }
        Start-Sleep -Seconds 2
        exit
    }

    function Draw-SetupHeader ($Step) {
        Clear-Host
        Write-Host "=========================================" -ForegroundColor Cyan
        Write-Host "       DUALSHOCK BATTERY TRACKER" -ForegroundColor Green
        Write-Host "=========================================" -ForegroundColor Cyan
        Write-Host ""
        $c1 = if ($Step -eq 1) { "Green" } else { "DarkGray" }
        $c2 = if ($Step -eq 2) { "Green" } else { "DarkGray" }
        $c3 = if ($Step -eq 3) { "Green" } else { "DarkGray" }
        Write-Host "[Step 1: Controller]  " -ForegroundColor $c1 -NoNewline
        Write-Host "[Step 2: DS4Windows]  " -ForegroundColor $c2 -NoNewline
        Write-Host "[Step 3: Shortcut]" -ForegroundColor $c3
        Write-Host "`n-----------------------------------------`n" -ForegroundColor DarkGray
    }

    # ==========================================================
    # PART 3: THE UI FOLDERS (Frontend)
    # ==========================================================

    function Invoke-SetupWizard {
        Clear-Host
        Write-Host "=========================================" -ForegroundColor Cyan
        Write-Host "       DUALSHOCK BATTERY TRACKER" -ForegroundColor Green
        Write-Host "=========================================" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "IMPORTANT:" -ForegroundColor Red
        Write-Host "Make sure you fully charge your modded DS4 battery to full" -ForegroundColor White
        Write-Host "before you begin tracking!" -ForegroundColor White
        Write-Host ""
        Write-Host "ABOUT THIS TOOL:" -ForegroundColor Magenta
        Write-Host "This is a persistent background tracker designed to measure" -ForegroundColor White
        Write-Host "the exact hours and minutes it takes to completely drain" -ForegroundColor White
        Write-Host "a modded controller battery from 100% down to 0%." -ForegroundColor White
        Write-Host ""
        Write-Host "NOTE:" -ForegroundColor Yellow
        Write-Host "The final grand total from this log will be used to calibrate" -ForegroundColor Yellow
        Write-Host "the upcoming Phase 2 'Fuel Gauge' script for estimating" -ForegroundColor Yellow
        Write-Host "the exact battery level of your controller." -ForegroundColor Yellow
        Write-Host ""
        Write-Host "-----------------------------------------" -ForegroundColor DarkGray
        Write-Host "Let's get you set up." -ForegroundColor Cyan
        Write-Host "(You can always change these settings later from the Main Menu," -ForegroundColor DarkGray
        Write-Host "or manually by editing the config.json file)." -ForegroundColor DarkGray
        Write-Host ""
        $null = Read-Host "Press Enter to begin setup..."

        # Step 1: Controller Setup
        Draw-SetupHeader 1
        Write-Host "Make sure your controller is currently CONNECTED via Bluetooth." -ForegroundColor Yellow
        Write-Host "Scanning your PC for ACTIVELY CONNECTED Bluetooth devices..." -ForegroundColor DarkGray
        Write-Host ""
        
        $targetID = ""
        $targetName = ""

        while ($true) {
            $btDevices = @()
            try {
                $rawDevices = Get-PnpDevice -Class Bluetooth -ErrorAction Stop | Where-Object { $_.FriendlyName -ne $null -and $_.FriendlyName -notmatch $script:BtBlacklist }
                foreach ($d in $rawDevices) {
                    $connProp = Get-PnpDeviceProperty -InstanceId $d.InstanceId -KeyName '{83DA6326-97A6-4088-9453-A1923F573B29} 15' -ErrorAction SilentlyContinue
                    if ($null -ne $connProp -and $connProp.Data -eq $true) { $btDevices += $d }
                }
            } catch {
                Write-Host "   [!] Note: Windows WMI scan had a minor hiccup, but we can still proceed manually." -ForegroundColor DarkGray
            }

            if ($btDevices.Count -eq 0) {
                Write-Host "No ACTIVE Bluetooth devices found! Turn your controller on and rescan." -ForegroundColor Red
            } else {
                for ($i = 0; $i -lt $btDevices.Count; $i++) {
                    $d = $btDevices[$i]
                    $sHWID = Get-ShortHWID $d.InstanceId
                    Write-Host "   [ $($i + 1) ] $($d.FriendlyName) ($sHWID) " -NoNewline -ForegroundColor White
                    Write-Host "[CONNECTED]" -ForegroundColor Green
                }
            }

            Write-Host ""
            Write-Host "   [ R ] Rescan for devices" -ForegroundColor Cyan
            Write-Host "   [ M ] Enter Hardware ID manually" -ForegroundColor Yellow
            Write-Host "   [ S ] Skip adding a controller for now" -ForegroundColor DarkGray
            Write-Host "   [ T ] Open Windows Device Manager" -ForegroundColor DarkGray
            Write-Host ""
            Write-Host "Type the number of your controller (or a letter option) and press Enter:" -ForegroundColor White
            
            $btIn = Read-Host "-> "
            
            if ($btIn.Trim().ToUpper() -eq 'R') {
                Draw-SetupHeader 1; Write-Host "Rescanning..." -ForegroundColor Yellow; Start-Sleep -Seconds 1; continue
            } elseif ($btIn.Trim().ToUpper() -eq 'T') {
                Start-Process devmgmt.msc; Draw-SetupHeader 1; continue
            } elseif ($btIn.Trim().ToUpper() -eq 'S') {
                $targetID = ""; $targetName = ""; Write-Host "`nSkipped! (You can add one later in Tracker Settings)" -ForegroundColor Yellow; break
            } elseif ($btIn.Trim().ToUpper() -eq 'M') {
                Write-Host "`nPaste your exact InstanceId / Hardware ID below:" -ForegroundColor Cyan
                $manualID = Read-Host "-> "
                if ($manualID.Trim() -ne "") {
                    $targetID = $manualID.Trim(); $targetName = "Custom Controller"
                    Write-Host "Saved ID: $targetID" -ForegroundColor Green; break
                }
            } else {
                if ($btIn -match '^\d+$') {
                    $idx = [int]$btIn - 1
                    if ($idx -ge 0 -and $idx -lt $btDevices.Count) {
                        $targetID = $btDevices[$idx].InstanceId; $targetName = $btDevices[$idx].FriendlyName
                        Write-Host "`nSelected: $targetName!" -ForegroundColor Green; break
                    } else { Write-Host "Invalid number! Try again." -ForegroundColor Red }
                }
            }
        }
        Start-Sleep -Seconds 1

        # Step 2: DS4Windows Auto-Launch
        Draw-SetupHeader 2
        Write-Host "Do you want this script to automatically open DS4Windows?" -ForegroundColor DarkGray
        Write-Host "Paste the folder directory OR the full path to DS4Windows.exe below." -ForegroundColor DarkGray
        Write-Host "Example: C:\DS4Windows  OR  C:\DS4Windows\DS4Windows.exe" -ForegroundColor Cyan
        Write-Host "Or just press Enter to skip." -ForegroundColor DarkGray
        Write-Host ""
        
        $DS4Path = ""
        while ($true) {
            $ds4Input = Read-Host "-> "
            if ($ds4Input.Trim() -eq "") { Write-Host "No path entered. Skipping auto-launch." -ForegroundColor Yellow; break }

            $ds4Input = $ds4Input.Trim().Trim('"').Trim("'")
            if ($ds4Input -match '(?i)\.exe$') {
                if ($ds4Input -notmatch '(?i)DS4Windows\.exe$') { Write-Host "Error: Only DS4Windows.exe is allowed! Try again." -ForegroundColor Red; continue } 
                else { $DS4Path = $ds4Input }
            } else { $DS4Path = Join-Path -Path $ds4Input -ChildPath "DS4Windows.exe" }

            if (-not (Test-Path $DS4Path)) { Write-Host "Error: DS4Windows.exe was not found in that folder! Try again." -ForegroundColor Red; continue }

            Write-Host "Saved Path: $DS4Path" -ForegroundColor Green
            break
        }
        Start-Sleep -Seconds 1

        # Step 3: Desktop Shortcut
        Draw-SetupHeader 3
        Write-Host "Do you want to create a desktop shortcut?" -ForegroundColor DarkGray
        Write-Host "(It will automatically use the official Windows Gamepad icon)" -ForegroundColor DarkGray
        Write-Host ""
        $scChoice = Read-Host "Press 'Y' for Yes, or 'N' for No (->)"

        if ($scChoice.Trim().ToUpper() -eq 'Y') {
            $DesktopPath = [Environment]::GetFolderPath("Desktop")
            $ShortcutPath = "$DesktopPath\DualShock Battery Tracker.lnk"
            if (-not (Test-Path $ShortcutPath)) {
                try {
                    $WshShell = New-Object -ComObject WScript.Shell
                    $Shortcut = $WshShell.CreateShortcut($ShortcutPath)
                    $Shortcut.TargetPath = "powershell.exe"
                    $Shortcut.Arguments = "-ExecutionPolicy Bypass -File `"$PSCommandPath`""
                    $Shortcut.WorkingDirectory = $PSScriptRoot
                    $Shortcut.IconLocation = "joy.cpl,0"
                    $Shortcut.Save()
                    Write-Host "Desktop shortcut created!" -ForegroundColor Green
                } catch { Write-Host "Failed to create shortcut." -ForegroundColor Red }
            } else { Write-Host "Shortcut already exists!" -ForegroundColor Yellow }
        }

        # Save Configuration
        $ctrlList = New-Object System.Collections.ArrayList
        if ($targetID -ne "") { $ctrlList.Add([PSCustomObject]@{ ID = $targetID; Name = $targetName }) | Out-Null }
        
        $SettingsObj = [PSCustomObject]@{
            Controllers = $ctrlList
            DS4WindowsPath = $DS4Path
            DS4Enabled = ($DS4Path -ne "")
            ShowDS4Menu = $false
            AutoCloseDS4 = $false
            AutoStartTracking = $false
        }
        Save-AtomicJson $script:SettingsFile $SettingsObj

        Clear-Host
        Write-Host "Setup Complete! You are ready to track." -ForegroundColor Green
        Start-Sleep -Seconds 2
    }

    function Show-MainMenu {
        $menuDrawn = $false
        $menuChoice = ""

        while ($true) {
            $anyConnected = $false
            $connectedCtrl = $null

            if ($null -ne $script:Settings.Controllers -and $script:Settings.Controllers.Count -gt 0) {
                foreach ($c in $script:Settings.Controllers) {
                    try {
                        $connProp = Get-PnpDeviceProperty -InstanceId $c.ID -KeyName '{83DA6326-97A6-4088-9453-A1923F573B29} 15' -ErrorAction SilentlyContinue
                        if ($null -ne $connProp -and $connProp.Data -eq $true) { 
                            $anyConnected = $true
                            $connectedCtrl = $c
                            break 
                        }
                    } catch {}
                }
            }

            if ($anyConnected -and $script:lastConnectedStatus -eq $false -and $script:lastFiredToastCtrlID -ne $connectedCtrl.ID) {
                $sID = Get-ShortHWID $connectedCtrl.ID
                Show-Toast "Tracker Connected" "Controller $sID connected."
                $script:lastFiredToastCtrlID = $connectedCtrl.ID
                
                # Auto-Start Intervention Timer
                if ($script:Settings.AutoStartTracking) {
                    $abortAutoStart = $false
                    for ($counter = 5; $counter -gt 0; $counter--) {
                        Clear-Host
                        Write-Host "=========================================" -ForegroundColor Cyan
                        Write-Host "       DUALSHOCK BATTERY TRACKER" -ForegroundColor Green
                        Write-Host "=========================================" -ForegroundColor Cyan
                        Write-Host " Controller: $sID [CONNECTED]" -ForegroundColor Green
                        Write-Host " Status    : [AUTO-START IN $counter SECONDS]" -ForegroundColor Yellow
                        Write-Host "-----------------------------------------" -ForegroundColor DarkGray
                        Write-Host ""
                        Write-Host " Press ANY KEY to cancel auto-start." -ForegroundColor White
                        
                        if ([console]::KeyAvailable) {
                            $null = [console]::ReadKey($true)
                            $abortAutoStart = $true
                            break
                        }
                        Start-Sleep -Seconds 1
                    }
                    if (-not $abortAutoStart) { return "TRACK" }
                }
            }
            if ($null -eq $anyConnected -or $anyConnected -eq $false) { $script:lastFiredToastCtrlID = "" }

            if (-not $menuDrawn -or $anyConnected -ne $script:lastConnectedStatus) {
                Clear-Host
                Write-Host "=========================================" -ForegroundColor Cyan
                Write-Host "       DUALSHOCK BATTERY TRACKER" -ForegroundColor Green
                Write-Host "=========================================" -ForegroundColor Cyan
                
                if ($anyConnected -and $null -ne $connectedCtrl) {
                    $sID = Get-ShortHWID $connectedCtrl.ID
                    Write-Host " Controller: " -NoNewline; Write-Host "$sID [CONNECTED]" -ForegroundColor Green
                } else {
                    Write-Host " Controller: " -NoNewline; Write-Host "(None) [DISCONNECTED]" -ForegroundColor DarkGray
                }
                Write-Host " Status    : " -NoNewline; Write-Host "[IDLE] (Tracking Stopped)" -ForegroundColor DarkGray
                Write-Host "-----------------------------------------" -ForegroundColor DarkGray
                
                Write-Host "   [ 1 ] START TRACKING" -ForegroundColor White
                $menuMap = @{}
                $menuIndex = 2
                
                if ($script:Settings.DS4Enabled -and $script:Settings.DS4WindowsPath -ne "" -and $script:Settings.ShowDS4Menu) {
                    Write-Host "   [ $menuIndex ] Start DS4Windows" -ForegroundColor Cyan
                    $menuMap[$menuIndex.ToString()] = "DS4"
                    $menuIndex++
                }
                
                Write-Host "   [ $menuIndex ] Tracker Settings" -ForegroundColor DarkGray
                $menuMap[$menuIndex.ToString()] = "SETTINGS"
                $menuIndex++
                
                Write-Host "   [ $menuIndex ] Exit" -ForegroundColor Red
                $menuMap[$menuIndex.ToString()] = "EXIT"
                
                Write-Host ""
                Write-Host "=========================================" -ForegroundColor Cyan
                Write-Host "Press a key to select an option..." -ForegroundColor DarkGray

                $menuDrawn = $true
                $script:lastConnectedStatus = $anyConnected
            }

            $inputFound = $false
            $timeoutSw = [System.Diagnostics.Stopwatch]::StartNew()
            while ($timeoutSw.ElapsedMilliseconds -lt 1000) {
                if ([console]::KeyAvailable) {
                    $menuChoice = [console]::ReadKey($true).KeyChar.ToString().ToUpper()
                    $inputFound = $true
                    break
                }
                Start-Sleep -Milliseconds 50
            }
            
            if ($inputFound) {
                if ($menuChoice -eq '1') { return "TRACK" } 
                elseif ($menuMap.ContainsKey($menuChoice)) { return $menuMap[$menuChoice] }
            }
        }
    }

    function Show-TrackerSettings {
        while ($true) {
            Clear-Host
            Write-Host "--- 3. TRACKER SETTINGS ---" -ForegroundColor Cyan
            Write-Host ""
            Write-Host "   [ 1 ] Manage Saved Controllers" -ForegroundColor White
            Write-Host "   [ 2 ] DS4Windows Settings" -ForegroundColor White
            Write-Host "   [ 3 ] View Tracking Logs" -ForegroundColor White
            Write-Host "   [ 4 ] Delete Logs (Start over a new tracking session)" -ForegroundColor Yellow
            Write-Host "   [ 5 ] Factory Reset (Wipe Everything)" -ForegroundColor Red
            Write-Host "   [ B ] Back to Main Menu" -ForegroundColor DarkGray
            Write-Host ""
            Write-Host "Press a key to select an option..." -ForegroundColor DarkGray
            
            $sIn = [console]::ReadKey($true).KeyChar.ToString().ToUpper()
            
            if ($sIn -eq '1') {
                # --- MANAGE CONTROLLERS ---
                while ($true) {
                    Clear-Host
                    Write-Host "--- 3.1 MANAGE SAVED CONTROLLERS ---" -ForegroundColor Cyan
                    Write-Host ""
                    if ($script:Settings.Controllers.Count -eq 0) {
                        Write-Host "   (No controllers saved)" -ForegroundColor DarkGray
                    } else {
                        for($i=0; $i -lt $script:Settings.Controllers.Count; $i++) {
                            $c = $script:Settings.Controllers[$i]
                            $sHWID = Get-ShortHWID $c.ID
                            Write-Host "   [$($i+1)] $($c.Name) ($sHWID)" -ForegroundColor White
                        }
                    }
                    Write-Host ""
                    Write-Host "   [ A ] Add New Controller" -ForegroundColor Green
                    Write-Host "   [ C ] Clear / Remove a Controller" -ForegroundColor Yellow
                    Write-Host "   [ B ] Back" -ForegroundColor DarkGray
                    Write-Host ""
                    
                    $cIn = [console]::ReadKey($true).KeyChar.ToString().ToUpper()
                    if ($cIn -eq 'A') {
                        Write-Host "`nScanning for actively connected devices..." -ForegroundColor DarkGray
                        $btDevices = @()
                        try {
                            $rawDevices = Get-PnpDevice -Class Bluetooth -ErrorAction Stop | Where-Object { $_.FriendlyName -ne $null -and $_.FriendlyName -notmatch $script:BtBlacklist }
                            foreach ($d in $rawDevices) {
                                $connProp = Get-PnpDeviceProperty -InstanceId $d.InstanceId -KeyName '{83DA6326-97A6-4088-9453-A1923F573B29} 15' -ErrorAction SilentlyContinue
                                if ($null -ne $connProp -and $connProp.Data -eq $true) { $btDevices += $d }
                            }
                        } catch {}
                        
                        if ($btDevices.Count -eq 0) {
                            Write-Host "No ACTIVE Bluetooth devices found! Turn it on and try again." -ForegroundColor Red
                            Start-Sleep -Seconds 2
                        } else {
                            Write-Host ""
                            for ($i = 0; $i -lt $btDevices.Count; $i++) {
                                $d = $btDevices[$i]
                                $sHWID = Get-ShortHWID $d.InstanceId
                                
                                $already = ""; $isAdded = $false
                                if ($null -ne $script:Settings.Controllers) {
                                    foreach ($saved in $script:Settings.Controllers) {
                                        if ($saved.ID -eq $d.InstanceId) { $already = " (Already Added)"; $isAdded = $true; break }
                                    }
                                }

                                Write-Host "   [ $($i + 1) ] $($d.FriendlyName) ($sHWID) " -NoNewline -ForegroundColor White
                                if ($isAdded) { Write-Host "[CONNECTED]$already" -ForegroundColor Yellow }
                                else { Write-Host "[CONNECTED]" -ForegroundColor Green }
                            }
                            Write-Host ""
                            $sel = Read-Host "Type the number to add (or press Enter to cancel)"
                            if ($sel -match '^\d+$') {
                                $idx = [int]$sel - 1
                                if ($idx -ge 0 -and $idx -lt $btDevices.Count) {
                                    $tID = $btDevices[$idx].InstanceId
                                    $tName = $btDevices[$idx].FriendlyName
                                    
                                    $isDup = $false
                                    foreach ($saved in $script:Settings.Controllers) { if ($saved.ID -eq $tID) { $isDup = $true; break } }
                                    
                                    if ($isDup) {
                                        Write-Host "This controller is already on your list!" -ForegroundColor Red
                                        Start-Sleep -Seconds 2
                                    } else {
                                        $shortHWID = Get-ShortHWID $tID
                                        $existingLog = "$script:TrackerFolder\TrackerLog_$shortHWID.txt"
                                        
                                        if (Test-Path $existingLog) {
                                            Write-Host "`nNote: We found an old tracking log for this exact controller." -ForegroundColor Yellow
                                            $ans = Read-Host "Do you want to DELETE it and start a new tracking session? (Y/N) -> "
                                            if ($ans.Trim().ToUpper() -eq 'Y') {
                                                Remove-Item $existingLog -Force -ErrorAction SilentlyContinue
                                                if (Test-Path $script:DataFile) {
                                                    $allData = Get-Content $script:DataFile -Raw | ConvertFrom-Json
                                                    $allData | Add-Member -MemberType NoteProperty -Name $shortHWID -Value ([PSCustomObject]@{ GrandTotalSeconds = 0; Days = @() }) -Force
                                                    Save-AtomicJson $script:DataFile $allData
                                                }
                                                Write-Host "Old log deleted!" -ForegroundColor Green
                                            }
                                        }
                                        
                                        $arr = New-Object System.Collections.ArrayList
                                        foreach($c in $script:Settings.Controllers) { $arr.Add($c) | Out-Null }
                                        $arr.Add([PSCustomObject]@{ ID = $tID; Name = $tName }) | Out-Null
                                        $script:Settings.Controllers = $arr
                                        Save-AtomicJson $script:SettingsFile $script:Settings
                                        Write-Host "Controller Added!" -ForegroundColor Green
                                        Start-Sleep -Seconds 1
                                    }
                                }
                            }
                        }
                    } elseif ($cIn -eq 'C') {
                        if ($script:Settings.Controllers.Count -eq 0) { continue }
                        Write-Host ""
                        $rm = Read-Host "Enter the number of the controller to remove"
                        if ($rm -match '^\d+$') {
                            $rmIdx = [int]$rm - 1
                            if ($rmIdx -ge 0 -and $rmIdx -lt $script:Settings.Controllers.Count) {
                                $targetCtrl = $script:Settings.Controllers[$rmIdx]
                                Write-Host ""
                                $ans = Read-Host "Do you want to ALSO delete the tracking logs for this controller? (Y/N) -> "
                                if ($ans.Trim().ToUpper() -eq 'Y') {
                                    $shortHWID = Get-ShortHWID $targetCtrl.ID
                                    $delLog = "$script:TrackerFolder\TrackerLog_$shortHWID.txt"
                                    if (Test-Path $delLog) { Remove-Item $delLog -Force -ErrorAction SilentlyContinue }
                                    
                                    if (Test-Path $script:DataFile) {
                                        $allData = Get-Content $script:DataFile -Raw | ConvertFrom-Json
                                        $allData | Add-Member -MemberType NoteProperty -Name $shortHWID -Value ([PSCustomObject]@{ GrandTotalSeconds = 0; Days = @() }) -Force
                                        Save-AtomicJson $script:DataFile $allData
                                    }
                                }
                                
                                $arr = New-Object System.Collections.ArrayList
                                for($i=0; $i -lt $script:Settings.Controllers.Count; $i++) {
                                    if ($i -ne $rmIdx) { $arr.Add($script:Settings.Controllers[$i]) | Out-Null }
                                }
                                $script:Settings.Controllers = $arr
                                Save-AtomicJson $script:SettingsFile $script:Settings
                                Write-Host "Controller Removed." -ForegroundColor Yellow
                                Start-Sleep -Seconds 1
                            }
                        }
                    } elseif ($cIn -eq 'B') { break }
                }
            } elseif ($sIn -eq '2') {
                # --- DS4WINDOWS SETTINGS ---
                while ($true) {
                    Clear-Host
                    Write-Host "--- 3.2 DS4WINDOWS SETTINGS ---" -ForegroundColor Cyan
                    Write-Host ""
                    if ($script:Settings.DS4Enabled -eq $true) { Write-Host "  Status           : " -NoNewline; Write-Host "Auto-Launch Enabled" -ForegroundColor Green } 
                    else { Write-Host "  Status           : " -NoNewline; Write-Host "Auto-Launch Disabled" -ForegroundColor Red }
                    if ($script:Settings.ShowDS4Menu -eq $true) { Write-Host "  Main Menu Button : " -NoNewline; Write-Host "Visible" -ForegroundColor Green } 
                    else { Write-Host "  Main Menu Button : " -NoNewline; Write-Host "Hidden" -ForegroundColor Red }
                    if ($script:Settings.AutoCloseDS4 -eq $true) { Write-Host "  Kill on Exit     : " -NoNewline; Write-Host "Enabled" -ForegroundColor Green } 
                    else { Write-Host "  Kill on Exit     : " -NoNewline; Write-Host "Disabled" -ForegroundColor Red }
                    if ($script:Settings.AutoStartTracking -eq $true) { Write-Host "  Auto-Start Track : " -NoNewline; Write-Host "Enabled" -ForegroundColor Green } 
                    else { Write-Host "  Auto-Start Track : " -NoNewline; Write-Host "Disabled" -ForegroundColor Red }
                    
                    if ($script:Settings.DS4WindowsPath -ne "") { Write-Host "  Current Path     : $($script:Settings.DS4WindowsPath)" -ForegroundColor White } 
                    else { Write-Host "  Current Path     : (None Set)" -ForegroundColor DarkGray }
                    Write-Host ""
                    Write-Host "   [ C ] Change Path" -ForegroundColor Yellow
                    Write-Host "   [ D ] Toggle Auto-launch everytime tracking started" -ForegroundColor Magenta
                    Write-Host "   [ A ] Toggle 'Start DS4Windows' on Main Menu" -ForegroundColor Cyan
                    Write-Host "   [ K ] Toggle Auto-Close DS4Windows on Exit" -ForegroundColor Red
                    Write-Host "   [ T ] Toggle Auto-Start Tracking when Bluetooth connects" -ForegroundColor Yellow
                    Write-Host "   [ B ] Back" -ForegroundColor DarkGray
                    Write-Host ""
                    Write-Host "Press a key to select an option..." -ForegroundColor DarkGray
                    
                    $ds4In = [console]::ReadKey($true).KeyChar.ToString().ToUpper()
                    if ($ds4In -eq 'C') {
                        Write-Host "`nPaste the folder directory OR the full path to DS4Windows below:" -ForegroundColor Cyan
                        Write-Host "Example: C:\DS4Windows  OR  C:\DS4Windows\DS4Windows.exe" -ForegroundColor DarkGray
                        while ($true) {
                            $newPath = Read-Host "-> "
                            if ($newPath.Trim() -eq "") { Write-Host "Canceled." -ForegroundColor Yellow; break }
                            $newPath = $newPath.Trim().Trim('"').Trim("'")
                            if ($newPath -match '(?i)\.exe$') {
                                if ($newPath -notmatch '(?i)DS4Windows\.exe$') { Write-Host "Error: Only DS4Windows.exe is allowed! Try again." -ForegroundColor Red; continue }
                            } else { $newPath = Join-Path -Path $newPath -ChildPath "DS4Windows.exe" }

                            if (-not (Test-Path $newPath)) { Write-Host "Error: DS4Windows.exe was not found in that folder! Try again." -ForegroundColor Red; continue }

                            $script:Settings.DS4WindowsPath = $newPath
                            $script:Settings.DS4Enabled = $true
                            Save-AtomicJson $script:SettingsFile $script:Settings
                            Write-Host "Path Saved and Auto-Launch Enabled!" -ForegroundColor Green
                            Start-Sleep -Seconds 2
                            break
                        }
                    } elseif ($ds4In -eq 'D') {
                        if ($script:Settings.DS4WindowsPath -eq "") { Write-Host "`nYou must set a valid path [C] before you can enable Auto-Launch!" -ForegroundColor Yellow; Start-Sleep -Seconds 2 } 
                        else { $script:Settings.DS4Enabled = -not $script:Settings.DS4Enabled; Save-AtomicJson $script:SettingsFile $script:Settings }
                    } elseif ($ds4In -eq 'A') {
                        if ($script:Settings.DS4WindowsPath -eq "") { Write-Host "`nYou must set a valid path [C] before you can show the button!" -ForegroundColor Yellow; Start-Sleep -Seconds 2 } 
                        else { $script:Settings.ShowDS4Menu = -not $script:Settings.ShowDS4Menu; Save-AtomicJson $script:SettingsFile $script:Settings }
                    } elseif ($ds4In -eq 'K') {
                        $script:Settings.AutoCloseDS4 = -not $script:Settings.AutoCloseDS4
                        Save-AtomicJson $script:SettingsFile $script:Settings
                    } elseif ($ds4In -eq 'T') {
                        $script:Settings.AutoStartTracking = -not $script:Settings.AutoStartTracking
                        Save-AtomicJson $script:SettingsFile $script:Settings
                    } elseif ($ds4In -eq 'B' -or $ds4In -eq 'Escape') { break }
                }
            } elseif ($sIn -eq '3') {
                # --- VIEW LOGS ---
                $logs = Get-ChildItem "$script:TrackerFolder\TrackerLog_*.txt" -ErrorAction SilentlyContinue
                if ($logs.Count -eq 0) {
                    Write-Host "`nNo tracking logs found yet!" -ForegroundColor Yellow
                    Start-Sleep -Seconds 2
                } else {
                    Write-Host "`nSelect a log to open:" -ForegroundColor Cyan
                    for($i=0; $i -lt $logs.Count; $i++){
                        Write-Host "   [$($i+1)] $($logs[$i].Name)" -ForegroundColor White
                    }
                    Write-Host ""
                    $lsel = Read-Host "-> "
                    if ($lsel -match '^\d+$') {
                        $lidx = [int]$lsel - 1
                        if ($lidx -ge 0 -and $lidx -lt $logs.Count) { Invoke-Item $logs[$lidx].FullName }
                    }
                }
            } elseif ($sIn -eq '4') {
                # --- DELETE SPECIFIC LOG ---
                $logs = Get-ChildItem "$script:TrackerFolder\TrackerLog_*.txt" -ErrorAction SilentlyContinue
                if ($logs.Count -eq 0) {
                    Write-Host "`nNo tracking logs found to delete." -ForegroundColor Yellow
                    Start-Sleep -Seconds 2
                } else {
                    Write-Host "`nSelect a log to DELETE (Start over):" -ForegroundColor Red
                    for($i=0; $i -lt $logs.Count; $i++){
                        Write-Host "   [$($i+1)] $($logs[$i].Name)" -ForegroundColor White
                    }
                    Write-Host ""
                    $lsel = Read-Host "-> "
                    if ($lsel -match '^\d+$') {
                        $lidx = [int]$lsel - 1
                        if ($lidx -ge 0 -and $lidx -lt $logs.Count) {
                            $targetLog = $logs[$lidx]
                            $ans = Read-Host "Are you sure you want to permanently delete $($targetLog.Name)? (Y/N) -> "
                            if ($ans.Trim().ToUpper() -eq 'Y') {
                                $shortHWID = $targetLog.Name.Replace("TrackerLog_","").Replace(".txt","")
                                Remove-Item $targetLog.FullName -Force -ErrorAction SilentlyContinue
                                if (Test-Path $script:DataFile) {
                                    $allData = Get-Content $script:DataFile -Raw | ConvertFrom-Json
                                    $allData | Add-Member -MemberType NoteProperty -Name $shortHWID -Value ([PSCustomObject]@{ GrandTotalSeconds = 0; Days = @() }) -Force
                                    Save-AtomicJson $script:DataFile $allData
                                }
                                Write-Host "Log deleted! Ready for a new tracking session." -ForegroundColor Green
                                Start-Sleep -Seconds 2
                            }
                        }
                    }
                }
            } elseif ($sIn -eq '5') {
                Write-Host "`n--- FACTORY RESET ---" -ForegroundColor Red
                Write-Host "This will erase EVERYTHING (Controllers, Logs, and Settings)." -ForegroundColor Yellow
                $confirm = Read-Host "Type 'YES' to confirm reset, or press Enter to cancel -> "
                if ($confirm.Trim().ToUpper() -eq "YES") {
                    if (Test-Path $script:SettingsFile) { Remove-Item -Path $script:SettingsFile -Force -ErrorAction SilentlyContinue }
                    if (Test-Path $script:DataFile) { Remove-Item -Path $script:DataFile -Force -ErrorAction SilentlyContinue }
                    Get-ChildItem "$script:TrackerFolder\TrackerLog_*.txt" | Remove-Item -Force -ErrorAction SilentlyContinue
                    Write-Host "All data wiped! Restarting application..." -ForegroundColor Green
                    Start-Sleep -Seconds 2
                    return "RESTART"
                }
            } elseif ($sIn -eq 'B') { break }
        }
    }

    # ==========================================================
    # PART 4: THE ENGINE ROOM (Backend)
    # ==========================================================

    function Start-TrackingEngine {
        Clear-Host
        
        if ($script:Settings.Controllers.Count -eq 0) {
            Write-Host "=========================================" -ForegroundColor Cyan
            Write-Host "       DUALSHOCK BATTERY TRACKER" -ForegroundColor Green
            Write-Host "=========================================" -ForegroundColor Cyan
            Write-Host ""
            Write-Host "   [!] You must add at least one Controller first!" -ForegroundColor Red
            Write-Host "       Please go to Tracker Settings -> Manage Saved Controllers." -ForegroundColor Yellow
            Start-Sleep -Seconds 3
            return
        }
        
        $key = $null

        # Auto-Launch DS4Windows
        if ($script:Settings.DS4Enabled -eq $true -and $script:Settings.DS4WindowsPath -ne "" -and (Test-Path $script:Settings.DS4WindowsPath)) {
            $ds4Running = Get-Process -Name "DS4Windows" -ErrorAction SilentlyContinue
            if ($null -eq $ds4Running) {
                $script:DS4Process = Start-Process -FilePath $script:Settings.DS4WindowsPath -PassThru
            }
        }

        while ($true) {
            if (Test-Path $script:DataFile) { $dataMaster = Get-Content $script:DataFile -Raw | ConvertFrom-Json } 
            else { $dataMaster = [PSCustomObject]@{ } }

            $DateStr = (Get-Date).ToString("MMMM dd, yyyy")
            
            Write-Host "Today's Date : $DateStr" -ForegroundColor White
            Write-Host ""
            Write-Host "Listening for saved controllers:" -ForegroundColor DarkGray
            foreach ($c in $script:Settings.Controllers) {
                $sID = Get-ShortHWID $c.ID
                Write-Host " - $($c.Name) ($sID)" -ForegroundColor DarkGray
            }
            Write-Host ""

            # --- HEARTBEAT UI (WAITING) ---
            Write-Host " [ DISCONNECTED ] (Waiting for Controller...) " -BackgroundColor DarkRed -ForegroundColor White
            Write-Host ""
            Write-Host "Press " -NoNewline -ForegroundColor DarkGray; Write-Host "'R'" -NoNewline -ForegroundColor Cyan; Write-Host " to recap today's sessions or see all-time accumulation." -ForegroundColor DarkGray
            Write-Host "Press " -NoNewline -ForegroundColor DarkGray; Write-Host "'L'" -NoNewline -ForegroundColor Green; Write-Host " to open this session tracking log." -ForegroundColor DarkGray

            if ($script:Settings.DS4Enabled -and $script:Settings.DS4WindowsPath -ne "") {
                Write-Host "Press " -NoNewline -ForegroundColor DarkGray; Write-Host "'D'" -NoNewline -ForegroundColor Cyan; Write-Host " to manually start DS4Windows." -ForegroundColor DarkGray
            }
            
            Write-Host "Press " -NoNewline -ForegroundColor DarkGray; Write-Host "'M'" -NoNewline -ForegroundColor Yellow; Write-Host " to return to the Main Menu." -ForegroundColor DarkGray
            Write-Host "Press " -NoNewline -ForegroundColor DarkGray; Write-Host "'Q'" -NoNewline -ForegroundColor Red; Write-Host " to quit the app (or close this window to stop tracking)." -ForegroundColor DarkGray
            Write-Host ""

            $isConnected = $false
            $activeCtrl = $null
            $key = $null

            while (-not $isConnected) {
                $inputFound = $false
                $timeoutSw = [System.Diagnostics.Stopwatch]::StartNew()
                while ($timeoutSw.ElapsedMilliseconds -lt 1000) {
                    if ([console]::KeyAvailable) {
                        $key = [console]::ReadKey($true).KeyChar.ToString().ToUpper()
                        $inputFound = $true
                        break
                    }
                    Start-Sleep -Milliseconds 50
                }

                if ($inputFound) {
                    if ($key -eq 'Q') { Exit-App }
                    elseif ($key -eq 'M') { break }
                    elseif ($key -eq 'D' -and $script:Settings.DS4Enabled -and $script:Settings.DS4WindowsPath -ne "") {
                        try {
                            $script:DS4Process = Start-Process -FilePath $script:Settings.DS4WindowsPath -PassThru
                            Write-Host "`nDS4Windows Launched!" -ForegroundColor Green
                            Start-Sleep -Seconds 1
                        } catch { Write-Host "`nFailed to launch DS4Windows!" -ForegroundColor Red; Start-Sleep -Seconds 1 }
                        break 
                    }
                    elseif ($key -eq 'L') {
                        $logs = Get-ChildItem "$script:TrackerFolder\TrackerLog_*.txt" -ErrorAction SilentlyContinue
                        if ($logs.Count -gt 0) { Invoke-Item $logs[0].FullName } 
                        else { Write-Host "`nNo log file has been created yet! Track a session first." -ForegroundColor Yellow; Start-Sleep -Seconds 2; break }
                    }
                    elseif ($key -eq 'R') {
                        Write-Host "`n-----------------------------------------`n" -ForegroundColor DarkGray
                        Write-Host ">>>>> Today's Recap :`n" -ForegroundColor Cyan
                        
                        if (Test-Path $script:DataFile) {
                            $DateStr = (Get-Date).ToString("MMMM dd, yyyy")
                            $allData = Get-Content $script:DataFile -Raw | ConvertFrom-Json
                            $foundAny = $false
                            
                            foreach ($p in $allData.PSObject.Properties) {
                                $cData = $p.Value
                                foreach ($day in @($cData.Days)) {
                                    if ($day.DateStr -eq $DateStr) {
                                        foreach ($sess in @($day.Sessions)) {
                                            $foundAny = $true
                                            $st = [TimeSpan]::FromSeconds($sess.PlaytimeSeconds)
                                            $stFmt = "$([math]::Floor($st.TotalHours)) hours, $($st.Minutes) minutes, $($st.Seconds) seconds"
                                            Write-Host "Session $($sess.SessionNumber) : ($($sess.HardwareName))" -ForegroundColor White
                                            Write-Host "Session Total : $stFmt`n" -ForegroundColor White
                                        }
                                    }
                                }
                            }
                            if (-not $foundAny) { Write-Host "No completed sessions recorded today yet." -ForegroundColor DarkGray }
                        } else { Write-Host "No data found." -ForegroundColor DarkGray }
                        
                        Write-Host "`n(Note: Data for an active session is saved immediately upon disconnection.)" -ForegroundColor DarkGray
                        Write-Host "-----------------------------------------`n" -ForegroundColor DarkGray
                        Write-Host "Press any key to resume waiting..." -ForegroundColor DarkGray
                        [console]::ReadKey($true) | Out-Null
                        break
                    }
                }

                foreach ($c in $script:Settings.Controllers) {
                    try {
                        $connProp = Get-PnpDeviceProperty -InstanceId $c.ID -KeyName '{83DA6326-97A6-4088-9453-A1923F573B29} 15' -ErrorAction SilentlyContinue
                        if ($null -ne $connProp -and $connProp.Data -eq $true) { 
                            $activeCtrl = $c; $isConnected = $true; break
                        }
                    } catch { }
                }
            }
            
            if ($key -eq 'M' -or $key -eq 'D') { if ($key -eq 'M') { break } else { continue } }
            if (-not $isConnected) { continue }
            
            # --- CONTROLLER CONNECTED! ---
            $shortHWID = Get-ShortHWID $activeCtrl.ID
            $LogFile = "$script:TrackerFolder\TrackerLog_$shortHWID.txt"

            $allDataHT = @{}
            if (Test-Path $script:DataFile) {
                $parsed = Get-Content $script:DataFile -Raw | ConvertFrom-Json
                foreach ($prop in $parsed.PSObject.Properties) { $allDataHT[$prop.Name] = $prop.Value }
            }

            if (-not $allDataHT.Contains($shortHWID)) { $allDataHT[$shortHWID] = [PSCustomObject]@{ GrandTotalSeconds = 0; Days = @() } }
            $data = $allDataHT[$shortHWID]
            
            $DateStr = (Get-Date).ToString("MMMM dd, yyyy")
            $dayEntry = $null
            foreach ($day in @($data.Days)) { if ($day.DateStr -eq $DateStr) { $dayEntry = $day; break } }
            
            $sessionNum = 1
            if ($null -ne $dayEntry) { $sessionNum = @($dayEntry.Sessions).Count + 1 }

            $StartTime = Get-Date
            $activeSeconds = 0
            $lastCheckTime = Get-Date

            # --- SLEEP-PROTECTED STOPWATCH LOOP ---
            while ($true) {
                Clear-Host
                Write-Host "Session $sessionNum is active." -ForegroundColor Magenta
                Write-Host ""
                Write-Host " [ CONNECTED ] ($shortHWID) Stopwatch is Running! " -BackgroundColor DarkGreen -ForegroundColor White
                Write-Host ""
                Write-Host "[$($StartTime.ToString('HH:mm:ss'))] Controller connected." -ForegroundColor Green
                
                $elapsed = [TimeSpan]::FromSeconds($activeSeconds)
                Write-Host "Elapsed Runtime: $([math]::Floor($elapsed.TotalHours))h $($elapsed.Minutes)m $($elapsed.Seconds)s" -ForegroundColor Cyan
                Write-Host "`n(Do not close this window while tracking!)" -ForegroundColor DarkGray

                Start-Sleep -Seconds 2
                $now = Get-Date
                $delta = ($now - $lastCheckTime).TotalSeconds
                $lastCheckTime = $now

                if ($delta -lt 15) { $activeSeconds += $delta } 
                else { Write-Host "   [!] PC Sleep or Lag detected. Discarding ghost time..." -ForegroundColor Yellow }

                try {
                    $checkAlive = Get-PnpDeviceProperty -InstanceId $activeCtrl.ID -KeyName '{83DA6326-97A6-4088-9453-A1923F573B29} 15' -ErrorAction Stop
                    if ($null -eq $checkAlive -or $checkAlive.Data -ne $true) { break }
                } catch { }
            }

            # --- CONTROLLER DISCONNECTED ---
            $EndTime = Get-Date
            Show-Toast "Battery Tracker" "$($activeCtrl.Name) disconnected! Final time logged."

            Write-Host "`n[$($EndTime.ToString('HH:mm:ss'))] Controller disconnected. Stopwatch stopped." -ForegroundColor Red
            Write-Host "Session $sessionNum recorded!`n" -ForegroundColor White
            Write-Host "-----------------------------------------`n" -ForegroundColor DarkGray

            # --- SAVE DATA ---
            $TimeRange = "$($StartTime.ToString('HH:mm')) to $($EndTime.ToString('HH:mm'))"

            if ($null -eq $dayEntry) {
                $dayEntry = [PSCustomObject]@{ DateStr = $DateStr; DailyTotalSeconds = 0; Sessions = @() }
                $DaysArray = @($data.Days)
                $DaysArray += $dayEntry
                $data.Days = $DaysArray
            }

            $SessionsArray = @($dayEntry.Sessions)
            $newSession = [PSCustomObject]@{ SessionNumber = $sessionNum; HardwareName = $activeCtrl.Name; TimeRange = $TimeRange; PlaytimeSeconds = $activeSeconds }
            $SessionsArray += $newSession
            $dayEntry.Sessions = $SessionsArray
            $dayEntry.DailyTotalSeconds += $activeSeconds
            $data.GrandTotalSeconds += $activeSeconds

            $allDataHT[$shortHWID] = $data
            Save-AtomicJson $script:DataFile $allDataHT

            # --- WRITE LOG FILE ---
            $logContent = @()
            $logContent += "========================================="
            $logContent += "   DualShock Battery Tracker Script"
            $logContent += "        By : cyanojar"
            $logContent += "========================================="
            $logContent += ""
            $logContent += "Hardware ID : $($shortHWID)"
            $logContent += "Name        : $($activeCtrl.Name)"
            $logContent += ""

            foreach ($day in @($data.Days)) {
                $logContent += "--------------------"
                $logContent += "Date : $($day.DateStr)"
                $logContent += "--------------------"
                $logContent += ""

                foreach ($session in @($day.Sessions)) {
                    $t = [TimeSpan]::FromSeconds($session.PlaytimeSeconds)
                    $pTime = "$([math]::Floor($t.TotalHours)) hours, $($t.Minutes) minutes, $($t.Seconds) seconds"
                    $logContent += "Session $($session.SessionNumber)"
                    $logContent += "Hardware : $($session.HardwareName)"
                    $logContent += "Time : ($($session.TimeRange))"
                    $logContent += "Uptime : $pTime"
                    $logContent += ""
                }

                $dTotal = [TimeSpan]::FromSeconds($day.DailyTotalSeconds)
                $dTime = "$([math]::Floor($dTotal.TotalHours)) hours, $($dTotal.Minutes) minutes, $($dTotal.Seconds) seconds"
                $logContent += "TOTAL ACCUMULATED TODAY : $dTime"
                $logContent += "`n=========================================`n"
            }

            $gTotal = [TimeSpan]::FromSeconds($data.GrandTotalSeconds)
            $gTime = "$([math]::Floor($gTotal.TotalHours)) hours, $($gTotal.Minutes) minutes, $($gTotal.Seconds) seconds"
            $logContent += "All Total Accumulated :`n`n$gTime`n`nNote :"
            $logContent += "The final grand total from this log will be used" 
            $logContent += "to calibrate the upcoming Phase 2 'Fuel Gauge' script"
            $logContent += "for estimating the battery level of your controller."

            $logContent | Set-Content $LogFile

            # UI Update
            $sTotal = [TimeSpan]::FromSeconds($activeSeconds)
            $sTime = "$([math]::Floor($sTotal.TotalHours)) hours, $($sTotal.Minutes) minutes, $($sTotal.Seconds) seconds"
            Write-Host ">>> Results :" -ForegroundColor Yellow
            Write-Host "Session Total : $sTime`n" -ForegroundColor White
            Write-Host "=========== Accumulation ==========" -ForegroundColor Magenta
            Write-Host "Daily Total: $dTime" -ForegroundColor Cyan
            Write-Host "Grand Total: $gTime`n" -ForegroundColor Green
            Write-Host "Log file successfully updated.`n" -ForegroundColor DarkGray
            Write-Host "Preparing next session..." -ForegroundColor DarkGray
            Start-Sleep -Seconds 3
        }
    }

    # ==========================================================
    # PART 5: THE IGNITION (Execution Loop)
    # ==========================================================

    # 1. Run the OTA check silently
    Check-OTAUpdate

    :MainRouter while ($true) {
        # 2. Version Migration & Setup
        if (Test-Path $script:SettingsFile) {
            $checkOld = Get-Content $script:SettingsFile -Raw | ConvertFrom-Json
            $props = $checkOld.PSObject.Properties.Name
            if ($props -contains 'ControllerID') { Remove-Item -Path $script:SettingsFile -Force -ErrorAction SilentlyContinue } 
            else {
                $modified = $false
                if ($props -notcontains 'ShowDS4Menu') { $checkOld | Add-Member -MemberType NoteProperty -Name "ShowDS4Menu" -Value $false; $modified = $true }
                if ($props -notcontains 'AutoCloseDS4') { $checkOld | Add-Member -MemberType NoteProperty -Name "AutoCloseDS4" -Value $false; $modified = $true }
                if ($props -notcontains 'AutoStartTracking') { $checkOld | Add-Member -MemberType NoteProperty -Name "AutoStartTracking" -Value $false; $modified = $true }
                if ($modified) { Save-AtomicJson $script:SettingsFile $checkOld }
            }
        }

        if (-not (Test-Path $script:SettingsFile)) {
            Invoke-SetupWizard
        }

        # 3. Load the central brain variables
        $script:Settings = Get-Content $script:SettingsFile -Raw | ConvertFrom-Json

        # 4. Route traffic
        $UserAction = Show-MainMenu
        
        switch ($UserAction) {
            'TRACK' { Start-TrackingEngine }
            'SETTINGS' { 
                $status = Show-TrackerSettings 
                if ($status -eq "RESTART") { continue MainRouter }
            }
            'DS4' {
                if (Test-Path $script:Settings.DS4WindowsPath) {
                    $script:DS4Process = Start-Process -FilePath $script:Settings.DS4WindowsPath -PassThru
                    Write-Host "`nDS4Windows Launched!" -ForegroundColor Green
                    Start-Sleep -Seconds 1
                }
            }
            'EXIT' { Exit-App }
        }
    }

} catch {
    Write-Host "`n=========================================" -ForegroundColor Red
    Write-Host "FATAL ERROR OCCURRED!" -ForegroundColor Red
    Write-Host "=========================================" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Yellow
    Write-Host "`nPlease screenshot this error." -ForegroundColor DarkGray
    $null = Read-Host "Press Enter to exit..."
}
