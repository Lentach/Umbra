# Umbra

End-to-end encrypted messenger built with Flutter and NestJS.
*(Internal codename: Fireplace — code identifiers, storage keys, and paths keep that name by design; see `CLAUDE.md` §2.)*

**Production:** https://fireplace.ignorelist.com

---

## Features

- **End-to-end encryption** — Signal Protocol (X3DH + Double Ratchet) for all message types
- **Real-time messaging** — Socket.IO with delivery receipts (SENDING -> SENT -> DELIVERED -> READ)
- **Message types** — Text, Voice, Image, GIF (Giphy), File attachments, Ping
- **Disappearing messages** — configurable timer per conversation (default 24h)
- **Friend system** — Discord-style username#tag, friend requests, block/unblock
- **Reactions** — 6-emoji reaction picker, max one per user per message
- **Link previews** — OG metadata fetch with SSRF protection
- **Voice messages** — hold-to-record, waveform display, playback speed 1x/1.5x/2x
- **Anti-Quantum Notes** — one-time self-destructing encrypted notes (shareable link)
- **3 themes** — Light, Dark (Wire-style), Blue (Telegram-style)
- **Polish / English** — full localization via Flutter l10n
- **Push notifications** — Dual channel: FCM (native Android/iOS) + standards-based Web Push VAPID (PWA)
- **Web + Mobile** — Flutter web + Android/iOS from single codebase

---

## Tech Stack

| Layer | Technology |
|---|---|
| Frontend | Flutter 3.x (Dart) |
| Backend | NestJS 11 (Node.js + TypeScript) |
| Database | PostgreSQL 16 |
| Real-time | Socket.IO 4 |
| Auth | JWT (HS256) |
| Encryption | Signal Protocol (libsignal_protocol_dart 0.7.4) |
| Media storage | Cloudinary |
| Push | FCM (native) + Web Push VAPID (PWA), content-free box wake-ups only |
| Containerization | Docker + Docker Compose |
| Production | OVH VPS (Ubuntu 24.04) + Nginx + Let's Encrypt |

---

## Quick Start

**Prerequisites:** Docker, Flutter 3.x, Chrome

Start backend + database:

    docker-compose up

Start frontend (separate terminal):

    cd frontend
    flutter run -d chrome

**Ports:** Backend :3000 | Database :5433 (host) -> :5432 (container)

**Before starting:** Kill stale Node processes if backend fails to bind:

    taskkill //F //IM node.exe

### Phone (same WiFi)

    cd frontend
    .\run_web_for_phone.ps1

Or manually:

    flutter run -d web-server --web-hostname 0.0.0.0 --web-port 8080 --dart-define=BASE_URL=http://YOUR_PC_IP:3000

---

## Environment Variables

Set in docker-compose.yml or a .env file:

    DB_HOST=db
    DB_PORT=5432
    DB_USER=postgres
    DB_PASS=postgres
    DB_NAME=chatdb
    JWT_SECRET=your-secret-at-least-32-chars

    # Cloudinary (required for media)
    CLOUDINARY_CLOUD_NAME=your-cloud
    CLOUDINARY_API_KEY=your-key
    CLOUDINARY_API_SECRET=your-secret

    # Optional
    FIREBASE_SERVICE_ACCOUNT=...             # Box wake-up push, native (JSON string)
    WEB_PUSH_VAPID_PUBLIC_KEY=...            # Box wake-up push, Web Push (PWA) public key
    WEB_PUSH_VAPID_PRIVATE_KEY=...           # Web Push private key (backend only)
    WEB_PUSH_VAPID_SUBJECT=mailto:admin@...  # VAPID subject
    ALLOWED_ORIGINS=https://your-domain.com  # CORS (comma-separated)
    GIPHY_API_KEY=your-key                   # GIF picker (beta key used in dev)

For web subscribe flow, pass the same public key to Flutter:

    flutter run -d chrome --dart-define=WEB_PUSH_VAPID_PUBLIC_KEY=YOUR_PUBLIC_KEY

---

## Architecture

### Frontend Providers

State management uses 7 ChangeNotifier providers, orchestrated by ConnectionProvider:

