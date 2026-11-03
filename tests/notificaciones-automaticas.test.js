/*
 * Pruebas de las notificaciones automáticas (AUTO_EMAIL_NOTIFICATIONS_ENABLED = true).
 *
 * - Sesión de Administrador y cliente de Supabase simulados; sin red ni datos reales.
 * - Toda solicitud a la función de correo se intercepta y se responde localmente:
 *   no se envía ningún correo real.
 *
 * Ejecutar: node tests/notificaciones-automaticas.test.js   (requiere el paquete "playwright")
 */
const path = require('path');
const assert = require('assert');
const { chromium } = require('playwright');

const PAGE = 'file://' + path.resolve(__dirname, '..', 'index.html');
const results = [];
async function check(name, fn) {
  try { await fn(); results.push('PASA  ' + name); }
  catch (e) { results.push('FALLA ' + name + ' -> ' + e.message); }
}

(async () => {
  const browser = await chromium.launch();
  const page = await browser.newPage();
  const pageErrors = [];
  const mailRequests = [];
  page.on('pageerror', (e) => pageErrors.push(e.message));
  await page.route('**/*', (route) => {
    const req = route.request();
    if (req.url().startsWith('file:')) return route.continue();
    if (req.url().endsWith('/.netlify/functions/sendmail')) {
      mailRequests.push({ url: req.url(), headers: req.headers(), body: JSON.parse(req.postData() || '{}') });
      return route.fulfill({ status: 200, contentType: 'application/json', body: '{"ok":true,"simulado":true}' });
    }
    return route.abort();
  });
  await page.addInitScript(() => {
    localStorage.setItem('sb-prueba-auth-token', '{"fake":true}');
    window.__inserts = [];
    const user = { id: 'admin-1', email: 'karlaramirez@tecnomotum.com', user_metadata: {} };
    const tables = {
      perfiles: { id: 'admin-1', nombre_completo: 'Karla', correo: user.email, activo: true, avatar_url: '' },
      usuario_roles: [{ rol_id: 'r1' }], roles: [{ id: 'r1', nombre: 'Administrador' }], rol_permisos: [], permisos: [],
      usuario_departamentos: [], departamentos: [], historial_actividades: { id: 'h1' }, notificaciones: { id: 'n1' }
    };
    const chain = (t) => {
      let single = false;
      const h = { get(_, k) {
        if (k === 'then') return (res) => res(single ? { data: tables[t] || { id: 'x' }, error: null } : { data: Array.isArray(tables[t]) ? tables[t] : [], error: null });
        return (...args) => { if (k === 'single' || k === 'maybeSingle') single = true; if (k === 'insert') window.__inserts.push({ t, args }); return new Proxy({}, h); };
      } };
      return new Proxy({}, h);
    };
    window.supabase = { createClient: () => ({
      auth: {
        getSession: async () => ({ data: { session: { user, access_token: 'token-prueba' } }, error: null }),
        onAuthStateChange: () => ({ data: { subscription: { unsubscribe() {} } } }),
        signOut: async () => ({}), signInWithOAuth: async () => ({})
      },
      from: chain, rpc: async () => ({ data: null, error: null }),
      storage: { from: () => ({ createSignedUrl: async () => ({ data: null, error: { message: 'x' } }) }) }
    }) };
  });
  await page.goto(PAGE);
  await page.waitForFunction(() => window._isAdminSession === true, null, { timeout: 15000 });

  const out = await page.evaluate(async () => {
    window.renderAdminNotificaciones = () => {};
    AREAS.splice(0, AREAS.length,
      { id: 1, nombre: 'Customer Experience', dbId: 'd-cx' },
      { id: 2, nombre: 'Servicio Técnico', dbId: 'd-st' });
    USERS_DB.splice(0, USERS_DB.length,
      { id: 1, nombre: 'Vladimir', email: 'vladimir@tecnomotum.com', area: 'Customer Experience', areas: ['Customer Experience'], rol: 'Usuario', activo: true },
      { id: 2, nombre: 'Inactivo CX', email: 'inactivo@tecnomotum.com', area: 'Customer Experience', areas: ['Customer Experience'], rol: 'Usuario', activo: false },
      { id: 3, nombre: 'Técnico', email: 'tecnico@tecnomotum.com', area: 'Servicio Técnico', areas: ['Servicio Técnico'], rol: 'Usuario', activo: true },
      { id: 4, nombre: 'Karla', email: 'karlaramirez@tecnomotum.com', area: 'Administrador', areas: [], rol: 'Administrador', activo: true });
    const r = {};
    r.nueva = await window.sendEmailNotification('nueva_plantilla', { nombre: 'Plantilla A', areaId: 1, areaIds: [1], categoria: 'Reportes' });
    r.actualiza = await window.sendEmailNotification('actualiza_plantilla', { nombre: 'Plantilla A', areaId: 1, areaIds: [1], categoria: 'Reportes' });
    r.contenido = await window.sendEmailNotification('nuevo_contenido', { nombre: 'Manual 2026' });
    await new Promise((res) => setTimeout(res, 500));
    const pick = (e) => e && { type: e.type, recipients: e.recipients, status: e.status };
    return { nueva: pick(r.nueva), actualiza: pick(r.actualiza), contenido: pick(r.contenido), inserts: window.__inserts.filter((i) => i.t === 'notificaciones').length };
  });
  await page.waitForTimeout(300);

  await check('Nueva plantilla: se envía a los usuarios activos del departamento', () => {
    assert.ok(out.nueva, 'la notificación no se generó'); assert.deepStrictEqual(out.nueva.recipients, ['vladimir@tecnomotum.com']);
    assert.strictEqual(out.nueva.status, 'enviado');
  });
  await check('Actualización de plantilla: se envía a los usuarios activos del departamento', () => {
    assert.ok(out.actualiza, 'la notificación no se generó'); assert.deepStrictEqual(out.actualiza.recipients, ['vladimir@tecnomotum.com']);
    assert.strictEqual(out.actualiza.status, 'enviado');
  });
  await check('Nuevo contenido digital: se envía a todos los usuarios activos (sin Administrador)', () => {
    assert.ok(out.contenido, 'la notificación no se generó');
    assert.deepStrictEqual(out.contenido.recipients.slice().sort(), ['tecnico@tecnomotum.com', 'vladimir@tecnomotum.com']);
    assert.strictEqual(out.contenido.status, 'enviado');
  });
  await check('Se hicieron 3 solicitudes a la función de correo (interceptadas, sin envío real)', () => {
    assert.strictEqual(mailRequests.length, 3);
    for (const r of mailRequests) {
      assert.strictEqual(r.url, 'https://enchanting-unicorn-63d51b.netlify.app/.netlify/functions/sendmail');
      assert.strictEqual(r.headers['authorization'], 'Bearer token-prueba');
      assert.ok(!('x-api-key' in r.headers));
      assert.deepStrictEqual(Object.keys(r.body), ['subject', 'textMail', 'emails']);
    }
  });
  await check('Cada notificación se registra en la tabla notificaciones', () => assert.strictEqual(out.inserts, 3));
  await check('Sin errores de página', () => assert.deepStrictEqual(pageErrors, []));
  await browser.close();

  console.log(results.join('\n'));
  const failed = results.filter((r) => r.startsWith('FALLA')).length;
  console.log('\n' + (results.length - failed) + '/' + results.length + ' pruebas pasaron');
  process.exit(failed ? 1 : 0);
})().catch((e) => { console.error(e); process.exit(1); });
