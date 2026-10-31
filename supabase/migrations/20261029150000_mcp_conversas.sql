-- =============================================================================
-- MCP (fase 4): leitura do conteúdo das conversas de WhatsApp.
--
-- Exige, além de admin, que a loja tenha ligado "Permitir que a IA leia o conteúdo
-- das conversas" (mcp_empresa_config.permite_conteudo_chat). A checagem é feita
-- aqui no banco (mcp_exigir_conteudo_chat) e também no servidor.
--
-- Direção invertida: outbound = cliente, inbound = loja.
-- SECURITY DEFINER pelo mesmo motivo da fase 3 (helper mcp__conversas_desde).
-- =============================================================================

create or replace function public.mcp_exigir_conteudo_chat()
returns uuid
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_empresa uuid := public.mcp_exigir_admin();
begin
  if not exists (
    select 1 from public.mcp_empresa_config c
    where c.empresa_id = v_empresa and c.permite_conteudo_chat
  ) then
    raise exception 'mcp: leitura de conversas não habilitada' using errcode = '42501';
  end if;
  return v_empresa;
end;
$$;

-- Texto de uma mensagem como a IA deve vê-lo (mídias viram marcadores)
create or replace function public.mcp__texto_mensagem(p_tipo text, p_conteudo text)
returns text
language sql
immutable
as $$
  select case p_tipo
    when 'text' then left(coalesce(p_conteudo, ''), 2000)
    when 'audio' then '[áudio — não transcrito]'
    when 'image' then '[imagem]' || coalesce(' ' || nullif(trim(p_conteudo), ''), '')
    when 'video' then '[vídeo]' || coalesce(' ' || nullif(trim(p_conteudo), ''), '')
    when 'document' then '[documento' || coalesce(': ' || nullif(trim(p_conteudo), ''), '') || ']'
    when 'call' then '[ligação] ' || coalesce(p_conteudo, '')
    else '[' || coalesce(p_tipo, 'mensagem') || ']' || coalesce(' ' || nullif(trim(p_conteudo), ''), '')
  end
$$;

-- -----------------------------------------------------------------------------
-- listar_conversas (métricas por conversa, sem conteúdo)
-- -----------------------------------------------------------------------------
create or replace function public.mcp_listar_conversas(
  p_inicio date,
  p_fim date,
  p_situacao text default 'todas',
  p_vendedor uuid default null,
  p_instancia uuid default null,
  p_limite integer default 50,
  p_offset integer default 0
) returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_empresa uuid := public.mcp_exigir_conteudo_chat();
  v_periodo tstzrange := public.mcp_periodo(p_inicio, p_fim);
  v_limite integer := least(greatest(coalesce(p_limite, 50), 1), 200);
