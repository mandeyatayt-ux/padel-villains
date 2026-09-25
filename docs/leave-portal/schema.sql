-- =====================================================================
-- Leave Management Portal — draft schema (v0.1)
-- Target: Supabase Postgres (15+). Assumes Supabase `auth` schema exists.
-- Business rules live in SECURITY DEFINER functions; clients get read
-- access via RLS and write access only through RPCs.
-- =====================================================================

create extension if not exists btree_gist;

-- ---------------------------------------------------------------------
-- Enums
-- ---------------------------------------------------------------------
create type app_role as enum (
  'employee','leave_clerk','supervisor','hod','hr_officer','hr_admin',
  'payroll_officer','it_admin','executive','auditor'
);
create type role_scope as enum ('global','site','department');
create type employment_type as enum ('permanent','fixed_term','casual','contractor');
create type pattern_kind as enum ('weekly','rotation');
create type accrual_method as enum ('monthly','per_days_worked','upfront','none');
create type half_day as enum ('full','am','pm');
create type request_status as enum (
  'draft','pending','approved','rejected','cancelled',
  'cancellation_requested','recalled'
);
create type approval_decision as enum ('pending','approved','rejected','skipped','escalated');
create type approver_rule as enum ('line_manager','hod','hr','role');
create type ledger_entry_type as enum (
  'opening','accrual','taken','reversal','adjustment','forfeiture',
  'carry_over','expiry','encashment','toil_earned'
);
create type rule_severity as enum ('hard','soft');
create type proxy_confirmation as enum ('signed_form','supervisor_verbal','sms_otp','none');
create type period_status as enum ('open','locked');

-- ---------------------------------------------------------------------
-- Organisation
-- ---------------------------------------------------------------------
create table legal_entities (
  id          uuid primary key default gen_random_uuid(),
  name        text not null unique,
  belina_company_code text
);

create table holiday_calendars (
  id    uuid primary key default gen_random_uuid(),
  name  text not null unique            -- e.g. 'Zimbabwe'
);

create table public_holidays (
  calendar_id uuid not null references holiday_calendars on delete cascade,
  holiday_date date not null,
  name        text not null,
  primary key (calendar_id, holiday_date)
);

create table sites (
  id          uuid primary key default gen_random_uuid(),
  legal_entity_id uuid not null references legal_entities,
  name        text not null unique,     -- e.g. 'Shaft 2', 'Head Office Harare'
  holiday_calendar_id uuid not null references holiday_calendars,
  is_remote   boolean not null default false
);

create table work_patterns (
  id            uuid primary key default gen_random_uuid(),
  name          text not null unique,   -- 'Office Mon-Fri', '4on4off 12h', '14/14 FIFO'
  kind          pattern_kind not null,
  cycle_length  int check (kind = 'weekly' or cycle_length > 0),
  observes_public_holidays boolean not null default true,
  hours_per_shift numeric(4,2) not null default 8
);

-- weekly patterns: one row per ISO weekday (1=Mon..7=Sun)
create table work_pattern_days (
  work_pattern_id uuid references work_patterns on delete cascade,
  iso_dow   int check (iso_dow between 1 and 7),
  is_working boolean not null,
  portion   numeric(3,2) not null default 1,   -- e.g. Saturday half day = 0.5
  primary key (work_pattern_id, iso_dow)
);

-- rotation patterns: one row per day in the cycle (0..cycle_length-1)
create table rotation_days (
  work_pattern_id uuid references work_patterns on delete cascade,
  day_index  int check (day_index >= 0),
  is_working boolean not null,
  shift_code text,                       -- 'D','N','OFF'
  primary key (work_pattern_id, day_index)
);

create table employees (
  id              uuid primary key default gen_random_uuid(),
  employee_no     text not null unique,
  first_name      text not null,
  last_name       text not null,
  email           text unique,           -- nullable: frontline staff
  mobile          text,                  -- for SMS notifications (phase 2)
  entra_object_id text unique,           -- Entra ID `oid`, preferred link key
  auth_user_id    uuid unique references auth.users on delete set null,
  site_id         uuid not null references sites,
  department_id   uuid,                  -- FK added after departments
  manager_id      uuid references employees,
  job_title       text,
  grade           text,
  employment_type employment_type not null default 'permanent',
  critical_roles  text[] not null default '{}',   -- {'blaster','winder_driver','shift_boss'}
  work_pattern_id uuid not null references work_patterns,
  rotation_anchor_date date,             -- day_index 0 of the rotation cycle
  hire_date       date not null,
  termination_date date,
  belina_employee_code text unique,
  is_active       boolean generated always as (termination_date is null) stored,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  check (manager_id is distinct from id)
);

create table departments (
  id          uuid primary key default gen_random_uuid(),
  site_id     uuid references sites,     -- null = cross-site department
  name        text not null,
  cost_centre text,
  hod_employee_id uuid references employees,
  unique (site_id, name)
);
alter table employees
  add constraint employees_department_fk foreign key (department_id) references departments;

create index on employees (manager_id);
create index on employees (department_id);
create index on employees (site_id);

-- ---------------------------------------------------------------------
-- Access control
-- ---------------------------------------------------------------------
create table user_roles (
  id          uuid primary key default gen_random_uuid(),
  employee_id uuid not null references employees on delete cascade,
  role        app_role not null,
  scope       role_scope not null default 'global',
  scope_id    uuid,                      -- site_id or department_id
  valid_from  date not null default current_date,
  valid_to    date,
  granted_by  uuid references employees,
  check ((scope = 'global') = (scope_id is null)),
  unique (employee_id, role, scope, scope_id)
);

