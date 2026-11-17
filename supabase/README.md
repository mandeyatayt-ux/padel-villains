# Database changes

Every change to the live Supabase database goes in `migrations/` as a dated
SQL file, committed together with the app change that needs it.

- `migrations/20261117120000_lockdown.sql` — applied 17 Nov 2026. Strangers can
  read but not write; results, scheduling and players are written only by
  circuit staff (app admin, or circuit owner/admin/scorer); a signed-in player
  can edit only their own profile fields; accounts can be claimed only through
  an invite or a one-time token from a successful name-and-password sign-in.
- `rollback/20261117120000_lockdown_rollback.sql` — exact reversal. It reopens
  every hole the lockdown closed; use only if scoring breaks and a forward fix
  is not possible.

Before the lockdown a full copy of every public table was taken into the
schema `pv_snapshot_20261117` (not reachable through the API). Drop it once an
off-platform `pg_dump` exists:

    drop schema pv_snapshot_20261117 cascade;

The schema as it stood before 17 Nov is not in this folder yet; the October
security work was applied by hand. A baseline dump should be added here.

To give someone scoring rights without making them an admin, run in the
Supabase SQL editor (their profile must exist, i.e. they have signed in once):

    update circuit_members set role = 'scorer'
     where circuit_id = 1 and profile_id = '<their profile id>';
