-- Padel Villains lockdown, 17 Nov 2026.
-- Closes anonymous writes, restricts results/scheduling to circuit staff,
-- stops account claiming, constrains fields that reach the page unescaped,
-- removes a leftover readable password hash, lengthens new invite codes.
-- Rollback: supabase/rollback/20261117120000_lockdown_rollback.sql
-- Precondition: snapshot schema pv_snapshot_20261117 exists (taken first).

-- 1. Who counts as staff: app admin, or owner/admin/scorer of the circuit.
create or replace function public.pv_is_staff(cid bigint default 1)
returns boolean language sql stable security definer
set search_path = public, pg_temp as $$
  select auth.uid() is not null and (
    exists (select 1 from public.user_accounts ua where ua.profile_id = auth.uid() and ua.is_admin)
    or exists (select 1 from public.circuit_members cm
               where cm.circuit_id = coalesce(cid, 1) and cm.profile_id = auth.uid()
                 and cm.role in ('owner','admin','scorer'))
  );
$$;
revoke all on function public.pv_is_staff(bigint) from public, anon;
grant execute on function public.pv_is_staff(bigint) to authenticated;

-- 2. Core tables: reads stay public; every write needs signed-in staff.
do $$ declare t text; r record; begin
  foreach t in array array['players','teams','matches','ongoing_matches','matchdays'] loop
    for r in select policyname from pg_policies
             where schemaname = 'public' and tablename = t and cmd <> 'SELECT' loop
      execute format('drop policy %I on public.%I', r.policyname, t);
    end loop;
    execute format('create policy %I on public.%I for insert to authenticated with check (public.pv_is_staff(circuit_id))', t || ': staff insert', t);
    execute format('create policy %I on public.%I for update to authenticated using (public.pv_is_staff(circuit_id)) with check (public.pv_is_staff(circuit_id))', t || ': staff update', t);
    execute format('create policy %I on public.%I for delete to authenticated using (public.pv_is_staff(circuit_id))', t || ': staff delete', t);
  end loop;
end $$;

-- A signed-in player may edit their own profile fields (photo, bio, nickname,
-- phone, position, availability), never their stats, link or identity.
create policy "players: self update" on public.players for update to authenticated
  using (profile_id = auth.uid()) with check (profile_id = auth.uid());

create or replace function public.pv_guard_players_update()
returns trigger language plpgsql set search_path = public, pg_temp as $$
begin
  -- Server-side functions (invites, triggers) run as the table owner: allowed.
  if current_user not in ('anon', 'authenticated') then return new; end if;
  if public.pv_is_staff(coalesce(old.circuit_id, 1)) then return new; end if;
  new.id := old.id;               new.name := old.name;
  new.profile_id := old.profile_id; new.claimed_at := old.claimed_at;
  new.circuit_id := old.circuit_id; new.is_guest := old.is_guest;
  new.wins := old.wins;           new.losses := old.losses;
  new.games_played := old.games_played; new.active := old.active;
  new.created_at := old.created_at;
  return new;
end $$;
drop trigger if exists pv_guard_players_update_trg on public.players;
create trigger pv_guard_players_update_trg before update on public.players
  for each row execute function public.pv_guard_players_update();

-- 3. Accounts: only the owner of a row, or an admin, may update it.
drop policy if exists "User accounts can be updated by app" on public.user_accounts;
create policy "user_accounts: self or admin update" on public.user_accounts for update to authenticated
  using (profile_id = auth.uid() or public.pv_is_admin())
  with check (profile_id = auth.uid() or public.pv_is_admin());

create or replace function public.pv_guard_user_accounts_update()
returns trigger language plpgsql security definer
set search_path = public, pg_temp as $$
declare
  v_bypass boolean := coalesce(current_setting('pv.sec_bypass', true), '0') = '1';
  v_uid    uuid    := auth.uid();
  v_admin  boolean;
begin
  if new.settings is not null then new.settings := new.settings - 'password'; end if;
  if v_bypass then return new; end if;
  if new.password_hash is distinct from old.password_hash then new.password_hash := old.password_hash; end if;
  v_admin := v_uid is not null and exists (
    select 1 from public.user_accounts ua where ua.profile_id = v_uid and ua.is_admin = true);
  if v_admin then return new; end if;
  -- Non-admins: no self-promotion, no claiming, no re-pointing to another player.
  new.id := old.id;
  new.is_admin := old.is_admin;
  new.profile_id := old.profile_id;
  new.player_id := old.player_id;
  new.circuit_id := old.circuit_id;
  return new;
end $$;

create or replace function public.pv_guard_user_accounts_insert()
returns trigger language plpgsql security definer
set search_path = public, pg_temp as $$
declare
  v_bypass boolean := coalesce(current_setting('pv.sec_bypass', true), '0') = '1';
  v_uid    uuid    := auth.uid();
  v_admin  boolean;