-- who may apply on behalf of whom (for staff without email/login)
create table proxy_assignments (
  id            uuid primary key default gen_random_uuid(),
  proxy_employee_id uuid not null references employees on delete cascade,
  target_employee_id   uuid references employees on delete cascade,
  target_department_id uuid references departments,
  target_site_id       uuid references sites,
  valid_from    date not null default current_date,
  valid_to      date,
  check (num_nonnulls(target_employee_id, target_department_id, target_site_id) = 1)
);

create table approval_delegations (
  id            uuid primary key default gen_random_uuid(),
  delegator_id  uuid not null references employees,
  delegate_id   uuid not null references employees,
  period        daterange not null,
  reason        text,
  check (delegator_id <> delegate_id),
  exclude using gist (delegator_id with =, period with &&)
);

-- ---------------------------------------------------------------------
-- Leave configuration
-- ---------------------------------------------------------------------
create table leave_types (
  id            uuid primary key default gen_random_uuid(),
  code          text not null unique,    -- 'ANNUAL','SICK','MAT','SPECIAL','UNPAID','IOD','TOIL','STUDY','TRAVEL'
  name          text not null,
  colour        text not null default '#64748b',
  is_paid       boolean not null default true,
  deducts_balance boolean not null default true,   -- IOD/TRAVEL = false
  counts_calendar_days boolean not null default false, -- maternity = true
  allow_half_day boolean not null default true,
  min_notice_days int not null default 0,
  max_consecutive_days numeric,
  allow_negative_days numeric not null default 0,  -- how far below zero
  requires_attachment_after_days numeric,          -- e.g. sick: 2
  requires_fitness_clearance_after_days numeric,   -- e.g. sick: 5 (mining)
  requires_reference boolean not null default false, -- IOD incident no.
  visible_to_peers boolean not null default false, -- peers only see 'Away'
  belina_leave_code text,
  is_active     boolean not null default true
);

create table leave_policies (
  id              uuid primary key default gen_random_uuid(),
  leave_type_id   uuid not null references leave_types,
  name            text not null,
  -- eligibility filters (null = any)
  employment_types employment_type[],
  grades          text[],
  site_ids        uuid[],
  min_service_months int not null default 0,
  -- entitlement
  accrual_method  accrual_method not null,
  annual_entitlement numeric(6,2) not null default 0,
  cycle_basis     text not null default 'calendar' check (cycle_basis in ('calendar','anniversary','rolling_12m')),
  max_accumulation numeric(6,2),         -- annual leave: 90
  carry_over_max  numeric(6,2),          -- null = carry everything (up to cap)
  -- sick-type pay bands: [{"up_to_days":90,"pay_rate":1.0},{"up_to_days":180,"pay_rate":0.5}]
  pay_bands       jsonb,
  priority        int not null default 100,  -- lower wins when several match
  effective_from  date not null,
  effective_to    date
);

create table approval_chains (
  id            uuid primary key default gen_random_uuid(),
  leave_type_id uuid not null references leave_types,
  site_id       uuid references sites,   -- null = default for all sites
  unique (leave_type_id, site_id)
);

create table approval_chain_steps (
  chain_id      uuid references approval_chains on delete cascade,
  step_no       int not null,
  rule          approver_rule not null,
  role          app_role,                -- when rule = 'role'
  skip_if_days_lte numeric,              -- e.g. skip HOD for <= 3 days
  sla_hours     int not null default 48,
  primary key (chain_id, step_no),
  check ((rule = 'role') = (role is not null))
);

create table coverage_rules (
  id            uuid primary key default gen_random_uuid(),
  name          text not null,
  department_id uuid references departments,
  site_id       uuid references sites,
  critical_role text,                    -- matches employees.critical_roles
  max_absent    int,                     -- absolute cap
  min_present   int,                     -- alternative: minimum on duty
  severity      rule_severity not null default 'soft',
  check (num_nonnulls(max_absent, min_present) >= 1)
);

create table blackout_periods (
  id            uuid primary key default gen_random_uuid(),
  name          text not null,           -- 'Plant shutdown Dec 2026'
  period        daterange not null,
  site_id       uuid references sites,
  department_id uuid references departments,
  leave_type_ids uuid[],                 -- null = all types except sick/IOD
  severity      rule_severity not null default 'hard'
);

-- ---------------------------------------------------------------------
-- Requests
-- ---------------------------------------------------------------------
create sequence leave_request_no_seq;

