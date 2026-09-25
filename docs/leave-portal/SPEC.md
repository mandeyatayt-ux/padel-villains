# Leave Management Portal — Rough Spec (v0.1)

> Scope: ~400 employees, mining operation (multi-site, shift/rotation workers, frontline staff without email).
> Stack: Next.js on Vercel · Supabase (Postgres, Auth, Storage, pg_cron, Edge Functions) · Microsoft 365 / Entra ID sign-in · Belina Payroll (integration later, CSV/XLSX export first).
> Companion file: [`schema.sql`](./schema.sql) — draft Postgres schema + core functions (validated against Postgres 16 with Supabase `auth` stubs).

---

## 1. What the market leaders teach us

| Product | What they get right | What we take |
|---|---|---|
| **BambooHR** | Policy-driven accruals; "what will my balance be on date X" projection | Policies as data, not code. Balance projection on the request form |
| **Timetastic** | Deliberately simple; department wallchart; "max N people off" lock-outs | Team wallchart for HODs. Hard/soft concurrency limits per team |
| **Vacation Tracker** | Lives inside Teams/Slack; approve from a chat card | Teams/Outlook actionable notifications + Outlook calendar entry on approval (phase 2) |
| **Personio / Factorial** | Multi-step approval chains; substitute/handover person; absence types with own rules | Configurable approval chains per leave type; handover field |
| **Zoho People** | Leave encashment, compensatory off, rich reports | Encashment + time-off-in-lieu as ledger entry types |
| **SAP SuccessFactors / Workday** | Time *accounts* with postings; payroll period lock; retro corrections | **Append-only leave ledger** + payroll period lock. Skip the rest of the enterprise complexity |
| **Sage HR / Deputy** | Leave aware of the shift roster | Chargeable days calculated from each employee's roster, not Mon–Fri |
| **Kiosk-style systems (e.g. Calamari)** | Frontline staff use shared terminals | Proxy applications by a clerk; optional site kiosk later |

**The single most important lesson:** systems that store a balance as one editable number lose trust within a year ("why is my balance 14.5?"). Every serious product uses **transactions**. The balance is `SUM(ledger)`, and every change has a reason, an author, and a source. Build it that way from day one. Retrofitting is painful.

**What to avoid:** the enterprise tools' configurability. At 400 users you need about 8 leave types, 3–5 roster patterns, and 2–3 approval chains. Put them in tables, but don't build a rules engine.

---

## 2. Mining-specific requirements (the parts generic tools get wrong)

1. **Shift rosters and rotations.** Many staff work patterns like 5×2, 4-on/4-off, 2-week-on/2-week-off, or 21/7 FIFO. Leave must be charged only against **scheduled shift days**. Otherwise a rotation worker taking their off-rotation week gets charged 7 days for nothing. → `work_patterns` + `rotation_days`, anchored to a cycle start date per employee.
2. **Continuous operations and public holidays.** Plant/shaft staff often work holidays. A holiday falling on a scheduled shift is *not* free for them unless policy says so. → `work_patterns.observes_public_holidays` flag.
3. **Minimum manning / safety-critical roles.** You can't have both licensed blasters, both winder drivers, or all shift bosses off at once. → `coverage_rules` (hard block or soft warning) by department, site, or **critical role**, not just by team.
4. **Blackout periods.** Planned shutdowns, production ramp-ups, audit windows. → `blackout_periods`. The reverse also applies: **forced leave during shutdowns** (bulk leave booking by HR).
5. **Frontline staff without email or a device.** → proxy applications (see §4), SMS/WhatsApp notifications later, paper-form upload as evidence.
6. **Injury on duty ≠ sick leave.** IOD is NSSA/WCIF territory, often with an incident reference, and must not burn sick leave. → separate leave type, linked to a SHEQ incident number.
7. **Fitness for work after absence.** A long sick absence in a mining environment may need medical clearance before the next underground shift. → `requires_fitness_clearance_after_days` on the leave type. The system flags "Return-to-work clearance pending" to SHEQ/HR and the supervisor.
8. **Remote sites and travel days.** FIFO/remote employees may get travel days that aren't charged. → `travel` leave type (non-deducting) or a policy flag.
9. **Multiple sites with local HR clerks.** Everything is scoped by site. A site HR officer should only see their site.
10. **Connectivity.** Keep pages light. The employee "apply" flow must work on a cheap Android phone over a weak connection. No heavy SPA bundle on that route.