begin
  if p_situacao not in ('todas', 'aguardando_loja', 'nunca_respondidas', 'lead_perdido',
                        'lead_vendido', 'sem_lead') then
    raise exception 'mcp: situacao deve ser todas, aguardando_loja, nunca_respondidas, lead_perdido, lead_vendido ou sem_lead'
      using errcode = '22023';
  end if;

  return (
    with base as (
      select s.*, c.lead_id, c.instance_id, c.fone,
             coalesce(c.assigned_user_id, l.responsible_uuid) as responsavel,
             l.name as lead_nome, l.phone, l.stage_id,
             case when l.status = 'venda_confirmada' and l.sold_at is not null then 'vendido'
                  when l.status = 'perdido' and l.lost_at is not null then 'perdido'
                  when l.id is not null then 'em aberto' end as status_lead,
             l.sold_at, l.lost_at
      from public.mcp__conversas_desde(v_empresa, lower(v_periodo)) s
      join public.chat_conversations c on c.id = s.conversation_id and c.empresa_id = v_empresa
      left join public.leads l on l.id = c.lead_id
      where s.primeira_em < upper(v_periodo)
        and (p_instancia is null or c.instance_id = p_instancia)
        and (p_vendedor is null or coalesce(c.assigned_user_id, l.responsible_uuid) = p_vendedor)
    ),
    filtradas as (
      select * from base
      where case p_situacao
              when 'todas' then true
              when 'aguardando_loja' then ultima_direcao = 'outbound'
              when 'nunca_respondidas' then msgs_loja = 0 and msgs_cliente > 0
              when 'lead_perdido' then lost_at <@ v_periodo and status_lead = 'perdido'
              when 'lead_vendido' then sold_at <@ v_periodo and status_lead = 'vendido'
              when 'sem_lead' then lead_id is null
            end
    )
    select jsonb_build_object(
      'total', (select count(*) from filtradas),
      'limite', v_limite,
      'offset', greatest(coalesce(p_offset, 0), 0),
      'conversas', coalesce((
        select jsonb_agg(jsonb_build_object(
          'conversa_id', f.conversation_id,
          'lead_id', f.lead_id,
          'lead', f.lead_nome,
          'telefone', coalesce(f.phone, f.fone),
          'status_lead', f.status_lead,
          'etapa', st.name,
          'responsavel', coalesce(p.full_name, 'Sem responsável'),
          'instancia', coalesce(nullif(i.display_name, ''), i.name),
          'instancia_com_ia', coalesce(i."IA", false),
          'mensagens_do_cliente', f.msgs_cliente,
          'mensagens_da_loja', f.msgs_loja,
          'ultima_mensagem_em', f.ultima_em,
          'ultima_mensagem_de', case f.ultima_direcao when 'outbound' then 'cliente' else 'loja' end
        ) order by f.ultima_em desc)
        from (
          select * from filtradas
          order by ultima_em desc
          limit v_limite offset greatest(coalesce(p_offset, 0), 0)
        ) f
        left join public.stages st on st.id = f.stage_id
        left join public.profiles p on p.uuid = f.responsavel
        left join public.whatsapp_instances i on i.id = f.instance_id
      ), '[]'::jsonb)
    )
  );
end;
$$;

-- -----------------------------------------------------------------------------
-- ler_conversa (transcrição cronológica, paginada para trás)
-- -----------------------------------------------------------------------------
create or replace function public.mcp_ler_conversa(
  p_conversa uuid,
  p_max integer default 100,
  p_antes timestamptz default null
) returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_empresa uuid := public.mcp_exigir_conteudo_chat();
  v_max integer := least(greatest(coalesce(p_max, 100), 1), 300);
  v_conv public.chat_conversations%rowtype;
begin
  select * into v_conv from public.chat_conversations c
  where c.id = p_conversa and c.empresa_id = v_empresa;

  if not found then
    return null;
  end if;

  return (
    with ultimas as (
      select m.id, m."timestamp" as ts, m.direction, m.message_type, m.content
      from public.chat_messages m
      where m.conversation_id = v_conv.id
        and m.empresa_id = v_empresa
        and (p_antes is null or m."timestamp" < p_antes)
      order by m."timestamp" desc, m.id desc
      limit v_max + 1
    ),
    pagina as (
      select * from ultimas order by ts desc, id desc limit v_max
    )
    select jsonb_build_object(
      'conversa', jsonb_build_object(
        'conversa_id', v_conv.id,
        'contato', v_conv."Nome_Whatsapp",
        'telefone', coalesce(l.phone, v_conv.fone),
        'lead_id', l.id,
        'lead', l.name,
        'status_lead', case when l.status = 'venda_confirmada' and l.sold_at is not null then 'vendido'
                            when l.status = 'perdido' and l.lost_at is not null then 'perdido'
                            when l.id is not null then 'em aberto' end,
        'etapa', st.name,
        'responsavel', p.full_name,
        'instancia', coalesce(nullif(i.display_name, ''), i.name),
        'instancia_com_ia', coalesce(i."IA", false)
      ),
      'mensagens', coalesce((
        select jsonb_agg(jsonb_build_object(
          'quando', pg.ts,
          'de', case pg.direction when 'outbound' then 'cliente' else 'loja' end,
          'texto', public.mcp__texto_mensagem(pg.message_type, pg.content)
        ) order by pg.ts, pg.id)
        from pagina pg
      ), '[]'::jsonb),
      'audios_no_trecho', (select count(*) from pagina where message_type = 'audio'),
      'mensagens_no_trecho', (select count(*) from pagina),
      'tem_mensagens_anteriores', (select count(*) from ultimas) > v_max,
      'cursor_antes', (select min(ts) from pagina)
    )
    from (select 1) um
    left join public.leads l on l.id = v_conv.lead_id
    left join public.stages st on st.id = l.stage_id
    left join public.profiles p on p.uuid = coalesce(v_conv.assigned_user_id, l.responsible_uuid)
    left join public.whatsapp_instances i on i.id = v_conv.instance_id
  );
