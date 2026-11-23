-- =====================================================================
-- 다온 ERP · 로그인 아이디 (관리자만 정함)
--  - 로그인은 아이디로만 한다. 아이디를 아직 정하지 않은 직원은 사번이 곧 아이디
--  - 로그인 계정 이메일 = 'e' || 아이디 || '@staff.daonconst.com'  (앱이 입력값으로 바로 만든다
--    → 로그인 전에 계정을 찾아보는 기능이 없어 아이디가 있는지 밖에서 알아낼 수 없다)
--  - 아이디: 영문 소문자로 시작, 영문 소문자 · 숫자 · . _ - 4~20자 (숫자로만 된 사번과 겹치지 않게)
-- SQL Editor 에 붙여넣고 Run (한 번만, 다시 실행해도 안전)
-- =====================================================================

alter table public.profiles add column if not exists login_id text;
create unique index if not exists ux_profiles_login_id on public.profiles (lower(login_id)) where login_id is not null;

-- 로그인 이름(아이디가 없으면 사번) → 로그인 이메일
create or replace function public.login_email(p_login text) returns text
language sql immutable as $$ select 'e' || lower(btrim(p_login)) || '@staff.daonconst.com' $$;

-- 관리자: 직원 아이디 정하기 · 바꾸기 (p_id 가 비어 있으면 아이디를 지우고 사번으로 돌린다)
create or replace function public.admin_set_login_id(p_emp text, p_id text)
returns text language plpgsql security definer set search_path = public, auth as
$$
declare uid uuid; v text := nullif(lower(btrim(coalesce(p_id, ''))), ''); mail text;
begin
  perform assert_admin();
  select id into uid from profiles where emp_no = p_emp;
  if uid is null then raise exception '계정이 없는 사번입니다: %', p_emp using errcode = 'P0002'; end if;
  if v is not null then
    if v !~ '^[a-z][a-z0-9._-]{3,19}$' then
      raise exception '아이디는 영문 소문자로 시작하고 영문 · 숫자 · . _ - 4~20자로 정하세요' using errcode = '22023';
    end if;
    if exists (select 1 from profiles where id <> uid and (lower(login_id) = v or lower(emp_no) = v)) then
      raise exception '이미 쓰고 있는 아이디입니다' using errcode = '23505';
    end if;
  end if;
  mail := login_email(coalesce(v, p_emp));
  if exists (select 1 from auth.users where lower(email) = mail and id <> uid) then
    raise exception '이미 쓰고 있는 아이디입니다' using errcode = '23505';
  end if;
  update profiles set login_id = v, updated_at = now() where id = uid;
  update auth.users set email = mail, updated_at = now() where id = uid;
  update auth.identities set identity_data = identity_data || jsonb_build_object('email', mail), updated_at = now()
   where user_id = uid and provider = 'email';
  return coalesce(v, p_emp);
end $$;

-- 사번 바꾸기: 아이디를 정한 직원은 로그인 이메일을 그대로 둔다 (아이디로 로그인하므로)
create or replace function public.admin_change_emp(p_old text, p_new text)
returns boolean language plpgsql security definer set search_path = public, auth as
$$
declare uid uuid; other uuid; lid text;
begin
  perform assert_admin();
  if p_new !~ '^[0-9A-Za-z]{3,20}$' then raise exception '사번 형식이 맞지 않습니다: %', p_new; end if;
  select id, login_id into uid, lid from profiles where emp_no = p_old;
  if uid is null then return false; end if;
  select id into other from profiles where emp_no = p_new;
  if other is not null and other <> uid then
    if exists (select 1 from auth.users where id = other and last_sign_in_at is not null) then
      raise exception '새 사번 %은(는) 이미 다른 직원이 쓰고 있습니다', p_new;
    end if;
    delete from docs where path = 'requests/' || other;
    delete from auth.users where id = other;   -- 아직 한 번도 로그인하지 않은 빈 계정 (명단 동기화가 미리 만든 것)
  end if;
  if exists (select 1 from profiles where id <> uid and lower(login_id) = lower(p_new)) then
    raise exception '새 사번 %이(가) 다른 직원의 아이디와 같습니다', p_new;
  end if;
  update profiles set emp_no = p_new, updated_at = now() where id = uid;
  update auth.users set raw_user_meta_data = raw_user_meta_data || jsonb_build_object('emp', p_new) where id = uid;
  if lid is null then
    update auth.users set email = login_email(p_new), updated_at = now() where id = uid;
    update auth.identities set identity_data = identity_data || jsonb_build_object('email', login_email(p_new)), updated_at = now()
     where user_id = uid and provider = 'email';
  end if;
  update docs set data = jsonb_set(data, '{emp}', to_jsonb(p_new)) where path = 'requests/' || uid;
  return true;
end $$;

-- 새 직원 계정: 그 사번이 누군가의 아이디와 같으면 만들지 않는다 (로그인 이메일이 겹치므로)
create or replace function public.admin_sync_employees(p_staff jsonb, p_retired jsonb default '[]'::jsonb)
returns jsonb language plpgsql security definer set search_path = public, auth as
$$
declare r jsonb; made int := 0; off int := 0; e text; skipped jsonb := '[]'::jsonb;
begin
  perform assert_admin();
  for r in select * from jsonb_array_elements(coalesce(p_staff, '[]'::jsonb)) loop
    if not exists (select 1 from profiles where emp_no = r->>'emp') then
      if exists (select 1 from auth.users where lower(email) = login_email(r->>'emp')) then
        skipped := skipped || to_jsonb(r->>'emp'); continue;
      end if;
      made := made + 1;
    end if;
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
  return jsonb_build_object('created', made, 'retired', off, 'skipped', skipped);
end $$;

revoke all on function public.admin_set_login_id(text, text) from public, anon;
grant execute on function public.admin_set_login_id(text, text) to authenticated;

select emp_no, name, login_id, (select email from auth.users u where u.id = p.id) as login_email
  from public.profiles p order by emp_no limit 5;
