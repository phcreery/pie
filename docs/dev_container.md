## VSCode

### toolbx as devcontainer

Ctrl+Shift+P > Dev Containers: Open Container Configuration File

```json
{
	"workspaceFolder": "/home/phcreery/Documents/zig/pie",
	"extensions": [
		"ziglang.vscode-zig"
	],
	"remoteUser": "${localEnv:USER}",
	"remoteEnv": {
		"PATH": "/home/phcreery/.local/bin:/home/phcreery/bin:/usr/local/bin:/usr/bin",
		"DISPLAY": "${localEnv:DISPLAY}",
		"XDG_RUNTIME_DIR": "${containerEnv:XDG_RUNTIME_DIR}" // <-- THIS!!!
	},
	"settings": {
		"github.copilot.chat.codeGeneration.instructions": [
			{
				"text": "This workspace is in a dev container running on \"Fedora Linux 44 (Toolbx Container Image)\".\n\nUse `\"$BROWSER\" <url>` to open a webpage in the host's default browser.\n\nSome of the command line tools available on the `PATH`: `dnf`, `yum`, `rpm`, `git`, `curl`, `wget`, `ssh`, `scp`, `rsync`, `gpg`, `ps`, `lsof`, `top`, `tree`, `find`, `grep`, `zip`, `unzip`, `tar`, `gzip`, `bzip2`, `xz`"
			}
		],
		"zig.zls.enabled": "on",
		"zig.path": "/var/home/phcreery/.local/share/zvm/bin/zig",
		"zig.zls.path": "/var/home/phcreery/Downloads/zigscient-x86_64-linux_1/zigscient-x86_64-linux"
	}
}
```