---

## 3. Statutory baseline (Zimbabwe — **verify with HR/legal before build**)

The defaults below are my reading of the Labour Act [Chapter 28:01] and common practice. **The Mining Industry NEC CBA and your own contracts may be more generous, and the CBA overrides where it's better for the employee.** Treat these as seed data for `leave_policies`, not as hard-coded logic.

| Leave type | Default rule to seed | Notes |
|---|---|---|
| Annual (vacation) | ~1 day per 12 days worked (≈30 days/yr); **accumulation cap 90 days**, excess forfeited unless otherwise agreed | Cap warnings are a key tile. Forfeiture must be a visible ledger entry, never silent |
| Sick | Up to 90 days full pay per year, then up to 90 days half pay at employer discretion; medical certificate required | Model as one type with **pay-rate bands** so payroll gets 100%/50% correctly |
| Maternity | 98 days full pay, service requirement and frequency limits apply | Eligibility checks, not balance checks |
| Special leave | Up to ~12 days/yr (e.g. quarantine, court/subpoena, national duty) | Supporting document usually required |
| Compassionate / bereavement | Company policy | Often inside special leave. Confirm with HR |
| Unpaid leave | Discretionary | Feeds payroll as a deduction |
| Study / exam | Company policy | |
| Injury on duty | NSSA/WCIF process | Non-deducting, links to incident ref |
| Time off in lieu (TOIL) | Company policy | Earned via ledger credit by supervisor/HR |

Public holidays are held per `holiday_calendar` and assigned per site. Include the "holiday falls on Sunday → Monday off" rule when seeding. Load dates yearly and don't compute them.

---

## 4. Identity and access

### 4.1 Authentication
- **Supabase Auth → Azure (Entra ID) provider**, configured **single-tenant** (use your tenant URL, not `common`). This is the most common mistake: a multi-tenant config lets *any* Microsoft account sign in.
- On first login, link `auth.users.id` → `employees.auth_user_id` by matching the Entra **object ID (`oid`)** first, email second. **Never auto-create an employee from a login.** Employees come from the master data sync (Belina/CSV/Entra). A login with no matching employee lands on a "contact HR" page.
- Roles are put into the JWT with a Supabase **custom access token hook**, so RLS policies don't need extra lookups on every row.

### 4.2 Users without email — three options
| Option | How | Pros | Cons |
|---|---|---|---|
| **A. Proxy only (recommended for v1)** | Employee has no login. An assigned *leave clerk* (site admin, timekeeper, supervisor) applies for them | Zero licence cost, fits current paper flow | Employee can't self-check balance; risk of applications without consent |
| B. Entra frontline accounts | Give frontline staff F1/F3-type identities (no mailbox needed) | Everyone is on SSO, one model | Licence cost × headcount. Check current Microsoft pricing |
| C. Site kiosk | Shared tablet, employee no. + PIN | Self-service balance check | Another credential system to secure and support |

**Challenge on Option A:** a clerk can apply for someone without their knowledge (to use up balance, cover absences, etc.). Mitigate with:
- `on_behalf_of_confirmation` on each proxy request: **uploaded signed paper form**, **verbal confirmation noted by a supervisor**, or **SMS OTP to the employee's phone** (phase 2).
- Clerks are scoped with `proxy_assignments` (by employee, department or site) and can't approve their own proxy submissions.
- Monthly HR report "proxy submissions by clerk".
- SMS/WhatsApp notification to the employee when leave is booked in their name (phase 2). This is the strongest control.

