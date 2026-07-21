# Speakeasy Mac Setup

This is the local Mac checklist for unattended Speakeasy development. It avoids
secret values and focuses on toolchain readiness.

## Current Target

- Apple Silicon Mac (`arm64`)
- Xcode installed at `/Applications/Xcode.app`
- Homebrew installed at `/opt/homebrew`
- Go installed through Homebrew
- Docker Desktop installed through Homebrew
- Xcode command line tools selected with:

```bash
xcode-select -p
xcodebuild -version
```

If `xcode-select -p` points at `/Library/Developer/CommandLineTools`, switch
back to full Xcode before normal iOS work:

```bash
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
```

For one-off commands where changing the global developer directory is
inconvenient, set `DEVELOPER_DIR`:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -version
```

## Install Homebrew

Homebrew is the easiest way to install Go and Docker Desktop on this Mac.

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

On Apple Silicon, add Homebrew to zsh after the installer finishes:

```bash
echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> ~/.zprofile
eval "$(/opt/homebrew/bin/brew shellenv)"
brew doctor
```

If macOS opens a Command Line Tools installer and reports that the software is
not available from the Software Update server, dismiss the popup and let the
terminal step finish or fail. This Mac already has full Xcode installed, so try
the full-Xcode first-launch path before retrying Homebrew:

```bash
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -runFirstLaunch
sudo xcodebuild -license accept
```

Then run the Homebrew installer again. If Homebrew still requires Command Line
Tools, download the matching "Command Line Tools for Xcode" package directly
from Apple's developer downloads in the browser and install the `.pkg` locally.
Match the package to the installed Xcode version from `xcodebuild -version`;
do not grab Apple's newest Command Line Tools package unless macOS and Xcode are
also being updated to match. For example, a `Command Line Tools for Xcode 26.x`
package can require a newer macOS than a machine with Xcode 16.2 has installed.
Do not paste Apple credentials into chat.

If a failed installer leaves a partial Command Line Tools directory behind,
remove only that directory before installing the matching `.pkg`:

```bash
sudo rm -rf /Library/Developer/CommandLineTools
```

After the matching package installs and Homebrew succeeds, switch back to full
Xcode for iOS work:

```bash
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
```

## Install Required Tools

```bash
brew update
brew install go
brew install --cask docker-desktop
```

After installing Docker Desktop, open it once and complete any macOS prompts for
the privileged helper and file access:

```bash
open -a Docker
```

Do not paste Apple, GitHub, Docker, or other account secrets into chat. If a GUI
asks for your Mac password, enter it directly in the macOS prompt.

## Verify Tools

From the repo root:

```bash
go version
gofmt -w server/internal/api/server_test.go
cd server
go test ./...
cd ..
docker version
docker compose version
docker compose config
docker compose up --build
```

In another terminal, confirm the relay is alive:

```bash
curl http://localhost:8080/healthz
```

Stop the relay with `Control-C`. If running detached later, use
`docker compose down`.

## Verify iOS

Unsigned simulator builds do not require Apple signing secrets:

```bash
xcodebuild build \
  -project ios/Kithra.xcodeproj \
  -scheme Kithra \
  -configuration Debug \
  -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/KithraDerivedData \
  CODE_SIGNING_ALLOWED=NO
```

To run the app visually, open `ios/Kithra.xcodeproj`, select the shared
`Kithra` scheme, choose an installed simulator such as iPhone 16, and press Run.

## Keep The Mac Awake

For a one-night unattended work session, plug the Mac into power and run this in
a Terminal window you leave open:

```bash
caffeinate -ims
```

This prevents idle, disk, and system sleep while allowing the display to turn
off normally. Stop it later with `Control-C`.

For a persistent setting, use System Settings:

1. Open System Settings.
2. Go to Battery.
3. Open Options.
4. Enable the setting that prevents automatic sleep while connected to power.
5. Keep the Mac plugged in and on a stable network.

## Ready For Overnight Agent Work

Before leaving Codex running:

```bash
git status --short --branch
go test ./...
xcodebuild build \
  -project ios/Kithra.xcodeproj \
  -scheme Kithra \
  -configuration Debug \
  -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/KithraDerivedData \
  CODE_SIGNING_ALLOWED=NO
docker compose config
```

Make sure Docker Desktop is running before asking Codex to verify relay behavior
with Docker Compose.
