-- =====================================================================
-- 다온 ERP · Supabase 1차 구성 (A안: 저장 통로 교체)
--  - docs     : 앱이 쓰던 문서형 저장소(경로 → JSON)를 그대로 옮긴 표
--  - profiles : 직원 계정 (사번 ↔ Supabase 로그인 계정)
--  - 권한     : 로그인한 재직 직원만 읽기 · 각자 자기 영역만 쓰기 · 관리자는 전체
--               급여(payroll · pay · paysign)와 개인 영역(data/users)은 본인 · 관리자만 읽기
--  - files    : 첨부 · 현장사진 저장소
-- Supabase 대시보드 › SQL Editor 에 이 파일 전체를 붙여넣고 Run (한 번만)
-- =====================================================================

-- ---------- 직원 계정 ----------
create table if not exists public.profiles (
  id             uuid primary key references auth.users(id) on delete cascade,
  emp_no         text not null unique,
  name           text not null,
  is_admin       boolean not null default false,   -- 저장소 전체 관리 권한 (앱의 '포털 소유자')
  must_change_pw boolean not null default true,    -- 초기 비밀번호(사번)로 들어오면 새 비밀번호를 정하게
  active         boolean not null default true,    -- 퇴사자는 false (로그인 · 읽기 차단)
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);

-- ---------- 문서형 저장소 ----------
-- path : 'config/staff', 'appr/<계정>/docs/<번호>' …  (짝수 개 구간 = 문서)
-- col  : 문서가 속한 모음 경로 ('appr/<계정>/docs')
create table if not exists public.docs (
  path       text primary key,
  col        text not null,
  doc_id     text not null,
  data       jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now(),
  updated_by uuid default auth.uid()
);
create index if not exists ix_docs_col on public.docs(col);

-- ---------- 권한 계산 ----------
create or replace function public.me_active() returns boolean
language sql stable security definer set search_path = public as
$$ select exists (select 1 from profiles where id = auth.uid() and active) $$;

create or replace function public.me_admin() returns boolean
language sql stable security definer set search_path = public as
$$ select exists (select 1 from profiles where id = auth.uid() and active and is_admin) $$;

-- 경로의 '주인' 계정: 대부분 두 번째 구간, 개인 영역(data/users/<계정>/…)은 세 번째 구간
create or replace function public.doc_owner(p text) returns text
language sql immutable as
$$ select case when p like 'data/users/%' then split_part(p, '/', 3) else split_part(p, '/', 2) end $$;

create or replace function public.doc_can_read(p text) returns boolean
language sql stable security definer set search_path = public as
$$
  select me_active() and (
    me_admin()
    or case split_part(p, '/', 1)
         when 'payroll' then false                                   -- 전 직원 연봉표: 관리자만
         when 'pay'     then doc_owner(p) = auth.uid()::text         -- 내 연봉 (관리자가 넣어 줌)
         when 'paysign' then doc_owner(p) = auth.uid()::text
         when 'data'    then doc_owner(p) = auth.uid()::text         -- 개인 영역 (임시저장 · 캐비넷)
         when 'pw'      then false                                   -- 예전 비밀번호 기록 (쓰지 않음)
         else true
       end
  )
$$;

create or replace function public.doc_can_write(p text) returns boolean
language sql stable security definer set search_path = public as
$$ select me_active() and (me_admin() or doc_owner(p) = auth.uid()::text) $$;

alter table public.docs     enable row level security;
alter table public.profiles enable row level security;

drop policy if exists docs_read   on public.docs;
drop policy if exists docs_insert on public.docs;
drop policy if exists docs_update on public.docs;
drop policy if exists docs_delete on public.docs;
create policy docs_read   on public.docs for select to authenticated using (doc_can_read(path));
create policy docs_insert on public.docs for insert to authenticated with check (doc_can_write(path));
create policy docs_update on public.docs for update to authenticated using (doc_can_write(path)) with check (doc_can_write(path));
create policy docs_delete on public.docs for delete to authenticated using (doc_can_write(path));

drop policy if exists profiles_read on public.profiles;
create policy profiles_read on public.profiles for select to authenticated using (me_active());
-- profiles 쓰기는 아래 함수로만

