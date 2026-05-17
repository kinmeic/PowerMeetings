# PowerMeetings

Live memory for serious meetings.

A native macOS app that captures, transcribes, and translates your meetings in real time — then distills them into searchable minutes, decisions, and action items with AI.

## Features

- **Live Transcription** — Real-time speech-to-text using Apple's Speech framework, supporting Mandarin Chinese and English simultaneously
- **Instant Translation** — Translates transcripts into your local language via an OpenAI-compatible API (OpenAI, Ollama, LM Studio, etc.)
- **Audio Recording** — Captures meetings as M4A files with pause/resume support, exportable to any location
- **AI Summaries** — Generates meeting minutes with decisions, action items, and open questions
- **Agent Assistant** — An integrated chat agent panel that surfaces likely questions, suggested replies, and follow-up actions
- **Multi-Device Input** — Select any microphone or external audio input device for capture

## Requirements

- macOS 14 (Sonoma) or later
- Swift 6.0
- Xcode 16+
- An OpenAI-compatible API endpoint for translation and summary features (optional — transcription works without it)

## Build & Run

```bash
git clone https://github.com/<your-username>/PowerMeetings.git
cd PowerMeetings
swift build
swift run PowerMeetings
```

For a fully bundled macOS app with Dock icon and menu bar:

```bash
Scripts/build_app.sh
open dist/PowerMeetings.app
```

Note: `swift run` starts a raw executable, not a bundled `.app`, so Dock/menu behavior can be incomplete.

## Configuration

Open **Settings** (gear icon) to configure:

| Setting | Description |
|---|---|
| **Provider** | OpenAI, OpenAI Compatible, Ollama, or LM Studio |
| **API Base URL** | Endpoint for translation and summary calls |
| **API Key** | Your provider's API key |
| **Realtime Model** | Model used for live translation (e.g. `gpt-4o-realtime-preview`) |
| **Translation Model** | Model used for batch translation (e.g. `gpt-4.1-mini`) |
| **Local Language** | Target language for translations (Chinese / English) |

Transcription via Apple Speech Recognition works without any API configuration.

## How It Works

1. **Start Meeting** — Grants microphone + speech recognition permissions, begins audio capture and live transcription
2. **Live View** — Watch transcripts appear in real time, with optional inline translations
3. **Pause / Resume** — Audio and transcription pause together; recording continues as segments
4. **End Meeting** — All segments merge into a single M4A, and an AI summary is generated
5. **Playback & Export** — Review the recording in-app or export the M4A file

## Architecture

```text
PowerMeetingsApp          — App entry point & scene registration
├── MainView              — Three-column NavigationSplitView
│   ├── MeetingListView   — Sidebar: meeting list, search, create/delete
│   ├── MeetingWorkspace  — Center: audio controls, transcript timeline, summary
│   └── AgentPanelView    — Detail: chat agent for questions & suggestions
│
├── Services
│   ├── AudioCaptureEngine    — AVCaptureSession-based recording with pause/resume
│   ├── LiveSpeechTranscriber — Apple Speech Recognition (SFSpeechRecognizer)
│   ├── AudioDeviceManager    — Input device discovery & selection
│   └── MeetingAIClient       — OpenAI-compatible HTTP client for translation/summary
│
├── Stores
│   ├── MeetingStore          — CRUD for meetings, segments, agent messages (persisted to JSON)
│   └── ModelSettingsStore    — @AppStorage-backed model configuration
│
└── Models                 — Meeting, Participant, TranscriptSegment, AgentMessage, etc.
```

## Chat Agent Integration

The Agent panel connects to an external WorkAgent endpoint:

- Stream path: `/api/agent/chat/stream`
- Auth: `Authorization: Bearer <token>`
- Payload: `message`, `conversation_id`, and `history`

Configure the host, port, base path, and auth token in Settings.

## License

MIT