# Workspace++ Cloud Sync

Workspace++ cloud sync is local-first and opt-in. Without an account or an
internet connection, the existing `UserDefaults` store remains authoritative.

## Data saved

The account snapshot contains only workspace layout metadata:

- custom workspace name, category assignment, and resolved six-digit colour;
- category names, colours, and deletion records;
- macOS stable Space identifier when available;
- monitor identifier, friendly monitor name, and monitor order;
- workspace order within its monitor;
- per-workspace modification time for conflict resolution;
- a random installation identifier (not a hardware serial number).

Passwords and refresh tokens are never stored in the snapshot. Supabase Auth
stores password hashes on the service; the Mac keeps its session in Keychain.

## Cross-Mac mapping

On the same Mac, records match using the stable macOS Space UUID. On another
Mac, those UUIDs are different, so Workspace++ falls back to monitor order plus
workspace order. An explicit **Restore from Cloud** action is cloud-authoritative.
Normal automatic sync chooses the most recently modified name/colour for each
matching position.

## Backend setup

1. Create a dedicated Supabase project.
2. Apply `supabase/schema.sql`.
3. Ensure `workspace_profiles` is exposed by the Data API. The schema grants
   access only to `authenticated`; RLS still limits every row to its owner.
4. Enable email/password authentication and decide whether email confirmation
   is required.
5. Put the project URL and **publishable** key (never a secret/service-role key)
   in `WorkspaceCloudURL` and `WorkspaceCloudPublishableKey` in `project.yml`.
6. Regenerate the Xcode project with `xcodegen generate`, then build and test.

The official repository is connected to the dedicated Workspace++ Cloud
project. Forks can replace these public client values with their own backend;
placeholder values intentionally disable the cloud controls.
