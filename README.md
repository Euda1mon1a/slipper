<p align="center"><img src="https://raw.githubusercontent.com/Euda1mon1a/slipper/main/docs/icon/icon-256.png" width="128" alt="Slipper icon"></p>

# Slipper

Turn a local web app into a Mac app you keep in the Dock.

A slip is a boat's berth at a dock, and Slipper slips your web app into the Dock.

Point it at a Next.js, Vite, Flask or FastAPI project, or a static folder. Opening the app
starts the server in a Terminal window, waits for it to answer, and opens the browser.
Closing the window stops the server. No Xcode and no signing.

## Install

```bash
brew install euda1mon1a/tap/slipper
```

Or run it from a clone:

```bash
git clone https://github.com/Euda1mon1a/slipper.git
slipper/slipper --help
```

It needs macOS 12 (Monterey) or later and nothing else: it uses `sips`, `iconutil`, `plutil`
and Terminal, which ship with the system.

## Usage

```bash
slipper --name "My App" --icon icon.png --port 3000 \
  --workdir ~/projects/my-app --start-cmd "npm run dev"
```

That creates `~/Desktop/My App.app`. Open it once from Finder, then keep it in the Dock: drag
it there, or right-click its Dock icon and choose Options > Keep in Dock.

| Option | Required | What it does |
|---|---|---|
| `--name NAME` | yes | Name shown in Finder and the Dock |
| `--port PORT` | yes | Port the server listens on |
| `--start-cmd CMD` | yes | Command that starts the server, run with `/bin/zsh` |
| `--icon IMAGE` | no | Square image for the icon; 1024x1024 PNG is best. Without it, macOS shows the generic app icon |
| `--output PATH` | no | Where to create the app (default `~/Desktop/NAME.app`); an existing folder puts `NAME.app` inside it |
| `--workdir DIR` | no | Folder the commands run in (default: your home folder) |
| `--venv DIR` | no | Python virtual environment to activate first |
| `--install-cmd CMD` | no | Command to run on the first launch, and again if you change it (for example `npm install`) |
| `--url URL` | no | Page to open (default `http://localhost:PORT`) |
| `--wait SECONDS` | no | How long to wait for the server to answer before opening the page anyway (default 30) |
| `--force` | no | Replace an existing app that Slipper did not create; the old one is kept beside it, renamed |

### Examples

A Vite or React project:

```bash
slipper --name "My React App" --icon react.png --port 5173 \
  --workdir ~/projects/my-app --install-cmd "npm install" --start-cmd "npm run dev"
```

A FastAPI backend in a virtual environment:

```bash
slipper --name "Notes API" --icon notes.png --port 8000 \
  --workdir ~/projects/notes --venv ~/projects/notes/.venv \
  --start-cmd "uvicorn app:app --port 8000" --url http://localhost:8000/docs
```

A static folder:

```bash
slipper --name Dashboard --port 8080 \
  --workdir ~/projects/dashboard --start-cmd "python3 -m http.server 8080"
```

## What it creates

```
My App.app/
  Contents/
    Info.plist                 bundle metadata, written with plutil
    MacOS/My_App               hands the launcher to Terminal
    Resources/
      launcher.command         starts the server; the same file in every app
      slipper.conf             this app's settings
      AppIcon.icns             built from --icon
```

Everything lives inside the app, so you can move it anywhere. To change the command or port
later, edit `slipper.conf` or run Slipper again with the same `--output`. It replaces apps it
made without asking (keeping their ID), and refuses to touch any other app unless you pass
`--force`. Two Slipper runs on the same app never overlap: the second is turned away until
the first finishes.

Each app gets a random ID when it is first made, and its bundle ID is `local.slipper.<ID>`.
The launcher keys its small state files on that ID plus the app's own location, so two apps
never collide even with the same name, and a duplicated copy keeps its own state. Moving an
app runs its install command once more.

## What happens when you open it

1. Terminal runs a .command file by typing its path into a shell, and an app's path can hold
   any character. So each launch writes a one-time shim under `~/Library/Caches/Slipper/`,
   at a path of plain characters, and Terminal opens that. The shim deletes itself and runs
   the app's launcher.
2. If something already listens on the port and it is the server this app started, the
   launcher opens the browser and exits. Anything else on the port counts as another program,
   including a server this app's command handed off to Docker Desktop or `brew services`. The
   launcher shows what it is and asks before stopping it, and never force-kills.
3. It changes to `--workdir` (or your home folder), activates `--venv`, and runs
   `--install-cmd` if it has not run yet. A record of the install command and the running
   server's PID are kept in `~/Library/Application Support/Slipper/`.
4. It runs `--start-cmd` and waits up to `--wait` seconds for the URL to answer. A command that
   fails stops there with its exit status. A command that exits 0 is assumed to have started
   the server in the background, so the wait continues.
5. It opens the browser. Closing the Terminal window, or Ctrl-C, stops the server and its
   child processes. A server that detached itself into the background keeps running.

Commands run in the Terminal window, so they get the `PATH` your login shell sets up
(Homebrew, nvm, pyenv and so on).

## Limits

- The app is unsigned. An app you build on your own Mac opens normally. If you copy it to
  another Mac through a browser, AirDrop or email, macOS treats it as downloaded and blocks the
  first launch; allow it once in System Settings > Privacy & Security.
- It uses Terminal. Other terminal apps are not supported.
- A home folder whose path has spaces or other unusual characters can't open Slipper apps;
  the app shows an alert saying so instead of handing Terminal an unsafe path.
- The readiness check only asks whether `--url` answers. It doesn't verify HTTPS certificates,
  so a local server with a self-signed certificate counts as ready.
- Apps made by earlier private versions of this tool count as apps Slipper did not create.

## Why it is built this way

Earlier hand-built wrappers tried other routes first, on macOS 26:

- **An AppleScript app (`osacompile`)** needs Automation permission to control Terminal, and
  the request was blocked without a prompt: "Not authorized to send Apple events to Terminal
  (-1743)".
- **A custom icon through `osacompile -i`** was overridden by the bundle's `Assets.car`, and
  deleting `Assets.car` did not reliably fix it.
- **A `.command` file in the Dock** can only go on the right-hand side, where it looks like a
  document.

A plain bundle whose executable is a short shell script avoids all three. On some setups macOS
has offered to install Rosetta the first time such an app opens; the app works either way.

Icon tips: use a square image with no rounded corners (macOS applies its own mask) and no
transparency, with the background running to every edge.

## Tests

```bash
scripts/test.sh /tmp/slipper-test
```

The test builds apps with hostile names and paths into that new folder, runs them through the
Terminal shim and the launcher with stand-ins for `open` and `osascript`, and checks quoting,
the plist, the icon, port handling, signals and the replace rules. It never touches the Dock,
`/Applications` or your home folder.

## License

MIT. See [LICENSE](LICENSE).

Provided as-is; bug reports are welcome, fixes are not guaranteed.
