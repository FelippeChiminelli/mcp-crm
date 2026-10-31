-- =============================================================================
-- MCP (fase 2): ferramentas comerciais (funil, origens, vendedores, perdas,
-- leads parados, busca de lead, tarefas, estoque e vendas).
--
-- Mesmas regras da fase 1: SECURITY INVOKER, empresa vinda de mcp_exigir_admin(),
-- filtro explícito por empresa_id e períodos em America/Sao_Paulo.
--
-- Definições (iguais às telas de Analytics do CRM):
--   venda  = status 'venda_confirmada' e sold_at no período
--   perda  = status 'perdido' e lost_at no período
--   aberto = sold_at is null and lost_at is null (mesmo filtro dos índices parciais)
--   origem = lower(trim(coalesce(origin, 'Não informado')))
--   investimento por origem = proporcional aos dias de sobreposição com o período
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Período: valida e converte datas (inclusivas) para timestamptz em São Paulo
-- -----------------------------------------------------------------------------
create or replace function public.mcp_periodo(p_inicio date, p_fim date)
returns tstzrange
language plpgsql
stable
set search_path = public
as $$
begin
  if p_inicio is null or p_fim is null then
    raise exception 'mcp: período obrigatório' using errcode = '22023';
  end if;
  if p_fim < p_inicio then
    raise exception 'mcp: data final anterior à inicial' using errcode = '22023';
  end if;
  if p_fim - p_inicio > 92 then
    raise exception 'mcp: período máximo é de 93 dias' using errcode = '22023';
  end if;
  return tstzrange(
    p_inicio::timestamp at time zone 'America/Sao_Paulo',
    (p_fim + 1)::timestamp at time zone 'America/Sao_Paulo',
    '[)'
  );
end;
$$;

create or replace function public.mcp_origem_chave(p_origem text)
returns text
language sql
immutable
as $$
  select lower(trim(coalesce(nullif(trim(p_origem), ''), 'Não informado')))
$$;

-- -----------------------------------------------------------------------------
-- resumo_funil
-- -----------------------------------------------------------------------------
create or replace function public.mcp_resumo_funil(
  p_inicio date,
  p_fim date,
  p_pipeline uuid default null
) returns jsonb
language plpgsql
stable
security invoker
set search_path = public
as $$
declare
  v_empresa uuid := public.mcp_exigir_admin();
  v_periodo tstzrange := public.mcp_periodo(p_inicio, p_fim);
  v_novos bigint;
  v_vendas bigint;
  v_valor_vendas numeric;
  v_perdas bigint;
  v_vendas_baixo_valor bigint;
begin
  select count(*) into v_novos
  from public.leads l
  where l.empresa_id = v_empresa
    and l.created_at <@ v_periodo
    and (p_pipeline is null or l.pipeline_id = p_pipeline);

  select count(*), coalesce(sum(coalesce(l.sold_value, l.value)), 0),
         count(*) filter (where coalesce(l.sold_value, l.value, 0) < 1000)
    into v_vendas, v_valor_vendas, v_vendas_baixo_valor
  from public.leads l
  where l.empresa_id = v_empresa
    and l.status = 'venda_confirmada'
    and l.sold_at <@ v_periodo
    and (p_pipeline is null or l.pipeline_id = p_pipeline);

  select count(*) into v_perdas
  from public.leads l
  where l.empresa_id = v_empresa
    and l.status = 'perdido'
    and l.lost_at <@ v_periodo
    and (p_pipeline is null or l.pipeline_id = p_pipeline);

  return jsonb_build_object(
    'periodo', jsonb_build_object('inicio', p_inicio, 'fim', p_fim),
    'novos_leads', v_novos,
    'vendas', v_vendas,
    'valor_vendido', v_valor_vendas,
    'ticket_medio', case when v_vendas > 0 then round(v_valor_vendas / v_vendas, 2) end,
    -- Vendas registradas com valor simbólico (ex.: R$ 1) distorcem valor e ticket
    'vendas_com_valor_abaixo_de_1000', v_vendas_baixo_valor,
    'perdas', v_perdas,
    'taxa_conversao_pct', case when v_novos > 0 then round(100.0 * v_vendas / v_novos, 2) end,
    'observacao_conversao',
      'vendas fechadas no período / leads criados no período (coortes diferentes)',
    -- Retrato de agora (não depende do período): leads em aberto por etapa
    'em_aberto_por_etapa', coalesce((
      select jsonb_agg(x order by x->>'pipeline', (x->>'posicao')::int)
      from (
        select jsonb_build_object(
          'pipeline', pl.name,
          'pipeline_id', pl.id,
          'etapa', s.name,
          'etapa_id', s.id,
          'posicao', s.position,
          'leads', count(l.id),
          'valor', coalesce(sum(l.value), 0),
          'dias_medios_na_etapa', round(avg(extract(epoch from now() - l.current_stage_since) / 86400)::numeric, 1),
          'parados_mais_de_7_dias', count(l.id) filter (where l.current_stage_since < now() - interval '7 days')
        ) as x
        from public.stages s
        join public.pipelines pl on pl.id = s.pipeline_id and pl.empresa_id = v_empresa
        left join public.leads l
          on l.stage_id = s.id
         and l.empresa_id = v_empresa
         and l.sold_at is null and l.lost_at is null
        where s.empresa_id = v_empresa
          and coalesce(pl.active, true)
          and (p_pipeline is null or pl.id = p_pipeline)
        group by pl.id, pl.name, s.id, s.name, s.position
      ) t
    ), '[]'::jsonb)
  );
