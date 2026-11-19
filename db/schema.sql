-- =====================================================================
-- 사내 업무포탈: 조직 / 사용자 / 메뉴 / 권한 스키마 (PostgreSQL 14+)
-- =====================================================================

-- ---------- 조직 ----------
CREATE TABLE departments (
    id          SERIAL PRIMARY KEY,
    parent_id   INT REFERENCES departments(id),        -- 상위 부서 (NULL = 최상위)
    code        VARCHAR(30)  NOT NULL UNIQUE,
    name        VARCHAR(100) NOT NULL,
    sort_order  INT          NOT NULL DEFAULT 0,
    is_active   BOOLEAN      NOT NULL DEFAULT TRUE
);

CREATE TABLE positions (                               -- 직급
    id          SERIAL PRIMARY KEY,
    name        VARCHAR(30) NOT NULL UNIQUE,           -- 사원, 대리, 과장 ...
    rank_level  INT         NOT NULL                   -- 높을수록 상위 (결재선 계산용)
);

CREATE TABLE users (
    id             SERIAL PRIMARY KEY,
    login_id       VARCHAR(50)  NOT NULL UNIQUE,
    password_hash  VARCHAR(255) NOT NULL,              -- bcrypt/argon2 해시만 저장
    name           VARCHAR(50)  NOT NULL,
    dept_id        INT NOT NULL REFERENCES departments(id),
    position_id    INT NOT NULL REFERENCES positions(id),
    email          VARCHAR(100),
    ext_no         VARCHAR(20),                        -- 내선번호
    is_active      BOOLEAN   NOT NULL DEFAULT TRUE,    -- 퇴사자는 삭제하지 않고 FALSE
    created_at     TIMESTAMP NOT NULL DEFAULT now()
);
CREATE INDEX ix_users_dept ON users(dept_id);

-- ---------- 역할 ----------
CREATE TABLE roles (
    id    SERIAL PRIMARY KEY,
    code  VARCHAR(30)  NOT NULL UNIQUE,                -- ADMIN, EMPLOYEE, ACCOUNTING ...
    name  VARCHAR(50)  NOT NULL,
    note  VARCHAR(200)
);

CREATE TABLE user_roles (
    user_id  INT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    role_id  INT NOT NULL REFERENCES roles(id) ON DELETE CASCADE,
    PRIMARY KEY (user_id, role_id)
);

-- ---------- 메뉴 ----------
-- 한 테이블로 트리 구성: GROUP(상단 대메뉴) → SCREEN(하위 화면)
-- 프로토타입의 MENUS 배열과 1:1로 대응한다.
CREATE TABLE menus (
    id           SERIAL PRIMARY KEY,
    parent_id    INT REFERENCES menus(id),
    code         VARCHAR(50)  NOT NULL UNIQUE,         -- 'notice', 'notice.all' (탭 ID로 사용)
    name         VARCHAR(100) NOT NULL,
    menu_type    VARCHAR(10)  NOT NULL CHECK (menu_type IN ('GROUP', 'SCREEN', 'LINK')),
    screen_type  VARCHAR(20)  CHECK (screen_type IN ('board', 'apprdo', 'apprstatus', 'apprsearch', 'docwrite', 'overtime', 'calendar', 'contacts', 'payslip', 'leave', 'paycontract', 'pinadmin', 'siteov', 'sitework', 'siteatt', 'sitedeploy', 'siteequip', 'sitephoto', 'custom')),
    route        VARCHAR(200),                         -- 화면 경로 또는 LINK의 외부 URL
    icon         VARCHAR(30),
    open_mode    VARCHAR(10)  NOT NULL DEFAULT 'TAB' CHECK (open_mode IN ('TAB', 'POPUP', 'NEWWIN')),
    sort_order   INT          NOT NULL DEFAULT 0,
    is_active    BOOLEAN      NOT NULL DEFAULT TRUE,
    CHECK (menu_type <> 'SCREEN' OR screen_type IS NOT NULL)
);
CREATE INDEX ix_menus_parent ON menus(parent_id, sort_order);