create table leave_requests (
  id            uuid primary key default gen_random_uuid(),
  ref_no        text not null unique
                 default 'LV-' || to_char(now(), 'YYYY') || '-' || lpad(nextval('leave_request_no_seq')::text, 5, '0'),
  employee_id   uuid not null references employees,
  leave_type_id uuid not null references leave_types,
  start_date    date not null,
  end_date      date not null,
  start_portion half_day not null default 'full',
  end_portion   half_day not null default 'full',
  days_requested numeric(6,2) not null,  -- computed by fn_calculate_leave_days
  status        request_status not null default 'pending',
  reason        text,
  external_reference text,               -- IOD incident no., court case no.
  handover_to_id uuid references employees,
  contact_while_away text,
  -- proxy submission
  submitted_by_id uuid not null references employees,
  on_behalf     boolean generated always as (submitted_by_id <> employee_id) stored,
  proxy_confirmation proxy_confirmation,
  -- overrides & flags
  override_reason text,                  -- HR overrode blackout/coverage/notice
  coverage_warnings jsonb,
  attachment_pending boolean not null default false,
  fitness_clearance_required boolean not null default false,
  fitness_cleared_at timestamptz,
  fitness_cleared_by uuid references employees,
  submitted_at  timestamptz not null default now(),
  decided_at    timestamptz,
  updated_at    timestamptz not null default now(),
  check (end_date >= start_date),
  check (not on_behalf or proxy_confirmation is not null)
);
create index on leave_requests (employee_id, start_date);
create index on leave_requests (status);

-- one row per calendar date in the request
create table leave_request_days (
  request_id    uuid references leave_requests on delete cascade,
  leave_date    date not null,
  is_chargeable boolean not null,
  portion       numeric(3,2) not null,   -- 0, 0.5, 1
  exclusion_reason text,                 -- 'rest_day','public_holiday'
  pay_rate      numeric(3,2) not null default 1,  -- sick bands: 1.0 / 0.5 / 0
  primary key (request_id, leave_date)
);
create index on leave_request_days (leave_date);

create table leave_approvals (
  id            uuid primary key default gen_random_uuid(),
  request_id    uuid not null references leave_requests on delete cascade,
  step_no       int not null,
  approver_id   uuid references employees,   -- resolved approver
  acted_by_id   uuid references employees,   -- may be a delegate
  decision      approval_decision not null default 'pending',
  comment       text,
  due_at        timestamptz,
  acted_at      timestamptz,
  unique (request_id, step_no),
  check (decision <> 'rejected' or comment is not null)
);
create index on leave_approvals (approver_id) where decision = 'pending';