end;
$$;

-- -----------------------------------------------------------------------------
-- leads_por_origem
-- -----------------------------------------------------------------------------
create or replace function public.mcp_leads_por_origem(
  p_inicio date,
  p_fim date,
  p_pipeline uuid default null
) returns jsonb
language plpgsql
stable
security invoker
set search_path = public
as $$
declare
  v_empresa uuid := public.mcp_exigir_admin();
  v_periodo tstzrange := public.mcp_periodo(p_inicio, p_fim);
begin
  return coalesce((
    with leads_periodo as (
      select public.mcp_origem_chave(l.origin) as chave, l.origin
      from public.leads l
      where l.empresa_id = v_empresa
        and l.created_at <@ v_periodo
        and (p_pipeline is null or l.pipeline_id = p_pipeline)
    ),
    vendas as (
      select public.mcp_origem_chave(l.origin) as chave, l.origin,
             coalesce(l.sold_value, l.value, 0) as valor
      from public.leads l
      where l.empresa_id = v_empresa
        and l.status = 'venda_confirmada'
        and l.sold_at <@ v_periodo
        and (p_pipeline is null or l.pipeline_id = p_pipeline)
    ),
    perdas as (
      select public.mcp_origem_chave(l.origin) as chave, l.origin
      from public.leads l
      where l.empresa_id = v_empresa
        and l.status = 'perdido'
        and l.lost_at <@ v_periodo
        and (p_pipeline is null or l.pipeline_id = p_pipeline)
    ),
    investimentos as (
      select public.mcp_origem_chave(i.origin) as chave, i.origin,
             i.value::numeric
               * (least(i.end_date, p_fim) - greatest(i.start_date, p_inicio) + 1)
               / greatest(i.end_date - i.start_date + 1, 1) as valor
      from public.origin_investments i
      where i.empresa_id = v_empresa
        and i.start_date <= p_fim
        and i.end_date >= p_inicio
    ),
    chaves as (
      select chave, origin from leads_periodo
      union all select chave, origin from vendas
      union all select chave, origin from perdas
      union all select chave, origin from investimentos
    ),
    nomes as (
      select chave, coalesce(max(nullif(trim(origin), '')), 'Não informado') as nome
      from chaves group by chave
    ),
    linhas as (
      select n.nome,
             (select count(*) from leads_periodo x where x.chave = n.chave) as leads,
             (select count(*) from vendas x where x.chave = n.chave) as vendas,
             (select coalesce(sum(x.valor), 0) from vendas x where x.chave = n.chave) as valor_vendido,
             (select count(*) from perdas x where x.chave = n.chave) as perdas,
             (select round(sum(x.valor), 2) from investimentos x where x.chave = n.chave) as investimento
      from nomes n
    )
    select jsonb_agg(jsonb_build_object(
      'origem', nome,
      'leads', leads,
      'vendas', vendas,
      'valor_vendido', valor_vendido,
      'perdas', perdas,
      'taxa_conversao_pct', case when leads > 0 then round(100.0 * vendas / leads, 2) end,
      'investimento', investimento,
      'custo_por_lead', case when investimento is not null and leads > 0 then round(investimento / leads, 2) end,
      'custo_por_venda', case when investimento is not null and vendas > 0 then round(investimento / vendas, 2) end
    ) order by leads desc, vendas desc)
    from linhas
  ), '[]'::jsonb);
