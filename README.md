![Meetings — a dinosaur with glasses taking a call](app_icon_wide.png)

# Meetings

**Be in the conversation. Keep the notes.**

Meetings is a Mac app for recording conversations, turning them into searchable transcripts, and keeping track of what comes next. Use it for online calls or meetings in the room. No meeting bot to invite.

## Get Meetings

[**Download from GitHub Releases**](https://github.com/rb81/meetings/releases)

Requires **macOS 15 or later**. Signed Mac builds will be published on the Releases page; if there isn't a release yet, the first build is still on its way. Download the app, move it to Applications, and open it.

## What it does

- **Record online or in person.** Capture your microphone and call audio, or the voices around the table.
- **See the conversation as it happens.** Live transcripts, speaker labels, and names you can edit.
- **Find the important bits.** Search past meetings, flag moments, and revisit the recording alongside the transcript.
- **Get optional AI help.** Summaries, action items, and questions about your meeting, using Apple Intelligence, Ollama, OpenRouter, or an OpenAI-compatible provider you choose.
- **Keep your day in view.** Connect Calendar for upcoming meetings and optional reminders, or start a recording straight from the menu bar.

## Your first meeting

1. Download the speech model when prompted. It's saved on your Mac for future use.
2. Allow microphone access. Online calls also need the macOS permission for screen/system audio recording. Connect Calendar only if you want upcoming events.
3. Choose **Online** or **In Person**, then start recording. In-person speaker labels need an additional one-time model download of about 430 MB.
4. Pause whenever you need to. Stop when you're done to keep the transcript and recording. AI notes are optional; you don't need an API key to transcribe.

Always let people know you're recording and get the consent required where you are.

## Your meetings stay yours

Recordings and transcripts are saved on your Mac, in a folder you can choose. Transcription and speaker separation run locally after the models are downloaded. API keys are kept in macOS Keychain.

Cloud AI is optional. If you choose a cloud provider, the meeting text needed for that request is sent to that provider. For local AI, use Apple Intelligence (on supported Macs) or a local Ollama server.

**Offline mode** blocks remote AI and update checks. Model downloads still work when you explicitly request them. Links you open launch in your browser.

You can keep recordings or automatically delete the audio after transcription or after a set period.

## Updates

Meetings checks this repository's public GitHub Releases once a day while it's running and shows a notice when a newer stable version is available. You can also check in **Settings → Updates**, or turn automatic checks off.

Update checks send no meeting content to GitHub. Updates are never installed automatically: the notice takes you to the release so you can download it yourself.

## Issues

Found a problem or have an idea? [Open an issue](https://github.com/rb81/meetings/issues). Please leave out private recordings, transcripts, API keys, and personal details.

## License

[MIT](LICENSE). Built with [FluidAudio](https://github.com/FluidInference/FluidAudio). Dependencies and speech models have their own licenses.