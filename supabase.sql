-- Blueberry direct-message MVP (Supabase)
-- Run once in Supabase Dashboard > SQL Editor > New query.
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  username text not null unique check (username = lower(username) and username ~ '^[a-z0-9_]{3,24}$'),
  display_name text not null default '',
  bio text not null default '',
  created_at timestamptz not null default now()
);
create table if not exists public.messages (
  id uuid primary key default gen_random_uuid(),
  sender_id uuid not null references public.profiles(id) on delete cascade,
  recipient_id uuid not null references public.profiles(id) on delete cascade,
  body text not null check (char_length(body) between 1 and 10000),
  created_at timestamptz not null default now(),
  edited_at timestamptz,
  check (sender_id <> recipient_id)
);
create index if not exists messages_sender_created on public.messages(sender_id, created_at desc);
create index if not exists messages_recipient_created on public.messages(recipient_id, created_at desc);

alter table public.profiles enable row level security;
alter table public.messages enable row level security;
grant select on public.profiles to authenticated;
grant insert (id, username, display_name, bio) on public.profiles to authenticated;
grant update (username, display_name, bio) on public.profiles to authenticated;
grant select, delete on public.messages to authenticated;
grant insert (sender_id, recipient_id, body) on public.messages to authenticated;
grant update (body, edited_at) on public.messages to authenticated;

drop policy if exists "profiles visible to signed-in users" on public.profiles;
create policy "profiles visible to signed-in users" on public.profiles for select to authenticated using (true);
drop policy if exists "users create their own profile" on public.profiles;
create policy "users create their own profile" on public.profiles for insert to authenticated with check (id = (select auth.uid()));
drop policy if exists "users update their own profile" on public.profiles;
create policy "users update their own profile" on public.profiles for update to authenticated using (id = (select auth.uid())) with check (id = (select auth.uid()));

drop policy if exists "participants read messages" on public.messages;
create policy "participants read messages" on public.messages for select to authenticated using ((select auth.uid()) = sender_id or (select auth.uid()) = recipient_id);
drop policy if exists "sender creates own messages" on public.messages;
create policy "sender creates own messages" on public.messages for insert to authenticated with check ((select auth.uid()) = sender_id and exists(select 1 from public.profiles p where p.id = recipient_id));
drop policy if exists "sender edits own messages" on public.messages;
create policy "sender edits own messages" on public.messages for update to authenticated using ((select auth.uid()) = sender_id) with check ((select auth.uid()) = sender_id);
drop policy if exists "participants delete messages" on public.messages;
create policy "participants delete messages" on public.messages for delete to authenticated using ((select auth.uid()) = sender_id or (select auth.uid()) = recipient_id);

do $$ begin
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'messages') then
    alter publication supabase_realtime add table public.messages;
  end if;
end $$;

create or replace function public.create_blueberry_profile()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  insert into public.profiles (id, username, display_name)
  values (
    new.id,
    coalesce(nullif(lower(new.raw_user_meta_data ->> 'username'), ''), 'user_' || substr(new.id::text, 1, 8)),
    coalesce(nullif(new.raw_user_meta_data ->> 'display_name', ''), 'Blueberry user')
  ) on conflict (id) do nothing;
  return new;
end;
$$;
drop trigger if exists blueberry_profile_after_signup on auth.users;
create trigger blueberry_profile_after_signup after insert on auth.users
for each row execute function public.create_blueberry_profile();

