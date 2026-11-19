-- =====================================================================
-- 초기 데이터: 프로토타입(index.html)의 메뉴 구성 + 예시 조직/권한
-- 사람·부서는 예시이므로 실제 데이터로 교체할 것
-- =====================================================================

INSERT INTO positions (name, rank_level) VALUES
 ('사원', 1), ('대리', 2), ('과장', 3), ('차장', 4), ('부장', 5), ('이사', 6), ('대표', 9);

INSERT INTO departments (code, name, parent_id, sort_order) VALUES ('HQ', '㈜다온종합건설', NULL, 1);
INSERT INTO departments (code, name, parent_id, sort_order) VALUES
 ('EXEC',   '임원실',       (SELECT id FROM departments WHERE code = 'HQ'), 1),
 ('MGMT',   '경영관리본부', (SELECT id FROM departments WHERE code = 'HQ'), 2),
 ('TECH',   '기술사업본부', (SELECT id FROM departments WHERE code = 'HQ'), 3),
 ('BIZ',    '건설사업본부', (SELECT id FROM departments WHERE code = 'HQ'), 4),
 ('SAFETY', '안전관리본부', (SELECT id FROM departments WHERE code = 'HQ'), 5);
INSERT INTO departments (code, name, parent_id, sort_order)
SELECT t.code, t.name, p.id, t.sort_order
FROM (VALUES
 ('MGMT_ADMIN', '관리부',       'MGMT',   1), ('MGMT_ACCT', '경리부',     'MGMT',   2),
 ('MGMT_OPS',   '업무부',       'MGMT',   3), ('MGMT_CONT', '계약관리부', 'MGMT',   4),
 ('TECH_ARCH',  '건축설계팀',   'TECH',   1),
 ('BIZ_ENG',    '공무팀',       'BIZ',    1), ('BIZ_CONST', '공사팀',     'BIZ',    2), ('BIZ_SITE', '현장지원팀', 'BIZ', 3),
 ('SAFE_HS',    '안전보건팀',   'SAFETY', 1), ('SAFE_SITE', '현장관리팀', 'SAFETY', 2)
) AS t(code, name, parent_code, sort_order)
JOIN departments p ON p.code = t.parent_code;

INSERT INTO roles (code, name, note) VALUES
 ('EMPLOYEE',   '일반 임직원', '전 직원 기본 권한'),
 ('ACCOUNTING', '경리 담당',   '경리게시판 관리'),
 ('GA',         '총무 담당',   '공지·총무게시판 관리'),
 ('IT',         '전산 담당',   '전산게시판 관리'),
 ('ADMIN',      '시스템 관리자', '모든 메뉴 관리');

-- ---------- 메뉴: 대메뉴(GROUP) ----------
INSERT INTO menus (code, name, menu_type, icon, sort_order) VALUES
 ('notice', '공지사항', 'GROUP', 'notice', 1),
 ('mail',   '전자우편', 'GROUP', 'mail',   2),
 ('doc',    '문서관리', 'GROUP', 'doc',    3),
 ('appr',   '전자결재', 'GROUP', 'appr',   4),
 ('cons',   '공사관리', 'GROUP', 'cons',   5),
 ('sec',    '전자비서', 'GROUP', 'sec',    6),
 ('know',   '지식관리', 'GROUP', 'know',   7),
 ('comm',   '커뮤니티', 'GROUP', 'comm',   8),
 ('work',   '업무관리', 'GROUP', 'work',   9);

