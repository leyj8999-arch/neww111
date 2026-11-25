-- 체력단련실 예약 공유 DB (Supabase SQL Editor에서 실행)
-- 일반 이용자: 예약된 시간/인원만 조회, 예약 생성
-- 관리자: 예약 상세 조회, 수정, 삭제
-- 이름·학년·반·이용 목적은 공개 일정에 노출되지 않습니다.

create schema if not exists private;
revoke all on schema private from public, anon, authenticated;

create table if not exists public.bookings (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(trim(name)) between 1 and 20),
  grade smallint not null check (grade between 1 and 3),
  class_no smallint not null check (class_no between 1 and 20),
  headcount smallint not null check (headcount between 1 and 10),
  booking_date date not null,
  start_minute smallint not null,
  end_minute smallint not null,
  purpose text not null default '' check (char_length(purpose) <= 120),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint bookings_duration_check
    check (end_minute > start_minute and end_minute - start_minute in (5, 10, 15, 20)),
  constraint bookings_start_step_check
    check (start_minute between 0 and 1435 and start_minute % 5 = 0),
  constraint bookings_end_range_check
    check (end_minute between 5 and 1440)
);

-- 공개 시간표에는 개인정보를 복제하지 않습니다.
create table if not exists public.booking_schedule (
  id uuid primary key references public.bookings(id) on delete cascade,
  booking_date date not null,
  start_minute smallint not null,
  end_minute smallint not null,
  headcount smallint not null
);

create table if not exists public.booking_admins (
  user_id uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);

alter table public.bookings enable row level security;
alter table public.booking_schedule enable row level security;
alter table public.booking_admins enable row level security;

-- 일반 이용자는 공개 요약 행만 읽을 수 있습니다.
drop policy if exists "Anyone can read booking schedule" on public.booking_schedule;
create policy "Anyone can read booking schedule"
  on public.booking_schedule for select to anon, authenticated
  using (true);

-- 예약 등록은 허용하되, 시간/겹침/입력 검증은 DB 트리거가 수행합니다.
drop policy if exists "Anyone can create a booking" on public.bookings;
create policy "Anyone can create a booking"
  on public.bookings for insert to anon, authenticated
  with check (true);

-- 관리자만 개인 정보가 포함된 예약을 읽고 수정/삭제할 수 있습니다.
drop policy if exists "Admins can read bookings" on public.bookings;
create policy "Admins can read bookings"
  on public.bookings for select to authenticated
  using (exists (
    select 1 from public.booking_admins a
    where a.user_id = (select auth.uid())
  ));

drop policy if exists "Admins can update bookings" on public.bookings;
create policy "Admins can update bookings"
  on public.bookings for update to authenticated
  using (exists (
    select 1 from public.booking_admins a
    where a.user_id = (select auth.uid())
  ))
  with check (exists (
    select 1 from public.booking_admins a
    where a.user_id = (select auth.uid())
  ));

drop policy if exists "Admins can delete bookings" on public.bookings;
create policy "Admins can delete bookings"
  on public.bookings for delete to authenticated
  using (exists (
    select 1 from public.booking_admins a
    where a.user_id = (select auth.uid())
  ));

drop policy if exists "Admins can read own admin row" on public.booking_admins;
create policy "Admins can read own admin row"
  on public.booking_admins for select to authenticated
  using (user_id = (select auth.uid()));

-- 테이블 권한은 RLS와 함께 최소 범위로 제한합니다.
revoke all on public.bookings from anon, authenticated;
grant insert (name, grade, class_no, headcount, booking_date, start_minute, end_minute, purpose)
  on public.bookings to anon, authenticated;
grant select, update, delete on public.bookings to authenticated;

revoke all on public.booking_schedule from anon, authenticated;
grant select on public.booking_schedule to anon, authenticated;

revoke all on public.booking_admins from anon, authenticated;
grant select on public.booking_admins to authenticated;

-- private 스키마의 보안 definer 트리거 함수만 요약 시간표를 갱신합니다.
create or replace function private.validate_booking()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public, pg_temp
as $$
declare
  v_weekday integer;
  v_after_school_start integer;
begin
  if NEW.booking_date < (now() at time zone 'Asia/Seoul')::date then
    raise exception 'PAST_DATE' using errcode = '22007';
  end if;

  if NEW.end_minute - NEW.start_minute not in (5, 10, 15, 20)
     or NEW.start_minute % 5 <> 0 then
    raise exception 'INVALID_DURATION' using errcode = '22023';
  end if;

  v_weekday := extract(dow from NEW.booking_date)::integer;
  if v_weekday = 0 or v_weekday = 6 then
    raise exception 'CLOSED_DAY' using errcode = '22023';
  end if;

  v_after_school_start := case when v_weekday in (1, 3, 5) then 930 else 990 end;

  if not (
    (NEW.start_minute >= 390 and NEW.end_minute <= 510)
    or (NEW.start_minute >= 760 and NEW.end_minute <= 820)
    or (NEW.start_minute >= v_after_school_start and NEW.end_minute <= 1050)
  ) then
    raise exception 'OUTSIDE_OPERATING_HOURS' using errcode = '22023';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(NEW.booking_date::text, 0));

  if exists (
    select 1
    from public.bookings b
    where b.booking_date = NEW.booking_date
      and b.id is distinct from NEW.id
      and b.start_minute < NEW.end_minute
      and b.end_minute > NEW.start_minute
  ) then
    raise exception 'BOOKING_CONFLICT' using errcode = '23P01';
  end if;

  NEW.updated_at := now();
  return NEW;
end;
$$;

create or replace function private.sync_booking_schedule()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public, pg_temp
as $$
begin
  insert into public.booking_schedule (id, booking_date, start_minute, end_minute, headcount)
  values (NEW.id, NEW.booking_date, NEW.start_minute, NEW.end_minute, NEW.headcount)
  on conflict (id) do update set
    booking_date = excluded.booking_date,
    start_minute = excluded.start_minute,
    end_minute = excluded.end_minute,
    headcount = excluded.headcount;
  return NEW;
end;
$$;

drop trigger if exists bookings_validate_before_write on public.bookings;
create trigger bookings_validate_before_write
before insert or update on public.bookings
for each row execute function private.validate_booking();

drop trigger if exists bookings_sync_schedule_after_write on public.bookings;
create trigger bookings_sync_schedule_after_write
after insert or update on public.bookings
for each row execute function private.sync_booking_schedule();

-- 실시간 동기화에서 사용할 공개 시간표 테이블을 Realtime publication에 추가합니다.
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'booking_schedule'
  ) then
    alter publication supabase_realtime add table public.booking_schedule;
  end if;
end
$$;
