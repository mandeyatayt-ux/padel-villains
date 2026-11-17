-- Reverses supabase/migrations/20261117120000_lockdown.sql, restoring the
-- 16 Nov 2026 state exactly, EXCEPT the leftover password hash copy in
-- user_accounts.settings, which is not put back. Running this reopens every
-- hole the lockdown closed: use only if the lockdown breaks scoring and a
-- forward fix is not possible.

-- Constraints and their helper
alter table public.matches   drop constraint if exists matches_scores_shape;
alter table public.matchdays drop constraint if exists matchdays_time_fmt;
alter table public.events    drop constraint if exists events_time_fmt;
alter table public.players   drop constraint if exists players_text_len;
alter table public.teams     drop constraint if exists teams_name_len;
drop function if exists public.pv_scores_ok(jsonb);

-- Core-table policies back to open
do $$ declare t text; label text; r record; begin
  foreach t in array array['players','teams','matches','ongoing_matches','matchdays'] loop
    for r in select policyname from pg_policies where schemaname = 'public' and tablename = t and cmd <> 'SELECT' loop
      execute format('drop policy %I on public.%I', r.policyname, t);
    end loop;
    label := case t when 'players' then 'Players' when 'teams' then 'Teams' when 'matches' then 'Matches'
                    when 'ongoing_matches' then 'Ongoing matches' else 'Matchdays' end;
    execute format('create policy %I on public.%I for all to public using (true) with check (true)', 'Allow all access to ' || t, t);
    execute format('create policy %I on public.%I for delete to public using (true)', label || ' can be deleted by app', t);
    execute format('create policy %I on public.%I for insert to public with check (true)', label || ' can be inserted by app', t);
    execute format('create policy %I on public.%I for update to public using (true) with check (true)', label || ' can be updated by app', t);
  end loop;
end $$;
drop trigger if exists pv_guard_players_update_trg on public.players;
drop function if exists public.pv_guard_players_update();

drop policy if exists "user_accounts: self or admin update" on public.user_accounts;
create policy "User accounts can be updated by app" on public.user_accounts for update to public using (true) with check (true);
drop policy if exists "audit: staff append" on public.match_audit_log;
create policy "audit: append" on public.match_audit_log for insert to public with check (true);
drop function if exists public.pv_is_staff(bigint);

-- Guards, invite and login functions as they were
create or replace function public.pv_guard_user_accounts_update()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $function$
DECLARE
  v_bypass boolean := coalesce(current_setting('pv.sec_bypass', true), '0') = '1';
  v_uid    uuid    := auth.uid();
  v_admin  boolean;
BEGIN
  IF v_bypass THEN RETURN NEW; END IF;
  v_admin := v_uid IS NOT NULL AND EXISTS (SELECT 1 FROM public.user_accounts ua WHERE ua.profile_id = v_uid AND ua.is_admin = true);
  IF NEW.is_admin IS DISTINCT FROM OLD.is_admin AND NOT v_admin THEN NEW.is_admin := OLD.is_admin; END IF;
  IF NEW.profile_id IS DISTINCT FROM OLD.profile_id AND NOT v_admin THEN
    IF OLD.profile_id IS NULL AND NEW.profile_id = v_uid THEN NULL; ELSE NEW.profile_id := OLD.profile_id; END IF;
  END IF;
  IF NEW.password_hash IS DISTINCT FROM OLD.password_hash THEN NEW.password_hash := OLD.password_hash; END IF;
  RETURN NEW;
END;
$function$;

create or replace function public.pv_guard_user_accounts_insert()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $function$
DECLARE
  v_bypass boolean := coalesce(current_setting('pv.sec_bypass', true), '0') = '1';
  v_uid    uuid    := auth.uid();
  v_admin  boolean;
BEGIN
  IF v_bypass THEN RETURN NEW; END IF;
  v_admin := v_uid IS NOT NULL AND EXISTS (SELECT 1 FROM public.user_accounts ua WHERE ua.profile_id = v_uid AND ua.is_admin = true);
  IF coalesce(NEW.is_admin, false) = true AND NOT v_admin THEN NEW.is_admin := false; END IF;
  NEW.password_hash := NULL;
  IF NEW.profile_id IS NOT NULL AND NEW.profile_id <> v_uid AND NOT v_admin THEN NEW.profile_id := NULL; END IF;
  RETURN NEW;