end;
$$;

-- -----------------------------------------------------------------------------
-- desempenho_vendedores
-- -----------------------------------------------------------------------------
create or replace function public.mcp_desempenho_vendedores(
  p_inicio date,
  p_fim date,
  p_pipeline uuid default null
) returns jsonb
language plpgsql
stable
security invoker
set search_path = public
as $$
declare
  v_empresa uuid := public.mcp_exigir_admin();
  v_periodo tstzrange := public.mcp_periodo(p_inicio, p_fim);
begin
  return coalesce((
    with base as (
      select l.responsible_uuid as vendedor,
             count(*) filter (where l.created_at <@ v_periodo) as leads_recebidos,
             count(*) filter (where l.status = 'venda_confirmada' and l.sold_at <@ v_periodo) as vendas,
             coalesce(sum(coalesce(l.sold_value, l.value, 0))
               filter (where l.status = 'venda_confirmada' and l.sold_at <@ v_periodo), 0) as valor_vendido,
             count(*) filter (where l.status = 'perdido' and l.lost_at <@ v_periodo) as perdas,
             count(*) filter (where l.sold_at is null and l.lost_at is null) as em_aberto_agora,
             count(*) filter (where l.sold_at is null and l.lost_at is null
                                and l.current_stage_since < now() - interval '7 days') as parados_7_dias
      from public.leads l
      where l.empresa_id = v_empresa
        and (p_pipeline is null or l.pipeline_id = p_pipeline)
        and (l.created_at <@ v_periodo
             or l.sold_at <@ v_periodo
             or l.lost_at <@ v_periodo
             or (l.sold_at is null and l.lost_at is null))
      group by l.responsible_uuid
    ),
    tarefas as (
      select t.assigned_to as vendedor,
             count(*) filter (where coalesce(t.status, '') <> 'concluida' and t.due_date < now()) as tarefas_atrasadas
      from public.tasks t
      where t.empresa_id = v_empresa
      group by t.assigned_to
    )
    select jsonb_agg(jsonb_build_object(
      'vendedor_id', b.vendedor,
      'vendedor', case when b.vendedor is null then 'Sem responsável'
                       else coalesce(nullif(trim(p.full_name), ''), 'Usuário removido') end,
      'leads_recebidos', b.leads_recebidos,
      'vendas', b.vendas,
      'valor_vendido', b.valor_vendido,
      'taxa_conversao_pct', case when b.leads_recebidos > 0 then round(100.0 * b.vendas / b.leads_recebidos, 2) end,
      'perdas', b.perdas,
      'em_aberto_agora', b.em_aberto_agora,
      'parados_mais_de_7_dias', b.parados_7_dias,
      'tarefas_atrasadas', coalesce(tf.tarefas_atrasadas, 0)
    ) order by b.vendas desc, b.leads_recebidos desc)
    from base b
    left join public.profiles p on p.uuid = b.vendedor and p.empresa_id = v_empresa
    left join tarefas tf on tf.vendedor is not distinct from b.vendedor
  ), '[]'::jsonb);
end;
$$;

-- -----------------------------------------------------------------------------
-- motivos_perda
-- -----------------------------------------------------------------------------
create or replace function public.mcp_motivos_perda(
  p_inicio date,
  p_fim date,
  p_pipeline uuid default null,
  p_vendedor uuid default null
) returns jsonb
language plpgsql
stable
security invoker
set search_path = public
as $$
declare
  v_empresa uuid := public.mcp_exigir_admin();
  v_periodo tstzrange := public.mcp_periodo(p_inicio, p_fim);
