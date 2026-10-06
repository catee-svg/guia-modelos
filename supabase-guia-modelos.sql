-- ============================================================
-- GUÍA DE MODELOS — tabla abierta (cualquiera con el link edita)
-- Pegar ENTERO en Supabase → SQL Editor → Run. Se puede correr
-- más de una vez sin romper nada.
--
-- Redes de seguridad incluidas:
--   1. Nadie puede borrar de verdad desde la página: "Borrar" solo
--      marca borrado = true. Se recupera con el UPDATE del final.
--   2. Cada alta y cada cambio queda en guia_modelos_historial
--      (antes / después). La página pública NO puede leerlo ni tocarlo.
-- ============================================================

create table if not exists public.guia_modelos (
  id          uuid primary key default gen_random_uuid(),
  codigo      text,
  nombre      text not null check (length(trim(nombre)) > 0),
  estado      text not null default 'Nueva'
              check (estado in ('Nueva','Cuentas disponibles','En agencia','Conectada','Pausada / caída')),
  scouter     text,
  asistente   text,
  agencia     text,
  prioridad   text not null default 'media' check (prioridad in ('alta','media','baja')),
  motivo      text,
  portafolio  date,
  notas       text,
  borrado     boolean not null default false,
  creado      timestamptz not null default now(),
  actualizado timestamptz not null default now()
);

-- Un mismo código MDL no puede estar dos veces (salvo vacías o borradas)
create unique index if not exists guia_modelos_codigo_unico
  on public.guia_modelos (codigo)
  where codigo is not null and codigo <> '' and borrado = false;

-- ---------- Historial ----------
create table if not exists public.guia_modelos_historial (
  id        bigserial primary key,
  modelo_id uuid not null,
  accion    text not null,          -- 'alta' | 'cambio' | 'borrado' | 'restaurada'
  antes     jsonb,
  despues   jsonb,
  cuando    timestamptz not null default now()
);

create or replace function public.guia_modelos_registrar()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op = 'INSERT' then
    insert into guia_modelos_historial (modelo_id, accion, despues)
    values (new.id, 'alta', to_jsonb(new));
  else
    new.actualizado := now();
    insert into guia_modelos_historial (modelo_id, accion, antes, despues)
    values (new.id,
            case when new.borrado and not old.borrado then 'borrado'
                 when old.borrado and not new.borrado then 'restaurada'
                 else 'cambio' end,
            to_jsonb(old), to_jsonb(new));
  end if;
  return new;
end;
$$;

drop trigger if exists guia_modelos_historial_trg on public.guia_modelos;
create trigger guia_modelos_historial_trg
  before insert or update on public.guia_modelos
  for each row execute function public.guia_modelos_registrar();

-- ---------- Permisos ----------
alter table public.guia_modelos           enable row level security;
alter table public.guia_modelos_historial enable row level security;

-- La página (rol anon) puede leer, agregar y editar. NO puede borrar.
drop policy if exists guia_leer    on public.guia_modelos;
drop policy if exists guia_agregar on public.guia_modelos;
drop policy if exists guia_editar  on public.guia_modelos;
create policy guia_leer    on public.guia_modelos for select to anon, authenticated using (true);
create policy guia_agregar on public.guia_modelos for insert to anon, authenticated with check (true);
create policy guia_editar  on public.guia_modelos for update to anon, authenticated using (true) with check (true);

grant select, insert, update on public.guia_modelos to anon, authenticated;
revoke delete, truncate on public.guia_modelos from anon, authenticated;
-- El historial no tiene políticas: invisible e intocable desde la página.
revoke all on public.guia_modelos_historial from anon, authenticated;
revoke all on sequence public.guia_modelos_historial_id_seq from anon, authenticated;

-- ---------- Tiempo real (que todos vean los cambios al instante) ----------
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'guia_modelos'
  ) then
    alter publication supabase_realtime add table public.guia_modelos;
  end if;
end $$;

-- ============================================================
-- CONSULTAS ÚTILES (no hace falta correrlas ahora)
-- ============================================================
-- Últimos 50 cambios:
--   select cuando, accion, despues->>'nombre' as modelo, antes, despues
--   from guia_modelos_historial order by cuando desc limit 50;
--
-- Ver las borradas:
--   select id, codigo, nombre, actualizado from guia_modelos where borrado;
--
-- Recuperar una borrada:
--   update guia_modelos set borrado = false where id = 'PEGAR-ID';
--
-- Volver una modelo a como estaba antes de un cambio (id del historial):
--   update guia_modelos g set
--     codigo=h.antes->>'codigo', nombre=h.antes->>'nombre', estado=h.antes->>'estado',
--     scouter=h.antes->>'scouter', asistente=h.antes->>'asistente', agencia=h.antes->>'agencia',
--     prioridad=h.antes->>'prioridad', motivo=h.antes->>'motivo',
--     portafolio=(h.antes->>'portafolio')::date, notas=h.antes->>'notas',
--     borrado=(h.antes->>'borrado')::boolean
--   from guia_modelos_historial h where h.id = PEGAR_ID_HISTORIAL and g.id = h.modelo_id;