### 4.3 Roles (scoped)
A user can hold several roles. Each role has a **scope**: `global`, `site`, or `department`.

| Role | Can do |
|---|---|
| `employee` | Own requests, balances, history, calendar of own team (names + dates only, no leave type for privacy) |
| `leave_clerk` | Apply/cancel **on behalf of** employees in their proxy scope; upload forms |
| `supervisor` | Approve step 1 for direct reports; see direct reports' leave |
| `hod` | See all leave, balances, plans and history for their department(s); approve; team wallchart; department reports |
| `hr_officer` | Site or global scope: view all, approve HR steps, manual ledger adjustments (with reason), bulk leave, return-to-work clearance |
| `hr_admin` | Everything HR + policy/leave type config, holiday calendars, coverage rules, blackout periods, year-end runs |
| `payroll_officer` | Payroll export batches, period lock/unlock, leave liability report. **No approval rights** |
| `it_admin` | User/role management, integrations, sync logs, audit log. **No access to medical attachments or leave reasons** (segregation of duties) |
| `executive` | Read-only org dashboards (aggregates only) |
| `auditor` | Read-only everything incl. audit log, time-boxed assignment |

Rule of thumb: **IT admins manage who has access. They don't see sensitive HR content.** Medical certificates are visible only to the employee, HR roles, and the approver while the request is pending.

---

## 5. Core domain model (summary — full DDL in `schema.sql`)

```
legal_entities ─┬─ sites ── holiday_calendars ── public_holidays
                └─ departments (hod_employee_id)

employees (employee_no, email?, auth_user_id?, site, department, manager_id,
           grade, employment_type, work_pattern_id, rotation_anchor_date,
           critical_roles[], belina_employee_code, hire/termination dates)

work_patterns ── work_pattern_days (weekly)  |  rotation_days (N-day cycle)

leave_types ── leave_policies (entitlement, accrual method, cap, carry-over,
                               eligibility: grade/employment_type/site)
            └─ approval_chains ── approval_chain_steps (line_manager | hod | hr | role)

leave_requests ── leave_request_days (one row per calendar date: chargeable?, portion, pay_rate)
              ├─ leave_approvals (per step: approver, acted_by/delegate, decision, comment)
              └─ attachments (Supabase Storage, private bucket)

leave_ledger   (APPEND-ONLY: opening, accrual, taken, reversal, adjustment,
                forfeiture, carry_over, expiry, encashment, toil_earned)
   └─ v_leave_balances (view)

coverage_rules · blackout_periods · approval_delegations · proxy_assignments
payroll_periods (open/locked) · payroll_export_batches · payroll_export_lines
notifications (outbox) · integration_runs · audit_log
```

### Key design decisions (and why)
1. **Ledger, not balance column.** Balance = `SUM(amount)`. Corrections are new rows. This gives full history and an audit trail, and makes payroll reconciliation trivial.
2. **`leave_request_days` table.** Expanding each request into daily rows makes the wallchart, "who's off today", coverage checks, payroll-period splitting (leave across month-end) and sick pay bands simple SQL, not date arithmetic in the UI.
3. **Business rules live in Postgres functions (`SECURITY DEFINER` RPCs), not in Next.js.** Clients can't insert into `leave_requests` or `leave_ledger` directly. RLS protects reads; RPCs enforce rules. This way a bug in the UI can't bypass the balance check.
4. **Pending and future-dated leave both reserve balance.** `available = balance_today − booked_future − pending`. Without this, someone can book the same days twice (a bug the smoke test caught in the first draft).
5. **Payroll period lock.** Once a period is exported/locked, approved leave inside it cannot be edited or cancelled. Changes become adjustment entries in the next open period. This is what payroll teams need.

---

## 6. Core logic