begin
  return coalesce((
    with perdas as (
      select coalesce(lr.name, nullif(trim(l.loss_reason_category), ''), 'Sem motivo') as motivo,
             nullif(trim(l.loss_reason_notes), '') as nota
      from public.leads l
      left join public.loss_reasons lr
        on lr.id::text = l.loss_reason_category and lr.empresa_id = v_empresa
      where l.empresa_id = v_empresa
        and l.status = 'perdido'
        and l.lost_at <@ v_periodo
        and (p_pipeline is null or l.pipeline_id = p_pipeline)
        and (p_vendedor is null or l.responsible_uuid = p_vendedor)
    ),
    total as (select count(*) as n from perdas)
    select jsonb_agg(jsonb_build_object(
      'motivo', g.motivo,
      'perdas', g.n,
      'percentual', round(100.0 * g.n / nullif(t.n, 0), 1),
      'exemplos_de_observacao', g.exemplos
    ) order by g.n desc)
    from (
      select motivo, count(*) as n,
             (array_agg(left(nota, 200)) filter (where nota is not null))[1:3] as exemplos
      from perdas
      group by motivo
    ) g
    cross join total t
  ), '[]'::jsonb);
end;
$$;

-- -----------------------------------------------------------------------------
-- leads_parados (há mais de N dias na mesma etapa, em aberto)
-- -----------------------------------------------------------------------------
create or replace function public.mcp_leads_parados(
  p_dias integer default 7,
  p_pipeline uuid default null,
  p_etapa uuid default null,
  p_vendedor uuid default null,
  p_limite integer default 50,
  p_offset integer default 0
) returns jsonb
language plpgsql
stable
security invoker
set search_path = public
as $$
declare
  v_empresa uuid := public.mcp_exigir_admin();
  v_limite integer := least(greatest(coalesce(p_limite, 50), 1), 200);
  v_corte timestamptz;
begin
  if p_dias is null or p_dias < 1 then
    raise exception 'mcp: p_dias deve ser >= 1' using errcode = '22023';
  end if;
  v_corte := now() - make_interval(days => p_dias);

  return (
    with parados as (
      select l.id, l.name, l.phone, l.origin, l.value, l.last_contact_at,
             l.current_stage_since, l.responsible_uuid, l.pipeline_id, l.stage_id
      from public.leads l
      where l.empresa_id = v_empresa
        and l.sold_at is null and l.lost_at is null
        and l.pipeline_id is not null
        and l.current_stage_since < v_corte
        and (p_pipeline is null or l.pipeline_id = p_pipeline)
        and (p_etapa is null or l.stage_id = p_etapa)
        and (p_vendedor is null or l.responsible_uuid = p_vendedor)
    )
    select jsonb_build_object(
      'total', (select count(*) from parados),
      'limite', v_limite,
      'offset', greatest(coalesce(p_offset, 0), 0),
      'leads', coalesce(jsonb_agg(jsonb_build_object(
        'lead_id', x.id,
        'nome', coalesce(nullif(trim(x.name), ''), 'Sem nome'),
        'telefone', x.phone,
        'origem', x.origin,
        'valor', x.value,
        'pipeline', pl.name,
        'etapa', s.name,
        'responsavel', coalesce(p.full_name, 'Sem responsável'),
        'dias_na_etapa', floor(extract(epoch from now() - x.current_stage_since) / 86400)::int,
        'ultimo_contato', x.last_contact_at
      ) order by x.current_stage_since), '[]'::jsonb)
    )
    from (
      select * from parados
      order by current_stage_since, id
      limit v_limite offset greatest(coalesce(p_offset, 0), 0)
    ) x
    left join public.pipelines pl on pl.id = x.pipeline_id
    left join public.stages s on s.id = x.stage_id
    left join public.profiles p on p.uuid = x.responsible_uuid
  );
end;
$$;

-- -----------------------------------------------------------------------------
-- buscar_lead (por nome ou telefone; até 10 resultados)
-- -----------------------------------------------------------------------------
create or replace function public.mcp_buscar_lead(p_termo text)
returns jsonb
language plpgsql
stable
security invoker
set search_path = public
as $$
declare
  v_empresa uuid := public.mcp_exigir_admin();
  v_termo text := trim(coalesce(p_termo, ''));
  v_digitos text := regexp_replace(coalesce(p_termo, ''), '\D', '', 'g');
