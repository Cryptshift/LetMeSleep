# LetMeSleep

An iPhone app for when someone is NOT LETTING YOU SLEEP. Maybe your roommate is playing League at 2 AM. LetMeSleep listens to how loud your room is, and when it stays loud for a while, your own Discord bot sends them a DM asking them to keep it down.

## What it does

- Meters the microphone four times a second and smooths it into a 1-second rolling average.
- When the level stays above your threshold for a set time (default 5 seconds), your Discord bot DMs the person you picked. The default message is:
  > It's getting pretty loud: about -32 dB for the last 5 seconds. Mind keeping it down? 🙏
- Sends at most one message per cooldown period (default 5 minutes), no matter how long the noise goes on.
- Keeps listening with the screen locked, and doesn't stop music or white noise you have playing.
- Only measures loudness. Audio is never recorded, saved or uploaded.

## Requirements

- Xcode 26 (tested with 26.2). The project uses Swift 6.
- An iPhone running iOS 17 or later. The Simulator works for trying the UI, but it uses your Mac's microphone.
- A Discord bot (free; setup below).

## Build and run

```sh
git clone https://github.com/Cryptshift/LetMeSleep.git
cd LetMeSleep
open LetMeSleep.xcodeproj
```

To run on your iPhone, select the **LetMeSleep** target, open **Signing & Capabilities**, choose your team, and change the bundle identifier if Xcode asks you to.

From the command line:

```sh
# Build
xcodebuild -scheme LetMeSleep -destination 'generic/platform=iOS Simulator' build

# Run the unit tests (pick any installed simulator)
xcodebuild -scheme LetMeSleep -destination 'platform=iOS Simulator,name=iPhone 17' test
```

## Set up the Discord bot

1. Go to the [Discord Developer Portal](https://discord.com/developers/applications), click **New Application**, then open the **Bot** tab and click **Reset Token**. Copy the token. It's a password for your bot, so treat it like one.
2. Invite the bot to a server that the person you want to message is also in. Under **OAuth2 › URL Generator**, tick the `bot` scope (no permissions are needed), open the generated URL, and pick the server. A small private server with just the two of you works fine.
3. Get the person's user ID: in Discord, turn on **User Settings › Advanced › Developer Mode**, then right-click (or long-press) them and choose **Copy User ID**.
4. In LetMeSleep, tap the gear, paste the token and the user ID, and tap **Send test message**.

**Why the bot must share a server with them:** Discord only lets a bot DM people it shares a server with, and only if they allow DMs from members of that server (their **Privacy & Safety** settings). If not, Discord rejects the message and the app shows "Discord won't let the bot DM this user".

## Using it

1. Turn on **Listen for noise** and allow microphone access when iOS asks.
2. Pick a sensitivity (**Sensitive**, **Normal** or **Sleeping**).
3. Watch the live meter for a minute and adjust the thresholds in Settings to suit your room.
4. Leave the app running. You can lock the phone. iOS shows the orange microphone dot while it's listening.

Keep the phone plugged in overnight. If a phone call or another app takes the microphone, LetMeSleep pauses and picks up again when it's done. If you force-quit the app, it stops listening.

## About the numbers (dBFS)

The levels are **dBFS** (decibels relative to full scale): 0 is the loudest sound the microphone can report, and quieter sounds are more negative (-60 is quieter than -20). They are **not** calibrated sound-pressure decibels (dB SPL), so "-40 dBFS" does not mean "40 dB". The same room reads differently on different iPhone models, in a case, or in another spot. That's why the thresholds are adjustable and the meter is there. The `{db}` in the message is the same dBFS number.

## Settings

| Setting | Default | What it does |
| --- | --- | --- |
| Bot token | — | Your Discord bot's token. Stored in the Keychain. |
| Recipient user ID | — | Numeric Discord user ID of the person to message. |
| Thresholds | Sensitive -60, Normal -40, Sleeping -20 dBFS | The level each sensitivity has to exceed. |
| Loud for at least | 5 s | How long it must stay loud before a message is sent. Short pauses of up to 1 s don't reset the timer. |
| Wait between messages | 5 min | Cooldown between messages. |
| Message | see above | Your text. `{db}` is replaced with the level and `{seconds}` with how long it was loud. |

## Privacy and security

- **Your bot token stays in the iOS Keychain** on this iPhone (readable after the first unlock, so alerts still work while the phone is locked). It is never written to UserDefaults, logs or the project files.
- **Never put your token in the source code, and never commit it.** This repository is public. Anyone with the token can control your bot. If a token ever leaks, reset it in the Developer Portal right away.
- Audio goes to `/dev/null`. Only the loudness level is read. Messages go straight from your phone to Discord's API.

## Limitations

- The microphone also hears sound playing from the phone itself, so white noise played from the same phone can push the level up. Account for it when picking a threshold.
- iOS can still stop the app, for example if you force-quit it or the system restarts.
- Don't share a build of the app that has your token in it.

## Project layout

```
LetMeSleep/
  Alerting/   Rolling average, sustain/cooldown logic, message template
  Audio/      SoundMonitor: microphone, audio session, interruptions
  Discord/    Discord REST client and Retry-After parsing
  Settings/   Settings keys and defaults, Keychain storage
  Views/      Main screen, level meter, settings
LetMeSleepTests/  Unit tests (Swift Testing)
```

## License

MIT. See [LICENSE](LICENSE).
