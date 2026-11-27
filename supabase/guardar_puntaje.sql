-- Operación Cafecito · validación de puntajes en el servidor
-- Flujo: el juego llama iniciar_partida() al empezar y guardar_puntaje() al ganar.
-- Las tablas de puntajes no aceptan inserciones directas: solo esta función puede escribir.

create or replace function public.iniciar_partida(p_entorno text, p_mapa text)
returns json
language plpgsql
security definer
set search_path = ''
as $$
declare d jsonb; bid text; nm int; caf int; v_ip text := public.ip_cliente(); pid uuid;
begin
  if p_entorno not in ('prod','dev') then raise exception 'Entorno no válido'; end if;
  select doc, builtin_id into d, bid from public.mapas_ranking where entorno = p_entorno and mapa = p_mapa;
  if d is null then raise exception 'Este mapa no tiene ranking'; end if;
  -- en dev los mapas oficiales se pueden editar en la nube: se usa la versión guardada
  if p_entorno = 'dev' then
    d := coalesce((select jsonb_build_object('start', md.doc->'start', 'obj', md.doc->'obj')
                     from public.mapas_dev md where md.id = bid and md.doc ? 'obj' and md.doc ? 'start'), d);
  end if;
  if v_ip is not null and (select count(*) from public.partidas where ip = v_ip and inicio > now() - interval '5 minutes') >= 40 then
    raise exception 'Demasiadas partidas seguidas. Espera un poco.';
  end if;
  delete from public.partidas where inicio < now() - interval '1 day';
  nm := jsonb_array_length(d->'obj'->'machines');
  caf := case when nm > 1 then floor(random() * nm)::int else 0 end;
  insert into public.partidas (entorno, mapa, doc, cafetera, ip) values (p_entorno, p_mapa, d, caf, v_ip) returning id into pid;
  return json_build_object('id', pid, 'cafetera', caf);
end $$;

-- p_ruta: [[t, x, z, f], ...] cada ~0.25 s de juego; f: 1 = tiene cápsula, 2 = tiene café.
-- Devuelve {ok:true} o {ok:false, error:'...'}. Una partida rechazada queda usada.
create or replace function public.guardar_puntaje(p_partida uuid, p_nombre text, p_tiempo numeric, p_visto int, p_estrellas int, p_ruta jsonb)
returns json
language plpgsql
security definer
set search_path = ''
as $$
declare
  pa public.partidas%rowtype; d jsonb; o jsonb; cap jsonb; mq jsonb; desk jsonb;
  transcurrido numeric; n int; i int; e jsonb;
  t numeric; x numeric; z numeric; f int;
  pt numeric; px numeric; pz numeric; pf int := 0;
  dt numeric; dist numeric; vmax numeric;
  tiene_cap bool := false; tiene_cafe bool := false; cerca_maquina numeric := 0;
  v_tiempo numeric := round(p_tiempo, 2); v_visto int; v_estr int; v_nombre text := trim(coalesce(p_nombre, ''));
  err text := null;