begin
  if length(v_termo) < 3 then
    raise exception 'mcp: informe ao menos 3 caracteres' using errcode = '22023';
  end if;

  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'lead_id', l.id,
      'nome', coalesce(nullif(trim(l.name), ''), 'Sem nome'),
      'telefone', l.phone,
      'pipeline', pl.name,
      'etapa', s.name,
      'status', case when l.sold_at is not null then 'vendido'
                     when l.lost_at is not null then 'perdido'
                     else 'em aberto' end,
      'responsavel', p.full_name,
      'criado_em', l.created_at
    ) order by l.created_at desc)
    from (
      select * from public.leads l
      where l.empresa_id = v_empresa
        and (l.name ilike '%' || v_termo || '%'
             or (length(v_digitos) >= 8 and l.phone like '%' || v_digitos || '%'))
      order by l.created_at desc
      limit 10
    ) l
    left join public.pipelines pl on pl.id = l.pipeline_id
    left join public.stages s on s.id = l.stage_id
    left join public.profiles p on p.uuid = l.responsible_uuid
  ), '[]'::jsonb);
end;
$$;

-- -----------------------------------------------------------------------------
-- detalhar_lead (ficha completa de um lead)
-- -----------------------------------------------------------------------------
create or replace function public.mcp_detalhar_lead(p_lead_id uuid)
returns jsonb
language plpgsql
stable
security invoker
set search_path = public
as $$
declare
  v_empresa uuid := public.mcp_exigir_admin();
  v_lead public.leads%rowtype;
begin
  select * into v_lead from public.leads l
  where l.id = p_lead_id and l.empresa_id = v_empresa;

  if not found then
    return null;
  end if;

  return jsonb_build_object(
    'lead', jsonb_build_object(
      'lead_id', v_lead.id,
      'nome', v_lead.name,
      'telefone', v_lead.phone,
      'email', v_lead.email,
      'origem', v_lead.origin,
      'valor', v_lead.value,
      'temperatura', v_lead.status,
      'tags', v_lead.tags,
      'observacoes', left(v_lead.notes, 1000),
      'pipeline', (select name from public.pipelines where id = v_lead.pipeline_id),
      'etapa', (select name from public.stages where id = v_lead.stage_id),
      'na_etapa_desde', v_lead.current_stage_since,
      'responsavel', (select full_name from public.profiles where uuid = v_lead.responsible_uuid),
      'criado_em', v_lead.created_at,
      'ultimo_contato', v_lead.last_contact_at,
      'vendido_em', v_lead.sold_at,
      'valor_venda', v_lead.sold_value,
      'perdido_em', v_lead.lost_at,
      'motivo_perda', coalesce(
        (select name from public.loss_reasons where id::text = v_lead.loss_reason_category),
        v_lead.loss_reason_category),
      'observacao_perda', left(v_lead.loss_reason_notes, 500)
    ),
    'historico_etapas', coalesce((
      select jsonb_agg(jsonb_build_object(
        'quando', h.changed_at,
        'tipo', h.change_type,
        'etapa_anterior', sp.name,
        'etapa', s.name,
        'por', p.full_name,
        'nota', left(h.notes, 200)
      ) order by h.changed_at desc)
      from (
        select * from public.lead_pipeline_history h
        where h.empresa_id = v_empresa and h.lead_id = v_lead.id
        order by h.changed_at desc limit 20
      ) h
      left join public.stages s on s.id = h.stage_id
      left join public.stages sp on sp.id = h.previous_stage_id
      left join public.profiles p on p.uuid = h.changed_by
    ), '[]'::jsonb),
    'interacoes', coalesce((
      select jsonb_agg(jsonb_build_object(
        'quando', i.created_at, 'autor', i.author_name, 'descricao', left(i.description, 300)
      ) order by i.created_at desc)
      from (
        select * from public.lead_interactions i
        where i.empresa_id = v_empresa and i.lead_id = v_lead.id
        order by i.created_at desc limit 10
      ) i
    ), '[]'::jsonb),
    'tarefas', coalesce((
      select jsonb_agg(jsonb_build_object(
        'titulo', t.title, 'status', t.status, 'prazo', t.due_date,
        'concluida_em', t.completed_at, 'responsavel', p.full_name
      ) order by t.due_date desc nulls last)
      from (
        select * from public.tasks t
        where t.empresa_id = v_empresa and t.lead_id = v_lead.id
        order by t.due_date desc nulls last limit 10
      ) t
      left join public.profiles p on p.uuid = t.assigned_to
    ), '[]'::jsonb),
    -- Direção invertida no banco: outbound = cliente, inbound = loja
    -- last_message_at/message_count não são mantidos: calcula pelas mensagens
    'conversas', coalesce((
      select jsonb_agg(jsonb_build_object(
        'conversa_id', c.id,
        'instancia', c.nome_instancia,
        'responsavel', p.full_name,
        'mensagens_do_cliente', st.cliente,
        'mensagens_da_loja', st.loja,
        'ultima_mensagem_em', st.ultima_em,
        'ultima_mensagem_de', case st.ultima_direcao when 'outbound' then 'cliente'
                                                    when 'inbound' then 'loja' end
      ) order by st.ultima_em desc nulls last)
      from public.chat_conversations c
      left join public.profiles p on p.uuid = c.assigned_user_id
      cross join lateral (
        select count(*) filter (where m.direction = 'outbound') as cliente,
               count(*) filter (where m.direction = 'inbound') as loja,
               max(m."timestamp") as ultima_em,
               (array_agg(m.direction order by m."timestamp" desc, m.id desc))[1] as ultima_direcao
        from public.chat_messages m
        where m.conversation_id = c.id
      ) st
      where c.empresa_id = v_empresa and c.lead_id = v_lead.id
    ), '[]'::jsonb)
  );