-- ---------- 메뉴 권한 ----------
-- 한 행 = "누구에게(역할·부서·개인 중 정확히 하나) 어떤 메뉴를 무엇까지 허용하는가"
-- 여러 행이 겹치면 OR(합집합)로 계산한다. 거부(deny) 규칙은 두지 않는다.
CREATE TABLE menu_permissions (
    id          SERIAL PRIMARY KEY,
    menu_id     INT NOT NULL REFERENCES menus(id) ON DELETE CASCADE,
    role_id     INT REFERENCES roles(id)        ON DELETE CASCADE,
    dept_id     INT REFERENCES departments(id)  ON DELETE CASCADE,
    user_id     INT REFERENCES users(id)        ON DELETE CASCADE,
    can_read    BOOLEAN NOT NULL DEFAULT TRUE,     -- 메뉴 보이기 + 조회
    can_write   BOOLEAN NOT NULL DEFAULT FALSE,    -- 등록·수정 (본인 글)
    can_delete  BOOLEAN NOT NULL DEFAULT FALSE,
    can_manage  BOOLEAN NOT NULL DEFAULT FALSE,    -- 남의 글 수정·삭제, 공지 고정 등 관리자 기능
    CHECK (num_nonnulls(role_id, dept_id, user_id) = 1)
);
CREATE UNIQUE INDEX ux_perm_role ON menu_permissions(menu_id, role_id) WHERE role_id IS NOT NULL;
CREATE UNIQUE INDEX ux_perm_dept ON menu_permissions(menu_id, dept_id) WHERE dept_id IS NOT NULL;
CREATE UNIQUE INDEX ux_perm_user ON menu_permissions(menu_id, user_id) WHERE user_id IS NOT NULL;

-- ---------- 개인화 ----------
CREATE TABLE user_quicklinks (                        -- 대시보드 '바로가기'
    user_id     INT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    menu_id     INT NOT NULL REFERENCES menus(id) ON DELETE CASCADE,
    sort_order  INT NOT NULL DEFAULT 0,
    PRIMARY KEY (user_id, menu_id)
);

-- ---------- 감사 로그 ----------
CREATE TABLE menu_access_logs (
    id         BIGSERIAL PRIMARY KEY,
    user_id    INT NOT NULL REFERENCES users(id),
    menu_id    INT NOT NULL REFERENCES menus(id),
    action     VARCHAR(10) NOT NULL CHECK (action IN ('READ', 'WRITE', 'DELETE', 'DENIED')),
    ip_addr    VARCHAR(45),
    created_at TIMESTAMP NOT NULL DEFAULT now()
);
CREATE INDEX ix_access_logs_user_time ON menu_access_logs(user_id, created_at DESC);

-- =====================================================================
-- 사용자별 실효 권한 뷰
-- 부서 권한은 상위 부서에도 적용된다 (예: '사업본부'에 준 권한 → 하위 '상하수도사업부' 직원도 받음)
-- =====================================================================
CREATE VIEW v_user_menu_permissions AS
WITH RECURSIVE user_depts AS (                         -- 각 사용자의 소속 부서 + 모든 상위 부서
    SELECT u.id AS user_id, d.id AS dept_id, d.parent_id
    FROM users u JOIN departments d ON d.id = u.dept_id
    WHERE u.is_active
    UNION ALL
    SELECT ud.user_id, d.id, d.parent_id
    FROM user_depts ud JOIN departments d ON d.id = ud.parent_id
),
grants AS (
    SELECT ur.user_id AS uid, p.menu_id, p.can_read, p.can_write, p.can_delete, p.can_manage
    FROM menu_permissions p JOIN user_roles ur ON ur.role_id = p.role_id
    UNION ALL
    SELECT ud.user_id, p.menu_id, p.can_read, p.can_write, p.can_delete, p.can_manage
    FROM menu_permissions p JOIN user_depts ud ON ud.dept_id = p.dept_id
    UNION ALL
    SELECT p.user_id, p.menu_id, p.can_read, p.can_write, p.can_delete, p.can_manage
    FROM menu_permissions p WHERE p.user_id IS NOT NULL
)
SELECT g.uid AS user_id, g.menu_id,
       bool_or(g.can_read)   AS can_read,
       bool_or(g.can_write)  AS can_write,
       bool_or(g.can_delete) AS can_delete,
       bool_or(g.can_manage) AS can_manage
FROM grants g
JOIN menus m ON m.id = g.menu_id AND m.is_active
GROUP BY g.uid, g.menu_id;