END;
$function$;

create or replace function public.accept_invite(p_code text)
returns jsonb language plpgsql security definer set search_path = public as $function$
declare i record; uid uuid := auth.uid(); acc record; pname text;
begin
  if uid is null then return jsonb_build_object('ok', false, 'error', 'Not signed in'); end if;
  select * into i from circuit_invites where upper(code) = upper(p_code);
  if not found then return jsonb_build_object('ok', false, 'error', 'Invite not found'); end if;
  if i.expires_at is not null and i.expires_at < now() then return jsonb_build_object('ok', false, 'error', 'Invite expired'); end if;
  if i.max_uses is not null and i.uses >= i.max_uses then return jsonb_build_object('ok', false, 'error', 'Invite already used'); end if;
  if i.player_id is not null then
    select name into pname from players where id = i.player_id;
    select * into acc from user_accounts where player_id = i.player_id limit 1;
    if found then
      update user_accounts set profile_id = uid, is_admin = (is_admin or i.role in ('owner','admin')) where id = acc.id and (profile_id is null or profile_id = uid);
    else
      insert into user_accounts (id, player_id, username, is_admin, theme, settings, profile_id, circuit_id, created_at)
      values ((extract(epoch from clock_timestamp())*1000)::bigint, i.player_id, coalesce(pname,'villain'), i.role in ('owner','admin'), 'default', '{}'::jsonb, uid, i.circuit_id, now());
    end if;
  else
    perform link_membership(i.circuit_id, uid, null, i.role);
  end if;
  update circuit_invites set uses = uses + 1 where id = i.id;
  return jsonb_build_object('ok', true, 'circuit_id', i.circuit_id, 'player_id', i.player_id, 'player_name', pname);
end $function$;

drop function if exists public.pv_redeem_link_token(text);
drop function if exists public.pv_legacy_login(text, text);
create function public.pv_legacy_login(p_username text, p_password text)
returns table(id bigint, player_id bigint, profile_id uuid, username text, is_admin boolean, theme text, settings jsonb, last_login timestamptz, created_at timestamptz, updated_at timestamptz, circuit_id bigint)
language plpgsql security definer set search_path = public, pg_temp as $function$
DECLARE v_expected text;
BEGIN
  IF p_username IS NULL OR p_password IS NULL OR length(p_username) = 0 OR length(p_password) = 0 THEN RETURN; END IF;
  v_expected := encode(extensions.digest(convert_to(p_password || '_pv_salt_2026', 'UTF8'), 'sha256'), 'hex');
  RETURN QUERY
    SELECT ua.id, ua.player_id, ua.profile_id, ua.username, ua.is_admin, ua.theme, ua.settings, ua.last_login, ua.created_at, ua.updated_at, ua.circuit_id
    FROM public.user_accounts ua WHERE lower(ua.username) = lower(p_username) AND ua.password_hash = v_expected LIMIT 1;
END;
$function$;
grant execute on function public.pv_legacy_login(text, text) to anon, authenticated;
drop table if exists public.pv_link_tokens;

create or replace function public.ensure_player_invite(p_circuit bigint, p_player bigint, p_admin boolean default false)
returns text language plpgsql security definer set search_path = public as $function$
declare code text;
begin
  select ci.code into code from circuit_invites ci where ci.player_id = p_player and ci.uses < coalesce(ci.max_uses, 1) and (ci.expires_at is null or ci.expires_at > now()) limit 1;
  if code is not null then return code; end if;
  code := 'VLN-' || upper(substr(md5(random()::text || p_player::text || clock_timestamp()::text), 1, 5));
  insert into circuit_invites (circuit_id, code, role, player_id, max_uses, expires_at)
  values (coalesce(p_circuit, 1), code, case when p_admin then 'admin' else 'member' end, p_player, 1, now() + interval '60 days');
  return code;
end $function$;

-- Grants as they were
grant insert, update, delete, truncate, references, trigger on all tables in schema public to anon;
grant truncate, references, trigger on all tables in schema public to authenticated;
alter default privileges for role postgres in schema public grant insert, update, delete, truncate, references, trigger on tables to anon;
grant execute on function public.pv_claim_scorer(bigint, text, boolean), public.pv_release_scorer(bigint, text),
  public.pv_admin_set_password(bigint, text), public.pv_set_own_password(text, text), public.pv_is_admin() to public, anon;