end;
$$;

-- -----------------------------------------------------------------------------
-- amostrar_conversas (amostra aleatória para auditoria)
-- -----------------------------------------------------------------------------
create or replace function public.mcp_amostrar_conversas(
  p_inicio date,
  p_fim date,
  p_criterio text default 'qualquer',
  p_n integer default 10,
  p_vendedor uuid default null
) returns jsonb
language plpgsql
volatile  -- usa random()
security definer
set search_path = public
as $$
declare
  v_empresa uuid := public.mcp_exigir_conteudo_chat();
  v_periodo tstzrange := public.mcp_periodo(p_inicio, p_fim);
  v_n integer := least(greatest(coalesce(p_n, 10), 1), 20);
begin
  if p_criterio not in ('qualquer', 'lead_perdido', 'lead_vendido', 'aguardando_loja',
                        'nunca_respondidas') then
    raise exception 'mcp: criterio deve ser qualquer, lead_perdido, lead_vendido, aguardando_loja ou nunca_respondidas'
      using errcode = '22023';
  end if;

  return (
    with base as (
      select s.*, c.lead_id, l.name as lead_nome,
             coalesce(c.assigned_user_id, l.responsible_uuid) as responsavel,
             l.status, l.sold_at, l.lost_at
      from public.mcp__conversas_desde(v_empresa, lower(v_periodo)) s
      join public.chat_conversations c on c.id = s.conversation_id and c.empresa_id = v_empresa
      left join public.leads l on l.id = c.lead_id
      where s.primeira_em < upper(v_periodo)
        and s.msgs_cliente > 0
        and (p_vendedor is null or coalesce(c.assigned_user_id, l.responsible_uuid) = p_vendedor)
    ),
    candidatas as (
      select * from base
      where case p_criterio
              -- "qualquer": só conversas com troca real (para auditoria fazer sentido)
              when 'qualquer' then msgs_loja > 0 and msgs_cliente + msgs_loja >= 4
              when 'lead_perdido' then status = 'perdido' and lost_at <@ v_periodo
              when 'lead_vendido' then status = 'venda_confirmada' and sold_at <@ v_periodo
              when 'aguardando_loja' then ultima_direcao = 'outbound'
              when 'nunca_respondidas' then msgs_loja = 0
            end
    )
    select jsonb_build_object(
      'criterio', p_criterio,
      'total_candidatas', (select count(*) from candidatas),
      'amostra', coalesce((
        select jsonb_agg(jsonb_build_object(
          'conversa_id', a.conversation_id,
          'lead_id', a.lead_id,
          'lead', a.lead_nome,
          'responsavel', coalesce(p.full_name, 'Sem responsável'),
          'mensagens_do_cliente', a.msgs_cliente,
          'mensagens_da_loja', a.msgs_loja,
          'ultima_mensagem_em', a.ultima_em
        ))
        from (select * from candidatas order by random() limit v_n) a
        left join public.profiles p on p.uuid = a.responsavel
      ), '[]'::jsonb)
    )
  );
end;
$$;

-- -----------------------------------------------------------------------------
-- Permissões
-- -----------------------------------------------------------------------------
revoke all on function public.mcp__texto_mensagem(text, text) from public, anon, authenticated;

do $$
declare
  f text;
begin
  foreach f in array array[
    'public.mcp_exigir_conteudo_chat()',
    'public.mcp_listar_conversas(date, date, text, uuid, uuid, integer, integer)',
    'public.mcp_ler_conversa(uuid, integer, timestamptz)',
    'public.mcp_amostrar_conversas(date, date, text, integer, uuid)'
  ] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end;
$$;
