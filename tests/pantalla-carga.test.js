/*
 * Pruebas de la pantalla de carga durante la validación de sesión.
 * Usa un cliente de Supabase simulado (sin red, sin datos reales) y el reloj
 * simulado de Playwright para comprobar el límite de 30 s sin esperar en tiempo real.
 *
 * Ejecutar:  node tests/pantalla-carga.test.js   (requiere el paquete "playwright")
 */
const path = require('path');
const assert = require('assert');
const { chromium } = require('playwright');
const PAGE = 'file://' + path.resolve(__dirname, '..', 'index.html');
const base = { token: true, activo: true, depts: ['d1'] };
const SCEN = {
  karla:            { ...base, email: 'karlaramirez@tecnomotum.com', role: 'Administrador', depts: [], expect: 'pg-admin' },
  vladimir:         { ...base, email: 'vladimir@tecnomotum.com', role: 'Usuario', expect: 'pg-landing' },
  sinSesion:        { token: false, expect: 'pg-welcome' },
  errorValidacion:  { ...base, email: 'inactivo@tecnomotum.com', role: 'Usuario', activo: false, expect: 'pg-welcome' },
  cargaDatosLenta:  { ...base, email: 'karlaramirez@tecnomotum.com', role: 'Administrador', depts: [], slow: { plantillas: 40000 }, expect: 'pg-welcome' },
  perfilLento:      { ...base, email: 'vladimir@tecnomotum.com', role: 'Usuario', slow: { perfiles: 40000 }, expect: 'pg-welcome' },
};
(async () => {
  const b = await chromium.launch();
  const results = {};
  for (const [name, sc] of Object.entries(SCEN)) {
    const ctx = await b.newContext(); const p = await ctx.newPage(); const errs = [];
    p.on('pageerror', e => errs.push(e.message));
    await p.route('**/*', r => r.request().url().startsWith('file:') ? r.continue() : r.abort());
    await p.clock.install();
    await p.addInitScript((sc) => {
      if (sc.token) localStorage.setItem('sb-zxkmxtthgvwzrqpmfaso-auth-token', '{"fake":true}');
      window.__log = [];
      const delay = (v, ms) => new Promise(r => setTimeout(() => r(v), ms || 300));
      const user = sc.token ? { id: 'u1', email: sc.email, user_metadata: {} } : null;
      const tables = {
        perfiles: { id: 'u1', nombre_completo: 'x', correo: sc.email, activo: sc.activo, avatar_url: '' },
        usuario_roles: [{ rol_id: 'r1' }], roles: [{ id: 'r1', nombre: sc.role }], rol_permisos: [], permisos: [],
        usuario_departamentos: (sc.depts || []).map(d => ({ departamento_id: d })),
        departamentos: [{ id: 'd1', nombre: 'Customer Experience', activo: true }], historial_actividades: { id: 'h1' },
      };
      const slow = sc.slow || {};
      const chain = (t) => { let single = false; const h = { get(_, k) {
        if (k === 'then') return (res) => delay(single ? { data: tables[t] || null, error: null } : { data: Array.isArray(tables[t]) ? tables[t] : [], error: null }, slow[t]).then(res);
        return () => { if (k === 'single' || k === 'maybeSingle') single = true; return new Proxy({}, h); };
      } }; return new Proxy({}, h); };
      window.supabase = { createClient: () => ({
        auth: { getSession: () => delay({ data: { session: user ? { user, access_token: 'x' } : null }, error: null }),
                onAuthStateChange: () => ({ data: { subscription: { unsubscribe() {} } } }), signOut: async () => ({}), signInWithOAuth: async () => ({}) },
        from: chain, rpc: async () => ({ data: null, error: null }),
        storage: { from: () => ({ createSignedUrl: async () => ({ data: null, error: { message: 'x' } }) }) },
      }) };
      const og = () => { const g = window.goTo; if (!g) return setTimeout(og, 5); window.goTo = function (pg) { window.__log.push('goTo:' + pg); return g.apply(this, arguments); }; };
      og();
    }, sc);
    await p.goto(PAGE);
    const snap = (label) => p.evaluate((label) => ({
      t: label,
      carga: document.documentElement.classList.contains('auth-booting'),
      activa: [...document.querySelectorAll('.page.active,.page-flex.active')].map(e => e.id).join(','),
      usuarioAsignado: !!window._supabaseUser,
      error: document.getElementById('reg-err').style.display === 'block' ? document.getElementById('reg-err').textContent : null,
      goTo: window.__log.join(' '),
    }), label);
    const timeline = [await snap('0s')];
    for (const [step, label] of [[5000, '5s'], [24000, '29s'], [2000, '31s'], [14000, '45s']]) {
      await p.clock.runFor(step); timeline.push(await snap(label));
    }
    results[name] = { timeline, pageErrors: errs, expected: sc.expect };
    await ctx.close();
  }
  await b.close();
  for (const [n, r] of Object.entries(results)) {
    console.log('\n## ' + n + ' (esperado: ' + r.expected + ')' + (r.pageErrors.length ? ' pageErrors=' + JSON.stringify(r.pageErrors) : ''));
    for (const s of r.timeline) console.log('  ' + s.t.padEnd(4), 'carga=' + String(s.carga).padEnd(5), 'activa=' + s.activa.padEnd(10), 'usuario=' + String(s.usuarioAsignado).padEnd(5), 'goTo=[' + s.goTo + ']', s.error ? 'error="' + s.error + '"' : '');
  }
  // ── Verificaciones ──
  const at = (n, t) => results[n].timeline.find((s) => s.t === t);
  const TIMEOUT = /tardando más de lo normal/;
  for (const n of Object.keys(results)) assert.deepStrictEqual(results[n].pageErrors, [], n + ': errores de página');
  for (const [n, pg] of [['karla', 'pg-admin'], ['vladimir', 'pg-landing']]) {
    assert.ok(at(n, '0s').carga, n + ': la pantalla de carga debe verse desde el inicio');
    assert.strictEqual(at(n, '5s').goTo, 'goTo:' + pg, n + ': redirección correcta');
    assert.strictEqual(at(n, '45s').activa, pg, n + ': sigue en su pantalla');
    assert.ok(!at(n, '45s').error, n + ': el temporizador se limpió al terminar');
  }
  assert.ok(!at('sinSesion', '0s').carga && at('sinSesion', '0s').activa === 'pg-welcome', 'sin sesión: acceso normal');
  assert.ok(!at('sinSesion', '45s').error, 'sin sesión: sin mensaje de tiempo agotado');
  assert.ok(!at('errorValidacion', '5s').carga && /inactiva/.test(at('errorValidacion', '5s').error), 'error: mensaje de validación');
  assert.ok(!TIMEOUT.test(at('errorValidacion', '45s').error), 'error: el temporizador se limpió');
  for (const n of ['cargaDatosLenta', 'perfilLento']) {
    assert.ok(at(n, '29s').carga, n + ': carga visible antes de 30 s');
    assert.ok(!at(n, '31s').carga && TIMEOUT.test(at(n, '31s').error), n + ': a los 30 s se oculta y muestra el mensaje');
    assert.strictEqual(at(n, '45s').goTo, '', n + ': sin redirección tardía');
    assert.strictEqual(at(n, '45s').activa, 'pg-welcome', n + ': permanece en el acceso');
  }
  assert.ok(at('cargaDatosLenta', '29s').usuarioAsignado, 'cargaDatosLenta: currentSupabaseUser ya estaba asignado');
  console.log('\nTodas las verificaciones pasaron.');
})().catch((e) => { console.error(e.message); process.exit(1); });