-- ---------- 메뉴: 하위 화면(SCREEN) ----------
INSERT INTO menus (parent_id, code, name, menu_type, screen_type, route, sort_order)
SELECT p.id, s.code, s.name, 'SCREEN', s.screen_type, '/' || replace(s.code, '.', '/'), s.sort_order
FROM (VALUES
 ('notice', 'notice.all',    '전체공지',       'board',    1),
 ('notice', 'notice.event',  '경조게시판',     'board',    2),
 ('notice', 'notice.acct',   '경리게시판',     'board',    3),
 ('notice', 'notice.admin',  '총무게시판',     'board',    4),
 ('notice', 'notice.plan',   '기획게시판',     'board',    5),
 ('notice', 'notice.it',     '전산게시판',     'board',    6),
 ('notice', 'notice.order',  '수주공지',       'board',    7),
 ('notice', 'notice.safety', '안전보건정보',   'board',    8),
 ('mail',   'mail.inbox',    '받은편지함',     'board',    1),
 ('mail',   'mail.sent',     '보낸편지함',     'board',    2),
 ('mail',   'mail.memo',     '사내통신',       'board',    3),
 ('doc',    'doc.write',     '문서작성',         'docwrite', 1),
 ('doc',    'doc.manage',    '문서관리',         'docmanage', 2),
 ('doc',    'doc.inout',     '문서수발함',       'docinout',  3),
 ('doc',    'doc.history',   '개인문서이력관리', 'dochist',   4),
 ('doc',    'doc.search',    '문서검색',         'docsearch', 5),
 ('doc',    'doc.external',  '대외문서조회(전체)', 'docext',  6),
 ('doc',    'doc.deptio',    '부서문서수발조회', 'docdept',   7),
 -- 전자결재는 문서관리 › 문서작성에서 상신한 문서를 같은 결재 문서 테이블에서 읽는다 (기안 작성은 문서관리 › 문서작성에서만)
 ('appr',   'appr.do',       '결재하기',       'apprdo',     1),
 ('appr',   'appr.status',   '결재현황',       'apprstatus', 2),
 ('appr',   'appr.search',   '결재문서조회',   'apprsearch', 3),
 ('cons',   'cons.overview', '프로젝트',       'siteov',   1),
 ('cons',   'cons.work',     '현장근무현황',   'sitework', 2),
 ('cons',   'cons.attend',   '인력투입현황',   'siteatt',  3),
 ('cons',   'cons.deploy',   '장비투입현황',   'sitedeploy', 4),
 ('cons',   'cons.equip',    '장비 점검현황',  'siteequip', 5),
 ('cons',   'cons.photo',    '현장사진',       'sitephoto', 6),
 ('sec',    'sec.cal',       '일정관리',       'calendar',    1),
 ('sec',    'sec.contacts',  '직원연락망',     'contacts',    2),
 ('sec',    'sec.pay',       '급여조회',       'payslip',     4),
 ('sec',    'sec.leave',     '연차조회',       'leave',       3),
 ('sec',    'sec.contract',  '연봉계약서',     'paycontract', 5),
 ('know',   'know.data',     '자료실',         'board',    1),
 ('know',   'know.report',   '프로젝트 보고서', 'board',   2),
 ('know',   'know.rules',    '회사규정',       'board',    3),
 ('comm',   'comm.suggest',  '건의사항',       'board',    1),
 ('comm',   'comm.free',     '자유게시판',     'board',    2),
 ('work',   'work.ot',       '연장근로신청',   'overtime', 1),
 ('work',   'work.prod',     '물품대여',       'rental',   2),
 ('work',   'work.post',     '우편물조회',     'mailpost', 3),
 ('work',   'work.cert',     '증명서신청',     'certreq',  4),
 ('work',   'work.car',      '차량신청',       'carreq',   5),
 ('work',   'work.carlog',   '차량운행일지',   'carlog',   6),
 ('work',   'work.pinadmin', '급여 비밀번호 관리', 'pinadmin', 7)
) AS s(parent_code, code, name, screen_type, sort_order)
JOIN menus p ON p.code = s.parent_code;

-- ---------- 권한 ----------
-- 1) 전 직원: 모든 화면 조회 + 쓰기 (게시판 관리 기능은 제외)
INSERT INTO menu_permissions (menu_id, role_id, can_read, can_write, can_delete)
SELECT m.id, r.id, TRUE, TRUE, TRUE
FROM menus m, roles r
WHERE r.code = 'EMPLOYEE' AND m.menu_type = 'SCREEN';