begin
  select * into pa from public.partidas where id = p_partida for update;
  if not found then return json_build_object('ok', false, 'error', 'Partida no válida'); end if;
  if pa.usada_en is not null then return json_build_object('ok', false, 'error', 'Esta partida ya se guardó'); end if;
  if pa.inicio < now() - interval '1 hour' then return json_build_object('ok', false, 'error', 'La partida expiró'); end if;
  if char_length(v_nombre) < 1 or char_length(v_nombre) > 20 then return json_build_object('ok', false, 'error', 'Escribe un nombre de 1 a 20 letras'); end if;
  if public.nombre_bloqueado(v_nombre) then return json_build_object('ok', false, 'error', 'Ese nombre no está permitido. Prueba con otro.'); end if;
  -- 10 segundos entre una marca y la siguiente del mismo nombre (no consume la partida: puede reintentar)
  if (pa.entorno = 'prod' and exists (select 1 from public.puntajes where lower(trim(nombre)) = lower(v_nombre) and creado > now() - interval '10 seconds'))
     or (pa.entorno = 'dev' and exists (select 1 from public.puntajes_dev where lower(trim(nombre)) = lower(v_nombre) and creado > now() - interval '10 seconds')) then
    return json_build_object('ok', false, 'error', 'Espera unos segundos antes de guardar otra marca.', 'reintentar', true);
  end if;

  d := pa.doc; o := d->'obj'; desk := d->'start'; mq := o->'machines'->pa.cafetera;  -- el escritorio es el punto de inicio
  cap := case when jsonb_typeof(o->'capsule') = 'object' then o->'capsule' else null end;
  transcurrido := extract(epoch from now() - pa.inicio);

  -- 1) el tiempo tiene que haber pasado de verdad en el reloj del servidor
  if v_tiempo is null or v_tiempo > transcurrido + 3 then err := 'reloj'; end if;
  -- 2) no más rápido que el mínimo físico del mapa con la cafetera que sorteó el servidor
  if err is null and v_tiempo < public.tiempo_minimo_mapa(d, pa.cafetera) * 0.97 then err := 'minimo'; end if;
  -- 3) el recorrido tiene que ser posible
  if err is null and (jsonb_typeof(p_ruta) <> 'array' or jsonb_array_length(p_ruta) < greatest(2, floor(v_tiempo / 0.6)) or jsonb_array_length(p_ruta) > 8000) then err := 'ruta-largo'; end if;

  if err is null then
    n := jsonb_array_length(p_ruta);
    for i in 0 .. n - 1 loop
      e := p_ruta->i;
      begin
        t := (e->>0)::numeric; x := (e->>1)::numeric; z := (e->>2)::numeric; f := coalesce((e->>3)::int, 0);
      exception when others then err := 'ruta-formato'; exit; end;
      if t is null or x is null or z is null then err := 'ruta-formato'; exit; end if;

      if i = 0 then
        if t > 0.5 or sqrt((x-(d->'start'->>'x')::numeric)^2 + (z-(d->'start'->>'z')::numeric)^2) > 1.2 then err := 'inicio'; exit; end if;
      else
        dt := t - pt;
        if dt <= 0 or dt > 1.0 then err := 'ruta-tiempo'; exit; end if;
        dist := sqrt((x-px)^2 + (z-pz)^2);
        vmax := case when (pf & 2) = 2 then 3.1 else 5.3 end;   -- con café no se puede correr
        if dist > vmax * dt * 1.15 + 0.25 then err := 'velocidad'; exit; end if;
        -- tiempo junto a la cafetera buena (la preparación dura 4 s, se puede hacer en tramos)
        if not tiene_cafe and (cap is null or tiene_cap)
           and sqrt((x-(mq->>'x')::numeric)^2 + (z-(mq->>'z')::numeric)^2) <= 2.5
           and sqrt((px-(mq->>'x')::numeric)^2 + (pz-(mq->>'z')::numeric)^2) <= 2.5 then
          cerca_maquina := cerca_maquina + dt;
        end if;
      end if;

      if (f & 1) = 1 and not tiene_cap then
        if cap is null or sqrt((x-(cap->>'x')::numeric)^2 + (z-(cap->>'z')::numeric)^2) > 2.5 then err := 'capsula'; exit; end if;
        tiene_cap := true;
      end if;
      if (f & 2) = 2 and not tiene_cafe then
        if (cap is not null and not tiene_cap) or cerca_maquina < 3.4
           or sqrt((x-(mq->>'x')::numeric)^2 + (z-(mq->>'z')::numeric)^2) > 2.5 then err := 'cafe'; exit; end if;
        tiene_cafe := true;
      end if;
      if tiene_cafe and (f & 2) = 0 then err := 'cafe-perdido'; exit; end if;

      pt := t; px := x; pz := z; pf := f;
    end loop;
  end if;

  if err is null then
    if not tiene_cafe or abs(pt - v_tiempo) > 0.35
       or sqrt((px-(desk->>'x')::numeric)^2 + (pz-(desk->>'z')::numeric)^2) > 2.2 then err := 'final'; end if;
  end if;

  update public.partidas set usada_en = now() where id = pa.id;
  if err is not null then
    raise log 'guardar_puntaje rechazado: % (partida %, tiempo %)', err, pa.id, v_tiempo;
    return json_build_object('ok', false, 'error', 'El ranking no pudo validar esta partida (' || err || ').');
  end if;

  v_visto := least(greatest(coalesce(p_visto, 0), 0), 999);
  v_estr := least(greatest(coalesce(p_estrellas, 1), 1), 3);
  if v_visto > 0 then v_estr := 1; end if;

  if pa.entorno = 'prod' then
    insert into public.puntajes (nombre, mapa, tiempo, visto, estrellas, ruta) values (v_nombre, pa.mapa, v_tiempo, v_visto, v_estr, p_ruta);
  else
    insert into public.puntajes_dev (nombre, mapa, tiempo, visto, estrellas, ruta) values (v_nombre, pa.mapa, v_tiempo, v_visto, v_estr, p_ruta);
  end if;
  return json_build_object('ok', true, 'tiempo', v_tiempo);
end $$;

-- Solo la función puede escribir puntajes (se aplica a puntajes_dev ya; a puntajes al pasar a prod)
-- drop policy if exists "agregar puntaje dev" on public.puntajes_dev;
-- revoke insert on public.puntajes_dev from anon, authenticated;
