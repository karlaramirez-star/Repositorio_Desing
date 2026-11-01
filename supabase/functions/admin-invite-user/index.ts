import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}

const json = (status: number, body: Record<string, unknown>) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  })

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })
  if (req.method !== 'POST') return json(405, { error: 'Método no permitido.' })

  const supabaseUrl = Deno.env.get('SUPABASE_URL')
  const anonKey = Deno.env.get('SUPABASE_ANON_KEY')
  const secretKey = Deno.env.get('MOTUM_SUPABASE_SECRET_KEY')
  if (!supabaseUrl || !anonKey || !secretKey) {
    return json(500, { error: 'Faltan variables de entorno de Supabase.' })
  }

  const authorization = req.headers.get('Authorization') || ''
  if (!authorization.startsWith('Bearer ')) {
    return json(401, { error: 'Sesión no válida.' })
  }

  const userClient = createClient(supabaseUrl, anonKey, {
    global: { headers: { Authorization: authorization } },
    auth: { persistSession: false, autoRefreshToken: false },
  })
  const adminClient = createClient(supabaseUrl, secretKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  })

  const { data: authData, error: authError } = await userClient.auth.getUser()
  if (authError || !authData.user) return json(401, { error: 'No se pudo validar la sesión.' })
  const callerId = authData.user.id

  const { data: callerProfile, error: profileError } = await adminClient
    .from('perfiles')
    .select('activo')
    .eq('id', callerId)
    .maybeSingle()
  if (profileError || !callerProfile?.activo) return json(403, { error: 'La cuenta no está activa.' })

  const { data: callerRoles, error: roleCheckError } = await adminClient
    .from('usuario_roles')
    .select('roles!inner(nombre)')
    .eq('usuario_id', callerId)
  if (roleCheckError) return json(500, { error: 'No fue posible validar el rol del administrador.' })
  const isAdmin = (callerRoles || []).some((item: any) =>
    String(item.roles?.nombre || '').toLowerCase() === 'administrador'
  )
  if (!isAdmin) return json(403, { error: 'Solo un Administrador puede invitar usuarios.' })

  let body: any
  try {
    body = await req.json()
  } catch {
    return json(400, { error: 'El cuerpo de la solicitud no contiene JSON válido.' })
  }

  const nombre = String(body.nombre || '').trim()
  const email = String(body.email || '').trim().toLowerCase()
  const telefono = String(body.telefono || '').trim() || null
  const roleName = String(body.rol || 'Usuario').trim()
  const departmentId = body.departamento_id ? String(body.departamento_id) : null
  const activo = body.activo !== false

  if (!nombre) return json(400, { error: 'El nombre es obligatorio.' })
  if (!/^[^\s@]+@tecnomotum\.com$/i.test(email)) {
    return json(400, { error: 'Solo se permiten correos @tecnomotum.com.' })
  }

  const { data: role, error: roleError } = await adminClient
    .from('roles')
    .select('id,nombre')
    .ilike('nombre', roleName)
    .maybeSingle()
  if (roleError || !role) return json(400, { error: 'El rol seleccionado no existe en la tabla roles.' })

  if (departmentId) {
    const { data: dept, error: deptError } = await adminClient
      .from('departamentos')
      .select('id')
      .eq('id', departmentId)
      .eq('activo', true)
      .maybeSingle()
    if (deptError || !dept) return json(400, { error: 'El departamento seleccionado no existe o está inactivo.' })
  } else if (String(role.nombre).toLowerCase() !== 'administrador') {
    return json(400, { error: 'Los usuarios que no son Administrador deben tener un departamento.' })
  }

  // Reuse an existing Auth account when the person has already signed in with Google.
  // Otherwise create a confirmed email identity without a password or invitation link.
  // Supabase can automatically link the matching verified Google identity to this email.
  let authUser: any = null
  for (let page = 1; page <= 20 && !authUser; page++) {
    const { data: listData, error: listError } = await adminClient.auth.admin.listUsers({ page, perPage: 1000 })
    if (listError) return json(500, { error: 'No fue posible consultar los usuarios de Auth: ' + listError.message })
    authUser = (listData.users || []).find((item: any) => String(item.email || '').toLowerCase() === email) || null
    if ((listData.users || []).length < 1000) break
  }

  if (!authUser) {
    const { data: createData, error: createError } = await adminClient.auth.admin.createUser({
      email,
      email_confirm: true,
      user_metadata: { full_name: nombre, name: nombre, phone: telefono },
    })
    if (createError || !createData.user) {
      return json(400, { error: createError?.message || 'No fue posible crear la cuenta de acceso.' })
    }
    authUser = createData.user
  }

  const newUserId = authUser.id
  const { error: upsertProfileError } = await adminClient
    .from('perfiles')
    .upsert({
      id: newUserId,
      nombre_completo: nombre,
      correo: email,
      telefono,
      activo,
      updated_at: new Date().toISOString(),
    }, { onConflict: 'id' })
  if (upsertProfileError) return json(500, { error: 'El usuario fue invitado, pero no se pudo completar su perfil: ' + upsertProfileError.message })

  const { error: clearRoleError } = await adminClient.from('usuario_roles').delete().eq('usuario_id', newUserId)
  if (clearRoleError) return json(500, { error: 'No fue posible preparar la asignación del rol.' })
  const { error: assignRoleError } = await adminClient.from('usuario_roles').insert({
    usuario_id: newUserId,
    rol_id: role.id,
    asignado_por: callerId,
  })
  if (assignRoleError) return json(500, { error: 'El usuario fue invitado, pero no se pudo asignar el rol: ' + assignRoleError.message })

  const { error: clearDeptError } = await adminClient.from('usuario_departamentos').delete().eq('usuario_id', newUserId)
  if (clearDeptError) return json(500, { error: 'No fue posible preparar la asignación del departamento.' })
  if (departmentId) {
    const { error: assignDeptError } = await adminClient.from('usuario_departamentos').insert({
      usuario_id: newUserId,
      departamento_id: departmentId,
    })
    if (assignDeptError) return json(500, { error: 'El usuario fue invitado, pero no se pudo asignar el departamento: ' + assignDeptError.message })
  }

  return json(200, {
    ok: true,
    user_id: newUserId,
    message: 'Cuenta registrada y permisos asignados. El acceso se realiza con Google.',
  })
})
