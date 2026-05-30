# ==========================================================
#   DualShock Battery Tracker (Made for modded DS4 Battery)
#   Version: v0.27
#   Authors: cyanojar
# ==========================================================

try {
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue

    # --- SYSTEM PATHS ---
    $TrackerFolder = $PSScriptRoot
    $DataFile = "$TrackerFolder\Tracker_Data.json"
    $SettingsFile = "$TrackerFolder\config.json"
    
    # --- BLUETOOTH BLACKLIST ---
    $BtBlacklist = "(?i)Enumerator|Adapter|AVRCP|Protocol|GATT|LE Generic|Hands-Free|Intel.*Bluetooth|Realtek.*Bluetooth|Qualcomm.*Bluetooth|MediaTek.*Bluetooth|Microsoft.*Bluetooth"

    if (-not (Test-Path $TrackerFolder)) {
        New-Item -ItemType Directory -Path $TrackerFolder -Force | Out-Null
    }

    # --- VERSION MIGRATION PROTECTOR ---
    if (Test-Path $SettingsFile) {
        $checkOld = Get-Content $SettingsFile -Raw | ConvertFrom-Json
        if ($null -ne $checkOld.ControllerID) {
            Remove-Item -Path $SettingsFile -Force -ErrorAction SilentlyContinue
        } 
        elseif ($null -eq $checkOld.ShowDS4Menu) {
            $checkOld | Add-Member -MemberType NoteProperty -Name "ShowDS4Menu" -Value $false
            $checkOld | Add-Member -MemberType NoteProperty -Name "AutoCloseDS4" -Value $false
            $checkOld | ConvertTo-Json -Depth 5 | Set-Content $SettingsFile
        }
        elseif ($null -eq $checkOld.AutoCloseDS4) {
            $checkOld | Add-Member -MemberType NoteProperty -Name "AutoCloseDS4" -Value $false
            $checkOld | ConvertTo-Json -Depth 5 | Set-Content $SettingsFile
        }
    }

    # --- HELPER: CLEAN HWID ---
    function Get-ShortHWID ($fullID) {
        if ($null -eq $fullID -or $fullID -eq "") { return "UNKNOWN" }
        if ($fullID -match 'DEV_([A-Z0-9]+)') {
            return "DEV_" + $matches[1]
        } else {
            return ($fullID -replace '[^a-zA-Z0-9]','').Substring(0, [math]::Min(($fullID -replace '[^a-zA-Z0-9]','').Length, 15))
        }
    }

    # --- UNIVERSAL EXIT FUNCTION ---
    function Exit-App {
        Write-Host ""
        Write-Host "Logs and settings automatically saved." -ForegroundColor Green
        
        if (Test-Path $SettingsFile) {
            $ExitSettings = Get-Content $SettingsFile -Raw | ConvertFrom-Json
            if ($ExitSettings.AutoCloseDS4 -eq $true) {
                Write-Host "Closing DS4Windows..." -ForegroundColor Yellow
                Stop-Process -Name "DS4Windows" -Force -ErrorAction SilentlyContinue
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
        Write-Host ""
        Write-Host "-----------------------------------------" -ForegroundColor DarkGray
        Write-Host ""
    }

    # --- MAIN APPLICATION LOOP ---
    :MainLoop while ($true) {

        # --- FIRST TIME SETUP WIZARD ---
        if (-not (Test-Path $SettingsFile)) {
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
                    $rawDevices = Get-PnpDevice -Class Bluetooth -ErrorAction Stop | Where-Object { $_.FriendlyName -ne $null -and $_.FriendlyName -notmatch $BtBlacklist }
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
                    Draw-SetupHeader 1
                    Write-Host "Rescanning..." -ForegroundColor Yellow
                    Start-Sleep -Seconds 1
                    continue
                } elseif ($btIn.Trim().ToUpper() -eq 'T') {
                    Start-Process devmgmt.msc
                    Draw-SetupHeader 1
                    continue
                } elseif ($btIn.Trim().ToUpper() -eq 'S') {
                    $targetID = ""
                    $targetName = ""
                    Write-Host ""
                    Write-Host "Skipped! (You can add one later in Tracker Settings)" -ForegroundColor Yellow
                    break
                } elseif ($btIn.Trim().ToUpper() -eq 'M') {
                    Write-Host ""
                    Write-Host "Paste your exact InstanceId / Hardware ID below:" -ForegroundColor Cyan
                    $manualID = Read-Host "-> "
                    if ($manualID.Trim() -ne "") {
                        $targetID = $manualID.Trim()
                        $targetName = "Custom Controller"
                        Write-Host "Saved ID: $targetID" -ForegroundColor Green
                        break
                    }
                } else {
                    if ($btIn -match '^\d+$') {
                        $idx = [int]$btIn - 1
                        if ($idx -ge 0 -and $idx -lt $btDevices.Count) {
                            $targetID = $btDevices[$idx].InstanceId
                            $targetName = $btDevices[$idx].FriendlyName
                            Write-Host ""
                            Write-Host "Selected: $targetName!" -ForegroundColor Green
                            break
                        } else {
                            Write-Host "Invalid number! Try again." -ForegroundColor Red
                        }
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
                if ($ds4Input.Trim() -eq "") {
                    Write-Host "No path entered. Skipping auto-launch." -ForegroundColor Yellow
                    break
                }

                $ds4Input = $ds4Input.Trim().Trim('"').Trim("'")
                
                if ($ds4Input -match '(?i)\.exe$') {
                    if ($ds4Input -notmatch '(?i)DS4Windows\.exe$') {
                        Write-Host "Error: Only DS4Windows.exe is allowed! Try again." -ForegroundColor Red
                        continue
                    } else {
                        $DS4Path = $ds4Input
                    }
                } else {
                    $DS4Path = Join-Path -Path $ds4Input -ChildPath "DS4Windows.exe"
                }

                if (-not (Test-Path $DS4Path)) {
                    Write-Host "Error: DS4Windows.exe was not found in that folder! Try again." -ForegroundColor Red
                    continue
                }

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
                    } catch {
                        Write-Host "Failed to create shortcut." -ForegroundColor Red
                    }
                } else {
                    Write-Host "Shortcut already exists!" -ForegroundColor Yellow
                }
            }

            # Save Configuration
            $ctrlArray = @()
            if ($targetID -ne "") {
                $ctrlArray += [PSCustomObject]@{ ID = $targetID; Name = $targetName }
            }
            
            $SettingsObj = [PSCustomObject]@{
                Controllers = $ctrlArray
                DS4WindowsPath = $DS4Path
                DS4Enabled = ($DS4Path -ne "")
                ShowDS4Menu = $false
                AutoCloseDS4 = $false
            }
            $SettingsObj | ConvertTo-Json -Depth 5 | Set-Content $SettingsFile

            Clear-Host
            Write-Host "Setup Complete! You are ready to track." -ForegroundColor Green
            Start-Sleep -Seconds 2
        }

        # Load current settings 
        $Settings = Get-Content $SettingsFile -Raw | ConvertFrom-Json

        # --- LIVE MAIN MENU UI LOOP ---
        $menuDrawn = $false
        $lastConnectedStatus = $null
        $menuChoice = ""

        while ($true) {
            $anyConnected = $false
            $connectedCtrl = $null

            if ($null -ne $Settings.Controllers -and $Settings.Controllers.Count -gt 0) {
                foreach ($c in $Settings.Controllers) {
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

            if (-not $menuDrawn -or $anyConnected -ne $lastConnectedStatus) {
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
                
                if ($Settings.DS4Enabled -and $Settings.DS4WindowsPath -ne "" -and $Settings.ShowDS4Menu) {
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
                $lastConnectedStatus = $anyConnected
            }

            # Highly responsive 1-second delay block
            $breakMenu = $false
            for ($i=0; $i -lt 10; $i++) {
                if ([console]::KeyAvailable) {
                    $menuChoice = [console]::ReadKey($true).KeyChar.ToString().ToUpper()
                    $breakMenu = $true
                    break
                }
                Start-Sleep -Milliseconds 100
            }
            if ($breakMenu) { break }
        }

        if ($menuChoice -eq '1') {
            $action = "TRACK"
        } else {
            $action = $menuMap[$menuChoice]
        }

        switch ($action) {
            'DS4' {
                if (Test-Path $Settings.DS4WindowsPath) {
                    Start-Process -FilePath $Settings.DS4WindowsPath
                    Write-Host "`nDS4Windows Launched!" -ForegroundColor Green
                    Start-Sleep -Seconds 1
                }
            }
            'SETTINGS' {
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
                            if ($Settings.Controllers.Count -eq 0) {
                                Write-Host "   (No controllers saved)" -ForegroundColor DarkGray
                            } else {
                                for($i=0; $i -lt $Settings.Controllers.Count; $i++) {
                                    $c = $Settings.Controllers[$i]
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
                                Write-Host ""
                                Write-Host "Scanning for actively connected devices..." -ForegroundColor DarkGray
                                $btDevices = @()
                                try {
                                    $rawDevices = Get-PnpDevice -Class Bluetooth -ErrorAction Stop | Where-Object { $_.FriendlyName -ne $null -and $_.FriendlyName -notmatch $BtBlacklist }
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
                                        
                                        $already = ""
                                        $isAdded = $false
                                        if ($null -ne $Settings.Controllers) {
                                            foreach ($saved in $Settings.Controllers) {
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
                                            foreach ($saved in $Settings.Controllers) { if ($saved.ID -eq $tID) { $isDup = $true; break } }
                                            
                                            if ($isDup) {
                                                Write-Host "This controller is already on your list!" -ForegroundColor Red
                                                Start-Sleep -Seconds 2
                                            } else {
                                                $shortHWID = Get-ShortHWID $tID
                                                $existingLog = "$TrackerFolder\TrackerLog_$shortHWID.txt"
                                                
                                                if (Test-Path $existingLog) {
                                                    Write-Host ""
                                                    Write-Host "Note: We found an old tracking log for this exact controller." -ForegroundColor Yellow
                                                    $ans = Read-Host "Do you want to DELETE it and start a new tracking session? (Y/N) -> "
                                                    if ($ans.Trim().ToUpper() -eq 'Y') {
                                                        Remove-Item $existingLog -Force -ErrorAction SilentlyContinue
                                                        if (Test-Path $DataFile) {
                                                            $allData = Get-Content $DataFile -Raw | ConvertFrom-Json
                                                            $allData | Add-Member -MemberType NoteProperty -Name $shortHWID -Value ([PSCustomObject]@{ GrandTotalSeconds = 0; Days = @() }) -Force
                                                            $allData | ConvertTo-Json -Depth 5 | Set-Content $DataFile
                                                        }
                                                        Write-Host "Old log deleted!" -ForegroundColor Green
                                                    }
                                                }
                                                
                                                $newCtrl = [PSCustomObject]@{ ID = $tID; Name = $tName }
                                                $Settings.Controllers += $newCtrl
                                                $Settings | ConvertTo-Json -Depth 5 | Set-Content $SettingsFile
                                                Write-Host "Controller Added!" -ForegroundColor Green
                                                Start-Sleep -Seconds 1
                                            }
                                        }
                                    }
                                }
                            } elseif ($cIn -eq 'C') {
                                if ($Settings.Controllers.Count -eq 0) { continue }
                                Write-Host ""
                                $rm = Read-Host "Enter the number of the controller to remove"
                                if ($rm -match '^\d+$') {
                                    $rmIdx = [int]$rm - 1
                                    if ($rmIdx -ge 0 -and $rmIdx -lt $Settings.Controllers.Count) {
                                        $targetCtrl = $Settings.Controllers[$rmIdx]
                                        Write-Host ""
                                        $ans = Read-Host "Do you want to ALSO delete the tracking logs for this controller? (Y/N) -> "
                                        if ($ans.Trim().ToUpper() -eq 'Y') {
                                            $shortHWID = Get-ShortHWID $targetCtrl.ID
                                            $delLog = "$TrackerFolder\TrackerLog_$shortHWID.txt"
                                            if (Test-Path $delLog) { Remove-Item $delLog -Force -ErrorAction SilentlyContinue }
                                            
                                            if (Test-Path $DataFile) {
                                                $allData = Get-Content $DataFile -Raw | ConvertFrom-Json
                                                $allData | Add-Member -MemberType NoteProperty -Name $shortHWID -Value ([PSCustomObject]@{ GrandTotalSeconds = 0; Days = @() }) -Force
                                                $allData | ConvertTo-Json -Depth 5 | Set-Content $DataFile
                                            }
                                        }
                                        
                                        $newArray = @()
                                        for($i=0; $i -lt $Settings.Controllers.Count; $i++) {
                                            if ($i -ne $rmIdx) { $newArray += $Settings.Controllers[$i] }
                                        }
                                        $Settings.Controllers = $newArray
                                        $Settings | ConvertTo-Json -Depth 5 | Set-Content $SettingsFile
                                        Write-Host "Controller Removed." -ForegroundColor Yellow
                                        Start-Sleep -Seconds 1
                                    }
                                }
                            } elseif ($cIn -eq 'B') {
                                break
                            }
                        }
                    } elseif ($sIn -eq '2') {
                        # --- DS4WINDOWS SETTINGS ---
                        while ($true) {
                            Clear-Host
                            Write-Host "--- 3.2 DS4WINDOWS SETTINGS ---" -ForegroundColor Cyan
                            Write-Host ""
                            if ($Settings.DS4Enabled -eq $true) { Write-Host "  Status           : " -NoNewline; Write-Host "Auto-Launch Enabled" -ForegroundColor Green } 
                            else { Write-Host "  Status           : " -NoNewline; Write-Host "Auto-Launch Disabled" -ForegroundColor Red }
                            if ($Settings.ShowDS4Menu -eq $true) { Write-Host "  Main Menu Button : " -NoNewline; Write-Host "Visible" -ForegroundColor Green } 
                            else { Write-Host "  Main Menu Button : " -NoNewline; Write-Host "Hidden" -ForegroundColor Red }
                            if ($Settings.AutoCloseDS4 -eq $true) { Write-Host "  Kill on Exit     : " -NoNewline; Write-Host "Enabled" -ForegroundColor Green } 
                            else { Write-Host "  Kill on Exit     : " -NoNewline; Write-Host "Disabled" -ForegroundColor Red }
                            
                            if ($Settings.DS4WindowsPath -ne "") { Write-Host "  Current Path     : $($Settings.DS4WindowsPath)" -ForegroundColor White } 
                            else { Write-Host "  Current Path     : (None Set)" -ForegroundColor DarkGray }
                            Write-Host ""
                            Write-Host "   [ C ] Change Path" -ForegroundColor Yellow
                            Write-Host "   [ D ] Toggle Auto-launch everytime tracking started" -ForegroundColor Magenta
                            Write-Host "   [ A ] Toggle 'Start DS4Windows' on Main Menu" -ForegroundColor Cyan
                            Write-Host "   [ K ] Toggle Auto-Close DS4Windows on Exit" -ForegroundColor Red
                            Write-Host "   [ B ] Back" -ForegroundColor DarkGray
                            Write-Host ""
                            Write-Host "Press a key to select an option..." -ForegroundColor DarkGray
                            
                            $ds4In = [console]::ReadKey($true).KeyChar.ToString().ToUpper()
                            if ($ds4In -eq 'C') {
                                Write-Host ""
                                Write-Host "Paste the folder directory OR the full path to DS4Windows below:" -ForegroundColor Cyan
                                Write-Host "Example: C:\DS4Windows  OR  C:\DS4Windows\DS4Windows.exe" -ForegroundColor DarkGray
                                while ($true) {
                                    $newPath = Read-Host "-> "
                                    if ($newPath.Trim() -eq "") { Write-Host "Canceled." -ForegroundColor Yellow; break }
                                    $newPath = $newPath.Trim().Trim('"').Trim("'")
                                    if ($newPath -match '(?i)\.exe$') {
                                        if ($newPath -notmatch '(?i)DS4Windows\.exe$') { Write-Host "Error: Only DS4Windows.exe is allowed! Try again." -ForegroundColor Red; continue }
                                    } else { $newPath = Join-Path -Path $newPath -ChildPath "DS4Windows.exe" }

                                    if (-not (Test-Path $newPath)) { Write-Host "Error: DS4Windows.exe was not found in that folder! Try again." -ForegroundColor Red; continue }

                                    $Settings.DS4WindowsPath = $newPath
                                    $Settings.DS4Enabled = $true
                                    $Settings | ConvertTo-Json -Depth 5 | Set-Content $SettingsFile
                                    Write-Host "Path Saved and Auto-Launch Enabled!" -ForegroundColor Green
                                    Start-Sleep -Seconds 2
                                    break
                                }
                            } elseif ($ds4In -eq 'D') {
                                if ($Settings.DS4WindowsPath -eq "") { Write-Host "`nYou must set a valid path [C] before you can enable Auto-Launch!" -ForegroundColor Yellow; Start-Sleep -Seconds 2 } 
                                else {
                                    $Settings.DS4Enabled = -not $Settings.DS4Enabled
                                    $Settings | ConvertTo-Json -Depth 5 | Set-Content $SettingsFile
                                }
                            } elseif ($ds4In -eq 'A') {
                                if ($Settings.DS4WindowsPath -eq "") { Write-Host "`nYou must set a valid path [C] before you can show the button!" -ForegroundColor Yellow; Start-Sleep -Seconds 2 } 
                                else {
                                    $Settings.ShowDS4Menu = -not $Settings.ShowDS4Menu
                                    $Settings | ConvertTo-Json -Depth 5 | Set-Content $SettingsFile
                                }
                            } elseif ($ds4In -eq 'K') {
                                $Settings.AutoCloseDS4 = -not $Settings.AutoCloseDS4
                                $Settings | ConvertTo-Json -Depth 5 | Set-Content $SettingsFile
                            } elseif ($ds4In -eq 'B' -or $ds4In -eq 'Escape') { break }
                        }
                    } elseif ($sIn -eq '3') {
                        # --- VIEW LOGS ---
                        $logs = Get-ChildItem "$TrackerFolder\TrackerLog_*.txt" -ErrorAction SilentlyContinue
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
                                if ($lidx -ge 0 -and $lidx -lt $logs.Count) {
                                    Invoke-Item $logs[$lidx].FullName
                                }
                            }
                        }
                    } elseif ($sIn -eq '4') {
                        # --- DELETE SPECIFIC LOG ---
                        $logs = Get-ChildItem "$TrackerFolder\TrackerLog_*.txt" -ErrorAction SilentlyContinue
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
                                        if (Test-Path $DataFile) {
                                            $allData = Get-Content $DataFile -Raw | ConvertFrom-Json
                                            $allData | Add-Member -MemberType NoteProperty -Name $shortHWID -Value ([PSCustomObject]@{ GrandTotalSeconds = 0; Days = @() }) -Force
                                            $allData | ConvertTo-Json -Depth 5 | Set-Content $DataFile
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
                            if (Test-Path $SettingsFile) { Remove-Item -Path $SettingsFile -Force -ErrorAction SilentlyContinue }
                            if (Test-Path $DataFile) { Remove-Item -Path $DataFile -Force -ErrorAction SilentlyContinue }
                            Get-ChildItem "$TrackerFolder\TrackerLog_*.txt" | Remove-Item -Force -ErrorAction SilentlyContinue
                            Write-Host "All data wiped! Rebooting wizard..." -ForegroundColor Green
                            Start-Sleep -Seconds 2
                            continue MainLoop
                        }
                    } elseif ($sIn -eq 'B') {
                        break
                    }
                }
            }
            'EXIT' {
                Exit-App
            }
            'TRACK' {
                # --- START TRACKING ENGINE ---
                Clear-Host
                
                if ($Settings.Controllers.Count -eq 0) {
                    Write-Host "=========================================" -ForegroundColor Cyan
                    Write-Host "       DUALSHOCK BATTERY TRACKER" -ForegroundColor Green
                    Write-Host "=========================================" -ForegroundColor Cyan
                    Write-Host ""
                    Write-Host "   [!] You must add at least one Controller first!" -ForegroundColor Red
                    Write-Host "       Please go to Tracker Settings -> Manage Saved Controllers." -ForegroundColor Yellow
                    Start-Sleep -Seconds 3
                    continue MainLoop
                }
                
                $key = $null

                # Auto-Launch DS4Windows
                if ($Settings.DS4Enabled -eq $true -and $Settings.DS4WindowsPath -ne "" -and (Test-Path $Settings.DS4WindowsPath)) {
                    $ds4Running = Get-Process -Name "DS4Windows" -ErrorAction SilentlyContinue
                    if ($null -eq $ds4Running) {
                        Start-Process -FilePath $Settings.DS4WindowsPath
                    }
                }

                while ($true) {
                    # Load Tracker Data
                    if (Test-Path $DataFile) {
                        $data = Get-Content $DataFile -Raw | ConvertFrom-Json
                    } else {
                        $data = [PSCustomObject]@{ GrandTotalSeconds = 0; Days = @() }
                    }

                    $DateStr = (Get-Date).ToString("MMMM dd, yyyy")
                    $dayEntry = $null
                    foreach ($day in @($data.Days)) {
                        if ($day.DateStr -eq $DateStr) { $dayEntry = $day; break }
                    }
                    
                    $sessionNum = 1
                    if ($null -ne $dayEntry) {
                        $sessionNum = @($dayEntry.Sessions).Count + 1
                    }

                    if ($sessionNum -eq 1) {
                        Write-Host "Today's Date : $DateStr" -ForegroundColor White
                        Write-Host ""
                    }

                    Write-Host "Listening for saved controllers:" -ForegroundColor DarkGray
                    foreach ($c in $Settings.Controllers) {
                        $sID = Get-ShortHWID $c.ID
                        Write-Host " - $($c.Name) ($sID)" -ForegroundColor DarkGray
                    }
                    Write-Host ""

                    # --- HEARTBEAT UI (WAITING) ---
                    Write-Host " [ DISCONNECTED ] (Waiting for Controller...) " -BackgroundColor DarkRed -ForegroundColor White
                    Write-Host ""
                    
                    # --- COLORIZED INSTRUCTIONS ---
                    Write-Host "Press " -NoNewline -ForegroundColor DarkGray
                    Write-Host "'R'" -NoNewline -ForegroundColor Cyan
                    Write-Host " to recap today's sessions or see all-time accumulation." -ForegroundColor DarkGray
                    
                    Write-Host "Press " -NoNewline -ForegroundColor DarkGray
                    Write-Host "'L'" -NoNewline -ForegroundColor Green
                    Write-Host " to open this session tracking log." -ForegroundColor DarkGray

                    if ($Settings.DS4Enabled -and $Settings.DS4WindowsPath -ne "") {
                        Write-Host "Press " -NoNewline -ForegroundColor DarkGray
                        Write-Host "'D'" -NoNewline -ForegroundColor Cyan
                        Write-Host " to manually start DS4Windows." -ForegroundColor DarkGray
                    }
                    
                    Write-Host "Press " -NoNewline -ForegroundColor DarkGray
                    Write-Host "'M'" -NoNewline -ForegroundColor Yellow
                    Write-Host " to return to the Main Menu." -ForegroundColor DarkGray

                    Write-Host "Press " -NoNewline -ForegroundColor DarkGray
                    Write-Host "'Q'" -NoNewline -ForegroundColor Red
                    Write-Host " to quit the app (or close this window to stop tracking)." -ForegroundColor DarkGray
                    Write-Host ""

                    # Wait for ANY saved Controller HWID
                    $isConnected = $false
                    $activeCtrl = $null
                    $key = $null

                    while (-not $isConnected) {
                        if ([console]::KeyAvailable) {
                            $key = [console]::ReadKey($true).KeyChar.ToString().ToUpper()
                            if ($key -eq 'Q') {
                                Exit-App 
                            }
                            elseif ($key -eq 'M') {
                                break 
                            }
                            elseif ($key -eq 'D' -and $Settings.DS4Enabled -and $Settings.DS4WindowsPath -ne "") {
                                try {
                                    Start-Process -FilePath $Settings.DS4WindowsPath
                                    Write-Host "`nDS4Windows Launched!" -ForegroundColor Green
                                    Start-Sleep -Seconds 1
                                } catch {
                                    Write-Host "`nFailed to launch DS4Windows!" -ForegroundColor Red
                                    Start-Sleep -Seconds 1
                                }
                                break # breaks the key-checker to re-render the waiting screen
                            }
                            elseif ($key -eq 'L') {
                                $logs = Get-ChildItem "$TrackerFolder\TrackerLog_*.txt" -ErrorAction SilentlyContinue
                                if ($logs.Count -gt 0) { 
                                    Invoke-Item $logs[0].FullName 
                                } else {
                                    Write-Host ""
                                    Write-Host "No log file has been created yet! Track a session first." -ForegroundColor Yellow
                                    Start-Sleep -Seconds 2
                                    break 
                                }
                            }
                            elseif ($key -eq 'R') {
                                Write-Host ""
                                Write-Host "-----------------------------------------" -ForegroundColor DarkGray
                                Write-Host ""
                                Write-Host ">>>>> Today's Recap :" -ForegroundColor Cyan
                                Write-Host ""
                                
                                if (Test-Path $DataFile) {
                                    $DateStr = (Get-Date).ToString("MMMM dd, yyyy")
                                    $allData = Get-Content $DataFile -Raw | ConvertFrom-Json
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
                                                    Write-Host "Session Total : $stFmt" -ForegroundColor White
                                                    Write-Host ""
                                                }
                                            }
                                        }
                                    }
                                    if (-not $foundAny) { Write-Host "No completed sessions recorded today yet." -ForegroundColor DarkGray }
                                } else {
                                    Write-Host "No data found." -ForegroundColor DarkGray
                                }
                                
                                Write-Host ""
                                Write-Host "(Note: Data for an active session is saved immediately upon disconnection.)" -ForegroundColor DarkGray
                                Write-Host "-----------------------------------------" -ForegroundColor DarkGray
                                Write-Host ""
                                Write-Host "Press any key to resume waiting..." -ForegroundColor DarkGray
                                [console]::ReadKey($true) | Out-Null
                                break
                            }
                        }

                        # SAFE WMI POLLING: Check all saved controllers
                        foreach ($c in $Settings.Controllers) {
                            try {
                                $connProp = Get-PnpDeviceProperty -InstanceId $c.ID -KeyName '{83DA6326-97A6-4088-9453-A1923F573B29} 15' -ErrorAction Stop
                                if ($null -ne $connProp -and $connProp.Data -eq $true) { 
                                    $activeCtrl = $c
                                    $isConnected = $true 
                                    break
                                }
                            } catch { }
                        }
                        
                        if (-not $isConnected) {
                            Start-Sleep -Milliseconds 2000
                        }
                    }
                    
                    if ($key -eq 'M' -or $key -eq 'D') {
                        if ($key -eq 'M') { break } else { continue }
                    }
                    if (-not $isConnected) {
                        continue 
                    }
                    
                    # --- CONTROLLER CONNECTED! ---
                    $shortHWID = Get-ShortHWID $activeCtrl.ID
                    $LogFile = "$TrackerFolder\TrackerLog_$shortHWID.txt"

                    # Load Data specifically for this Controller
                    if (Test-Path $DataFile) {
                        $allData = Get-Content $DataFile -Raw | ConvertFrom-Json
                    } else {
                        $allData = [PSCustomObject]@{ }
                    }

                    $exists = $false
                    foreach ($p in $allData.PSObject.Properties) {
                        if ($p.Name -eq $shortHWID) { $exists = $true; break }
                    }
                    
                    if (-not $exists) {
                        $allData | Add-Member -MemberType NoteProperty -Name $shortHWID -Value ([PSCustomObject]@{ GrandTotalSeconds = 0; Days = @() }) -Force
                    }
                    
                    $data = $allData.$shortHWID
                    
                    $DateStr = (Get-Date).ToString("MMMM dd, yyyy")
                    $dayEntry = $null
                    foreach ($day in @($data.Days)) {
                        if ($day.DateStr -eq $DateStr) { $dayEntry = $day; break }
                    }
                    
                    $sessionNum = 1
                    if ($null -ne $dayEntry) {
                        $sessionNum = @($dayEntry.Sessions).Count + 1
                    }

                    $StartTime = Get-Date

                    Clear-Host
                    Write-Host "Session $sessionNum is active." -ForegroundColor Magenta
                    Write-Host ""
                    Write-Host " [ CONNECTED ] ($shortHWID) Stopwatch is Running! " -BackgroundColor DarkGreen -ForegroundColor White
                    Write-Host ""
                    Write-Host "[$($StartTime.ToString('HH:mm:ss'))] Controller connected." -ForegroundColor Green
                    Write-Host ""
                    Write-Host "(Do not close this window while tracking!)" -ForegroundColor DarkGray

                    # --- SLEEP-PROTECTED STOPWATCH LOOP ---
                    $activeSeconds = 0
                    $lastCheckTime = Get-Date

                    while ($true) {
                        Start-Sleep -Seconds 5
                        $now = Get-Date
                        $delta = ($now - $lastCheckTime).TotalSeconds
                        $lastCheckTime = $now

                        if ($delta -lt 15) {
                            $activeSeconds += $delta
                        } else {
                            Write-Host "   [!] PC Sleep or Lag detected. Discarding ghost time..." -ForegroundColor Yellow
                        }

                        try {
                            $checkAlive = Get-PnpDeviceProperty -InstanceId $activeCtrl.ID -KeyName '{83DA6326-97A6-4088-9453-A1923F573B29} 15' -ErrorAction Stop
                            if ($null -eq $checkAlive -or $checkAlive.Data -ne $true) {
                                break # Disconnected!
                            }
                        } catch { }
                    }

                    # --- CONTROLLER DISCONNECTED (OR DIED) ---
                    $EndTime = Get-Date
                    
                    # NOTIFICATION TOAST + SOUND
                    try {
                        [System.Media.SystemSounds]::Exclamation.Play()
                        $notify = New-Object System.Windows.Forms.NotifyIcon
                        $notify.Icon = [System.Drawing.SystemIcons]::Warning
                        $notify.Visible = $true
                        $notify.ShowBalloonTip(5000, "Battery Tracker", "$($activeCtrl.Name) disconnected! Final time logged.", [System.Windows.Forms.ToolTipIcon]::Warning)
                        Start-Sleep -Seconds 3
                        $notify.Dispose()
                    } catch {}

                    Write-Host "[$($EndTime.ToString('HH:mm:ss'))] Controller disconnected. Stopwatch stopped." -ForegroundColor Red
                    Write-Host "Session $sessionNum recorded!" -ForegroundColor White
                    Write-Host ""
                    Write-Host "-----------------------------------------" -ForegroundColor DarkGray
                    Write-Host ""

                    # --- SAVE DATA ---
                    $TimeRange = "$($StartTime.ToString('HH:mm')) to $($EndTime.ToString('HH:mm'))"

                    if ($null -eq $dayEntry) {
                        $dayEntry = [PSCustomObject]@{ DateStr = $DateStr; DailyTotalSeconds = 0; Sessions = @() }
                        $DaysArray = @($data.Days)
                        $DaysArray += $dayEntry
                        $data.Days = $DaysArray
                    }

                    $SessionsArray = @($dayEntry.Sessions)
                    $newSession = [PSCustomObject]@{ 
                        SessionNumber = $sessionNum; 
                        HardwareName = $activeCtrl.Name; 
                        TimeRange = $TimeRange; 
                        PlaytimeSeconds = $activeSeconds 
                    }
                    
                    $SessionsArray += $newSession
                    $dayEntry.Sessions = $SessionsArray
                    $dayEntry.DailyTotalSeconds += $activeSeconds
                    $data.GrandTotalSeconds += $activeSeconds

                    # Save specific property back to the main object
                    $allData.$shortHWID = $data
                    $allData | ConvertTo-Json -Depth 5 | Set-Content $DataFile

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
                        $logContent += ""
                        $logContent += "========================================="
                        $logContent += ""
                    }

                    $gTotal = [TimeSpan]::FromSeconds($data.GrandTotalSeconds)
                    $gTime = "$([math]::Floor($gTotal.TotalHours)) hours, $($gTotal.Minutes) minutes, $($gTotal.Seconds) seconds"
                    $logContent += "All Total Accumulated :"
                    $logContent += ""
                    $logContent += $gTime
                    $logContent += ""
                    $logContent += ""
                    $logContent += "Note :"
                    $logContent += "The final grand total from this log will be used" 
                    $logContent += "to calibrate the upcoming Phase 2 'Fuel Gauge' script"
                    $logContent += "for estimating the battery level of your controller."

                    $logContent | Set-Content $LogFile

                    # UI Update
                    $sTotal = [TimeSpan]::FromSeconds($activeSeconds)
                    $sTime = "$([math]::Floor($sTotal.TotalHours)) hours, $($sTotal.Minutes) minutes, $($sTotal.Seconds) seconds"
                    Write-Host ">>> Results :" -ForegroundColor Yellow
                    Write-Host "Session Total : $sTime" -ForegroundColor White
                    Write-Host ""
                    Write-Host "=========== Accumulation ==========" -ForegroundColor Magenta
                    Write-Host "Daily Total: $dTime" -ForegroundColor Cyan
                    Write-Host "Grand Total: $gTime" -ForegroundColor Green
                    Write-Host ""
                    Write-Host "Log file successfully updated." -ForegroundColor DarkGray
                    Write-Host ""
                    
                    # SEAMLESS AUTO-RESTART
                    Write-Host "Preparing next session..." -ForegroundColor DarkGray
                    Start-Sleep -Seconds 3
                }
            }
        }
    }
} catch {
    Write-Host ""
    Write-Host "=========================================" -ForegroundColor Red
    Write-Host "FATAL ERROR OCCURRED!" -ForegroundColor Red
    Write-Host "=========================================" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Please screenshot this error." -ForegroundColor DarkGray
    $null = Read-Host "Press Enter to exit..."
}