end;
$$;

-- -----------------------------------------------------------------------------
-- tarefas
-- -----------------------------------------------------------------------------
create or replace function public.mcp_tarefas(
  p_inicio date,
  p_fim date,
  p_vendedor uuid default null,
  p_situacao text default 'atrasadas',
  p_limite integer default 50
) returns jsonb
language plpgsql
stable
security invoker
set search_path = public
as $$
declare
  v_empresa uuid := public.mcp_exigir_admin();
  v_periodo tstzrange := public.mcp_periodo(p_inicio, p_fim);
  v_limite integer := least(greatest(coalesce(p_limite, 50), 1), 200);
begin
  if p_situacao not in ('atrasadas', 'pendentes', 'concluidas') then
    raise exception 'mcp: situacao deve ser atrasadas, pendentes ou concluidas' using errcode = '22023';
  end if;

  return (
    with t as (
      select t.*,
             coalesce(t.status, '') <> 'concluida' and t.due_date < now() as atrasada
      from public.tasks t
      where t.empresa_id = v_empresa
        and (p_vendedor is null or t.assigned_to = p_vendedor)
    )
    select jsonb_build_object(
      'resumo', (
        select jsonb_build_object(
          'atrasadas_agora', count(*) filter (where atrasada),
          'pendentes_agora', count(*) filter (where coalesce(status, '') <> 'concluida'),
          'criadas_no_periodo', count(*) filter (where created_at <@ v_periodo),
          'concluidas_no_periodo', count(*) filter (where status = 'concluida' and completed_at <@ v_periodo)
        ) from t
      ),
      'por_responsavel', coalesce((
        select jsonb_agg(jsonb_build_object(
          'responsavel', coalesce(p.full_name, 'Sem responsável'),
          'atrasadas', g.atrasadas,
          'pendentes', g.pendentes,
          'concluidas_no_periodo', g.concluidas
        ) order by g.atrasadas desc)
        from (
          select assigned_to,
                 count(*) filter (where atrasada) as atrasadas,
                 count(*) filter (where coalesce(status, '') <> 'concluida') as pendentes,
                 count(*) filter (where status = 'concluida' and completed_at <@ v_periodo) as concluidas
          from t group by assigned_to
        ) g
        left join public.profiles p on p.uuid = g.assigned_to
      ), '[]'::jsonb),
      'lista', coalesce((
        select jsonb_agg(jsonb_build_object(
          'titulo', x.title,
          'status', x.status,
          'prioridade', x.priority,
          'prazo', x.due_date,
          'concluida_em', x.completed_at,
          'responsavel', p.full_name,
          'lead_id', x.lead_id,
          'lead', l.name
        ))
        from (
          select * from t
          where (p_situacao = 'atrasadas' and atrasada)
             or (p_situacao = 'pendentes' and coalesce(status, '') <> 'concluida')
             or (p_situacao = 'concluidas' and status = 'concluida' and completed_at <@ v_periodo)
          order by case when p_situacao = 'concluidas' then completed_at end desc,
                   due_date nulls last
          limit v_limite
        ) x
        left join public.profiles p on p.uuid = x.assigned_to
        left join public.leads l on l.id = x.lead_id
      ), '[]'::jsonb)
    )
  );
