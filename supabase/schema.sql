-- 체력단련실 예약 공유 DB (Supabase SQL Editor에서 실행)
-- 학생 이름·학년·반·목적은 관리자만 조회할 수 있고,
-- 일반 방문자는 예약된 시간과 인원만 확인할 수 있습니다.

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

create table if not exists public.booking_admins (
  user_id uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);

alter table public.bookings enable row level security;
alter table public.booking_admins enable row level security;

drop policy if exists "Admins can read bookings" on public.bookings;
create policy "Admins can read bookings"
  on public.bookings for select to authenticated
  using (exists (
    select 1 from public.booking_admins a where a.user_id = auth.uid()
  ));

drop policy if exists "Admins can update bookings" on public.bookings;
create policy "Admins can update bookings"
  on public.bookings for update to authenticated
  using (exists (
    select 1 from public.booking_admins a where a.user_id = auth.uid()
  ))
  with check (exists (
    select 1 from public.booking_admins a where a.user_id = auth.uid()
  ));

drop policy if exists "Admins can delete bookings" on public.bookings;
create policy "Admins can delete bookings"
  on public.bookings for delete to authenticated
  using (exists (
    select 1 from public.booking_admins a where a.user_id = auth.uid()
  ));

drop policy if exists "Admins can read own admin row" on public.booking_admins;
create policy "Admins can read own admin row"
  on public.booking_admins for select to authenticated
  using (user_id = auth.uid());

revoke all on public.bookings from anon, authenticated;
grant select, update, delete on public.bookings to authenticated;
revoke all on public.booking_admins from anon, authenticated;
grant select on public.booking_admins to authenticated;

-- 일반 이용자에게는 이름·학년·반·목적을 제외한 시간표만 공개합니다.
drop view if exists public.booking_schedule;
create view public.booking_schedule as
select id, booking_date, start_minute, end_minute, headcount
from public.bookings;
grant select on public.booking_schedule to anon, authenticated;

-- 모든 신규 예약 및 관리자 수정 시 운영시간과 중복 예약을 DB에서 재검증합니다.
create or replace function public.validate_booking()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
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

  -- 같은 날짜의 동시 예약 요청도 서로 겹치지 않도록 날짜별 잠금을 사용합니다.
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

drop trigger if exists bookings_validate_before_write on public.bookings;
create trigger bookings_validate_before_write
before insert or update on public.bookings
for each row execute function public.validate_booking();

-- 비로그인 이용자는 이 함수로만 예약을 등록할 수 있습니다.
create or replace function public.create_booking(
  p_name text,
  p_grade integer,
  p_class_no integer,
  p_headcount integer,
  p_booking_date date,
  p_start_minute integer,
  p_duration integer,
  p_purpose text default ''
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_id uuid;
begin
  if p_name is null or char_length(trim(p_name)) not between 1 and 20 then
    raise exception 'INVALID_NAME' using errcode = '22023';
  end if;
  if p_grade not between 1 and 3 or p_class_no not between 1 and 20 then
    raise exception 'INVALID_CLASS' using errcode = '22023';
  end if;
  if p_headcount not between 1 and 10 then
    raise exception 'INVALID_HEADCOUNT' using errcode = '22023';
  end if;
  if p_duration not in (5, 10, 15, 20) then
    raise exception 'INVALID_DURATION' using errcode = '22023';
  end if;
  if char_length(coalesce(p_purpose, '')) > 120 then
    raise exception 'PURPOSE_TOO_LONG' using errcode = '22023';
  end if;

  insert into public.bookings (
    name, grade, class_no, headcount, booking_date,
    start_minute, end_minute, purpose
  ) values (
    trim(p_name), p_grade, p_class_no, p_headcount, p_booking_date,
    p_start_minute, p_start_minute + p_duration, coalesce(trim(p_purpose), '')
  )
  returning id into v_id;

  return v_id;
end;
$$;

revoke all on function public.create_booking(text, integer, integer, integer, date, integer, integer, text) from public;
grant execute on function public.create_booking(text, integer, integer, integer, date, integer, integer, text) to anon, authenticated;