-- =====================================================================
-- 전자결재: 결재 문서 / 결재선 / 첨부 / 열람 기록
-- 열람 권한 = 결재선(approval_lines) + 참조자(approval_refs). 관리자·대표도 예외 없음
-- 참조자는 읽기만 하고 결재하지 않는다. 수신부서 직원은 결재선·참조자가 아니면 열람 불가 (2026-11-01 결정)
-- (나중에 정책이 바뀌면 아래 approval_can_read() 한 곳만 고치면 된다)
-- =====================================================================
CREATE TABLE approval_docs (
    id             BIGSERIAL PRIMARY KEY,
    doc_no         VARCHAR(30) UNIQUE,                 -- DOC-2026-0813, 다온-261101-01 (상신 때 부여, 임시저장은 NULL)
    kind           VARCHAR(10) NOT NULL CHECK (kind IN ('일반결재', '회람결재', '수신문서', '업무연락', '업무보고', '업무일지', '업무지시')),
    form_name      VARCHAR(100) NOT NULL,              -- 문서작성 양식명 (내부품의서, 대외공문 ...)
    form_category  VARCHAR(50)  NOT NULL,              -- 양식분류 (기안, 협조전, 출장관리 ...)
    title          VARCHAR(300) NOT NULL,
    drafter_id     INT NOT NULL REFERENCES users(id),
    dept_id        INT NOT NULL REFERENCES departments(id),   -- 기안 부서
    status         VARCHAR(10) NOT NULL CHECK (status IN ('임시저장', '진행', '완료', '반려')),
    urgent         BOOLEAN NOT NULL DEFAULT FALSE,
    security_level SMALLINT NOT NULL DEFAULT 2,        -- 1: 작성자와 결재자, 2: 결재자와 모든 부서원 (표시용, 열람은 결재선 기준)
    keep_years     SMALLINT,                           -- NULL = 영구
    current_seq    SMALLINT NOT NULL DEFAULT 1,        -- 지금 결재할 결재선 순번
    body_html      TEXT NOT NULL,                      -- 상신 시점의 용지(읽기 전용 HTML)
    submitted_at   TIMESTAMP,
    finished_at    TIMESTAMP,
    created_at     TIMESTAMP NOT NULL DEFAULT now()
);
CREATE INDEX ix_approval_docs_drafter ON approval_docs(drafter_id, created_at DESC);

CREATE TABLE approval_lines (                          -- 결재선 = 열람 권한 목록
    doc_id     BIGINT   NOT NULL REFERENCES approval_docs(id) ON DELETE CASCADE,
    seq        SMALLINT NOT NULL,                      -- 0 = 기안자, 1부터 결재 순서
    user_id    INT      NOT NULL REFERENCES users(id),
    role       VARCHAR(6) NOT NULL CHECK (role IN ('기안', '검토', '승인', '협조', '관리', '회람', '접수', '확인')),
    action     VARCHAR(6) CHECK (action IN ('상신', '결재', '합의', '확인', '접수', '반려')),   -- NULL = 아직 처리 전
    opinion    TEXT,                                   -- 결재의견 · 반려 사유
    acted_at   TIMESTAMP,
    PRIMARY KEY (doc_id, seq)
);
CREATE INDEX ix_approval_lines_user ON approval_lines(user_id, doc_id);   -- "내 문서" 조회용

CREATE TABLE approval_refs (                           -- 참조자 = 읽기 권한만 (결재 차례 없음)
    doc_id   BIGINT NOT NULL REFERENCES approval_docs(id) ON DELETE CASCADE,
    user_id  INT    NOT NULL REFERENCES users(id),
    read_at  TIMESTAMP,                                -- 처음 열어 본 시각
    PRIMARY KEY (doc_id, user_id)
);
CREATE INDEX ix_approval_refs_user ON approval_refs(user_id, doc_id);

CREATE TABLE approval_recv_depts (                     -- 수신부서 (표시용. 이 표만으로는 열람 권한이 생기지 않는다)
    doc_id   BIGINT NOT NULL REFERENCES approval_docs(id) ON DELETE CASCADE,
    dept_id  INT    NOT NULL REFERENCES departments(id),
    PRIMARY KEY (doc_id, dept_id)
);

CREATE TABLE approval_files (
    id         BIGSERIAL PRIMARY KEY,
    doc_id     BIGINT NOT NULL REFERENCES approval_docs(id) ON DELETE CASCADE,
    file_name  VARCHAR(255) NOT NULL,
    file_size  BIGINT NOT NULL,
    storage_key VARCHAR(300) NOT NULL                  -- 파일 서버 경로 (다운로드도 approval_can_read로 확인)
);

CREATE TABLE approval_access_logs (                    -- 누가 언제 열람·처리했는지 (거부도 남김)
    id         BIGSERIAL PRIMARY KEY,
    doc_id     BIGINT NOT NULL REFERENCES approval_docs(id),
    user_id    INT NOT NULL REFERENCES users(id),
    action     VARCHAR(10) NOT NULL CHECK (action IN ('READ', 'PRINT', 'DOWNLOAD', 'ACT', 'DENIED')),
    ip_addr    VARCHAR(45),
    created_at TIMESTAMP NOT NULL DEFAULT now()
);

-- ---------- 열람 권한 ----------
-- 웹 서버는 요청마다 로그인한 사용자 id를 세션 변수에 넣는다:  SET LOCAL app.user_id = '42';
CREATE FUNCTION app_user_id() RETURNS INT LANGUAGE sql STABLE AS
$$ SELECT NULLIF(current_setting('app.user_id', TRUE), '')::INT $$;