revoke all on public.docs, public.profiles from anon;
grant select, insert, update, delete on public.docs to authenticated;
grant select on public.profiles to authenticated;

-- 실시간 변경 알림 (다른 직원이 저장하면 바로 보이게)
do $$ begin
  alter publication supabase_realtime add table public.docs;
exception when duplicate_object then null; end $$;

-- ---------- 계정 관리 함수 (관리자 · SQL Editor 전용) ----------
create or replace function public.emp_email(p_emp text) returns text
language sql immutable as $$ select 'e' || lower(p_emp) || '@staff.daonconst.com' $$;

create or replace function public.assert_admin() returns void
language plpgsql stable security definer set search_path = public as
$$ begin
  -- 웹(PostgREST)으로 들어온 요청은 session_user가 authenticator. 그 밖(SQL Editor · 관리 도구)은 DB 관리자
  if session_user not in ('authenticator', 'anon', 'authenticated') or me_admin() then return; end if;
  raise exception '관리자만 할 수 있습니다' using errcode = '42501';
end $$;

-- 직원 계정 만들기 (이미 있으면 이름만 맞춤). 초기 비밀번호 = 사번
create or replace function public.admin_create_employee(p_emp text, p_name text, p_admin boolean default false)
returns uuid language plpgsql security definer set search_path = public, auth, extensions as
$$
declare uid uuid;
begin
  perform assert_admin();
  p_emp := btrim(p_emp);
  if p_emp !~ '^[0-9A-Za-z]{3,20}$' then raise exception '사번 형식이 맞지 않습니다: %', p_emp; end if;
  select id into uid from profiles where emp_no = p_emp;
  if uid is not null then
    update profiles set name = p_name, updated_at = now() where id = uid and name <> p_name;
    return uid;
  end if;
  uid := gen_random_uuid();
  insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
      raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
      confirmation_token, recovery_token, email_change_token_new, email_change,
      email_change_token_current, phone_change, phone_change_token, reauthentication_token)
  values ('00000000-0000-0000-0000-000000000000', uid, 'authenticated', 'authenticated', emp_email(p_emp),
      extensions.crypt(p_emp, extensions.gen_salt('bf')), now(),
      '{"provider":"email","providers":["email"]}'::jsonb, jsonb_build_object('emp', p_emp, 'name', p_name),
      now(), now(), '', '', '', '', '', '', '', '');
  insert into auth.identities (provider_id, user_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
  values (uid::text, uid, jsonb_build_object('sub', uid::text, 'email', emp_email(p_emp), 'email_verified', true),
      'email', null, now(), now());
  insert into profiles (id, emp_no, name, is_admin) values (uid, p_emp, p_name, p_admin);
  -- 앱의 '계정 ↔ 사번 연결' 기록
  insert into docs (path, col, doc_id, data, updated_by)
  values ('requests/' || uid, 'requests', uid::text, jsonb_build_object('sites', '[]'::jsonb, 'emp', p_emp, 'at', now()), uid)
  on conflict (path) do nothing;
  return uid;
end $$;

-- 재직자 명단 맞추기: 없는 계정은 만들고, 퇴사자는 막는다 (관리자가 로그인할 때 · 직원 명단을 고칠 때 앱이 부른다)
-- p_staff = [{ "emp": "230001", "name": "최유현" }, …],  p_retired = ["2010101", …]
create or replace function public.admin_sync_employees(p_staff jsonb, p_retired jsonb default '[]'::jsonb)
returns jsonb language plpgsql security definer set search_path = public, auth as
$$
declare r jsonb; made int := 0; off int := 0; e text;
begin
  perform assert_admin();
  for r in select * from jsonb_array_elements(coalesce(p_staff, '[]'::jsonb)) loop
    if not exists (select 1 from profiles where emp_no = r->>'emp') then made := made + 1; end if;
    perform admin_create_employee(r->>'emp', r->>'name');
    update profiles set active = true, updated_at = now() where emp_no = r->>'emp' and not active;
    update auth.users set banned_until = null where id = (select id from profiles where emp_no = r->>'emp') and banned_until is not null;
  end loop;
  for e in select jsonb_array_elements_text(coalesce(p_retired, '[]'::jsonb)) loop
    update profiles set active = false, updated_at = now() where emp_no = e and active and id is distinct from auth.uid();
    if found then
      off := off + 1;
      update auth.users set banned_until = 'infinity' where id = (select id from profiles where emp_no = e);
    end if;
  end loop;
  return jsonb_build_object('created', made, 'retired', off);
end $$;

-- 비밀번호 초기화 (관리자): 사번으로 되돌리고 다음 로그인 때 새 비밀번호를 정하게
create or replace function public.admin_reset_password(p_emp text)
returns boolean language plpgsql security definer set search_path = public, auth, extensions as
$$
declare uid uuid;
begin
  perform assert_admin();
  select id into uid from profiles where emp_no = p_emp;
  if uid is null then return false; end if;
  update auth.users set encrypted_password = extensions.crypt(p_emp, extensions.gen_salt('bf')), updated_at = now() where id = uid;
  update profiles set must_change_pw = true, updated_at = now() where id = uid;
  return true;
end $$;

-- 사번 변경 (관리자): 같은 계정의 로그인 사번만 바꾼다 (비밀번호 · 기록은 그대로)
create or replace function public.admin_change_emp(p_old text, p_new text)
returns boolean language plpgsql security definer set search_path = public, auth as
$$
declare uid uuid; dup uuid;
begin
  perform assert_admin();
  select id into uid from profiles where emp_no = p_old;
  if uid is null then return false; end if;
  select p.id into dup from profiles p join auth.users u on u.id = p.id where p.emp_no = p_new;
  if dup is not null then
    -- 명단 맞추기가 먼저 만든 새 사번 계정(한 번도 로그인하지 않음)은 지우고 옮긴다
    if exists (select 1 from auth.users where id = dup and last_sign_in_at is null) then
      delete from docs where path = 'requests/' || dup;
      delete from auth.users where id = dup;
    else
      raise exception '사번 %은(는) 이미 다른 계정이 쓰고 있습니다', p_new;
    end if;
  end if;
  update profiles set emp_no = p_new, updated_at = now() where id = uid;
  update auth.users set email = emp_email(p_new), raw_user_meta_data = raw_user_meta_data || jsonb_build_object('emp', p_new), updated_at = now() where id = uid;
  update auth.identities set identity_data = identity_data || jsonb_build_object('email', emp_email(p_new)), updated_at = now() where user_id = uid and provider = 'email';
  return true;
end $$;

-- 본인: 새 비밀번호를 정한 뒤 '초기 비밀번호' 표시를 지운다
create or replace function public.mark_password_changed()
returns void language sql security definer set search_path = public as
$$ update profiles set must_change_pw = false, updated_at = now() where id = auth.uid() $$;

revoke all on function public.admin_create_employee(text, text, boolean), public.admin_sync_employees(jsonb, jsonb),
  public.admin_reset_password(text), public.admin_change_emp(text, text), public.mark_password_changed() from public, anon;
grant execute on function public.admin_create_employee(text, text, boolean), public.admin_sync_employees(jsonb, jsonb),
  public.admin_reset_password(text), public.admin_change_emp(text, text), public.mark_password_changed() to authenticated;

-- ---------- 파일 저장소 (첨부 · 현장사진) ----------
-- 1차: 파일 이름이 추측할 수 없는 무작위 번호라 링크를 아는 사람만 열 수 있다 (2차에서 로그인 확인으로 강화)
insert into storage.buckets (id, name, public, file_size_limit)
values ('files', 'files', true, 52428800)
on conflict (id) do nothing;

drop policy if exists files_insert on storage.objects;
drop policy if exists files_delete on storage.objects;
create policy files_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'files' and public.me_active());
create policy files_delete on storage.objects for delete to authenticated
  using (bucket_id = 'files' and (owner = auth.uid() or public.me_admin()));

-- ---------- 첫 관리자 계정 ----------
-- 사번 9999 (기획실 · 서버관리자). 초기 비밀번호도 9999 → 처음 로그인할 때 새 비밀번호(6자 이상)를 정한다
select public.admin_create_employee('9999', '관리자', true);
