-- =============================================================================
-- MCP (fase 1): configuração por loja, auditoria, guarda de acesso e info_loja.
--
-- O servidor crm-mcp chama estas funções via PostgREST com o JWT do PRÓPRIO
-- usuário (nunca service_role). Regras:
--   * empresa_id sempre vem do profile de auth.uid(), nunca de parâmetro;
--   * toda função de dados começa com mcp_exigir_admin();
--   * timeout: o role authenticated já tem statement_timeout = 8s.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Configuração por loja (gerenciada pelo admin na tela "Assistentes de IA")
-- -----------------------------------------------------------------------------
create table if not exists public.mcp_empresa_config (
  empresa_id uuid primary key references public.empresas(id) on delete cascade,
  habilitado boolean not null default false,
  permite_conteudo_chat boolean not null default false,
  updated_by uuid references public.profiles(uuid),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint mcp_conteudo_exige_habilitado
    check (not permite_conteudo_chat or habilitado)
);

alter table public.mcp_empresa_config enable row level security;

drop policy if exists mcp_config_select on public.mcp_empresa_config;
create policy mcp_config_select on public.mcp_empresa_config
  for select to authenticated
  using (empresa_id = (select p.empresa_id from public.profiles p where p.uuid = auth.uid()));

drop policy if exists mcp_config_insert on public.mcp_empresa_config;
create policy mcp_config_insert on public.mcp_empresa_config
  for insert to authenticated
  with check (public.is_admin_company(empresa_id));

drop policy if exists mcp_config_update on public.mcp_empresa_config;
create policy mcp_config_update on public.mcp_empresa_config
  for update to authenticated
  using (public.is_admin_company(empresa_id))
  with check (public.is_admin_company(empresa_id));

-- -----------------------------------------------------------------------------
-- Auditoria: só gravada/lida por funções SECURITY DEFINER (sem policies)
-- -----------------------------------------------------------------------------
create table if not exists public.mcp_audit_log (
  id bigint generated always as identity primary key,
  empresa_id uuid not null,
  user_id uuid not null,
  ferramenta text not null,
  parametros jsonb,
  linhas integer,
  duracao_ms integer,
  erro text,
  created_at timestamptz not null default now()
);

alter table public.mcp_audit_log enable row level security;

create index if not exists idx_mcp_audit_empresa_created
  on public.mcp_audit_log (empresa_id, created_at desc);

-- -----------------------------------------------------------------------------
-- mcp_contexto: quem é o usuário e o que a loja dele permite.
-- Usado pelo middleware do servidor. Só devolve dados do próprio auth.uid().
-- -----------------------------------------------------------------------------
create or replace function public.mcp_contexto()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'user_id', p.uuid,
    'nome', p.full_name,
    'empresa_id', p.empresa_id,
    'empresa_nome', e.nome,
    'is_admin', coalesce(p.is_admin, false),
    'empresa_ativa', coalesce(e.ativo, false),
    'habilitado', coalesce(c.habilitado, false),
    'permite_conteudo_chat', coalesce(c.permite_conteudo_chat, false)
  )
  from public.profiles p
  join public.empresas e on e.id = p.empresa_id
  left join public.mcp_empresa_config c on c.empresa_id = p.empresa_id
  where p.uuid = auth.uid()
$$;

-- -----------------------------------------------------------------------------
-- mcp_exigir_admin: barreira usada no início de toda função de dados do MCP.
-- Defesa em profundidade: vale mesmo se alguém chamar a RPC direto pelo navegador.
-- -----------------------------------------------------------------------------
create or replace function public.mcp_exigir_admin()
returns uuid
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_empresa uuid;
  v_admin boolean;
  v_ativa boolean;
  v_habilitado boolean;
begin
  select p.empresa_id, coalesce(p.is_admin, false), coalesce(e.ativo, false),
         coalesce(c.habilitado, false)
    into v_empresa, v_admin, v_ativa, v_habilitado
  from public.profiles p
  join public.empresas e on e.id = p.empresa_id
  left join public.mcp_empresa_config c on c.empresa_id = p.empresa_id
  where p.uuid = auth.uid();

  if v_empresa is null or not v_admin or not v_ativa or not v_habilitado then
    raise exception 'mcp: acesso negado' using errcode = '42501';
  end if;

  return v_empresa;
end;
$$;

