# Providers

Generated from `Provider` and each wire's `WireCapabilities` by `swift run herdr-voice providers > docs/providers.md`.
Don't edit it by hand: a test fails when it differs from the generator, and WireConformanceTests holds every
wire to its row. `scripts/provider-contract` checks the cloud rows against the live APIs.

| Provider | Model | Endpoint | `explicitReplies` | `nativeResumption` | `dynamicTools` | `explicitSpeechOnsets` | `turnEpochs` | `setupHandshake` | `metered` | `deferredReplies` | `clearsInput` |
|---|---|---|---|---|---|---|---|---|---|---|---|
| Local OpenLive (`local`) | `qwen3.5:4b` | `ws://127.0.0.1:<port> (the helper's loopback port)` | yes | no | no | yes | yes | yes | no | no | yes |
| GPT (`openai`) | `gpt-realtime-2.1` | `wss://api.openai.com/v1/realtime` | yes | no | yes | no | no | no | yes | yes | yes |
| Grok (`grok`) | `grok-voice-3.0` | `wss://api.x.ai/v1/realtime` | yes | no | yes | no | no | no | yes | no | yes |
| Gemini (`gemini`) | `gemini-3.8-live` | `wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent` | no | yes | no | no | no | no | yes | no | no |

Models are the defaults: HERDR_VOICE_GEMINI_MODEL picks another Gemini model, and HERDR_LOCAL_BRAIN_MODEL
another brain for Local OpenLive.

- `explicitReplies`: the session requests, cancels and truncates replies; otherwise the provider answers by itself
- `nativeResumption`: a session resumes from a handle with its context, so no recap is sent
- `dynamicTools`: tools and instructions can be replaced mid-session; otherwise only at setup
- `explicitSpeechOnsets`: no server VAD: the session marks each utterance's start and end and asks for its reply
- `turnEpochs`: each onset or clear starts an epoch, and work from older epochs is dropped
- `setupHandshake`: the session is up only once the setup is acknowledged (sessionReady)
- `metered`: billed by use, so a quiet session is closed until you speak
- `deferredReplies`: the session can hold the reply to a spoken turn until it asks for one (deferReplies)
- `clearsInput`: a mute drops what the provider buffered of your speech; otherwise the mic just stops
