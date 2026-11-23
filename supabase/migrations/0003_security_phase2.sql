-- =====================================================================
-- 다온 ERP · 2차 보안
--  1) 결재 문서는 관계자만 읽는다
--     기안자(문서 주인) · 결재선 · 참조자 · 수신부서 직원 · 인수자 · (부서보관이면) 기안 부서 직원 · 관리자
--     결재 기록(acts)은 그 결재자 · 문서 주인 · 그 문서를 읽을 수 있는 사람만
--  2) 삭제한 결재 문서 보관함(trash)은 관리자만
--  3) 문서번호가 겹치지 않게: 번호 목록만 돌려주는 함수 (내용은 안 보임)
--  4) 첨부 · 사진 저장소를 비공개로: 로그인한 재직 직원만 받을 수 있다
-- SQL Editor 에 붙여넣고 Run (한 번만, 다시 실행해도 안전)
-- =====================================================================

-- 직원 부서 (수신부서 · 부서보관 판단용). 관리자가 로그인할 때 직원 명단으로 맞춘다
alter table public.profiles add column if not exists dept text;

-- 결재 문서 JSON 꺼내기 (깨진 값이면 null)
create or replace function public.appr_json(d jsonb) returns jsonb
language plpgsql immutable as
$$ begin return (d->>'json')::jsonb; exception when others then return null; end $$;

-- 이 결재 문서(appr/<주인>/docs/<번호>)를 내가 읽을 수 있나
create or replace function public.appr_doc_ok(p_owner text, d jsonb) returns boolean
language plpgsql stable security definer set search_path = public as
$$
declare j jsonb := appr_json(d); my_name text; my_dept text;
begin
  if p_owner = auth.uid()::text then return true; end if;
  if j is null then return false; end if;
  select name, dept into my_name, my_dept from profiles where id = auth.uid() and active;
  if my_name is null then return false; end if;
  return exists (select 1 from jsonb_array_elements(coalesce(j->'line', '[]'::jsonb)) x where x->>'name' = my_name)
      or coalesce(j->'refs', '[]'::jsonb) ? my_name
      or (my_dept is not null and coalesce(j->'recv', '[]'::jsonb) ? my_dept)
      or j->'dm'->>'handover' = my_name
      or (coalesce((j->'dm'->>'deptKeep')::boolean, false) and my_dept is not null and j->'line'->0->>'dept' = my_dept);
end $$;

-- 결재 관련 경로 읽기 규칙 (appr 가 아닌 경로는 true)
--   appr/<주인>/docs/<번호>                      → appr_doc_ok
--   appr/<결재자>/acts/<문서주인>__<번호>__<차례> → 결재자 본인 · 문서 주인 · 그 문서를 읽을 수 있는 사람
create or replace function public.appr_read_ok(p text, d jsonb) returns boolean
language plpgsql stable security definer set search_path = public as
$$
declare seg text := split_part(p, '/', 3); id text; doc_owner_id text; key text; row_data jsonb;
begin
  if split_part(p, '/', 1) <> 'appr' then return true; end if;
  if seg = 'docs' then return appr_doc_ok(split_part(p, '/', 2), d); end if;
  if seg = 'acts' then
    if split_part(p, '/', 2) = auth.uid()::text then return true; end if;
    id := split_part(p, '/', 4);
    doc_owner_id := split_part(id, '__', 1);
    if doc_owner_id = auth.uid()::text then return true; end if;
    key := regexp_replace(substr(id, length(doc_owner_id) + 3), '__[^_]*$', '');
    select data into row_data from docs where path = 'appr/' || doc_owner_id || '/docs/' || key;
    return row_data is not null and appr_doc_ok(doc_owner_id, row_data);
  end if;
  return true;
end $$;

-- 기존 읽기 규칙에 trash(관리자만) 추가
create or replace function public.doc_can_read(p text) returns boolean
language sql stable security definer set search_path = public as
$$
  select me_active() and (
    me_admin()
    or case split_part(p, '/', 1)
         when 'payroll' then false
         when 'pay'     then doc_owner(p) = auth.uid()::text
         when 'paysign' then doc_owner(p) = auth.uid()::text
         when 'data'    then doc_owner(p) = auth.uid()::text
         when 'pw'      then false
         when 'trash'   then false                                   -- 삭제한 결재 문서: 관리자만
         else true
       end
  )
$$;

drop policy if exists docs_read on public.docs;
create policy docs_read on public.docs for select to authenticated
  using (doc_can_read(path) and (me_admin() or appr_read_ok(path, data)));

-- 문서번호 목록 (내용 없이 번호만): 새 문서번호가 다른 직원 문서와 겹치지 않게
create or replace function public.appr_doc_numbers() returns setof text
language sql stable security definer set search_path = public as
$$ select distinct appr_json(data)->>'no' from docs
    where me_active() and path like 'appr/%/docs/%' and appr_json(data)->>'no' is not null $$;
revoke all on function public.appr_doc_numbers() from public, anon;
grant execute on function public.appr_doc_numbers() to authenticated;

-- 명단 맞추기: 이름 · 부서도 맞춘다 (p_staff = [{ emp, name, dept }, …])
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
    update profiles set dept = r->>'dept', updated_at = now()
     where emp_no = r->>'emp' and r ? 'dept' and dept is distinct from r->>'dept';
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

-- 첨부 · 사진 저장소 비공개: 로그인한 재직 직원만 받기
update storage.buckets set public = false where id = 'files';
drop policy if exists files_read on storage.objects;
create policy files_read on storage.objects for select to authenticated
  using (bucket_id = 'files' and public.me_active());

select 'ok' as result,
  (select public from storage.buckets where id = 'files') as files_public,
  (select count(*) from public.docs where path like 'appr/%/docs/%') as appr_docs;