end;
$$;

-- -----------------------------------------------------------------------------
-- estoque_veiculos
-- -----------------------------------------------------------------------------
create or replace function public.mcp_estoque_veiculos(
  p_status text default 'disponivel',
  p_marca text default null,
  p_dias_min integer default null,
  p_limite integer default 50
) returns jsonb
language plpgsql
stable
security invoker
set search_path = public
as $$
declare
  v_empresa uuid := public.mcp_exigir_admin();
  v_limite integer := least(greatest(coalesce(p_limite, 50), 1), 200);
  v_data_confiavel boolean;
begin
  -- Integrações de estoque costumam recriar os veículos a cada sincronização;
  -- nesse caso created_at não representa a entrada do carro na loja.
  select coalesce(min(created_at) < now() - interval '2 days', false)
    into v_data_confiavel
  from public.vehicles where empresa_id = v_empresa;

  return (
    with v as (
      select v.*,
             floor(extract(epoch from now() - v.created_at) / 86400)::int as dias_em_estoque,
             coalesce(nullif(v.promotion_price, 0), v.price_veiculo) as preco_atual
      from public.vehicles v
      where v.empresa_id = v_empresa
        and (p_status is null or v.status_veiculo = p_status)
        and (p_marca is null or v.marca_veiculo ilike p_marca)
        and (p_dias_min is null or v.created_at < now() - make_interval(days => p_dias_min))
    )
    select jsonb_build_object(
      'total', (select count(*) from v),
      'por_status', (
        select coalesce(jsonb_object_agg(coalesce(status_veiculo, 'sem status'), n), '{}'::jsonb)
        from (select status_veiculo, count(*) n from public.vehicles
              where empresa_id = v_empresa group by 1) s
      ),
      'precos', (
        select jsonb_build_object(
          'minimo', min(preco_atual),
          'mediana', percentile_cont(0.5) within group (order by preco_atual),
          'maximo', max(preco_atual),
          'soma', sum(preco_atual)
        ) from v
      ),
      'data_de_entrada_confiavel', v_data_confiavel,
      'dias_em_estoque', (
        select jsonb_build_object(
          'media', round(avg(dias_em_estoque), 1),
          'acima_de_60', count(*) filter (where dias_em_estoque > 60),
          'acima_de_90', count(*) filter (where dias_em_estoque > 90)
        ) from v
      ),
      'por_marca', coalesce((
        select jsonb_agg(jsonb_build_object('marca', marca, 'quantidade', n) order by n desc)
        from (select coalesce(marca_veiculo, 'Não informada') marca, count(*) n
              from v group by 1 order by 2 desc limit 15) m
      ), '[]'::jsonb),
      'veiculos', coalesce((
        select jsonb_agg(jsonb_build_object(
          'veiculo_id', x.id,
          'titulo', coalesce(x.titulo_veiculo, concat_ws(' ', x.marca_veiculo, x.modelo_veiculo)),
          'marca', x.marca_veiculo,
          'modelo', x.modelo_veiculo,
          'ano', x.ano_veiculo,
          'km', x.quilometragem_veiculo,
          'cambio', x.cambio_veiculo,
          'combustivel', x.combustivel_veiculo,
          'preco', x.price_veiculo,
          'preco_promocional', nullif(x.promotion_price, 0),
          'status', x.status_veiculo,
          'dias_em_estoque', x.dias_em_estoque
        ) order by x.dias_em_estoque desc)
        from (select * from v order by dias_em_estoque desc limit v_limite) x
      ), '[]'::jsonb)
    )
  );
end;
$$;

