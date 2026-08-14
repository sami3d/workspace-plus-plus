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
