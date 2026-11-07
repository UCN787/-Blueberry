# Blueberry

Blueberry is a responsive web messenger prototype backed by the configured Supabase project.

- `online.html` — live application.
- `supabase.js` — local bundled Supabase client, so the page does not need a third-party CDN just to load.
- `server.mjs` — tiny localhost static server; no npm dependencies.
- `supabase.sql` — repeatable schema/policy setup for the Supabase project.

## Current live features

- Email sign-up/sign-in, password reset email, profile and unique username.
- Private direct messages delivered through Supabase Realtime.
- Groups and public/private channels; group members can post, channel owners can publish, public rooms can be joined and usernames can be invited at creation.
- Username lookup, room search, current-chat message search, favorites, and light/dark theme.
- Reply, edit/delete own messages, one emoji reaction per message.
- Image avatar upload (2 MiB limit) and arbitrary message files (20 MiB limit) in private Supabase Storage, with RLS access checks. Images preview inline; audio and video attachments have in-chat playback.
- Attach files from the composer; image, audio, and video attachments can be previewed in chat. Video-message recording is intentionally disabled.
- Mobile layout, registration error messages, preserved login session.

## Run it

The database schema and policies are already installed in the connected Supabase project. To run locally, double-click `start-site.cmd`. It starts the server and opens the app at `http://localhost:4173/index.html`. Do not open `index.html` directly as `file://`: browser security blocks the local Supabase module and the buttons cannot initialize.

For a second person on another device, deploy the files in `outputs` to an HTTPS static host and share that URL. Set the hosted URL in Supabase **Authentication → URL Configuration**. The Supabase backend still needs to be reachable over the internet.

## GitHub Pages

The `index.html` file is the GitHub Pages entry point. Upload the contents of this folder to the root of a GitHub repository, then select **Settings → Pages → Deploy from a branch → main → /(root)**. After publishing, add the resulting `https://<account>.github.io/<repository>/` URL to the Supabase Auth redirect allow-list and set it as the Site URL if email confirmation or password recovery is enabled.

## Not implemented yet

Voice and video-note recording is not included. One-to-one and group calls, screen sharing, reliable scheduled delivery, polls/quizzes, stickers/GIF catalogs, stories, saved messages, folders/archive, member role management screens, moderation tools, comments/statistics/livestreams, secret chats, and end-to-end encryption are not implemented yet. Calls need authenticated WebRTC signaling plus TURN (and an SFU for reliable group calls). Secret chats require a reviewed end-to-end encryption design and key verification. Translation/transcription, GIF search, and reliable offline scheduling need external service integrations. The supplied Blueberry mark is used from `blueberry-logo-reference.png`; CSS reveals the light or dark half according to the selected theme without editing the image.

The public publishable key is embedded in the page and is meant for client use. RLS policies protect database rows; the secret key is not included. Review auth confirmation, email delivery, storage quotas, backups, abuse controls, rate limits and privacy policy before public launch.