-- 2) 공지사항(notice.*) 게시판은 전 직원 읽기만 (위에서 준 쓰기·삭제 권한을 낮춤)
UPDATE menu_permissions p SET can_write = FALSE, can_delete = FALSE
FROM menus m, roles r
WHERE p.menu_id = m.id AND p.role_id = r.id AND r.code = 'EMPLOYEE'
  AND m.code LIKE 'notice.%';

-- 3) 공지사항 글쓰기·수정·삭제는 경영관리본부(MGMT) 직원만 (2026-11-01 결정)
--    부서 권한은 하위 부서에도 적용되므로 관리부·경리부·업무부·계약관리부 직원 모두 포함 (v_user_menu_permissions)
--    can_manage = 다른 사람이 쓴 공지도 고치고 지울 수 있음
INSERT INTO menu_permissions (menu_id, dept_id, can_read, can_write, can_delete, can_manage)
SELECT m.id, d.id, TRUE, TRUE, TRUE, TRUE
FROM menus m JOIN departments d ON d.code = 'MGMT'
WHERE m.code LIKE 'notice.%';

-- 4) 시스템 관리자: 전 메뉴 전 권한
INSERT INTO menu_permissions (menu_id, role_id, can_read, can_write, can_delete, can_manage)
SELECT m.id, r.id, TRUE, TRUE, TRUE, TRUE
FROM menus m, roles r WHERE r.code = 'ADMIN' AND m.menu_type = 'SCREEN';

-- 5) 급여 비밀번호 관리(work.pinadmin)는 관리부(MGMT_ADMIN, 급여 담당)만: 전 직원 권한에서 빼고 관리부에만 준다
DELETE FROM menu_permissions p USING menus m, roles r
WHERE p.menu_id = m.id AND p.role_id = r.id AND r.code = 'EMPLOYEE' AND m.code = 'work.pinadmin';
INSERT INTO menu_permissions (menu_id, dept_id, can_read, can_write, can_delete, can_manage)
SELECT m.id, d.id, TRUE, TRUE, FALSE, TRUE
FROM menus m JOIN departments d ON d.code = 'MGMT_ADMIN'
WHERE m.code = 'work.pinadmin';

-- 6) 회사규정(know.rules)은 경영관리본부 담당자 한 사람과 경영관리본부장만 쓰기·수정·삭제 (2026-11-02 결정). 다른 직원은 읽기만
UPDATE menu_permissions p SET can_write = FALSE, can_delete = FALSE
FROM menus m, roles r
WHERE p.menu_id = m.id AND p.role_id = r.id AND r.code = 'EMPLOYEE' AND m.code = 'know.rules';
--    담당자 지정 = 개인 권한 한 줄 (담당자를 바꾸면 이 줄의 user_id만 바꾼다). :rules_owner_login 은 실제 담당자 로그인 ID
INSERT INTO menu_permissions (menu_id, user_id, can_read, can_write, can_delete, can_manage)
SELECT m.id, u.id, TRUE, TRUE, TRUE, TRUE
FROM menus m JOIN users u ON u.login_id = :'rules_owner_login'
WHERE m.code = 'know.rules';
--    경영관리본부장: 본부 직속(MGMT) 부장 이상에게 개인 권한 (본부장이 바뀌면 인사 정보 기준으로 다시 넣는다)
INSERT INTO menu_permissions (menu_id, user_id, can_read, can_write, can_delete, can_manage)
SELECT m.id, u.id, TRUE, TRUE, TRUE, TRUE
FROM menus m
JOIN users u ON u.dept_id = (SELECT id FROM departments WHERE code = 'MGMT')
JOIN positions ps ON ps.id = u.position_id AND ps.rank_level >= 5
WHERE m.code = 'know.rules' AND u.is_active
ON CONFLICT DO NOTHING;
-- 7) 커뮤니티(건의사항·자유게시판)는 전 직원 쓰기. 남의 글 수정·삭제는 화면·API에서 작성자 본인만 허용 (can_manage 없음)