-- -----------------------------------------------------------------------------
-- mcp_log_call: grava uma chamada de ferramenta (usuário/empresa vêm do token)
-- -----------------------------------------------------------------------------
create or replace function public.mcp_log_call(
  p_ferramenta text,
  p_parametros jsonb default null,
  p_linhas integer default null,
  p_duracao_ms integer default null,
  p_erro text default null
) returns void
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_empresa uuid;
begin
  select p.empresa_id into v_empresa from public.profiles p where p.uuid = auth.uid();
  if v_empresa is null then
    return;
  end if;

  insert into public.mcp_audit_log
    (empresa_id, user_id, ferramenta, parametros, linhas, duracao_ms, erro)
  values (
    v_empresa,
    auth.uid(),
    left(p_ferramenta, 100),
    case when pg_column_size(p_parametros) > 4000 then jsonb_build_object('truncado', true)
         else p_parametros end,
    p_linhas,
    p_duracao_ms,
    left(p_erro, 500)
  );
end;
$$;

-- -----------------------------------------------------------------------------
-- mcp_ultimos_acessos: lista para a tela "Assistentes de IA" (só admin da loja)
-- -----------------------------------------------------------------------------
create or replace function public.mcp_ultimos_acessos(p_limite integer default 50)
returns table (
  created_at timestamptz,
  usuario text,
  ferramenta text,
  linhas integer,
  duracao_ms integer,
  erro text
)
language sql
stable
security definer
set search_path = public
as $$
  select a.created_at, p.full_name, a.ferramenta, a.linhas, a.duracao_ms, a.erro
  from public.mcp_audit_log a
  left join public.profiles p on p.uuid = a.user_id
  where public.is_admin_company(a.empresa_id)
    and a.empresa_id = (select pr.empresa_id from public.profiles pr where pr.uuid = auth.uid())
  order by a.created_at desc
  limit least(greatest(coalesce(p_limite, 50), 1), 200)
$$;

-- -----------------------------------------------------------------------------
-- mcp_info_loja: contexto da loja para a IA (pipelines, etapas, equipe, WhatsApp)
-- SECURITY INVOKER: a RLS continua valendo; o filtro por empresa é explícito.
-- -----------------------------------------------------------------------------
create or replace function public.mcp_info_loja()
returns jsonb
language plpgsql
stable
security invoker
set search_path = public
as $$
declare
  v_empresa uuid := public.mcp_exigir_admin();
begin
  return jsonb_build_object(
    'loja', (
      select jsonb_build_object('id', e.id, 'nome', e.nome, 'nicho', e.nicho)
      from public.empresas e where e.id = v_empresa
    ),
    'permissoes', (
      select jsonb_build_object(
        'conteudo_chat', coalesce(c.permite_conteudo_chat, false)
      )
      from public.mcp_empresa_config c where c.empresa_id = v_empresa
    ),
    'pipelines', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', pl.id,
        'nome', pl.name,
        'ativo', pl.active,
        'etapas', coalesce((
          select jsonb_agg(jsonb_build_object(
            'id', s.id, 'nome', s.name, 'posicao', s.position, 'inicial', s.is_inicial
          ) order by s.position)
          from public.stages s
          where s.pipeline_id = pl.id and s.empresa_id = v_empresa
        ), '[]'::jsonb)
      ) order by pl.display_order nulls last, pl.name)
      from public.pipelines pl
      where pl.empresa_id = v_empresa
    ), '[]'::jsonb),
    'equipe', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', p.uuid,
        'nome', p.full_name,
        'admin', coalesce(p.is_admin, false),
        'participa_rodizio', coalesce(p.participa_rotacao, false)
      ) order by p.full_name)
      from public.profiles p
      where p.empresa_id = v_empresa
    ), '[]'::jsonb),
    'whatsapp', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', w.id,
        'nome', coalesce(w.display_name, w.name),
        'status', w.status,
        'ia_ativa', coalesce(w."IA", false)
      ) order by coalesce(w.display_name, w.name))
      from public.whatsapp_instances w
      where w.empresa_id = v_empresa
    ), '[]'::jsonb)
  );
end;
$$;

-- -----------------------------------------------------------------------------
-- Permissões: só usuários autenticados executam as funções do MCP
-- -----------------------------------------------------------------------------
revoke all on function public.mcp_contexto() from public, anon;
revoke all on function public.mcp_exigir_admin() from public, anon;
revoke all on function public.mcp_log_call(text, jsonb, integer, integer, text) from public, anon;
revoke all on function public.mcp_ultimos_acessos(integer) from public, anon;
revoke all on function public.mcp_info_loja() from public, anon;

grant execute on function public.mcp_contexto() to authenticated;
grant execute on function public.mcp_exigir_admin() to authenticated;
grant execute on function public.mcp_log_call(text, jsonb, integer, integer, text) to authenticated;
grant execute on function public.mcp_ultimos_acessos(integer) to authenticated;
grant execute on function public.mcp_info_loja() to authenticated;

revoke all on table public.mcp_audit_log from anon, authenticated;
revoke all on table public.mcp_empresa_config from anon;
