# DualShock-Battery-Tracker

WIP WIP WIP

A simple PowerShell script to track the battery life of modded DS4 controllers.

### The Backstory
So here's the story: I did a battery capacity mod on my DS4 controller a while ago. The problem? The controller's internal hardware has absolutely no idea how to measure the new battery's real percentage. It will literally flash 0% and warn me it's dying after just an hour of playing, even though I know for a fact this beefy battery can easily last 18+ hours.

Since I still haven't figured out how to intercept the actual raw voltage data, I decided to build a "dumb" workaround. If Windows can't read the battery, I'll just track the time. 

**Phase 1 (Current State):** This script is purely a stopwatch. You charge your modded controller to 100%, connect it, and the script tracks your playtime across multiple days until the controller physically dies. This gives us our baseline data.

**Phase 2 (Coming Soon):** The Fuel Gauge. Once we have that baseline data from Phase 1, the timer flips. The script will look at your tracked playtime and calculate an estimated real battery percentage based on the time you have left.

It might sound dumb, and it won't be scientifically accurate, but honestly? It's way better than just guessing when my controller is going to randomly shut off mid-game. Plus, it's a fun first project and I was just bored.

### Small simple features :
* **Sleep detection:** Pauses the timer if your PC goes to sleep or hibernates so your playtime data doesn't get inflated.
* **Multi-controller support:** You can save a few different controllers and switch between them.
* **Autosaves:** Writes the data safely so you don't lose your logs if the script closes or your PC crashes.
* **Simple auto DS4 launch:** An optional setting to automatically open and close DS4Windows when you start or stop tracking.
* **Desktop Shortcut:** Automatically makes shortcut on your desktop. 

### How to Use
1. Download the `Tracker.ps1` file.
2. Right-click the file and select "Run with PowerShell".
3. The setup will guide you through connecting your controller and saving your settings.

and I was just bored.. 