-- 이 사람이 이 문서를 볼 수 있는가 = 결재선에 있거나 참조자인가 (SECURITY DEFINER: 정책 안에서 결재선·참조 표를 읽기 위해)
CREATE FUNCTION approval_can_read(p_doc BIGINT, p_user INT) RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS
$$ SELECT EXISTS (SELECT 1 FROM approval_lines WHERE doc_id = p_doc AND user_id = p_user)
       OR EXISTS (SELECT 1 FROM approval_refs  WHERE doc_id = p_doc AND user_id = p_user) $$;

-- 행 수준 보안: 앱 계정(erp_app)으로 접속하면 결재선 밖의 문서는 SELECT 결과에서 아예 빠진다
-- (목록·건수·검색·문서번호 직접 입력 모두 같은 규칙. 숨은 문서의 건수도 알 수 없다)
ALTER TABLE approval_docs  ENABLE ROW LEVEL SECURITY;
ALTER TABLE approval_lines ENABLE ROW LEVEL SECURITY;
ALTER TABLE approval_files ENABLE ROW LEVEL SECURITY;
ALTER TABLE approval_refs  ENABLE ROW LEVEL SECURITY;
ALTER TABLE approval_recv_depts ENABLE ROW LEVEL SECURITY;
ALTER TABLE approval_docs  FORCE ROW LEVEL SECURITY;
ALTER TABLE approval_lines FORCE ROW LEVEL SECURITY;
ALTER TABLE approval_files FORCE ROW LEVEL SECURITY;
ALTER TABLE approval_refs  FORCE ROW LEVEL SECURITY;
ALTER TABLE approval_recv_depts FORCE ROW LEVEL SECURITY;
CREATE POLICY p_refs_read ON approval_refs       FOR SELECT USING (approval_can_read(doc_id, app_user_id()));
CREATE POLICY p_recv_read ON approval_recv_depts FOR SELECT USING (approval_can_read(doc_id, app_user_id()));
CREATE POLICY p_refs_insert ON approval_refs FOR INSERT
    WITH CHECK (EXISTS (SELECT 1 FROM approval_docs d WHERE d.id = doc_id AND d.drafter_id = app_user_id() AND d.status = '임시저장'));
CREATE POLICY p_refs_mark_read ON approval_refs FOR UPDATE USING (user_id = app_user_id()) WITH CHECK (user_id = app_user_id());   -- 읽은 시각만 기록
CREATE POLICY p_recv_insert ON approval_recv_depts FOR INSERT
    WITH CHECK (EXISTS (SELECT 1 FROM approval_docs d WHERE d.id = doc_id AND d.drafter_id = app_user_id() AND d.status = '임시저장'));

CREATE POLICY p_docs_read  ON approval_docs  FOR SELECT                       -- 기안자는 결재선(seq 0)을 넣기 전에도 자기 문서를 본다
    USING (drafter_id = app_user_id() OR approval_can_read(id, app_user_id()));
CREATE POLICY p_lines_read ON approval_lines FOR SELECT USING (approval_can_read(doc_id, app_user_id()));
CREATE POLICY p_files_read ON approval_files FOR SELECT USING (approval_can_read(doc_id, app_user_id()));

-- 쓰기: 기안자만 새 문서를 만들고, 임시저장 상태에서만 고친다
CREATE POLICY p_docs_insert ON approval_docs FOR INSERT WITH CHECK (drafter_id = app_user_id());
CREATE POLICY p_docs_update ON approval_docs FOR UPDATE
    USING (approval_can_read(id, app_user_id()))
    WITH CHECK (approval_can_read(id, app_user_id()));
-- 결재선 행은 기안자가 상신 전에만 구성하고, 처리(action)는 본인 차례의 본인 행만 기록한다
CREATE POLICY p_lines_insert ON approval_lines FOR INSERT
    WITH CHECK (EXISTS (SELECT 1 FROM approval_docs d WHERE d.id = doc_id AND d.drafter_id = app_user_id() AND d.status = '임시저장'));
CREATE POLICY p_lines_act ON approval_lines FOR UPDATE
    USING (user_id = app_user_id() AND action IS NULL
           AND EXISTS (SELECT 1 FROM approval_docs d WHERE d.id = doc_id AND d.status = '진행' AND d.current_seq = seq))
    WITH CHECK (user_id = app_user_id());
CREATE POLICY p_files_insert ON approval_files FOR INSERT
    WITH CHECK (EXISTS (SELECT 1 FROM approval_docs d WHERE d.id = doc_id AND d.drafter_id = app_user_id() AND d.status = '임시저장'));

