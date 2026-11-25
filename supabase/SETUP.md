# 공용 예약 DB 설정

1. Supabase에서 새 프로젝트를 만들고 **SQL Editor**를 엽니다.
2. 이 폴더의 `schema.sql` 전체를 붙여 넣고 실행합니다.
3. Supabase의 **Authentication → Users**에서 관리자 계정을 직접 생성합니다. 공개 회원가입은 비활성화하고, 관리자 계정만 만들어 사용합니다.
4. 생성한 관리자 사용자의 UUID를 복사한 뒤 SQL Editor에서 아래 문장을 실행합니다.

```sql
insert into public.booking_admins (user_id)
values ('관리자-사용자-UUID');
```

5. 프로젝트의 Project URL과 Publishable key(또는 anon key)를 프런트엔드 설정에 사용합니다. **service_role/secret key는 절대로 HTML, JavaScript 또는 GitHub 저장소에 넣지 마세요.**
6. 프런트엔드 설정이 완료되면 예약 목록은 공용 DB를 읽도록 연결합니다.

## 개인정보 보호
- 일반 방문자가 조회하는 `booking_schedule` 뷰에는 날짜, 예약 시간, 인원만 포함됩니다.
- 예약자 이름, 학년, 반, 이용 목적은 관리자 계정만 조회할 수 있습니다.
- 예약 등록은 `create_booking` RPC를 통해 수행하며, DB에서 운영시간·예약 중복을 다시 검사합니다.
- 기존 브라우저에만 저장된 예약은 자동으로 서버로 이동하지 않습니다. 관리자 기기에서 별도 이전 절차가 필요합니다.