create table attachments (
  id            uuid primary key default gen_random_uuid(),
  request_id    uuid not null references leave_requests on delete cascade,
  kind          text not null check (kind in ('medical_certificate','signed_form','court_order','other')),
  storage_path  text not null,           -- private bucket 'leave-attachments'
  uploaded_by_id uuid not null references employees,
  uploaded_at   timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- Payroll periods & ledger
-- ---------------------------------------------------------------------
create table payroll_periods (
  id        uuid primary key default gen_random_uuid(),
  legal_entity_id uuid not null references legal_entities,
  period    daterange not null,
  label     text not null,               -- '2026-09'
  status    period_status not null default 'open',
  locked_at timestamptz,
  locked_by uuid references employees,
  exclude using gist (legal_entity_id with =, period with &&)
);

-- APPEND-ONLY. Balance = SUM(amount).
create table leave_ledger (
  id            bigint generated always as identity primary key,
  employee_id   uuid not null references employees,
  leave_type_id uuid not null references leave_types,
  entry_type    ledger_entry_type not null,
  effective_date date not null,
  amount        numeric(7,2) not null,   -- +credit / -debit
  period_key    text,                    -- '2026-09' for idempotent accruals
  request_id    uuid references leave_requests,
  reason        text,
  created_by_id uuid references employees,   -- null = system job
  created_at    timestamptz not null default now(),
  check (entry_type not in ('adjustment','forfeiture','expiry','encashment') or reason is not null)
);
create unique index leave_ledger_accrual_once
  on leave_ledger (employee_id, leave_type_id, entry_type, period_key)
  where entry_type in ('accrual','forfeiture','carry_over','expiry');
create index on leave_ledger (employee_id, leave_type_id, effective_date);

create or replace function trg_ledger_immutable() returns trigger language plpgsql as $$
begin
  raise exception 'leave_ledger is append-only; post a reversal/adjustment instead';
end $$;
create trigger ledger_no_update before update or delete on leave_ledger
  for each row execute function trg_ledger_immutable();

-- ---------------------------------------------------------------------
-- Payroll export, notifications, integrations, audit
-- ---------------------------------------------------------------------
create table payroll_export_batches (
  id            uuid primary key default gen_random_uuid(),
  payroll_period_id uuid not null references payroll_periods,
  generated_by_id uuid not null references employees,
  generated_at  timestamptz not null default now(),
  file_path     text,
  line_count    int not null default 0
);

create table payroll_export_lines (
  batch_id      uuid references payroll_export_batches on delete cascade,
  line_no       int not null,
  employee_id   uuid not null references employees,
  belina_employee_code text,
  belina_leave_code text,
  from_date     date not null,
  to_date       date not null,
  days          numeric(6,2) not null,
  pay_rate      numeric(3,2) not null,
  line_kind     text not null check (line_kind in ('taken','adjustment','encashment')),
  request_id    uuid references leave_requests,
  primary key (batch_id, line_no)
);

create table notifications (
  id            bigint generated always as identity primary key,
  recipient_id  uuid not null references employees,
  channel       text not null check (channel in ('email','teams','sms','in_app')),
  template      text not null,           -- 'request_submitted','approval_needed',...
  payload       jsonb not null,
  status        text not null default 'queued' check (status in ('queued','sent','failed','skipped')),
  attempts      int not null default 0,
  last_error    text,
  created_at    timestamptz not null default now(),
  sent_at       timestamptz
);
create index on notifications (status) where status = 'queued';

create table integration_runs (
  id          bigint generated always as identity primary key,
  integration text not null,             -- 'entra_users','belina_employees','belina_export'
  started_at  timestamptz not null default now(),
  finished_at timestamptz,
  status      text not null default 'running',
  stats       jsonb,
  errors      jsonb
);

create table audit_log (
  id          bigint generated always as identity primary key,
  table_name  text not null,
  row_id      text not null,
  action      text not null,
  actor_auth_id uuid,
  old_data    jsonb,
  new_data    jsonb,
  at          timestamptz not null default now()
);

create or replace function trg_audit() returns trigger language plpgsql security definer as $$
begin
  insert into audit_log (table_name, row_id, action, actor_auth_id, old_data, new_data)
  values (tg_table_name,
          coalesce((to_jsonb(new)->>'id'), (to_jsonb(old)->>'id')),
          tg_op, auth.uid(),
          case when tg_op <> 'INSERT' then to_jsonb(old) end,
          case when tg_op <> 'DELETE' then to_jsonb(new) end);
  return coalesce(new, old);
end $$;

do $$
declare t text;
begin
  foreach t in array array['employees','user_roles','proxy_assignments','leave_types',
    'leave_policies','leave_requests','leave_approvals','leave_ledger','coverage_rules',
    'blackout_periods','payroll_periods','approval_delegations']
  loop
    execute format('create trigger audit_%1$s after insert or update or delete on %1$I
                    for each row execute function trg_audit()', t);
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- Views
-- ---------------------------------------------------------------------
-- balance   = everything posted up to today
-- booked    = approved leave dated in the future (already committed)
-- pending   = awaiting approval (reserved)
-- available = balance - booked - pending   <- what the apply form checks
create or replace view v_leave_balances with (security_invoker = true) as
with led as (
  select l.employee_id, l.leave_type_id,
         sum(l.amount) filter (where l.effective_date <= current_date) as balance,
         -sum(l.amount) filter (where l.effective_date > current_date
                                  and l.entry_type in ('taken','reversal')) as booked
  from leave_ledger l group by 1, 2
), pend as (
  select r.employee_id, r.leave_type_id, sum(r.days_requested) as pending
  from leave_requests r where r.status = 'pending' group by 1, 2
)
select e.id as employee_id, lt.id as leave_type_id, lt.code,
       coalesce(led.balance, 0) as balance,
       coalesce(led.booked, 0)  as booked,
       coalesce(pend.pending, 0) as pending,
       coalesce(led.balance, 0) - coalesce(led.booked, 0) - coalesce(pend.pending, 0) as available
from employees e
cross join leave_types lt
left join led  on led.employee_id = e.id and led.leave_type_id = lt.id
left join pend on pend.employee_id = e.id and pend.leave_type_id = lt.id
where lt.deducts_balance;

-- who is off on which day (drives wallchart, "off today", coverage checks)
create or replace view v_absence_days with (security_invoker = true) as
select d.leave_date, r.employee_id, r.leave_type_id, r.status, d.portion, r.id as request_id
from leave_request_days d
join leave_requests r on r.id = d.request_id
where r.status in ('pending','approved','cancellation_requested')
  and d.portion > 0;

-- ---------------------------------------------------------------------
-- Helper functions (used by RLS and RPCs)
-- ---------------------------------------------------------------------
create or replace function current_employee_id() returns uuid
language sql stable security definer set search_path = public as $$
  select id from employees where auth_user_id = auth.uid()
$$;

create or replace function has_role(p_role app_role, p_site uuid default null, p_dept uuid default null)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from user_roles ur
    where ur.employee_id = current_employee_id()
      and ur.role = p_role
      and current_date >= ur.valid_from
      and (ur.valid_to is null or current_date <= ur.valid_to)
      and (ur.scope = 'global'
           or (ur.scope = 'site' and ur.scope_id = p_site)
           or (ur.scope = 'department' and ur.scope_id = p_dept))
  )
$$;

-- Can the current user see this employee's leave detail?
create or replace function can_view_employee(p_employee uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from employees e
    where e.id = p_employee
      and (
        e.id = current_employee_id()
        or e.manager_id = current_employee_id()
        or exists (select 1 from departments d where d.id = e.department_id
                   and d.hod_employee_id = current_employee_id())
        or has_role('hod', e.site_id, e.department_id)
        or has_role('hr_officer', e.site_id, e.department_id)
        or has_role('hr_admin')
        or has_role('payroll_officer', e.site_id)
        or has_role('auditor')
        or exists (select 1 from proxy_assignments p
                   where p.proxy_employee_id = current_employee_id()
                     and current_date between p.valid_from and coalesce(p.valid_to, 'infinity')
                     and (p.target_employee_id = e.id or p.target_department_id = e.department_id
                          or p.target_site_id = e.site_id))
      )
  )
$$;

-- Is this date a scheduled working day for the employee? Returns portion (0..1).
create or replace function fn_scheduled_portion(p_employee uuid, p_date date) returns numeric
language sql stable set search_path = public as $$
  select case wp.kind
    when 'weekly' then coalesce((select case when wd.is_working then wd.portion else 0 end
                                 from work_pattern_days wd
                                 where wd.work_pattern_id = wp.id
                                   and wd.iso_dow = extract(isodow from p_date)::int), 0)
    when 'rotation' then coalesce((select case when rd.is_working then 1 else 0 end
                                   from rotation_days rd
                                   where rd.work_pattern_id = wp.id
                                     and rd.day_index = ((p_date - e.rotation_anchor_date) % wp.cycle_length
                                                         + wp.cycle_length) % wp.cycle_length), 0)
  end
  from employees e join work_patterns wp on wp.id = e.work_pattern_id
  where e.id = p_employee
$$;

-- ---------------------------------------------------------------------
-- Core logic: chargeable-day calculation (roster + holiday aware)
-- ---------------------------------------------------------------------
create or replace function fn_calculate_leave_days(
  p_employee uuid, p_leave_type uuid, p_start date, p_end date,
  p_start_portion half_day default 'full', p_end_portion half_day default 'full'
) returns table (leave_date date, is_chargeable boolean, portion numeric, exclusion_reason text)
language plpgsql stable set search_path = public as $$
declare
  v_calendar_days boolean;
  v_observes_ph   boolean;
  v_cal           uuid;
  d               date;
  v_sched         numeric;
  v_is_ph         boolean;
  v_portion       numeric;
begin
  select lt.counts_calendar_days into v_calendar_days from leave_types lt where lt.id = p_leave_type;
  select wp.observes_public_holidays, s.holiday_calendar_id into v_observes_ph, v_cal
    from employees e join work_patterns wp on wp.id = e.work_pattern_id
    join sites s on s.id = e.site_id where e.id = p_employee;

  d := p_start;
  while d <= p_end loop
    v_is_ph := exists (select 1 from public_holidays ph where ph.calendar_id = v_cal and ph.holiday_date = d);
    v_sched := fn_scheduled_portion(p_employee, d);

    if v_calendar_days then
      v_portion := 1; exclusion_reason := null;
    elsif v_sched = 0 then
      v_portion := 0; exclusion_reason := 'rest_day';
    elsif v_is_ph and v_observes_ph then
      v_portion := 0; exclusion_reason := 'public_holiday';
    else
      v_portion := v_sched; exclusion_reason := null;
    end if;

    if v_portion > 0 and ((d = p_start and p_start_portion <> 'full')
                       or (d = p_end   and p_end_portion   <> 'full')) then
      v_portion := least(v_portion, 0.5);
    end if;

    leave_date := d; is_chargeable := v_portion > 0; portion := v_portion;
    return next;
    d := d + 1;
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- Core logic: submit request (validation + routing). Called via RPC.
-- ---------------------------------------------------------------------
create or replace function fn_submit_leave_request(
  p_employee uuid, p_leave_type uuid, p_start date, p_end date,
  p_start_portion half_day default 'full', p_end_portion half_day default 'full',
  p_reason text default null, p_proxy_confirmation proxy_confirmation default null,
  p_external_reference text default null, p_handover_to uuid default null
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_actor   uuid := current_employee_id();
  v_emp     employees%rowtype;
  v_type    leave_types%rowtype;
  v_days    numeric;
  v_avail   numeric;
  v_req     uuid;
  v_warn    jsonb := '[]'::jsonb;
  r         record;
begin
  select * into v_emp  from employees   where id = p_employee;
  select * into v_type from leave_types where id = p_leave_type;
  if v_emp.id is null or not v_emp.is_active then raise exception 'Employee not found or inactive'; end if;
  if v_type.id is null or not v_type.is_active then raise exception 'Leave type not available'; end if;

  -- 1. actor must be self or a valid proxy
  if v_actor is distinct from p_employee then
    if not exists (select 1 from proxy_assignments p
                   where p.proxy_employee_id = v_actor
                     and current_date between p.valid_from and coalesce(p.valid_to, 'infinity')
                     and (p.target_employee_id = p_employee
                          or p.target_department_id = v_emp.department_id
                          or p.target_site_id = v_emp.site_id))
       and not has_role('hr_officer', v_emp.site_id, v_emp.department_id)
       and not has_role('hr_admin') then
      raise exception 'You may not apply on behalf of this employee';
    end if;
    if p_proxy_confirmation is null then
      raise exception 'Proxy submissions must record how the employee confirmed';
    end if;
  end if;

  -- 2. basic date rules
  if p_end < p_start then raise exception 'End date before start date'; end if;
  if p_start < current_date + v_type.min_notice_days
     and not has_role('hr_officer', v_emp.site_id) and not has_role('hr_admin') then
    raise exception 'This leave type needs % days notice', v_type.min_notice_days;
  end if;
  if v_type.requires_reference and p_external_reference is null then
    raise exception 'A reference number is required for %', v_type.name;
  end if;

  -- 3. overlap with own active requests
  if exists (select 1 from leave_requests x
             where x.employee_id = p_employee
               and x.status in ('pending','approved','cancellation_requested')
               and daterange(x.start_date, x.end_date, '[]') && daterange(p_start, p_end, '[]')) then
    raise exception 'Overlaps an existing request';
  end if;

  -- 4. chargeable days
  select coalesce(sum(c.portion), 0) into v_days
    from fn_calculate_leave_days(p_employee, p_leave_type, p_start, p_end, p_start_portion, p_end_portion) c;
  if v_days = 0 then raise exception 'No scheduled working days in the selected range'; end if;
  if v_type.max_consecutive_days is not null and v_days > v_type.max_consecutive_days then
    raise exception 'Maximum % days per request', v_type.max_consecutive_days;
  end if;

  -- 5. balance (TODO: add projected accrual up to p_start)
  if v_type.deducts_balance then
    select coalesce(b.available, 0) into v_avail from v_leave_balances b
      where b.employee_id = p_employee and b.leave_type_id = p_leave_type;
    if coalesce(v_avail, 0) - v_days < -v_type.allow_negative_days then
      raise exception 'Insufficient balance: % available, % requested', coalesce(v_avail, 0), v_days;
    end if;
  end if;

  -- 6. blackouts
  for r in select * from blackout_periods bp
           where bp.period && daterange(p_start, p_end, '[]')
             and (bp.site_id is null or bp.site_id = v_emp.site_id)
             and (bp.department_id is null or bp.department_id = v_emp.department_id)
             and (bp.leave_type_ids is null or p_leave_type = any(bp.leave_type_ids))
  loop
    if r.severity = 'hard' then raise exception 'Blocked by blackout period: %', r.name; end if;
    v_warn := v_warn || jsonb_build_object('type','blackout','rule',r.name);
  end loop;

  -- 7. coverage rules (max_absent variant; min_present handled in app/report)
  for r in
    select cr.name, cr.severity, cr.max_absent, a.leave_date, count(distinct a.employee_id) as off
    from coverage_rules cr
    join employees peer on peer.id <> p_employee
         and (cr.department_id is null or peer.department_id = cr.department_id)
         and (cr.site_id is null or peer.site_id = cr.site_id)
         and (cr.critical_role is null or cr.critical_role = any(peer.critical_roles))
    join v_absence_days a on a.employee_id = peer.id and a.leave_date between p_start and p_end
    where cr.max_absent is not null
      and (cr.department_id is null or cr.department_id = v_emp.department_id)
      and (cr.site_id is null or cr.site_id = v_emp.site_id)
      and (cr.critical_role is null or cr.critical_role = any(v_emp.critical_roles))
    group by cr.id, cr.name, cr.severity, cr.max_absent, a.leave_date
    having count(distinct a.employee_id) + 1 > cr.max_absent
  loop
    if r.severity = 'hard' then
      raise exception 'Minimum manning rule "%" breached on %', r.name, r.leave_date;
    end if;
    v_warn := v_warn || jsonb_build_object('type','coverage','rule',r.name,'date',r.leave_date,'off',r.off);
  end loop;

  -- 8. create request + days
  insert into leave_requests (employee_id, leave_type_id, start_date, end_date, start_portion, end_portion,
      days_requested, reason, external_reference, handover_to_id, submitted_by_id, proxy_confirmation,
      coverage_warnings, attachment_pending, fitness_clearance_required)
  values (p_employee, p_leave_type, p_start, p_end, p_start_portion, p_end_portion,
      v_days, p_reason, p_external_reference, p_handover_to, coalesce(v_actor, p_employee),
      case when v_actor is distinct from p_employee then p_proxy_confirmation end,
      nullif(v_warn, '[]'::jsonb),
      v_type.requires_attachment_after_days is not null and v_days > v_type.requires_attachment_after_days,
      v_type.requires_fitness_clearance_after_days is not null and v_days > v_type.requires_fitness_clearance_after_days)
  returning id into v_req;

  insert into leave_request_days (request_id, leave_date, is_chargeable, portion, exclusion_reason)
  select v_req, c.leave_date, c.is_chargeable, c.portion, c.exclusion_reason
  from fn_calculate_leave_days(p_employee, p_leave_type, p_start, p_end, p_start_portion, p_end_portion) c;

  -- 9. first approval step
  perform fn_route_next_approval(v_req);
  return v_req;
end $$;

-- Resolve approver for a rule, following delegations and preventing self-approval.
create or replace function fn_resolve_approver(p_request uuid, p_rule approver_rule, p_role app_role)
returns uuid language plpgsql stable security definer set search_path = public as $$
declare
  v_req leave_requests%rowtype;
  v_emp employees%rowtype;
  v_approver uuid;
begin
  select * into v_req from leave_requests where id = p_request;
  select * into v_emp from employees where id = v_req.employee_id;

  v_approver := case p_rule
    when 'line_manager' then v_emp.manager_id
    when 'hod' then (select hod_employee_id from departments where id = v_emp.department_id)
    when 'hr' then (select ur.employee_id from user_roles ur
                    where ur.role = 'hr_officer'
                      and (ur.scope = 'global' or (ur.scope = 'site' and ur.scope_id = v_emp.site_id))
                      and ur.employee_id not in (v_req.employee_id, v_req.submitted_by_id)
                    order by ur.scope desc limit 1)   -- site-scoped HR before global
    when 'role' then (select ur.employee_id from user_roles ur where ur.role = p_role
                      and ur.employee_id not in (v_req.employee_id, v_req.submitted_by_id) limit 1)
  end;

  -- no self-approval / proxy-approval: escalate to approver's manager
  if v_approver in (v_req.employee_id, v_req.submitted_by_id) then
    v_approver := (select manager_id from employees where id = v_approver);
  end if;

  -- delegation
  select coalesce((select d.delegate_id from approval_delegations d
                   where d.delegator_id = v_approver and d.period @> current_date), v_approver)
    into v_approver;
  return v_approver;
end $$;

-- Create the next pending approval step, or finalise the request.
create or replace function fn_route_next_approval(p_request uuid) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_req   leave_requests%rowtype;
  v_emp   employees%rowtype;
  v_chain uuid;
  v_step  approval_chain_steps%rowtype;
  v_last  int;
  v_approver uuid;
begin
  select * into v_req from leave_requests where id = p_request;
  select * into v_emp from employees where id = v_req.employee_id;
  select id into v_chain from approval_chains
    where leave_type_id = v_req.leave_type_id and (site_id = v_emp.site_id or site_id is null)
    order by site_id nulls last limit 1;
  select coalesce(max(step_no), 0) into v_last from leave_approvals where request_id = p_request;

  loop
    select * into v_step from approval_chain_steps
      where chain_id = v_chain and step_no > v_last order by step_no limit 1;
    if v_step.chain_id is null then
      perform fn_finalise_approval(p_request);
      return;
    end if;
    if v_step.skip_if_days_lte is not null and v_req.days_requested <= v_step.skip_if_days_lte then
      insert into leave_approvals (request_id, step_no, decision, acted_at)
        values (p_request, v_step.step_no, 'skipped', now());
      v_last := v_step.step_no;
      continue;
    end if;
    v_approver := fn_resolve_approver(p_request, v_step.rule, v_step.role);
    if v_approver is null then raise exception 'No approver found for step % (%)', v_step.step_no, v_step.rule; end if;
    -- same person already approved an earlier step (e.g. manager is also HOD): don't ask twice
    if exists (select 1 from leave_approvals a where a.request_id = p_request
               and a.decision = 'approved' and v_approver in (a.approver_id, a.acted_by_id)) then
      insert into leave_approvals (request_id, step_no, approver_id, decision, comment, acted_at)
        values (p_request, v_step.step_no, v_approver, 'skipped', 'Already approved at earlier step', now());
      v_last := v_step.step_no;
      continue;
    end if;
    insert into leave_approvals (request_id, step_no, approver_id, due_at)
      values (p_request, v_step.step_no, v_approver, now() + make_interval(hours => v_step.sla_hours));
    insert into notifications (recipient_id, channel, template, payload)
      values (v_approver, 'email', 'approval_needed', jsonb_build_object('request_id', p_request));
    return;
  end loop;
end $$;

-- Approver action (RPC)
create or replace function fn_decide_leave_request(p_request uuid, p_approve boolean, p_comment text default null)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_actor uuid := current_employee_id();
  v_appr  leave_approvals%rowtype;
begin
  select * into v_appr from leave_approvals
    where request_id = p_request and decision = 'pending'
    order by step_no limit 1 for update;
  if v_appr.id is null then raise exception 'Nothing pending on this request'; end if;
  if v_appr.approver_id is distinct from v_actor and not has_role('hr_admin') then
    raise exception 'You are not the approver for this step';
  end if;
  if not p_approve and p_comment is null then raise exception 'A comment is required to reject'; end if;
  -- certificates often arrive late: allow early steps, block the final step until uploaded
  if p_approve and exists (select 1 from leave_requests where id = p_request and attachment_pending)
     and not exists (select 1 from leave_requests r
                     join employees e on e.id = r.employee_id
                     join approval_chains c on c.leave_type_id = r.leave_type_id
                                           and (c.site_id = e.site_id or c.site_id is null)
                     join approval_chain_steps s on s.chain_id = c.id
                     where r.id = p_request and s.step_no > v_appr.step_no) then
    raise exception 'Supporting document outstanding — cannot give final approval';
  end if;

  update leave_approvals set decision = case when p_approve then 'approved' else 'rejected' end::approval_decision,
         acted_by_id = v_actor, comment = p_comment, acted_at = now()
   where id = v_appr.id;

  if p_approve then
    perform fn_route_next_approval(p_request);
  else
    update leave_requests set status = 'rejected', decided_at = now(), updated_at = now() where id = p_request;
  end if;
end $$;

-- Final approval: set status, apply sick pay bands, post ledger debit(s) split by month.
create or replace function fn_finalise_approval(p_request uuid) returns void
language plpgsql security definer set search_path = public as $$
declare v_req leave_requests%rowtype; v_type leave_types%rowtype;
begin
  select * into v_req from leave_requests where id = p_request for update;
  select * into v_type from leave_types where id = v_req.leave_type_id;
  update leave_requests set status = 'approved', decided_at = now(), updated_at = now() where id = p_request;

  -- TODO: pay bands — set leave_request_days.pay_rate from policy.pay_bands vs rolling usage

  if v_type.deducts_balance then
    insert into leave_ledger (employee_id, leave_type_id, entry_type, effective_date, amount, request_id, created_by_id)
    select v_req.employee_id, v_req.leave_type_id, 'taken', min(d.leave_date), -sum(d.portion), p_request, current_employee_id()
    from leave_request_days d
    where d.request_id = p_request and d.is_chargeable
    group by date_trunc('month', d.leave_date);
  end if;

  insert into notifications (recipient_id, channel, template, payload)
    values (v_req.employee_id, 'email', 'request_approved', jsonb_build_object('request_id', p_request));
end $$;

-- Monthly accrual job (pg_cron). Idempotent via leave_ledger_accrual_once.
create or replace function fn_run_monthly_accruals(p_month date default date_trunc('month', current_date)::date)
returns int language plpgsql security definer set search_path = public as $$
declare
  v_key   text := to_char(p_month, 'YYYY-MM');
  v_end   date := (p_month + interval '1 month - 1 day')::date;
  v_count int := 0;
  r       record;
  v_bal   numeric;
begin
  for r in
    select distinct on (e.id, p.leave_type_id) e.id as employee_id, p.leave_type_id, p.annual_entitlement,
           p.max_accumulation, e.hire_date, e.termination_date
    from employees e
    join leave_policies p on p.accrual_method = 'monthly'
      and p_month between p.effective_from and coalesce(p.effective_to, 'infinity')
      and (p.employment_types is null or e.employment_type = any(p.employment_types))
      and (p.grades is null or e.grade = any(p.grades))
      and (p.site_ids is null or e.site_id = any(p.site_ids))
      and e.hire_date + make_interval(months => p.min_service_months) <= v_end
    where e.hire_date <= v_end and (e.termination_date is null or e.termination_date >= p_month)
    order by e.id, p.leave_type_id, p.priority
  loop
    -- pro-rata by calendar days employed in the month
    insert into leave_ledger (employee_id, leave_type_id, entry_type, effective_date, amount, period_key, reason)
    values (r.employee_id, r.leave_type_id, 'accrual', v_end,
            round(r.annual_entitlement / 12
              * ((least(v_end, coalesce(r.termination_date, v_end)) - greatest(p_month, r.hire_date) + 1)::numeric
                 / (v_end - p_month + 1)), 2),
            v_key, 'Monthly accrual')
    on conflict do nothing;
    if found then v_count := v_count + 1; end if;

    -- enforce accumulation cap
    if r.max_accumulation is not null then
      select coalesce(sum(amount), 0) into v_bal from leave_ledger
        where employee_id = r.employee_id and leave_type_id = r.leave_type_id and effective_date <= v_end;
      if v_bal > r.max_accumulation then
        insert into leave_ledger (employee_id, leave_type_id, entry_type, effective_date, amount, period_key, reason)
        values (r.employee_id, r.leave_type_id, 'forfeiture', v_end, r.max_accumulation - v_bal, v_key,
                'Exceeded maximum accumulation of ' || r.max_accumulation || ' days')
        on conflict do nothing;
      end if;
    end if;
  end loop;
  return v_count;
end $$;
-- select cron.schedule('monthly-accruals', '5 0 1 * *', $$select fn_run_monthly_accruals((date_trunc('month', now()) - interval '1 month')::date)$$);

-- ---------------------------------------------------------------------
-- Row Level Security (reads). Writes go through the RPCs above.
-- ---------------------------------------------------------------------
alter table employees          enable row level security;
alter table leave_requests     enable row level security;
alter table leave_request_days enable row level security;
alter table leave_approvals    enable row level security;
alter table leave_ledger       enable row level security;
alter table attachments        enable row level security;
alter table user_roles         enable row level security;
alter table audit_log          enable row level security;
alter table payroll_export_batches enable row level security;
alter table payroll_export_lines   enable row level security;

-- Directory: everyone signed in can see basic colleague info (names for the team calendar).
-- Expose sensitive columns (mobile, belina code) via a separate restricted view if needed.
create policy emp_read on employees for select to authenticated using (true);

create policy req_read on leave_requests for select to authenticated
  using (can_view_employee(employee_id));
create policy req_days_read on leave_request_days for select to authenticated
  using (exists (select 1 from leave_requests r where r.id = request_id and can_view_employee(r.employee_id)));
create policy appr_read on leave_approvals for select to authenticated
  using (approver_id = current_employee_id()
         or exists (select 1 from leave_requests r where r.id = request_id and can_view_employee(r.employee_id)));
create policy ledger_read on leave_ledger for select to authenticated
  using (can_view_employee(employee_id));

-- Medical attachments: employee, HR, and the current pending approver only. IT admin excluded on purpose.
create policy att_read on attachments for select to authenticated
  using (exists (select 1 from leave_requests r join employees e on e.id = r.employee_id
                 where r.id = request_id and (
                   r.employee_id = current_employee_id()
                   or r.submitted_by_id = current_employee_id()
                   or has_role('hr_officer', e.site_id) or has_role('hr_admin')
                   or exists (select 1 from leave_approvals a where a.request_id = r.id
                              and a.decision = 'pending' and a.approver_id = current_employee_id()))));

create policy roles_read on user_roles for select to authenticated
  using (employee_id = current_employee_id() or has_role('it_admin') or has_role('hr_admin'));
create policy audit_read on audit_log for select to authenticated
  using (has_role('it_admin') or has_role('auditor') or has_role('hr_admin'));
create policy payroll_batches_read on payroll_export_batches for select to authenticated
  using (has_role('payroll_officer') or has_role('hr_admin') or has_role('auditor'));
create policy payroll_lines_read on payroll_export_lines for select to authenticated
  using (has_role('payroll_officer') or has_role('hr_admin') or has_role('auditor'));

-- No direct writes from clients to rule-bearing tables.
revoke insert, update, delete on leave_requests, leave_request_days, leave_approvals, leave_ledger
  from anon, authenticated;
grant execute on function fn_submit_leave_request, fn_decide_leave_request, fn_calculate_leave_days
  to authenticated;
revoke execute on function fn_run_monthly_accruals, fn_finalise_approval, fn_route_next_approval
  from public, anon, authenticated;
