-- =====================================================================
-- 화면에서 쓰는 핵심 조회
-- =====================================================================

-- [1] 로그인 직후: 이 사용자에게 보여줄 메뉴 트리 (GNB + LNB)
--     하위 화면 중 하나라도 읽을 수 있으면 상위 GROUP도 보여준다.
--     결과를 JSON으로 묶어 프론트의 MENUS 배열 모양 그대로 내려준다.
SELECT json_agg(g ORDER BY g.sort_order) AS menus
FROM (
    SELECT grp.code AS id, grp.name, grp.icon, grp.sort_order,
           json_agg(json_build_object(
               'id',    split_part(s.code, '.', 2),
               'name',  s.name,
               'type',  s.screen_type,
               'route', s.route,
               'perm',  json_build_object('write', p.can_write, 'delete', p.can_delete, 'manage', p.can_manage)
           ) ORDER BY s.sort_order) AS items
    FROM menus grp
    JOIN menus s ON s.parent_id = grp.id AND s.is_active
    JOIN v_user_menu_permissions p ON p.menu_id = s.id AND p.user_id = :user_id AND p.can_read
    WHERE grp.menu_type = 'GROUP' AND grp.is_active
    GROUP BY grp.id
) g;

-- [2] API 요청마다: 이 화면에 대해 이 동작이 허용되는가 (서버에서 반드시 재검사)
SELECT COALESCE(bool_or(can_write), FALSE) AS allowed
FROM v_user_menu_permissions p
JOIN menus m ON m.id = p.menu_id
WHERE p.user_id = :user_id AND m.code = :menu_code;

-- [3] 관리자 화면: 메뉴 하나에 누가 어떤 권한을 받았는지
SELECT m.name AS 메뉴,
       CASE WHEN p.role_id IS NOT NULL THEN '역할' WHEN p.dept_id IS NOT NULL THEN '부서' ELSE '개인' END AS 대상구분,
       COALESCE(r.name, d.name, u.name) AS 대상,
       p.can_read AS 조회, p.can_write AS 쓰기, p.can_delete AS 삭제, p.can_manage AS 관리
FROM menu_permissions p
JOIN menus m ON m.id = p.menu_id
LEFT JOIN roles r ON r.id = p.role_id
LEFT JOIN departments d ON d.id = p.dept_id
LEFT JOIN users u ON u.id = p.user_id
WHERE m.code = :menu_code
ORDER BY 대상구분, 대상;

-- =====================================================================
-- 전자결재 (approval_docs는 행 수준 보안으로 결재선 밖 문서가 자동으로 빠진다)
-- 요청마다 트랜잭션 시작 후:  SET LOCAL app.user_id = :login_user_id;
-- =====================================================================

-- [A1] 결재현황 집계표: 결재구분 × 결재하기 / 결재진행 / 결재완료
SELECT d.kind,
       count(*) FILTER (WHERE d.status = '진행' AND cur.user_id = app_user_id())                AS todo,
       count(*) FILTER (WHERE d.status = '진행' AND cur.user_id IS DISTINCT FROM app_user_id()) AS prog,
       count(*) FILTER (WHERE d.status IN ('완료', '반려'))                                      AS done
FROM approval_docs d
LEFT JOIN approval_lines cur ON cur.doc_id = d.id AND cur.seq = d.current_seq
WHERE d.status <> '임시저장'
GROUP BY d.kind;

-- [A2] 결재하기 목록 (내 차례인 문서)
SELECT d.id, dep.name AS dept, d.form_name, d.urgent, d.title, u.name AS drafter, d.submitted_at
FROM approval_docs d
JOIN approval_lines cur ON cur.doc_id = d.id AND cur.seq = d.current_seq AND cur.user_id = app_user_id()
JOIN users u ON u.id = d.drafter_id
JOIN departments dep ON dep.id = d.dept_id
WHERE d.status = '진행'
ORDER BY d.submitted_at DESC
LIMIT :page_size OFFSET :offset;

-- [A3] 결재 처리 (한 트랜잭션). 본인 차례의 본인 행이 아니면 UPDATE 0건 → 앱에서 거부
UPDATE approval_lines SET action = :action, opinion = :opinion, acted_at = now()
WHERE doc_id = :doc_id AND user_id = app_user_id() AND action IS NULL;
UPDATE approval_docs d
SET current_seq = CASE WHEN :action = '반려' THEN d.current_seq ELSE d.current_seq + 1 END,
    status      = CASE WHEN :action = '반려' THEN '반려'
                       WHEN NOT EXISTS (SELECT 1 FROM approval_lines l WHERE l.doc_id = d.id AND l.seq > d.current_seq) THEN '완료'
                       ELSE '진행' END,
    finished_at = CASE WHEN :action = '반려' OR NOT EXISTS (SELECT 1 FROM approval_lines l WHERE l.doc_id = d.id AND l.seq > d.current_seq) THEN now() END
WHERE d.id = :doc_id;