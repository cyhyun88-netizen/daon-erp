/* ─────────────────────────────────────────────────────────────────────
   다온 ERP · Supabase 연결 (A안: 저장 통로 교체)
   앱은 claude.ai 아티팩트의 window.claude.use('db' | 'user' | 'assets' | 'downloads')를 쓰도록 만들어져 있다.
   여기서 같은 모양의 window.claude를 Supabase로 만들어, 화면 코드는 그대로 두고 저장 위치만 바꾼다.

   db      : doc(path) / collection(path) → set · delete · get · onSnapshot   (표 public.docs, 실시간 알림)
   user    : me() · id() · can() · profiles()                                 (표 public.profiles)
   assets  : upload(blob) → { id } · delete(id)                               (Storage 'files')
   downloads: 없음 → 앱이 일반 내려받기로 처리
   daonAuth: 로그인 화면이 쓰는 사번 로그인 · 비밀번호 변경 · 관리자 계정 관리
   ───────────────────────────────────────────────────────────────────── */
(function () {
  'use strict';
  const CFG = window.DAON_SUPABASE;
  if (!CFG || !window.supabase || !window.supabase.createClient) { console.warn('[daon] Supabase 설정이 없어 로컬 모드로 동작합니다.'); return; }

  // 로그인은 이 탭에서만 유지 (원래 앱과 같은 규칙: 탭을 닫으면 다시 로그인)
  const sb = window.supabase.createClient(CFG.url, CFG.key, {
    auth: { storage: window.sessionStorage, storageKey: 'daon-erp-auth', persistSession: true, autoRefreshToken: true, detectSessionInUrl: false },
  });

  /* ---------- 로그인 상태 ---------- */
  let session = null, profile = null, resolveReady;
  const ready = new Promise(r => { resolveReady = r; });   // 로그인될 때까지 저장소 기능은 기다린다

  async function loadProfile(uid) {
    const { data, error } = await sb.from('profiles').select('id, emp_no, name, is_admin, must_change_pw, active').eq('id', uid).maybeSingle();
    if (error) throw error;
    return data;
  }
  async function onSignedIn(s) {
    session = s;
    profile = await loadProfile(s.user.id);
    if (!profile || !profile.active) { await sb.auth.signOut(); session = null; profile = null; return false; }
    resolveReady(true);
    startRealtime();
    return true;
  }
  const booted = sb.auth.getSession().then(async ({ data }) => {
    if (data && data.session) { try { await onSignedIn(data.session); } catch (e) { console.error(e); } }
    return !!profile;
  });

  /* ---------- 문서 저장소 (Firestore 비슷한 모양) ---------- */
  const cache = new Map();            // path → data (읽어 온 문서)
  const loadedCols = new Map();       // col → Promise (처음 읽기)
  const loadedDocs = new Map();       // path → Promise
  const colSubs = new Map();          // col → Set<fn>
  const docSubs = new Map();          // path → Set<fn>
  const clone = v => (v == null ? v : JSON.parse(JSON.stringify(v)));
  const parentOf = p => p.split('/').slice(0, -1).join('/');
  const lastOf = p => p.split('/').pop();

  const dbErr = (e) => {
    const err = new Error((e && e.message) || '저장소 오류');
    const c = e && e.code;
    err.code = c === '42501' ? 'permission_denied' : (c === 'PGRST301' || c === '401') ? 'unauthenticated' : (e && e.status === 0) || /fetch|network/i.test(err.message) ? 'unavailable' : 'internal';
    err.cause = e;
    return err;
  };

  function docSnap(path) {
    const has = cache.has(path), d = cache.get(path);
    return { id: lastOf(path), ref: docRef(path), exists: has, data: () => (has ? clone(d) : undefined), metadata: { fromCache: false, hasPendingWrites: false } };
  }
  function colSnap(col) {
    const docs = [];
    for (const [p, d] of cache) if (parentOf(p) === col) docs.push({ id: lastOf(p), ref: docRef(p), exists: true, data: () => clone(d) });
    docs.sort((a, b) => (a.id < b.id ? -1 : 1));
    return { docs, size: docs.length, empty: !docs.length, forEach: f => docs.forEach(f), metadata: { fromCache: false, hasPendingWrites: false } };
  }
  function notify(path) {
    (docSubs.get(path) || []).forEach(f => { try { f(docSnap(path)); } catch (e) { console.error(e); } });
    const col = parentOf(path);
    (colSubs.get(col) || []).forEach(f => { try { f(colSnap(col)); } catch (e) { console.error(e); } });
  }

  async function fetchAll(q) {   // 1000개씩 나눠 읽기
    const out = []; let from = 0;
    for (;;) {
      const { data, error } = await q().range(from, from + 999);
      if (error) throw dbErr(error);
      out.push(...data);
      if (data.length < 1000) return out;
      from += 1000;
    }
  }
  function loadCol(col) {
    if (!loadedCols.has(col)) {
      loadedCols.set(col, (async () => {
        await ready;
        const rows = await fetchAll(() => sb.from('docs').select('path, data').eq('col', col).order('path'));
        rows.forEach(r => cache.set(r.path, r.data));
      })().catch(e => { loadedCols.delete(col); throw e; }));
    }
    return loadedCols.get(col);
  }
  function loadDoc(path) {
    if (loadedCols.has(parentOf(path))) return loadedCols.get(parentOf(path));
    if (!loadedDocs.has(path)) {
      loadedDocs.set(path, (async () => {
        await ready;
        const { data, error } = await sb.from('docs').select('path, data').eq('path', path).maybeSingle();
        if (error) throw dbErr(error);
        if (data) cache.set(path, data.data); else cache.delete(path);
      })().catch(e => { loadedDocs.delete(path); throw e; }));
    }
    return loadedDocs.get(path);
  }

  function docRef(path) {
    return {
      id: lastOf(path), path,
      parent: { path: parentOf(path) },
      async get() { await loadDoc(path); return docSnap(path); },
      async set(data) {
        await ready;
        const value = clone(data) || {};
        const had = cache.has(path), prev = cache.get(path);
        cache.set(path, value); notify(path);   // 화면에는 바로 반영
        const { error } = await sb.from('docs').upsert({ path, col: parentOf(path), doc_id: lastOf(path), data: value, updated_at: new Date().toISOString(), updated_by: session.user.id });
        if (error) { if (had) cache.set(path, prev); else cache.delete(path); notify(path); throw dbErr(error); }
      },
      async update(part) { await loadDoc(path); return this.set({ ...(cache.get(path) || {}), ...clone(part) }); },
      async delete() {
        await ready;
        const had = cache.has(path), prev = cache.get(path);
        cache.delete(path); notify(path);
        const { error } = await sb.from('docs').delete().eq('path', path);
        if (error) { if (had) { cache.set(path, prev); notify(path); } throw dbErr(error); }
      },
      onSnapshot(next, fail) {
        const fn = typeof next === 'function' ? next : (next && next.next) || (() => {});
        let live = true;
        if (!docSubs.has(path)) docSubs.set(path, new Set());
        loadDoc(path).then(() => { if (!live) return; docSubs.get(path).add(fn); fn(docSnap(path)); }, e => { if (live && fail) fail(e); });
        return () => { live = false; docSubs.get(path)?.delete(fn); };
      },
    };
  }
  function colRef(col) {
    return {
      id: lastOf(col), path: col,
      doc: id => docRef(`${col}/${id}`),
      async get() { await loadCol(col); return colSnap(col); },
      async add(data) { const id = `${Date.now().toString(36)}${Math.random().toString(36).slice(2, 8)}`; const r = docRef(`${col}/${id}`); await r.set(data); return r; },
      onSnapshot(next, fail) {
        const fn = typeof next === 'function' ? next : (next && next.next) || (() => {});
        let live = true;
        if (!colSubs.has(col)) colSubs.set(col, new Set());
        loadCol(col).then(() => { if (!live) return; colSubs.get(col).add(fn); fn(colSnap(col)); }, e => { if (live && fail) fail(e); });
        return () => { live = false; colSubs.get(col)?.delete(fn); };
      },
    };
  }
  const db = { doc: docRef, collection: colRef };

  /* 다른 직원이 저장 · 삭제하면 실시간으로 받는다 (권한 규칙상 내가 읽을 수 있는 것만 온다) */
  let channel = null;
  function startRealtime() {
    if (channel) return;
    if (session) sb.realtime.setAuth(session.access_token);
    channel = sb.channel('daon-docs')
      .on('postgres_changes', { event: '*', schema: 'public', table: 'docs' }, ev => {
        if (ev.eventType === 'DELETE') { const p = ev.old && ev.old.path; if (p && cache.has(p)) { cache.delete(p); notify(p); } return; }
        const row = ev.new; if (!row || !row.path) return;
        const watched = loadedCols.has(row.col) || loadedDocs.has(row.path);
        if (!watched) return;   // 아직 열어 보지 않은 모음은 열 때 읽는다
        if (JSON.stringify(cache.get(row.path)) === JSON.stringify(row.data)) return;   // 내가 방금 저장한 것
        cache.set(row.path, row.data); notify(row.path);
      })
      .subscribe(status => { if (status === 'CHANNEL_ERROR' || status === 'TIMED_OUT') console.warn('[daon] 실시간 연결 상태:', status); });
  }
  sb.auth.onAuthStateChange((evt, s) => { if (s && channel) sb.realtime.setAuth(s.access_token); if (s) session = s; });

  /* ---------- 사용자 ---------- */
  const names = new Map();
  const user = {
    async me() { await ready; return { id: session.user.id, name: profile.name, isOwner: !!profile.is_admin, emp: profile.emp_no }; },
    async id() { await ready; return session.user.id; },
    async can() { await ready; return true; },   // 로그인한 재직 직원은 쓰기 가능 (어디에 쓰는지는 DB 규칙이 막는다)
    async profiles(ids) {
      await ready;
      const need = [...new Set(ids || [])].filter(id => id && !names.has(id) && /^[0-9a-f-]{36}$/i.test(id));
      if (need.length) {
        const { data } = await sb.from('profiles').select('id, name, emp_no').in('id', need);
        (data || []).forEach(p => names.set(p.id, { name: p.name, emp: p.emp_no }));
      }
      return Object.fromEntries((ids || []).filter(id => names.has(id)).map(id => [id, names.get(id)]));
    },
  };

  /* ---------- 파일 (첨부 · 현장사진) ---------- */
  const EXT = { 'image/jpeg': '.jpg', 'image/png': '.png', 'image/gif': '.gif', 'image/webp': '.webp', 'application/pdf': '.pdf' };
  const assets = {
    async upload(blob, opts) {
      await ready;
      const type = (opts && opts.type) || blob.type || 'application/octet-stream';
      const id = `${crypto.randomUUID()}${EXT[type] || ''}`;
      const { error } = await sb.storage.from(CFG.bucket).upload(id, blob, { contentType: type, upsert: false, cacheControl: '31536000' });
      if (error) throw dbErr(error);
      return { id };
    },
    async delete(id) { await ready; const { error } = await sb.storage.from(CFG.bucket).remove([id]); if (error) throw dbErr(error); },
  };
  // 앱이 '/_blob/<id>'로 부르던 파일 주소
  window.DAON_BLOB = id => `${CFG.url}/storage/v1/object/public/${CFG.bucket}/${encodeURIComponent(id)}`;

  /* ---------- window.claude 흉내 ---------- */
  window.claude = {
    async use(name) {
      switch (name) {
        case 'db': await ready; return db;
        case 'user': await ready; return user;
        case 'assets': await ready; return assets;
        default: return null;   // downloads 등: 없으면 앱이 일반 방식으로 처리
      }
    },
  };

  /* ---------- 로그인 화면 · 관리자 기능에서 쓰는 함수 ---------- */
  const emailOf = emp => `e${String(emp).trim().toLowerCase()}@${CFG.emailDomain}`;
  window.daonAuth = {
    client: sb,
    booted,
    get profile() { return profile; },
    /* 사번 · 비밀번호 로그인 → { ok, mustChange, error } */
    async signIn(emp, pw) {
      const { data, error } = await sb.auth.signInWithPassword({ email: emailOf(emp), password: pw });
      if (error) return { ok: false, error: /invalid/i.test(error.message) ? 'wrong' : /banned/i.test(error.message) ? 'retired' : 'network', detail: error.message };
      let ok = false;
      try { ok = await onSignedIn(data.session); } catch (e) { return { ok: false, error: 'network', detail: e.message }; }
      if (!ok) return { ok: false, error: 'retired' };
      return { ok: true, mustChange: !!profile.must_change_pw, emp: profile.emp_no };
    },
    /* 지금 비밀번호 확인 (개인정보 변경): 지금 로그인한 계정으로 다시 로그인해 본다 (아이디를 바꿨어도 맞게) */
    async verify(emp, pw) {
      const email = (session && session.user && session.user.email) || emailOf(emp);
      const { data, error } = await sb.auth.signInWithPassword({ email, password: pw });
      return !error && !!data.session && (!session || data.session.user.id === session.user.id);
    },
    async changePassword(pw) {
      const { error } = await sb.auth.updateUser({ password: pw });
      if (error) return { ok: false, error: /weak|short|least/i.test(error.message) ? 'weak' : /same/i.test(error.message) ? 'same' : 'network', detail: error.message };
      await sb.rpc('mark_password_changed');
      if (profile) profile.must_change_pw = false;
      return { ok: true };
    },
    async signOut() { try { await sb.auth.signOut(); } catch (e) {} },
    /* 직원 명단(config/staff)을 다 읽을 때까지 기다린다: 관리자가 추가한 직원도 로그인할 수 있게 */
    async staffReady(timeout = 8000) {
      const t0 = Date.now();
      while (Date.now() - t0 < timeout) {
        if (typeof auth !== 'undefined' && auth.db && auth.waiting <= 0) return true;
        await new Promise(r => setTimeout(r, 100));
      }
      return false;
    },
    /* 관리자: 재직자 명단에 맞춰 로그인 계정을 만들고 퇴사자는 막는다 */
    async syncEmployees() {
      if (!profile || !profile.is_admin) return null;
      try {
        const staff = (typeof STAFF !== 'undefined' ? STAFF : []).filter(s => s.empNo).map(s => ({ emp: s.empNo, name: s.name }));
        const retired = (typeof RETIRED !== 'undefined' ? RETIRED : []).map(s => s.empNo).filter(Boolean);
        const { data, error } = await sb.rpc('admin_sync_employees', { p_staff: staff, p_retired: retired });
        if (error) throw error;
        const say = typeof toast === 'function' ? toast : () => {};
        if (data && (data.created || data.retired)) say(`직원 계정 맞춤: 새로 만듦 ${data.created}명 · 퇴사 차단 ${data.retired}명`);
        console.info('[daon] 직원 계정 맞추기', staff.length, '명 확인', data);
        devLog({ sync: 'ok', staff: staff.length, sample: staff.slice(0, 3), retired: retired.length, data });
        return data;
      } catch (e) {
        console.warn('[daon] 직원 계정 맞추기 실패', e);
        devLog({ sync: 'fail', error: e && { message: e.message, code: e.code, details: e.details, hint: e.hint } });
        if (typeof toast === 'function') toast('직원 계정 맞추기 실패: ' + ((e && (e.message || e.details)) || e));
        return null;
      }
    },
    /* 관리자: 직원 로그인 아이디 목록 { 사번: 아이디 } (아이디를 안 정한 직원은 빠짐) */
    async loginIds() {
      const { data, error } = await sb.from('profiles').select('emp_no, login_id').not('login_id', 'is', null);
      if (error) throw dbErr(error);
      return Object.fromEntries((data || []).map(r => [r.emp_no, r.login_id]));
    },
    /* 관리자: 아이디 정하기 (빈 값이면 지우고 사번으로 돌림) → { ok, id } | { ok:false, error } */
    async setLoginId(emp, id) {
      const { data, error } = await sb.rpc('admin_set_login_id', { p_emp: emp, p_id: id || '' });
      if (error) return { ok: false, error: error.message || '저장하지 못했습니다' };
      return { ok: true, id: data };
    },
    async resetPassword(emp) { const { data, error } = await sb.rpc('admin_reset_password', { p_emp: emp }); return !error && data === true; },
    async changeEmp(o, n) { const { data, error } = await sb.rpc('admin_change_emp', { p_old: o, p_new: n }); if (error || data !== true) throw error || new Error('계정 없음'); return true; },
  };

  /* 관리자: 로그인하면 · 직원 명단을 고치면 계정을 맞춘다 (잠깐 모아서 한 번) */
  // 내 PC에서 시험할 때만: 진단 기록을 로컬 서버로 보낸다 (배포된 사이트에서는 아무 일도 안 함)
  function devLog(o) {
    if (!/^(localhost|127\.0\.0\.1)$/.test(location.hostname)) return;
    try { fetch('/__log', { method: 'POST', body: JSON.stringify(o) }).catch(() => {}); } catch (e) {}
  }
  let syncTimer = null;
  const scheduleSync = () => { clearTimeout(syncTimer); syncTimer = setTimeout(() => window.daonAuth.syncEmployees(), 2500); };
  if (/^(localhost|127\.0\.0\.1)$/.test(location.hostname)) {
    window.addEventListener('error', e => devLog({ jsError: String(e.message), at: e.filename + ':' + e.lineno }));
    window.addEventListener('unhandledrejection', e => devLog({ rejection: String(e.reason && (e.reason.message || e.reason)) }));
    booted.then(ok => devLog({ boot: ok, emp: profile && profile.emp_no, admin: profile && profile.is_admin }));
  }
  ready.then(() => {
    devLog({ ready: true, admin: !!(profile && profile.is_admin) });
    if (!profile.is_admin) return;
    db.doc('config/staff').onSnapshot(() => { devLog({ staffSnap: true }); scheduleSync(); }, e => devLog({ staffSnapErr: String(e && e.message) }));
  });
})();