-- 앱 계정: 테이블 소유자가 아닌 별도 계정으로 접속해야 정책이 적용된다 (BYPASSRLS 권한 주지 않음)
-- CREATE ROLE erp_app LOGIN PASSWORD '...';
-- GRANT SELECT, INSERT, UPDATE ON approval_docs, approval_lines, approval_files, approval_refs, approval_recv_depts TO erp_app;
-- GRANT INSERT ON approval_access_logs TO erp_app;
-- GRANT USAGE ON ALL SEQUENCES IN SCHEMA public TO erp_app;

-- =====================================================================
-- 급여·연봉계약: 본인만 조회 + 급여 비밀번호 이중 확인
--  1) 행 수준 보안: 급여명세·연봉계약 행은 user_id = 로그인 사용자만 읽힌다 (관리자 화면은 별도 계정·감사 로그)
--  2) 급여 비밀번호: 로그인 비밀번호와 별도. 확인에 성공하면 서버 세션에 pay_unlocked_until(10분)을 기록하고,
--     급여 API는 세션 값이 지났으면 데이터를 내려주지 않는다 (화면 잠금만으로 막지 않는다)
-- =====================================================================
CREATE TABLE user_pay_pins (
    user_id        INT PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    pin_hash       VARCHAR(255) NOT NULL,              -- bcrypt/argon2 해시
    failed_count   SMALLINT  NOT NULL DEFAULT 0,       -- 5회 실패 시 locked_until 설정
    locked_until   TIMESTAMP,
    changed_at     TIMESTAMP NOT NULL DEFAULT now()
);

CREATE TABLE payslips (                                -- 월별 급여명세 (급여 시스템에서 확정된 값)
    id          BIGSERIAL PRIMARY KEY,
    user_id     INT  NOT NULL REFERENCES users(id),
    pay_month   DATE NOT NULL,                         -- 해당 월 1일
    pay_date    DATE NOT NULL,
    items       JSONB NOT NULL,                        -- {"기본급": 3600000, ...}
    deductions  JSONB NOT NULL,                        -- {"국민연금": 190470, ...}
    total_pay   BIGINT NOT NULL,
    total_ded   BIGINT NOT NULL,
    net_pay     BIGINT NOT NULL,
    UNIQUE (user_id, pay_month)
);

CREATE TABLE pay_contracts (                           -- 연봉계약서
    id          BIGSERIAL PRIMARY KEY,
    user_id     INT  NOT NULL REFERENCES users(id),
    title       VARCHAR(200) NOT NULL,
    term_from   DATE NOT NULL,
    term_to     DATE NOT NULL,
    annual_pay  BIGINT NOT NULL,
    body_html   TEXT NOT NULL,
    made_at     DATE NOT NULL,
    signed_at   TIMESTAMP,                             -- 근로자 전자서명 일시 (NULL = 서명대기)
    signed_ip   VARCHAR(45)
);

CREATE TABLE pay_access_logs (                         -- 급여·계약 열람·잠금해제 시도 기록 (실패 포함)
    id         BIGSERIAL PRIMARY KEY,
    user_id    INT NOT NULL REFERENCES users(id),                 -- 대상 직원
    actor_id   INT REFERENCES users(id),                          -- 처리한 사람 (관리부 초기화·잠금 해제)
    reason     VARCHAR(200),
    action     VARCHAR(12) NOT NULL CHECK (action IN ('UNLOCK', 'UNLOCK_FAIL', 'READ_PAY', 'READ_CONTRACT', 'SIGN', 'PIN_CHANGE', 'PIN_RESET', 'PIN_UNLOCK')),
    ip_addr    VARCHAR(45),
    created_at TIMESTAMP NOT NULL DEFAULT now()
);

ALTER TABLE payslips      ENABLE ROW LEVEL SECURITY;
ALTER TABLE pay_contracts ENABLE ROW LEVEL SECURITY;
ALTER TABLE user_pay_pins ENABLE ROW LEVEL SECURITY;
ALTER TABLE payslips      FORCE ROW LEVEL SECURITY;
ALTER TABLE pay_contracts FORCE ROW LEVEL SECURITY;
ALTER TABLE user_pay_pins FORCE ROW LEVEL SECURITY;
CREATE POLICY p_payslips_self  ON payslips      FOR SELECT USING (user_id = app_user_id());
CREATE POLICY p_contract_self  ON pay_contracts FOR SELECT USING (user_id = app_user_id());
CREATE POLICY p_contract_sign  ON pay_contracts FOR UPDATE                     -- 본인 서명만 (서명 전 계약)
    USING (user_id = app_user_id() AND signed_at IS NULL) WITH CHECK (user_id = app_user_id());