| Provider | Responsibility |
|---|---|
| ConnectionProvider | Socket lifecycle, event routing to sub-providers |
| ConversationsProvider | Conversation list, unread counts, pending navigation |
| MessagingProvider | Message state, send/receive, E2E encrypt/decrypt |
| FriendsProvider | Friends list, friend requests, block/unblock, search |
| EncryptionProvider | Signal key management, session establishment |
| AuthProvider | Login, logout, JWT, current user |
| SettingsProvider | Theme (light/dark/blue), locale (pl/en) |

### Backend Services

ChatGateway delegates to 6 focused domain services:

| Service | Responsibility |
|---|---|
| ChatKeyExchangeService | Upload key bundles, fetch pre-keys |
| ChatPresenceService | Typing indicators, voice recording relay |
| ChatSearchService | User search |
| ChatDeviceListService | Signed device lists |
| ChatDeviceRevocationService | Device revocation |
| ChatProvisioningService | Linking a new device |

### E2E Encryption

All message content is encrypted client-side before leaving the device. The server stores ciphertext only — it cannot read any message content.

- **Protocol:** Signal (X3DH key agreement + Double Ratchet for forward secrecy)
- **Scope:** All message types — text, ping, voice URLs, image URLs, GIF URLs, file names
- **Media files** on Cloudinary are **not** encrypted — only the URLs are hidden inside the E2E envelope
- **Storage:** Keys in flutter_secure_storage + SharedPreferences (DualStorage for web reliability)
- **Key exchange:** 20 one-time pre-keys uploaded at login; auto-replenish when < 10 remain
- **No plaintext fallback:** if encryption fails, message is marked failed

---

## Running Tests

Backend (152 unit tests, no DB required):

    cd backend && npm test

Frontend (61 widget tests):

    cd frontend && flutter test

---

## Project Structure

    fireplace/
    +-- backend/src/
    |   +-- auth/              # JWT auth, registration, login
    |   +-- users/             # User entity, profile, account management
    |   +-- key-bundles/       # Signal public key storage, device lists, identity reset
    |   +-- box/               # Sealed-sender message box (/box, /box/media, wake-up push)
    |   +-- link-preview/      # POST /messages/link-preview (SSRF-guarded OG fetch)
    |   +-- secret-notes/      # Anti-Quantum one-time notes
    |   +-- chat/
    |       +-- chat.gateway.ts      # WebSocket entry point (thin delegation)
    |       +-- services/            # 6 focused domain services
    |       +-- dto/                 # Validated request DTOs
    |       +-- mappers/             # Payload serialization
    +-- frontend/lib/
        +-- models/            # UserModel, ConversationModel, MessageModel, ...
        +-- providers/         # 7 ChangeNotifier providers
        +-- services/          # SocketService, ApiService, EncryptionService, ...
        +-- screens/           # Auth, MainShell, Conversations, Chat, Contacts, ...
        +-- widgets/
        |   +-- message/       # ChatMessageBubble + per-type content widgets
        |   +-- input/         # ChatInputBar, RecordingController, AttachmentHandler
        |   +-- audio/         # PlaybackController, WaveformDisplay
        +-- theme/             # FireplaceColors ThemeExtension (3 themes)
        +-- l10n/              # Polish + English ARB files

---

## Deployment

Production is an **OVH VPS** (`ubuntu@51.68.138.13`, Warsaw) serving
`https://fireplace.ignorelist.com`. Deploy is **split** because the small VM
cannot compile the Flutter web bundle (dart2js OOM):

    # Backend — on the VM (builds the Docker image, runs migrations, verifies /health):
    cd ~/fireplace && ./deploy-backend.sh

    # Frontend — on your PC (builds web, publishes via atomic swap to the VM):
    git pull ; .\deploy-web.ps1

Verify: `curl -sS https://fireplace.ignorelist.com/version` and `/health`.
Full runbook: `.omp/rules/production-vm-deploy.md`. (The legacy `deploy.sh`
is disabled — it targeted the decommissioned GCP VM and the dev compose.)

Stack: Docker + Nginx reverse proxy + Let's Encrypt TLS.

---

## Username Format

Discord-style username#tag — a 4-digit tag (1000-9999) assigned randomly at registration. Usernames are unique (case-insensitive). Login accepts username or username#tag.
