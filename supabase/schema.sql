-- Workspace++ account backup/sync schema.
-- Run in a dedicated Supabase project. The app uses only a publishable key;
-- row-level security confines every profile to its authenticated owner.

create table if not exists public.workspace_profiles (
    user_id uuid primary key references auth.users(id) on delete cascade,
    snapshot jsonb not null,
    source_device_id uuid not null,
    updated_at timestamptz not null default now(),
    constraint workspace_profiles_snapshot_is_object
        check (jsonb_typeof(snapshot) = 'object')
);

alter table public.workspace_profiles enable row level security;
alter table public.workspace_profiles force row level security;

drop policy if exists "workspace_profiles_select_own" on public.workspace_profiles;
create policy "workspace_profiles_select_own"
on public.workspace_profiles
for select
to authenticated
using ((select auth.uid()) = user_id);

drop policy if exists "workspace_profiles_insert_own" on public.workspace_profiles;
create policy "workspace_profiles_insert_own"
on public.workspace_profiles
for insert
to authenticated
with check ((select auth.uid()) = user_id);

drop policy if exists "workspace_profiles_update_own" on public.workspace_profiles;
create policy "workspace_profiles_update_own"
on public.workspace_profiles
for update
to authenticated
using ((select auth.uid()) = user_id)
with check ((select auth.uid()) = user_id);

drop policy if exists "workspace_profiles_delete_own" on public.workspace_profiles;
create policy "workspace_profiles_delete_own"
on public.workspace_profiles
for delete
to authenticated
using ((select auth.uid()) = user_id);

revoke all on table public.workspace_profiles from anon;
grant select, insert, update, delete on table public.workspace_profiles to authenticated;
grant all on table public.workspace_profiles to service_role;

-- Each installation has a durable device UUID. Keeping devices separate from
-- workspace snapshots prevents two Macs signed into the same account from
-- overwriting one another's current state.
create table if not exists public.workspace_devices (
    user_id uuid not null references auth.users(id) on delete cascade,
    device_id uuid not null,
    name text not null,
    model text not null,
    operating_system text not null,
    app_version text not null,
    last_seen_at timestamptz not null default now(),
    created_at timestamptz not null default now(),
    primary key (user_id, device_id)
);

alter table public.workspace_devices enable row level security;
alter table public.workspace_devices force row level security;

drop policy if exists "workspace_devices_select_own" on public.workspace_devices;
create policy "workspace_devices_select_own" on public.workspace_devices
for select to authenticated using ((select auth.uid()) = user_id);
drop policy if exists "workspace_devices_insert_own" on public.workspace_devices;
create policy "workspace_devices_insert_own" on public.workspace_devices
for insert to authenticated with check ((select auth.uid()) = user_id);
drop policy if exists "workspace_devices_update_own" on public.workspace_devices;
create policy "workspace_devices_update_own" on public.workspace_devices
for update to authenticated
using ((select auth.uid()) = user_id)
with check ((select auth.uid()) = user_id);
drop policy if exists "workspace_devices_delete_own" on public.workspace_devices;
create policy "workspace_devices_delete_own" on public.workspace_devices
for delete to authenticated using ((select auth.uid()) = user_id);

revoke all on table public.workspace_devices from anon, authenticated;
grant select, insert, update, delete on table public.workspace_devices to authenticated;
grant all on table public.workspace_devices to service_role;

-- One latest snapshot per device + workspace. Upserting this row makes the
-- five-minute autosave idempotent and bounded while still giving the History
-- UI a coherent cross-device view. `id` remains stable across updates so UI
-- expansion state and explicit deletion are deterministic.
create table if not exists public.workspace_sessions (
    id uuid primary key,
    user_id uuid not null,
    device_id uuid not null,
    device_name text not null,
    workspace_key text not null,
    content_hash text not null,
    snapshot jsonb not null,
    captured_at timestamptz not null,
    updated_at timestamptz not null default now(),
    deleted_at timestamptz,
    constraint workspace_sessions_owner_device_fk
        foreign key (user_id, device_id)
        references public.workspace_devices(user_id, device_id)
        on delete cascade,
    constraint workspace_sessions_unique_device_workspace
        unique (user_id, device_id, workspace_key),
    constraint workspace_sessions_snapshot_is_object
        check (jsonb_typeof(snapshot) = 'object')
);

create index if not exists workspace_sessions_user_updated_idx
on public.workspace_sessions (user_id, updated_at desc);

alter table public.workspace_sessions enable row level security;
alter table public.workspace_sessions force row level security;

drop policy if exists "workspace_sessions_select_own" on public.workspace_sessions;
create policy "workspace_sessions_select_own" on public.workspace_sessions
for select to authenticated using ((select auth.uid()) = user_id);
drop policy if exists "workspace_sessions_insert_own" on public.workspace_sessions;
create policy "workspace_sessions_insert_own" on public.workspace_sessions
for insert to authenticated with check ((select auth.uid()) = user_id);
drop policy if exists "workspace_sessions_update_own" on public.workspace_sessions;
create policy "workspace_sessions_update_own" on public.workspace_sessions
for update to authenticated
using ((select auth.uid()) = user_id)
with check ((select auth.uid()) = user_id);
drop policy if exists "workspace_sessions_delete_own" on public.workspace_sessions;
create policy "workspace_sessions_delete_own" on public.workspace_sessions
for delete to authenticated using ((select auth.uid()) = user_id);

revoke all on table public.workspace_sessions from anon, authenticated;
grant select, insert, update, delete on table public.workspace_sessions to authenticated;
grant all on table public.workspace_sessions to service_role;

-- A soft deletion is a cross-device tombstone. The source Mac will not
-- recreate an unchanged snapshot on its next autosave; a genuinely changed
-- workspace clears the tombstone through the normal upsert.
alter table public.workspace_sessions
add column if not exists deleted_at timestamptz;
