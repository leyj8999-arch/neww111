# 공용 예약 DB 설정

## 1. Supabase 프로젝트 준비
1. Supabase에서 새 프로젝트를 준비합니다.
2. 이 저장소의 `supabase/schema.sql` 전체를 SQL Editor에서 실행합니다.
3. **Authentication → Users**에서 관리자가 사용할 계정을 직접 생성합니다.
4. 생성된 관리자 사용자의 UUID를 복사한 뒤 SQL Editor에서 실행합니다.

```sql
insert into public.booking_admins (user_id)
values ('관리자-사용자-UUID');
```

5. **Authentication 설정에서 공개 회원가입을 끄고**, 관리자 계정만 유지합니다.

## 2. 프런트엔드 연결 정보
- Project URL과 Publishable key를 프런트엔드 설정에 사용합니다.
- Publishable key(구형 anon key 포함)는 브라우저에서 사용하도록 설계된 공개 키이며, RLS가 반드시 켜져 있어야 합니다.
- **service_role 또는 secret key는 절대로 HTML/JavaScript/GitHub Pages에 넣지 마세요.**

## 3. 데이터 접근 구조
- 일반 이용자는 `booking_schedule`에서 날짜·시작/종료 시간·인원만 조회합니다.
- 이름·학년·반·이용 목적을 포함한 `bookings`는 관리자 계정만 읽을 수 있습니다.
- 일반 예약자는 `bookings`에 INSERT만 가능하며, DB 트리거가 운영 시간과 예약 겹침을 다시 검사합니다.
- 관리자 계정은 로그인 후 예약 상세 내용을 조회·수정·삭제할 수 있습니다.
- `booking_schedule`는 Realtime publication에 등록되어 다른 기기에 변경 사항을 전달합니다.

## 4. 기존 예약 이전
기존 예약은 각 브라우저의 localStorage에 따로 저장되어 있어 자동으로 합쳐지지 않습니다. 사용 중인 원래 기기에서 예약 데이터를 별도로 내보낸 뒤 관리자가 한 번 이전해야 합니다. 이전 절차를 수행하기 전에는 기존 기기의 브라우저 데이터를 지우지 마세요.