### 6.1 Chargeable-day calculation — `fn_calculate_leave_days(employee, type, start, end, start_half, end_half)`
For each date in range:
1. Is it a scheduled work day for this employee?
   - weekly pattern → `work_pattern_days[isodow].is_working`
   - rotation → `rotation_days[(date − anchor) mod cycle_length].is_working`
2. Is it a public holiday on the employee's site calendar **and** does the pattern observe holidays? → not chargeable.
3. If the leave type `counts_calendar_days` (e.g. maternity) → every day chargeable regardless of 1–2.
4. Apply half-day portions on the first/last day.

Returns the per-day rows (written to `leave_request_days`) and the total. **Always recomputed server-side, never trusted from the client.**

### 6.2 Submission — `fn_submit_leave_request(...)`
Validation order (fail fast, with clear messages):
1. Actor is the employee, **or** has a valid `proxy_assignment` covering them (logged as `submitted_by` + `on_behalf_confirmation`).
2. Employee is active, eligible for this leave type (policy match, probation/service requirement).
3. Dates are valid, no overlap with their own pending/approved requests, `min_notice_days` met (HR can override), `max_consecutive_days` respected.
4. Chargeable days > 0.
5. **Balance:** `available_on(start_date)` ≥ days, where available includes **projected accrual up to the start date** (BambooHR lesson) minus pending. `allow_negative_balance` per type (e.g. sick = no, annual = up to −N days by policy).
6. **Blackout** overlap → hard block (HR can override with reason).
7. **Coverage rules** → for each day, count others off in the same scope/critical role. `hard` → block. `soft` → warn the applicant and flag for the approver.
8. **Attachment** required if `days > requires_attachment_after_days` (e.g. sick > 2 days). Allow submitting with `attachment_pending`, and block final approval until it's uploaded (the certificate often arrives later).
9. Create request + day rows + first `leave_approvals` step. Queue notifications.

### 6.3 Approval routing
- Chain per leave type, e.g.:
  - Annual: `line_manager → hod` (skip HOD if ≤ 3 days, a configurable `skip_if_days_lte`)
  - Sick: `line_manager → hr` (HR validates certificate)
  - Unpaid / Special / Maternity: `hod → hr`
- Approver resolution: `line_manager` = `employees.manager_id`, `hod` = `departments.hod_employee_id`, `hr` = any `hr_officer` scoped to the employee's site.
- **Self-approval is impossible:** if the resolved approver is the applicant (or the proxy who submitted), escalate to the next level.
- **Delegation:** if the approver has an active `approval_delegation` (or is on approved leave themselves), route to the delegate. Record `approver_id` (who it was for) and `acted_by` (who clicked).
- **SLA escalation:** pending > N working days → reminder, then escalate to the next level (pg_cron job).
- **On final approval:** status `approved`, write **one `taken` ledger row per payroll period** the leave spans (negative), create Outlook calendar event (phase 2).
- **Rejection** needs a comment. Reserved balance is freed automatically (pending ≠ ledger).

### 6.4 Cancellation and recall
- Pending → employee/proxy can cancel freely.
- Approved, not started → employee requests cancellation. Approver confirms, then a `reversal` ledger row is written.
- Approved, in progress → **recall / early return**: HR or HOD shortens the end date. Unused days are reversed. Common in mining when production needs someone back.
- In a **locked payroll period** → can't edit. HR posts an `adjustment` in the current open period, linked to the original request.

### 6.5 Accruals (pg_cron, monthly, idempotent)
- For each active employee × applicable policy:
  - `monthly`: `annual_entitlement / 12`, pro-rata for the month of hire/termination.
  - `per_days_worked`: `days_worked / 12` (closest to the statute. Needs days-worked from roster/timekeeping, so v1 approximates with scheduled days minus unpaid leave).
  - `upfront`: full entitlement posted on cycle start (typical for special/study).
  - `none`: event-driven (maternity, IOD).