begin
  if new.settings is not null then new.settings := new.settings - 'password'; end if;
  if v_bypass then return new; end if;
  v_admin := v_uid is not null and exists (
    select 1 from public.user_accounts ua where ua.profile_id = v_uid and ua.is_admin = true);
  if coalesce(new.is_admin, false) and not v_admin then new.is_admin := false; end if;
  new.password_hash := null;
  if new.profile_id is not null and new.profile_id is distinct from v_uid and not v_admin then new.profile_id := null; end if;
  -- A new account cannot attach itself to an existing player; that happens via invite or admin.
  if not v_admin then new.player_id := null; end if;
  return new;
end $$;

-- accept_invite links accounts on purpose, so it switches the guard off for its own transaction.
create or replace function public.accept_invite(p_code text)
returns jsonb language plpgsql security definer set search_path = public as $function$
declare i record; uid uuid := auth.uid(); acc record; pname text;
begin
  if uid is null then return jsonb_build_object('ok', false, 'error', 'Not signed in'); end if;
  select * into i from circuit_invites where upper(code) = upper(p_code);
  if not found then return jsonb_build_object('ok', false, 'error', 'Invite not found'); end if;
  if i.expires_at is not null and i.expires_at < now() then return jsonb_build_object('ok', false, 'error', 'Invite expired'); end if;
  if i.max_uses is not null and i.uses >= i.max_uses then return jsonb_build_object('ok', false, 'error', 'Invite already used'); end if;

  perform set_config('pv.sec_bypass', '1', true);
  if i.player_id is not null then
    select name into pname from players where id = i.player_id;
    select * into acc from user_accounts where player_id = i.player_id limit 1;
    if found then
      update user_accounts set profile_id = uid, is_admin = (is_admin or i.role in ('owner','admin'))
       where id = acc.id and (profile_id is null or profile_id = uid);
    else
      insert into user_accounts (id, player_id, username, is_admin, theme, settings, profile_id, circuit_id, created_at)
      values ((extract(epoch from clock_timestamp())*1000)::bigint, i.player_id, coalesce(pname,'villain'), i.role in ('owner','admin'), 'default', '{}'::jsonb, uid, i.circuit_id, now());
    end if;
  else
    perform link_membership(i.circuit_id, uid, null, i.role);
  end if;
  perform set_config('pv.sec_bypass', '0', true);

  update circuit_invites set uses = uses + 1 where id = i.id;
  return jsonb_build_object('ok', true, 'circuit_id', i.circuit_id, 'player_id', i.player_id, 'player_name', pname);
end $function$;

-- 4. Linking a legacy account to Google/Apple/email now needs proof of the
--    legacy password: pv_legacy_login issues a one-time token, redeemed after sign-in.
create table if not exists public.pv_link_tokens (
  token text primary key,
  account_id bigint not null references public.user_accounts(id) on delete cascade,
  expires_at timestamptz not null default now() + interval '7 days',
  created_at timestamptz not null default now()
);
alter table public.pv_link_tokens enable row level security;
revoke all on public.pv_link_tokens from public, anon, authenticated;

drop function if exists public.pv_legacy_login(text, text);
create function public.pv_legacy_login(p_username text, p_password text)
returns table(id bigint, player_id bigint, profile_id uuid, username text, is_admin boolean,
              theme text, settings jsonb, last_login timestamptz, created_at timestamptz,
              updated_at timestamptz, circuit_id bigint, link_token text)
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_expected text; v_acc public.user_accounts%rowtype; v_token text;
begin
  if p_username is null or p_password is null or length(p_username) = 0 or length(p_password) = 0 then
    return;
  end if;
  v_expected := encode(extensions.digest(convert_to(p_password || '_pv_salt_2026', 'UTF8'), 'sha256'), 'hex');
  select * into v_acc from public.user_accounts ua
   where lower(ua.username) = lower(p_username) and ua.password_hash = v_expected limit 1;
  if not found then return; end if;
  if v_acc.profile_id is null then
    delete from public.pv_link_tokens lt where lt.account_id = v_acc.id or lt.expires_at < now();
    v_token := encode(extensions.gen_random_bytes(24), 'hex');
    insert into public.pv_link_tokens (token, account_id) values (v_token, v_acc.id);
  end if;
  return query select v_acc.id, v_acc.player_id, v_acc.profile_id, v_acc.username, v_acc.is_admin,
                      v_acc.theme, coalesce(v_acc.settings, '{}'::jsonb) - 'password', v_acc.last_login,
                      v_acc.created_at, v_acc.updated_at, v_acc.circuit_id, v_token;
end $$;
revoke all on function public.pv_legacy_login(text, text) from public;
grant execute on function public.pv_legacy_login(text, text) to anon, authenticated;

