# zbm-void-ts

ZFSBootMenu on Void Linux UEFI with Tailscale

## Overview

I tried getting ZFSBootMenu to work with Tailscale at the initramfs level using the [official documentation](https://docs.zfsbootmenu.org/en/latest/general/tailscale.html) as well as [ZQuickInit](https://github.com/midzelis/zquickinit), but DHCP never worked right for me so I put together this script to run it post-boot a [single, unencrypted UEFI disk](https://docs.zfsbootmenu.org/en/latest/guides/void-linux/uefi.html) that automatically boots. If you want to try out ZFS on Linux, this is the easiest method I've found.

## Instructions

1. Download the latest [hrmpf](https://github.com/leahneukirchen/hrmpf/releases) ISO image
2. Load the image on to a bootable USB using [balenaEtcher](https://etcher.balena.io/)
3. Insert the bootable USB into the device and power on (note: you may need to select a function key or bios option to boot into it)
4. SSH into the device via the user **anon** and password **voidlinux**
5. Create a free [Tailscale account](https://login.tailscale.com/start)
6. On the **Access Controls** tab, replace the existing code with:

```
{
	"tagOwners": {
		"tag:server": [
			"autogroup:admin"
		],
		"tag:admin": [
			"autogroup:admin"
		]
	},
	"acls": [
		{
			"action": "accept",
			"src": [
				"tag:admin"
			],
			"dst": [
				"tag:server:22"
			]
		},
		{
			"action": "accept",
			"src": [
				"autogroup:member"
			],
			"dst": [
				"autogroup:internet:*"
			]
		}
	],
	"ssh": [
		{
			"action": "accept",
			"src": [
				"tag:admin"
			],
			"dst": [
				"tag:server"
			],
			"users": [
				"autogroup:nonroot",
				"root"
			]
		}
	]
}
```

7. On the **DNS** tab, enter your desired nameservers and enable the _Override DNS servers_ option
8. On the **Settings** tab, click on the **Keys** option in the left-hand column
9. Click the **Generate auth key...** button
10. Keep the defaults and click the **Generate key** button
11. Save the resulting key code in a safe, temporary location
12. In the hrmpf SSH terminal, run `curl -s -o /tmp/zbm-void-ts.sh https://raw.githubusercontent.com/ascension-association/zbm-void-ts/refs/heads/main/zbm-void-ts.sh && sudo bash /tmp/zbm-void-ts.sh`
13. Follow the prompts to install
14. After the installation and reboot, the device will appear in Tailscale under the **Machines** tab

## TODO

- Encryption
- SSH key authentication