- Unique key `(employee, leave_type, entry_type, period_key)` makes re-runs safe.
- After posting: if balance > `max_accumulation` (90) → post a `forfeiture` row for the excess **and notify the employee + HOD 60 and 30 days before it happens**. This is one of the most useful tiles in the system: people hate losing leave, and it reduces your leave liability.

### 6.6 Sick leave pay bands
Rolling 12-month window (or cycle, per policy). When approving sick leave, each `leave_request_days` row gets `pay_rate` = 1.00 until 90 days used in the window, then 0.50, then 0 (unpaid) beyond the half-pay band. Payroll export uses these rates directly.

### 6.7 Termination
When `termination_date` is set: stop accruals after that date, pro-rate the final month, cancel future approved leave (with notification), compute the **leave payout days** (annual balance), and include it in the next payroll export as an `encashment` line.

### 6.8 Year-end / cycle rollover
Per policy: `carry_over_max` days carried, the rest `expiry` (unless the statute says accumulate to cap, as with annual leave). Runs as an HR-triggered job with a preview first. Never run it automatically without a preview.

---

## 7. Screens

**Employee (and clerk "acting as")**
- Home tiles: *Annual available*, *Pending requests*, *Next leave*, *Days at risk of forfeiture*, *Sick days used (12m)*
- Apply form: type → dates (half-day toggles) → **live preview**: chargeable days (showing excluded off-roster days/holidays), balance after, coverage warnings → attachment → submit
- My history: all requests with status timeline + ledger view ("statement" like a bank account)
- Team calendar (names + "away" only)

**Supervisor / HOD**
- Tiles: *Off today*, *Off this week*, *Pending my approval* (with oldest age), *Coverage risk days next 30d*, *Team annual liability (days)*, *People near 90-day cap*
- **Wallchart** (Timetastic-style): rows = people, columns = days, coloured by leave type, grouped by shift/crew. Shaded off-roster days. Red columns where a coverage rule is breached
- Approval inbox with context: balance, overlapping team leave on those dates, the requester's recent history
- Team leave plans (approved + pending forward 3/6/12 months)
- Team reports (below, scoped)

**HR**
- Org tiles by site: *Absent today %*, *Sick absence rate (30d)*, *Overdue approvals*, *Pending medical certificates*, *Return-to-work clearances pending*, *Forfeiture next 60d*, *Leave liability (days, and $ once salary is available)*
- Employee 360: profile, balances, ledger, requests, adjustments
- Bulk actions: shutdown leave, opening balance import, ledger adjustments (reason required)
- Config: leave types, policies, calendars, chains, coverage rules, blackouts

**Payroll**: periods, export batches, reconciliation, lock/unlock.
**IT Admin**: users & roles, proxy assignments, sync runs, audit log, integration health.

---

## 8. Reports (all exportable CSV/XLSX, all filterable by site/department/date/type)

1. **Balances as at date** (point-in-time, possible because of the ledger)
2. **Leave taken** by period/type/department
3. **Leave liability** — days owed × daily rate (rate from payroll, restricted to payroll/HR/exec)
4. **Forfeiture forecast** — who loses what, when
5. **Absenteeism** — sick rate, **Bradford Factor** (S² × D) per employee, Monday/Friday and pre/post-holiday pattern flags
6. **Coverage/manning** — days where rules were breached or overridden, and who overrode
7. **Approval SLA** — avg/median time to decision per approver
8. **Proxy submissions** — by clerk, with confirmation method
9. **Payroll reconciliation** — exported vs current state, adjustments since export
10. **Audit trail** — any entity, any user
11. **Leave planning forecast** — approved + pending by week, for production planning

---

## 9. Payroll (Belina) integration