CREATE POLICY p_pin_self       ON user_pay_pins FOR ALL USING (user_id = app_user_id()) WITH CHECK (user_id = app_user_id());
-- GRANT SELECT ON payslips TO erp_app; GRANT SELECT, UPDATE ON pay_contracts TO erp_app;
-- GRANT SELECT, UPDATE ON user_pay_pins TO erp_app; GRANT INSERT ON pay_access_logs TO erp_app;
-- 관리부 초기화: 앱 서버가 메뉴 권한(work.pinadmin)을 확인한 뒤 별도 관리 계정으로 user_pay_pins 행을 지우고
-- pay_access_logs에 (대상, 처리자, PIN_RESET, 사유)를 남긴다. 관리부도 비밀번호 해시는 볼 수 없다.

-- =====================================================================
-- 현장사진: 공사관리 › 현장사진에서 올리고 HOME 위젯이 최근 사진을 보여준다
-- 원본·썸네일은 파일 서버(또는 오브젝트 스토리지)에, DB에는 경로와 정보만. 지우기는 올린 사람만 (관리자는 숨김 처리)
-- =====================================================================
CREATE TABLE site_photos (
    id           BIGSERIAL PRIMARY KEY,
    project_no   VARCHAR(20)  NOT NULL,              -- 사업번호 (P-2026-014)
    taken_on     DATE         NOT NULL,              -- 촬영일
    work_type    VARCHAR(20)  NOT NULL,              -- 공종: 전경·토공·골조·관로·안전·품질·기타
    memo         VARCHAR(300),
    storage_key  VARCHAR(300) NOT NULL,              -- 원본 경로
    thumb_key    VARCHAR(300) NOT NULL,              -- 썸네일 경로 (목록·HOME 위젯용)
    file_name    VARCHAR(255) NOT NULL,
    file_size    BIGINT       NOT NULL,
    uploaded_by  INT          NOT NULL REFERENCES users(id),
    uploaded_at  TIMESTAMP    NOT NULL DEFAULT now(),
    is_hidden    BOOLEAN      NOT NULL DEFAULT FALSE
);
CREATE INDEX ix_site_photos_recent ON site_photos(project_no, taken_on DESC, id DESC) WHERE NOT is_hidden;
-- =====================================================================
-- 업무관리 (원본 ERP 구성: 연장근로신청 · 물품대여 · 우편물조회 · 증명서신청 · 차량신청 · 차량운행일지)
-- 승인·등록 담당은 총무(관리부): 앱 서버가 메뉴 권한으로 확인한다. 신청자는 자기 신청만 고치고 지운다
-- =====================================================================
CREATE TABLE overtime_requests (                    -- 연장근로신청 (평일 09:00~18:00에만 신청, 주 12시간 한도)
    id          BIGSERIAL PRIMARY KEY,
    user_id     INT          NOT NULL REFERENCES users(id),
    project_no  VARCHAR(20)  NOT NULL,              -- 사업번호 또는 'HQ'(본사 공통)
    cost_dept   INT          NOT NULL REFERENCES departments(id),   -- 원가부서
    work_date   DATE         NOT NULL,              -- 과업수행일
    time_from   TIME         NOT NULL,
    time_to     TIME         NOT NULL,
    overnight   BOOLEAN      NOT NULL DEFAULT FALSE,               -- 철야
    content     VARCHAR(300) NOT NULL,
    approved_minutes INT,                           -- 인정시간 (승인 때 확정)
    status      VARCHAR(8)   NOT NULL DEFAULT '신청' CHECK (status IN ('신청', '승인', '취소신청', '취소')),
    created_at  TIMESTAMP    NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX ux_ot_one_per_day ON overtime_requests(user_id, work_date) WHERE status <> '취소';

CREATE TABLE rental_items (                         -- 대여 물품 (노트북 · 프로젝터 · 카메라 …)
    code      VARCHAR(10) PRIMARY KEY,
    category  VARCHAR(20) NOT NULL,
    name      VARCHAR(50) NOT NULL,
    is_active BOOLEAN     NOT NULL DEFAULT TRUE
);
CREATE TABLE rental_requests (
    id          BIGSERIAL PRIMARY KEY,
    item_code   VARCHAR(10)  NOT NULL REFERENCES rental_items(code),
    user_id     INT          NOT NULL REFERENCES users(id),     -- 대여자(신청자)
    real_user   INT          NOT NULL REFERENCES users(id),     -- 실사용자
    start_at    TIMESTAMP    NOT NULL,
    end_at      TIMESTAMP    NOT NULL CHECK (end_at > start_at),
    purpose     VARCHAR(300) NOT NULL,
    returned_on DATE,
    status      VARCHAR(4)   NOT NULL DEFAULT '신청' CHECK (status IN ('신청', '승인', '취소', '반납', '완료')),
    created_at  TIMESTAMP    NOT NULL DEFAULT now()
);   -- 같은 물품 기간 겹침은 앱 서버(또는 btree_gist EXCLUDE 제약)로 막는다

CREATE TABLE mail_logs (                            -- 우편물 발송·접수 대장 (등록은 총무)
    id          BIGSERIAL PRIMARY KEY,
    direction   CHAR(4)      NOT NULL CHECK (direction IN ('SEND', 'RECV')),
    doc_no      VARCHAR(20)  NOT NULL UNIQUE,       -- S-2026-118 / R-2026-204
    dept_id     INT          NOT NULL REFERENCES departments(id),
    staff_id    INT          NOT NULL REFERENCES users(id),     -- 발송인 / 수신인
    counterpart VARCHAR(100) NOT NULL,              -- 수신처 / 발송자
    kind        VARCHAR(8)   NOT NULL CHECK (kind IN ('일반', '등기', '빠른등기', '내용증명', '택배')),
    content     VARCHAR(300) NOT NULL,
    amount      INT          NOT NULL DEFAULT 0,
    tracking_no VARCHAR(40),
    handled_on  DATE         NOT NULL,              -- 발송일 / 수신일
    created_by  INT          NOT NULL REFERENCES users(id),
    created_at  TIMESTAMP    NOT NULL DEFAULT now()
);

CREATE TABLE cert_requests (                        -- 증명서신청 (개별 · 그룹)
    id          BIGSERIAL PRIMARY KEY,
    is_group    BOOLEAN      NOT NULL DEFAULT FALSE,
    requested_by INT         NOT NULL REFERENCES users(id),
    kind        VARCHAR(20)  NOT NULL,              -- 재직·경력·퇴직·원천징수부 … (급여 관련은 본인 명의만)
    purpose     VARCHAR(50)  NOT NULL,
    submit_to   VARCHAR(100),
    show_ssn    BOOLEAN      NOT NULL DEFAULT FALSE,
    print_on    DATE         NOT NULL,
    copies      SMALLINT     NOT NULL CHECK (copies BETWEEN 1 AND 10),
    memo        VARCHAR(300),
    status      VARCHAR(4)   NOT NULL DEFAULT '신청' CHECK (status IN ('신청', '승인', '반려')),
    decided_by  INT REFERENCES users(id),
    decided_on  DATE,
    reject_reason VARCHAR(300),
    created_at  TIMESTAMP    NOT NULL DEFAULT now()
);
CREATE TABLE cert_request_targets (                 -- 증명서 명의자 (개별은 1명)
    request_id BIGINT NOT NULL REFERENCES cert_requests(id) ON DELETE CASCADE,
    user_id    INT    NOT NULL REFERENCES users(id),
    PRIMARY KEY (request_id, user_id)
);

CREATE TABLE vehicles (
    plate_no   VARCHAR(20) PRIMARY KEY,             -- 12가 3456
    model      VARCHAR(30) NOT NULL,
    dept_id    INT REFERENCES departments(id),      -- 배정 부서
    odometer   INT NOT NULL DEFAULT 0,              -- 최근 주행거리
    is_active  BOOLEAN NOT NULL DEFAULT TRUE
);
CREATE TABLE vehicle_requests (                     -- 차량신청 · 운행일지 (작성 → 신청 → 완료(승인) → 주행거리 입력)
    id          BIGSERIAL PRIMARY KEY,
    plate_no    VARCHAR(20)  NOT NULL REFERENCES vehicles(plate_no),
    user_id     INT          NOT NULL REFERENCES users(id),
    project_no  VARCHAR(20),
    purpose     VARCHAR(200),
    destination VARCHAR(100),
    start_at    TIMESTAMP    NOT NULL,
    end_at      TIMESTAMP    NOT NULL CHECK (end_at > start_at),
    memo        VARCHAR(300),
    km_start    INT,
    km_end      INT CHECK (km_end IS NULL OR km_end >= km_start),
    parking     VARCHAR(100),
    status      VARCHAR(4)   NOT NULL DEFAULT '작성' CHECK (status IN ('작성', '신청', '완료')),
    approved_by INT REFERENCES users(id),
    created_at  TIMESTAMP    NOT NULL DEFAULT now()
);
CREATE INDEX ix_vehicle_requests_log ON vehicle_requests(plate_no, start_at) WHERE status = '완료';
-- 첨부는 approval_files와 같은 방식의 파일 표를 하나 더 두거나 공용 첨부 표로 묶는다

-- =====================================================================
-- 문서관리 (원본 ERP 구성: 문서관리 함 · 문서수발함 · 개인문서이력 · 문서검색 · 대외문서조회 · 부서문서수발조회)
-- 결재 문서 본문 열람은 approval_can_read 규칙 그대로 (수신부서는 결재선·참조자가 아니면 본문을 못 본다)
-- =====================================================================
CREATE TABLE doc_cabinets (                         -- 보관함 캐비넷
    id         SERIAL PRIMARY KEY,
    owner_id   INT          NOT NULL REFERENCES users(id),
    name       VARCHAR(60)  NOT NULL,
    memo       VARCHAR(200),
    readers    VARCHAR(10)  NOT NULL DEFAULT '본인' CHECK (readers IN ('본인', '부서', '전체')),
    UNIQUE (owner_id, name)
);
CREATE TABLE doc_archive (                          -- 결재 완료 문서의 개인 보관 위치 (기결 → 보관·이관·폐기)
    doc_id      BIGINT      NOT NULL REFERENCES approval_docs(id),
    user_id     INT         NOT NULL REFERENCES users(id),
    box         VARCHAR(4)  NOT NULL DEFAULT '기결' CHECK (box IN ('기결', '보관', '이관', '폐기')),
    cabinet_id  INT REFERENCES doc_cabinets(id),
    dept_keep   BOOLEAN     NOT NULL DEFAULT FALSE,  -- 부서보관
    handed_to   INT REFERENCES users(id),            -- 인계 받은 사람
    handed_at   TIMESTAMP,
    PRIMARY KEY (doc_id, user_id),
    CHECK (box <> '보관' OR cabinet_id IS NOT NULL)
);
CREATE TABLE dept_doc_managers (                    -- 부서별 문서관리자 (지정은 관리부)
    dept_id  INT PRIMARY KEY REFERENCES departments(id),
    user_id  INT NOT NULL REFERENCES users(id)
);
CREATE TABLE doc_sends (                            -- 부서 간 발신 (발신대기 → 발신완료 / 발신취소)
    id          BIGSERIAL PRIMARY KEY,
    send_no     VARCHAR(20) UNIQUE,                 -- 발-2026-0031 (발신할 때 매김)
    doc_id      BIGINT REFERENCES approval_docs(id),
    from_dept   INT          NOT NULL REFERENCES departments(id),
    sender_id   INT          NOT NULL REFERENCES users(id),
    name_of     VARCHAR(30)  NOT NULL,              -- 발신자명의 (부서장 · 대표이사)
    status      VARCHAR(6)   NOT NULL DEFAULT '발신대기' CHECK (status IN ('발신대기', '발신완료', '발신취소')),
    sent_on     DATE,
    created_at  TIMESTAMP    NOT NULL DEFAULT now()
);
CREATE TABLE doc_send_targets (                     -- 수신부서별 처리 (미접수 → 접수 → 회람 / 반송)
    send_id      BIGINT NOT NULL REFERENCES doc_sends(id) ON DELETE CASCADE,
    dept_id      INT    NOT NULL REFERENCES departments(id),
    status       VARCHAR(4) NOT NULL DEFAULT '미접수' CHECK (status IN ('미접수', '접수', '반송')),
    recv_no      VARCHAR(20) UNIQUE,                -- 수-2026-0101
    recv_on      DATE,
    circ_doc_id  BIGINT REFERENCES approval_docs(id),  -- 회람상신한 회람 문서 (완료되면 회람완료)
    hidden       BOOLEAN NOT NULL DEFAULT FALSE,
    PRIMARY KEY (send_id, dept_id)
);
CREATE TABLE ext_docs_in (                          -- 대외문서 접수 (외부 기관 문서 등록 → 수신처 발신)
    id          BIGSERIAL PRIMARY KEY,
    recv_no     VARCHAR(20) NOT NULL UNIQUE,        -- 접-2026-0119
    doc_no      VARCHAR(50),
    org_name    VARCHAR(100) NOT NULL,
    title       VARCHAR(200) NOT NULL,
    is_abroad   BOOLEAN      NOT NULL DEFAULT FALSE,
    recv_on     DATE         NOT NULL,
    status      VARCHAR(4)   NOT NULL DEFAULT '접수' CHECK (status IN ('접수', '발신')),
    received_by INT          NOT NULL REFERENCES users(id),
    memo        VARCHAR(300)
);
CREATE TABLE ext_docs_in_targets (ext_id BIGINT REFERENCES ext_docs_in(id) ON DELETE CASCADE, dept_id INT REFERENCES departments(id), PRIMARY KEY (ext_id, dept_id));
CREATE TABLE ext_docs_out (                         -- 대외공문 발송 (결재 완료 대외공문 → 발신)
    doc_id     BIGINT PRIMARY KEY REFERENCES approval_docs(id),
    is_abroad  BOOLEAN    NOT NULL DEFAULT FALSE,
    status     VARCHAR(6) NOT NULL DEFAULT '발신대기' CHECK (status IN ('발신대기', '발신완료', '발신취소')),
    sender_id  INT REFERENCES users(id),
    sent_on    DATE,
    memo       VARCHAR(300)
);
