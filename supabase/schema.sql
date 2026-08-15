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

-- Workspace Library v2. A cloud workspace is the durable project. Instances
-- describe where it is currently loaded; immutable revisions preserve what
-- was captured on each Mac without last-writer-wins data loss.
create table if not exists public.cloud_workspaces (
    id uuid primary key,
    user_id uuid not null references auth.users(id) on delete cascade,
    name text not null,
    category_name text,
    color_hex text,
    current_revision_id uuid,
    is_archived boolean not null default false,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    deleted_at timestamptz,
    constraint cloud_workspaces_name_not_blank check (length(btrim(name)) > 0),
    constraint cloud_workspaces_color_hex check (
        color_hex is null or color_hex ~ '^[0-9A-Fa-f]{6}$'
    )
);

create index if not exists cloud_workspaces_owner_updated_idx
on public.cloud_workspaces (user_id, updated_at desc);

create table if not exists public.workspace_instances (
    id uuid primary key,
    user_id uuid not null references auth.users(id) on delete cascade,
    workspace_id uuid not null references public.cloud_workspaces(id) on delete cascade,
    device_id uuid not null,
    local_workspace_key text,
    display_name text,
    display_ordinal integer,
    space_ordinal integer,
    status text not null default 'loaded',
    head_revision_id uuid,
    last_seen_at timestamptz not null default now(),
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    deleted_at timestamptz,
    constraint workspace_instances_owner_device_fk
        foreign key (user_id, device_id)
        references public.workspace_devices(user_id, device_id)
        on delete cascade,
    constraint workspace_instances_valid_status check (
        status in ('loaded', 'focused', 'parked', 'pending_move', 'stale')
    )
);

create unique index if not exists workspace_instances_local_binding_unique
on public.workspace_instances (user_id, device_id, local_workspace_key)
where local_workspace_key is not null and deleted_at is null;
create index if not exists workspace_instances_workspace_idx
on public.workspace_instances (user_id, workspace_id, updated_at desc);
create index if not exists workspace_instances_device_idx
on public.workspace_instances (user_id, device_id, status);

create table if not exists public.workspace_revisions (
    id uuid primary key,
    user_id uuid not null references auth.users(id) on delete cascade,
    workspace_id uuid not null references public.cloud_workspaces(id) on delete cascade,
    instance_id uuid references public.workspace_instances(id) on delete set null,
    parent_revision_id uuid references public.workspace_revisions(id) on delete set null,
    source_device_id uuid not null,
    content_hash text not null,
    snapshot jsonb not null,
    created_at timestamptz not null default now(),
    constraint workspace_revisions_owner_device_fk
        foreign key (user_id, source_device_id)
        references public.workspace_devices(user_id, device_id)
        on delete cascade,
    constraint workspace_revisions_snapshot_is_object
        check (jsonb_typeof(snapshot) = 'object')
);

create unique index if not exists workspace_revisions_instance_hash_unique
on public.workspace_revisions (user_id, instance_id, content_hash)
where instance_id is not null;
create index if not exists workspace_revisions_workspace_created_idx
on public.workspace_revisions (user_id, workspace_id, created_at desc);

create table if not exists public.workspace_transfers (
    id uuid primary key,
    user_id uuid not null references auth.users(id) on delete cascade,
    workspace_id uuid not null references public.cloud_workspaces(id) on delete cascade,
    revision_id uuid not null references public.workspace_revisions(id) on delete cascade,
    source_instance_id uuid references public.workspace_instances(id) on delete set null,
    source_device_id uuid not null,
    destination_device_id uuid,
    destination_instance_id uuid references public.workspace_instances(id) on delete set null,
    mode text not null,
    status text not null default 'pending',
    created_at timestamptz not null default now(),
    accepted_at timestamptz,
    completed_at timestamptz,
    cancelled_at timestamptz,
    constraint workspace_transfers_mode_check check (mode in ('copy', 'move')),
    constraint workspace_transfers_status_check check (
        status in ('pending', 'accepted', 'completed', 'cancelled', 'failed')
    ),
    constraint workspace_transfers_not_same_device check (
        destination_device_id is null or destination_device_id <> source_device_id
    )
);

create index if not exists workspace_transfers_destination_idx
on public.workspace_transfers (user_id, destination_device_id, status, created_at desc);
-- Cover every foreign key used by deletes and Library graph traversal.
create index if not exists workspace_instances_workspace_fk_idx
on public.workspace_instances (workspace_id);
create index if not exists workspace_revisions_instance_fk_idx
on public.workspace_revisions (instance_id);
create index if not exists workspace_revisions_owner_device_fk_idx
on public.workspace_revisions (user_id, source_device_id);
create index if not exists workspace_revisions_parent_fk_idx
on public.workspace_revisions (parent_revision_id);
create index if not exists workspace_revisions_workspace_fk_idx
on public.workspace_revisions (workspace_id);
create index if not exists workspace_transfers_destination_instance_fk_idx
on public.workspace_transfers (destination_instance_id);
create index if not exists workspace_transfers_revision_fk_idx
on public.workspace_transfers (revision_id);
create index if not exists workspace_transfers_source_instance_fk_idx
on public.workspace_transfers (source_instance_id);
create index if not exists workspace_transfers_workspace_fk_idx
on public.workspace_transfers (workspace_id);

-- Every Workspace Library table is private to its authenticated owner.
alter table public.cloud_workspaces enable row level security;
alter table public.cloud_workspaces force row level security;
alter table public.workspace_instances enable row level security;
alter table public.workspace_instances force row level security;
alter table public.workspace_revisions enable row level security;
alter table public.workspace_revisions force row level security;
alter table public.workspace_transfers enable row level security;
alter table public.workspace_transfers force row level security;

do $workspace_library_policies$
declare table_name text;
begin
  foreach table_name in array array[
    'cloud_workspaces', 'workspace_instances',
    'workspace_revisions', 'workspace_transfers'
  ] loop
    execute format('drop policy if exists %I on public.%I', table_name || '_select_own', table_name);
    execute format('create policy %I on public.%I for select to authenticated using ((select auth.uid()) = user_id)', table_name || '_select_own', table_name);
    execute format('drop policy if exists %I on public.%I', table_name || '_insert_own', table_name);
    execute format('create policy %I on public.%I for insert to authenticated with check ((select auth.uid()) = user_id)', table_name || '_insert_own', table_name);
    execute format('drop policy if exists %I on public.%I', table_name || '_update_own', table_name);
    execute format('create policy %I on public.%I for update to authenticated using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id)', table_name || '_update_own', table_name);
    execute format('drop policy if exists %I on public.%I', table_name || '_delete_own', table_name);
    execute format('create policy %I on public.%I for delete to authenticated using ((select auth.uid()) = user_id)', table_name || '_delete_own', table_name);
  end loop;
end
$workspace_library_policies$;

revoke all on table public.cloud_workspaces from anon, authenticated;
revoke all on table public.workspace_instances from anon, authenticated;
revoke all on table public.workspace_revisions from anon, authenticated;
revoke all on table public.workspace_transfers from anon, authenticated;
grant select, insert, update, delete on table public.cloud_workspaces to authenticated;
grant select, insert, update, delete on table public.workspace_instances to authenticated;
grant select, insert, update, delete on table public.workspace_revisions to authenticated;
grant select, insert, update, delete on table public.workspace_transfers to authenticated;
grant all on table public.cloud_workspaces to service_role;
grant all on table public.workspace_instances to service_role;
grant all on table public.workspace_revisions to service_role;
grant all on table public.workspace_transfers to service_role;