**Phase 1 — export file.** Per payroll period:
1. Payroll officer opens the period and generates a batch.
2. Lines = approved `leave_request_days` in the period, grouped by employee × leave type × pay rate, plus encashments and adjustments.
3. Columns (to be matched to Belina's import template): `belina_employee_code, employee_no, period, belina_leave_code, from, to, days, pay_rate, units_unpaid, reference`.
4. Batch is **immutable** once downloaded. Period gets locked. Later changes become adjustment lines in the next batch.

**Phase 2 — API/automated.** Confirm with Belina what they actually offer (API vs. file drop vs. database import). **Don't assume an API exists.** Ask them for: an employee master export (to become our sync source), a leave transaction import spec, and whether leave balances should live in Belina or here. **Pick one system of record for balances.** Running two in parallel will cause reconciliation disputes.

**Employee master data:** Belina (or HR spreadsheet) is the source of truth for employee no., department, grade, hire/termination. Entra is the source of truth for identity/email. A nightly `integration_runs` sync upserts `employees` and flags conflicts for HR. It never deletes.

---

## 10. Notifications
Outbox table (`notifications`) drained by a Supabase Edge Function / Vercel cron:
- **Email via Microsoft Graph `sendMail`** from a shared mailbox (e.g. leave@company). This keeps the email inside your M365 tenant and avoids a third-party mail provider.
- Phase 2: Teams adaptive cards (approve in Teams), Outlook calendar "Out of office" events, SMS/WhatsApp for non-email staff.
- Events: submitted, needs your approval, approved/rejected, cancellation, SLA reminder, forfeiture warning, certificate outstanding, return-to-work clearance.

---

## 11. Non-functional
- **Audit:** trigger-based `audit_log` on every table that matters (old/new JSON, actor, timestamp). Ledger is append-only, enforced by revoking UPDATE/DELETE.
- **Privacy:** medical certificates in a **private** Storage bucket, served via short-lived signed URLs, access checked in an RPC. Leave *reason* and *type* hidden from peers.
- **Timezone:** store dates as `date` (not timestamps) for leave days. Business TZ `Africa/Harare`. All cron jobs run in that TZ.
- **Backups:** Supabase PITR on the paid plan. Leave data affects pay, so treat it that way.
- **Scale:** 400 users × ~15 requests/yr ≈ 6k requests, ~40k day rows/yr. Postgres won't notice. Don't add caching layers, queues, or microservices.

---

## 12. Delivery phases

| Phase | Scope | Rough effort |
|---|---|---|
| **0. Decisions** | Confirm statute/CBA rules, roster patterns, approval chains, Belina import format, non-email option | 1–2 wks (you, HR, payroll) |
| **1. MVP** | SSO, employees import, leave types/policies, roster-aware day calc, apply/approve, proxy apply, ledger + accruals, balances, HOD wallchart, core tiles, CSV payroll export, audit | 6–8 wks |
| **2. Ops** | Coverage rules, blackouts, delegation, SLA escalation, sick pay bands, return-to-work, forfeiture warnings, full reports | 4 wks |
| **3. Integrations** | Teams/Outlook, SMS, Belina automated sync, kiosk if needed | 3–4 wks |

**Go-live risk:** opening balances. Import them **as `opening` ledger rows with a signed-off spreadsheet from HR/payroll**, reconciled against Belina *before* launch. If the first balance people see is wrong, adoption dies.

---

## 13. Open questions (answer these before building)
1. Which CBA applies (Mining NEC)? What's the actual annual entitlement per grade? Calendar days or working days?
2. What roster patterns exist, and how many employees are on each? Who maintains roster assignments?
3. How many sites? Separate legal entities? Separate HR per site?
4. Approval chain per leave type: is HR always in the loop for sick leave?
5. Which roles are safety-critical for coverage rules, and what are the minimums?
6. For non-email staff: Option A, B or C? Do they have phones for SMS?
7. Belina: which product/version, what import format, and who is the balance system of record?
8. Is leave liability in $ needed (needs salary data, a sensitive data flow)?
9. Does timekeeping/clocking exist? It would improve `per_days_worked` accrual and absence detection (AWOL ≠ leave).