-- Groups and channels (safe to re-run after the direct-message schema).
create table if not exists public.rooms (
  id uuid primary key default gen_random_uuid(),
  kind text not null check (kind in ('group','channel')),
  title text not null check (char_length(title) between 1 and 120),
  description text not null default '',
  is_public boolean not null default false,
  created_by uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now()
);
create table if not exists public.room_members (
  room_id uuid not null references public.rooms(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  role text not null default 'member' check (role in ('owner','admin','member')),
  joined_at timestamptz not null default now(),
  primary key (room_id,user_id)
);
create table if not exists public.room_messages (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references public.rooms(id) on delete cascade,
  sender_id uuid not null references public.profiles(id) on delete cascade,
  body text not null check (char_length(body) between 1 and 10000),
  reply_to uuid references public.room_messages(id) on delete set null,
  reaction text,
  created_at timestamptz not null default now(),
  edited_at timestamptz
);
create index if not exists room_messages_room_created on public.room_messages(room_id,created_at desc);

create or replace function public.blueberry_is_room_member(rid uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists(select 1 from public.room_members m where m.room_id=rid and m.user_id=(select auth.uid()))
$$;
create or replace function public.blueberry_is_room_admin(rid uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists(select 1 from public.room_members m where m.room_id=rid and m.user_id=(select auth.uid()) and m.role in ('owner','admin'))
$$;
create or replace function public.blueberry_add_room_owner()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  insert into public.room_members(room_id,user_id,role) values(new.id,new.created_by,'owner') on conflict do nothing;
  return new;
end;
$$;
drop trigger if exists blueberry_room_owner_after_create on public.rooms;
create trigger blueberry_room_owner_after_create after insert on public.rooms for each row execute function public.blueberry_add_room_owner();

alter table public.rooms enable row level security;
alter table public.room_members enable row level security;
alter table public.room_messages enable row level security;
grant select,insert,update on public.rooms to authenticated;
grant select,insert,delete on public.room_members to authenticated;
grant select,insert,update,delete on public.room_messages to authenticated;

drop policy if exists "rooms visible to members or public" on public.rooms;
create policy "rooms visible to members or public" on public.rooms for select to authenticated using (is_public or public.blueberry_is_room_member(id));
drop policy if exists "users create rooms" on public.rooms;
create policy "users create rooms" on public.rooms for insert to authenticated with check (created_by=(select auth.uid()));
drop policy if exists "room admins update rooms" on public.rooms;
create policy "room admins update rooms" on public.rooms for update to authenticated using (public.blueberry_is_room_admin(id)) with check (public.blueberry_is_room_admin(id));

drop policy if exists "room members visible to members or public" on public.room_members;
create policy "room members visible to members or public" on public.room_members for select to authenticated using (public.blueberry_is_room_member(room_id) or exists(select 1 from public.rooms r where r.id=room_id and r.is_public));
drop policy if exists "users join public rooms or own new room" on public.room_members;
create policy "users join public rooms or own new room" on public.room_members for insert to authenticated with check (user_id=(select auth.uid()) and exists(select 1 from public.rooms r where r.id=room_id and (r.is_public or r.created_by=(select auth.uid()))));
drop policy if exists "room admins add members" on public.room_members;
create policy "room admins add members" on public.room_members for insert to authenticated with check (public.blueberry_is_room_admin(room_id));
drop policy if exists "members leave or admins remove" on public.room_members;
create policy "members leave or admins remove" on public.room_members for delete to authenticated using (user_id=(select auth.uid()) or public.blueberry_is_room_admin(room_id));

drop policy if exists "room messages visible to members or public" on public.room_messages;
create policy "room messages visible to members or public" on public.room_messages for select to authenticated using (public.blueberry_is_room_member(room_id) or exists(select 1 from public.rooms r where r.id=room_id and r.is_public));
drop policy if exists "members post in groups and admins in channels" on public.room_messages;
create policy "members post in groups and admins in channels" on public.room_messages for insert to authenticated with check (
  sender_id=(select auth.uid()) and public.blueberry_is_room_member(room_id) and exists(select 1 from public.rooms r where r.id=room_id and (r.kind='group' or public.blueberry_is_room_admin(room_id)))
);
drop policy if exists "authors edit their room messages" on public.room_messages;
create policy "authors edit their room messages" on public.room_messages for update to authenticated using (sender_id=(select auth.uid())) with check (sender_id=(select auth.uid()));
drop policy if exists "authors or admins delete room messages" on public.room_messages;
create policy "authors or admins delete room messages" on public.room_messages for delete to authenticated using (sender_id=(select auth.uid()) or public.blueberry_is_room_admin(room_id));

do $$ begin
  if not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='room_messages') then
    alter publication supabase_realtime add table public.room_messages;
  end if;
end $$;

-- Additional fields used by the live client.
alter table public.profiles add column if not exists avatar_url text;
alter table public.messages add column if not exists reply_to uuid references public.messages(id) on delete set null;
alter table public.messages add column if not exists reaction text;
grant update (reply_to,reaction) on public.messages to authenticated;
grant update (avatar_url) on public.profiles to authenticated;

-- Allow either participant/member to set a reaction, while keeping message text edits author-only.
create or replace function public.blueberry_guard_message_edit()
returns trigger language plpgsql set search_path = '' as $$
begin
  if old.sender_id <> (select auth.uid()) and (
    new.body is distinct from old.body or new.reply_to is distinct from old.reply_to or new.edited_at is distinct from old.edited_at
  ) then raise exception 'Only the message author may edit its content'; end if;
  return new;
end;
$$;
drop trigger if exists blueberry_guard_direct_message_edit on public.messages;
create trigger blueberry_guard_direct_message_edit before update on public.messages for each row execute function public.blueberry_guard_message_edit();
drop trigger if exists blueberry_guard_room_message_edit on public.room_messages;
create trigger blueberry_guard_room_message_edit before update on public.room_messages for each row execute function public.blueberry_guard_message_edit();

drop policy if exists "participants react to direct messages" on public.messages;
create policy "participants react to direct messages" on public.messages for update to authenticated
using ((select auth.uid())=sender_id or (select auth.uid())=recipient_id)
with check ((select auth.uid())=sender_id or (select auth.uid())=recipient_id);
drop policy if exists "members react to room messages" on public.room_messages;
create policy "members react to room messages" on public.room_messages for update to authenticated
using (public.blueberry_is_room_member(room_id)) with check (public.blueberry_is_room_member(room_id));

-- Backfill profiles for accounts that already existed before this schema was installed.
insert into public.profiles (id,username,display_name)
select u.id,
  case when coalesce(u.raw_user_meta_data ->> 'username','') ~* '^[a-z0-9_]{3,24}$'
    then lower(u.raw_user_meta_data ->> 'username')
    else 'user_' || substr(replace(u.id::text,'-',''),1,12)
  end,
  coalesce(nullif(u.raw_user_meta_data ->> 'display_name',''),'Blueberry user')
from auth.users u
on conflict (id) do nothing;

-- Public profile avatars, limited to image files of at most 2 MiB.
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values ('blueberry-avatars','blueberry-avatars',true,2097152,array['image/png','image/jpeg','image/webp','image/gif'])
on conflict (id) do update set public=true,file_size_limit=2097152,allowed_mime_types=array['image/png','image/jpeg','image/webp','image/gif'];
drop policy if exists "Blueberry avatars are publicly readable" on storage.objects;
create policy "Blueberry avatars are publicly readable" on storage.objects for select to public using(bucket_id='blueberry-avatars');
drop policy if exists "Users upload their own Blueberry avatar" on storage.objects;
create policy "Users upload their own Blueberry avatar" on storage.objects for insert to authenticated with check(bucket_id='blueberry-avatars' and (storage.foldername(name))[1]=(select auth.uid())::text);
drop policy if exists "Users update their own Blueberry avatar" on storage.objects;
create policy "Users update their own Blueberry avatar" on storage.objects for update to authenticated using(bucket_id='blueberry-avatars' and (storage.foldername(name))[1]=(select auth.uid())::text) with check(bucket_id='blueberry-avatars' and (storage.foldername(name))[1]=(select auth.uid())::text);
drop policy if exists "Users delete their own Blueberry avatar" on storage.objects;
create policy "Users delete their own Blueberry avatar" on storage.objects for delete to authenticated using(bucket_id='blueberry-avatars' and (storage.foldername(name))[1]=(select auth.uid())::text);

-- Message attachments stored privately. Each object is readable only by the sender/recipient or room members.
alter table public.messages add column if not exists attachment_path text;
alter table public.messages add column if not exists attachment_name text;
alter table public.messages add column if not exists attachment_type text;
alter table public.room_messages add column if not exists attachment_path text;
alter table public.room_messages add column if not exists attachment_name text;
alter table public.room_messages add column if not exists attachment_type text;
grant insert (sender_id,recipient_id,body,reply_to,attachment_path,attachment_name,attachment_type) on public.messages to authenticated;
insert into storage.buckets(id,name,public,file_size_limit)
values('blueberry-files','blueberry-files',false,20971520)
on conflict(id) do update set public=false,file_size_limit=20971520;
drop policy if exists "Blueberry users upload own message files" on storage.objects;
create policy "Blueberry users upload own message files" on storage.objects for insert to authenticated with check(bucket_id='blueberry-files' and (storage.foldername(name))[1]=(select auth.uid())::text);
drop policy if exists "Blueberry participants read message files" on storage.objects;
create policy "Blueberry participants read message files" on storage.objects for select to authenticated using(
 bucket_id='blueberry-files' and (
   (storage.foldername(name))[1]=(select auth.uid())::text
   or exists(select 1 from public.messages m where m.attachment_path=name and ((select auth.uid())=m.sender_id or (select auth.uid())=m.recipient_id))
   or exists(select 1 from public.room_messages m where m.attachment_path=name and public.blueberry_is_room_member(m.room_id))
   or exists(select 1 from public.room_messages m join public.rooms r on r.id=m.room_id where m.attachment_path=name and r.is_public)
 )
);
drop policy if exists "Blueberry users delete own message files" on storage.objects;
create policy "Blueberry users delete own message files" on storage.objects for delete to authenticated using(bucket_id='blueberry-files' and (storage.foldername(name))[1]=(select auth.uid())::text);

-- Tighten message updates: non-authors can change only the reaction field.
create or replace function public.blueberry_guard_message_edit()
returns trigger language plpgsql set search_path = '' as $$
begin
  if old.sender_id <> (select auth.uid()) and (to_jsonb(new) - 'reaction') is distinct from (to_jsonb(old) - 'reaction') then
    raise exception 'Only the message author may edit its content';
  end if;
  return new;
end;
$$;
drop policy if exists "participants delete messages" on public.messages;
drop policy if exists "authors delete own direct messages" on public.messages;
create policy "authors delete own direct messages" on public.messages for delete to authenticated using ((select auth.uid())=sender_id);