create or replace function public.pv_redeem_link_token(p_token text)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_uid uuid := auth.uid(); v_acc bigint; v_n int;
begin
  if v_uid is null then return jsonb_build_object('ok', false, 'error', 'Not signed in'); end if;
  if exists (select 1 from public.user_accounts ua where ua.profile_id = v_uid) then
    return jsonb_build_object('ok', false, 'error', 'This sign-in is already linked to an account');
  end if;
  select lt.account_id into v_acc from public.pv_link_tokens lt
   where lt.token = p_token and lt.expires_at > now();
  if v_acc is null then
    return jsonb_build_object('ok', false, 'error', 'Link expired. Sign in with your name and password again, then link.');
  end if;
  perform set_config('pv.sec_bypass', '1', true);
  update public.user_accounts ua set profile_id = v_uid where ua.id = v_acc and ua.profile_id is null;
  get diagnostics v_n = row_count;
  perform set_config('pv.sec_bypass', '0', true);
  delete from public.pv_link_tokens lt where lt.account_id = v_acc;
  if v_n = 0 then return jsonb_build_object('ok', false, 'error', 'That account is already linked'); end if;
  return jsonb_build_object('ok', true, 'account_id', v_acc);
end $$;
revoke all on function public.pv_redeem_link_token(text) from public, anon;
grant execute on function public.pv_redeem_link_token(text) to authenticated;

-- 5. Audit log: only staff append.
drop policy if exists "audit: append" on public.match_audit_log;
create policy "audit: staff append" on public.match_audit_log for insert to authenticated
  with check (public.pv_is_staff(circuit_id));

-- 6. Table grants: anon reads only; nobody truncates through the API.
revoke insert, update, delete, truncate, references, trigger on all tables in schema public from anon;
revoke truncate, references, trigger on all tables in schema public from authenticated;
alter default privileges for role postgres in schema public
  revoke insert, update, delete, truncate, references, trigger on tables from anon;

-- 7. Functions that need a signed-in user are no longer offered to anon.
revoke execute on function public.pv_claim_scorer(bigint, text, boolean), public.pv_release_scorer(bigint, text) from public, anon;
grant  execute on function public.pv_claim_scorer(bigint, text, boolean), public.pv_release_scorer(bigint, text) to authenticated;
revoke execute on function public.pv_admin_set_password(bigint, text), public.pv_set_own_password(text, text), public.pv_is_admin() from public, anon;
grant  execute on function public.pv_admin_set_password(bigint, text), public.pv_set_own_password(text, text), public.pv_is_admin() to authenticated;

-- 8. Shape constraints on fields the page prints (blank times stay allowed).
create or replace function public.pv_scores_ok(s jsonb) returns boolean
language sql immutable set search_path = public, pg_temp as $$
  select case when jsonb_typeof(s) <> 'array' then false else not exists (
    select 1 from jsonb_array_elements(s) e
     where case when jsonb_typeof(e) <> 'array' then true
                else exists (select 1 from jsonb_array_elements(e) x where jsonb_typeof(x) <> 'number') end
  ) end
$$;
alter table public.matches add constraint matches_scores_shape
  check (scores is null or public.pv_scores_ok(scores)) not valid;
alter table public.matches validate constraint matches_scores_shape;
alter table public.matchdays add constraint matchdays_time_fmt check (
  (start_time is null or start_time = '' or start_time ~ '^\d{1,2}:\d{2}(:\d{2})?$') and
  (end_time   is null or end_time   = '' or end_time   ~ '^\d{1,2}:\d{2}(:\d{2})?$')) not valid;
alter table public.matchdays validate constraint matchdays_time_fmt;
alter table public.events add constraint events_time_fmt check (
  (start_time is null or start_time = '' or start_time ~ '^\d{1,2}:\d{2}(:\d{2})?$') and
  (end_time   is null or end_time   = '' or end_time   ~ '^\d{1,2}:\d{2}(:\d{2})?$')) not valid;
alter table public.events validate constraint events_time_fmt;
alter table public.players add constraint players_text_len check (
  char_length(name) <= 60 and char_length(coalesce(nickname, '')) <= 60
  and char_length(coalesce(bio, '')) <= 1000) not valid;
alter table public.players validate constraint players_text_len;
alter table public.teams add constraint teams_name_len check (char_length(name) <= 60) not valid;
alter table public.teams validate constraint teams_name_len;

-- 9. Remove the leftover password hash copy that anon could read.
update public.user_accounts set settings = settings - 'password' where settings ? 'password';

-- 10. New invite codes: 16 hex characters (64 bits) instead of 5.
create or replace function public.ensure_player_invite(p_circuit bigint, p_player bigint, p_admin boolean default false)
returns text language plpgsql security definer set search_path = public as $function$
declare code text;
begin
  select ci.code into code from circuit_invites ci
   where ci.player_id = p_player and ci.uses < coalesce(ci.max_uses, 1)
     and (ci.expires_at is null or ci.expires_at > now()) limit 1;
  if code is not null then return code; end if;
  code := 'VLN-' || upper(encode(extensions.gen_random_bytes(8), 'hex'));
  insert into circuit_invites (circuit_id, code, role, player_id, max_uses, expires_at)
  values (coalesce(p_circuit, 1), code, case when p_admin then 'admin' else 'member' end, p_player, 1, now() + interval '60 days');
  return code;
end $function$;