-- -----------------------------------------------------------------------------
-- vendas_periodo
-- -----------------------------------------------------------------------------
create or replace function public.mcp_vendas_periodo(
  p_inicio date,
  p_fim date,
  p_agrupar text default 'semana',
  p_pipeline uuid default null
) returns jsonb
language plpgsql
stable
security invoker
set search_path = public
as $$
declare
  v_empresa uuid := public.mcp_exigir_admin();
  v_periodo tstzrange := public.mcp_periodo(p_inicio, p_fim);
begin
  if p_agrupar not in ('dia', 'semana', 'mes', 'vendedor', 'origem', 'pipeline') then
    raise exception 'mcp: agrupar deve ser dia, semana, mes, vendedor, origem ou pipeline'
      using errcode = '22023';
  end if;

  return jsonb_build_object(
    'agrupado_por', p_agrupar,
    'vendas_com_valor_abaixo_de_1000', (
      select count(*) from public.leads l
      where l.empresa_id = v_empresa
        and l.status = 'venda_confirmada'
        and l.sold_at <@ v_periodo
        and (p_pipeline is null or l.pipeline_id = p_pipeline)
        and coalesce(l.sold_value, l.value, 0) < 1000
    ),
    'series', coalesce((
      select jsonb_agg(jsonb_build_object('grupo', grupo, 'vendas', n, 'valor', valor)
                       order by ordem, grupo)
      from (
        select
          case p_agrupar
            when 'dia' then to_char(l.sold_at at time zone 'America/Sao_Paulo', 'YYYY-MM-DD')
            when 'semana' then to_char(date_trunc('week', l.sold_at at time zone 'America/Sao_Paulo'), 'YYYY-MM-DD')
            when 'mes' then to_char(l.sold_at at time zone 'America/Sao_Paulo', 'YYYY-MM')
            when 'vendedor' then coalesce(p.full_name, 'Sem responsável')
            when 'origem' then coalesce(nullif(trim(l.origin), ''), 'Não informado')
            when 'pipeline' then coalesce(pl.name, 'Sem pipeline')
          end as grupo,
          case when p_agrupar in ('vendedor', 'origem', 'pipeline') then -count(*) else 0 end as ordem,
          count(*) as n,
          coalesce(sum(coalesce(l.sold_value, l.value, 0)), 0) as valor
        from public.leads l
        left join public.profiles p on p.uuid = l.responsible_uuid
        left join public.pipelines pl on pl.id = l.pipeline_id
        where l.empresa_id = v_empresa
          and l.status = 'venda_confirmada'
          and l.sold_at <@ v_periodo
          and (p_pipeline is null or l.pipeline_id = p_pipeline)
        group by 1
      ) g
    ), '[]'::jsonb),
    -- Itens/produtos registrados nas vendas (product_sales), quando a loja usa
    'produtos_mais_vendidos', coalesce((
      select jsonb_agg(jsonb_build_object('produto', nome, 'quantidade', qtd, 'valor', valor)
                       order by valor desc)
      from (
        select coalesce(pr.nome, 'Produto removido') as nome,
               sum(ps.quantidade_vendida) as qtd,
               sum(ps.sold_value) as valor
        from public.product_sales ps
        left join public.products pr on pr.id = ps.product_id
        where ps.empresa_id = v_empresa
          and ps.sold_at <@ v_periodo
        group by 1
        order by 3 desc nulls last
        limit 10
      ) x
    ), '[]'::jsonb)
  );
end;
$$;

-- -----------------------------------------------------------------------------
-- Permissões
-- -----------------------------------------------------------------------------
do $$
declare
  f text;
begin
  foreach f in array array[
    'public.mcp_periodo(date, date)',
    'public.mcp_origem_chave(text)',
    'public.mcp_resumo_funil(date, date, uuid)',
    'public.mcp_leads_por_origem(date, date, uuid)',
    'public.mcp_desempenho_vendedores(date, date, uuid)',
    'public.mcp_motivos_perda(date, date, uuid, uuid)',
    'public.mcp_leads_parados(integer, uuid, uuid, uuid, integer, integer)',
    'public.mcp_buscar_lead(text)',
    'public.mcp_detalhar_lead(uuid)',
    'public.mcp_tarefas(date, date, uuid, text, integer)',
    'public.mcp_estoque_veiculos(text, text, integer, integer)',
    'public.mcp_vendas_periodo(date, date, text, uuid)'
  ] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end;
$$;
