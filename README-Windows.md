# LiveWall for Windows 11

This folder is a Windows 11 build of LiveWall. It downloads a selected MP4 to the user's local LiveWall cache and plays it as a desktop-level wallpaper behind the desktop icons.

## Build on Windows 11

Install Node.js 18 or newer, then in PowerShell run:

```powershell
cd WindowsApp
npm install
npm run start
npm run dist
```

The packaged files are created in `WindowsApp/dist/`: an installer and a portable `.exe`.

The Windows implementation uses Electron's Chromium video playback and a small PowerShell bridge to attach the wallpaper window to the Windows desktop WorkerW layer. It does not modify the Windows system wallpaper image and does not support YouTube downloads.
