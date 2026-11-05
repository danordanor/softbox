# Softbox

I design Softbox. Claude builds it. These are the rules for working in this repo.

## What Softbox is

A calm controller for one light: the Elgato Key Light Air MK.2. A Mac menu-bar app, an iPhone app, a home-screen widget, Shortcuts actions, and a soft signal for Claude Code. Calm is the product. If a change makes the light or the app louder, it's wrong, however well it works.

## Who decides

- I decide what the product does, what each screen shows and leaves out, the defaults, and when a version ships.
- You write the code and say what you changed in plain words.
- If a request is unclear, or there are two reasonable ways to do it, ask before building. Don't guess on anything I'll see.
- Don't add settings, screens or features I didn't ask for. Suggest them instead.

## The light

- Nothing blinks. Every change glides: ask the light for a slow fade and let it do the gliding.
- Effects change brightness only, never the colour.
- `lightd` keeps one connection open and paces requests. The firmware dislikes many connections in a row.
- Brightness is 0 to 100 of what the power supply allows. Show the cap honestly; never fake full brightness.
- A signal that fires too often stops meaning anything. New signals start off by default.

## The interface

- The whole light is the control: left to right is warm to cool, bottom to top is brightness.
- No loaders when there's something true to show. Open on the last known state and let the light take over when it answers.
- No text where the object can speak for itself (the widget has none).
- Same wording on Mac, iPhone and web.

## Before you say it's done

- Run it against `test/mocklight.py` when there's no light: `python3 test/mocklight.py`, then `LIGHTD_HOME=/tmp/sb LIGHTD_WEB=1 python3 mac/lightd.py` with `{"hosts": ["127.0.0.1"]}` in the test config.
- Tell me what to check on the real light, the Mac or the iPhone. I test on the device before a change stays.
- If something fails, say what failed and why, in one line. Error messages in the installer and the release pipeline should do the same for the person running them.

## Never

- Commit `~/.softbox`, `client.key`, `client-chain.crt`, `Softbox.p12` or `Local.xcconfig`. They're derived from Elgato's key or hold my signing details.
- Commit or print secrets from the release workflow.
- Rename the Shortcuts actions or the local API routes without asking. People's automations depend on them.

## Commits and releases

- One change per commit. The subject says what changed for the person using it, not which file moved: "iPhone: notice a lost network at once", not "update LightController.swift".
- The body explains why, in plain sentences, when the subject isn't enough.
- A release is a version tag (`git tag v1.x.y && git push origin v1.x.y`). See `docs/RELEASING.md`. Don't tag without me.

## Writing

README, release notes and the site are short and plain. No buzzwords, no exclamation marks. Show what it does; don't describe how amazing it is.
