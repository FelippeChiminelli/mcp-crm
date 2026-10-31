-- =============================================================================
-- MCP (fase 3): métricas de atendimento no WhatsApp (sem conteúdo de mensagens).
--
-- ATENÇÃO: a direção é invertida neste banco.
--   chat_messages.direction = 'outbound' -> mensagem/ligação DO CLIENTE
--   chat_messages.direction = 'inbound'  -> mensagem/ligação DA LOJA
--
-- chat_conversations.last_message_at e message_count NÃO são mantidos pelo CRM
-- (nulos/zero em todas as conversas). Tudo é calculado a partir de chat_messages,
-- varrendo idx_chat_messages_empresa_timestamp (empresa_id, timestamp) INCLUDE
-- (conversation_id, direction, id).
--
-- Responsável da conversa = chat_conversations.assigned_user_id e, se vazio, o
-- responsável do lead vinculado.
--
-- SECURITY DEFINER para reaproveitar o helper privado _chat_response_waits (o mesmo
-- da tela de tempo de resposta do CRM). A empresa vem SEMPRE de mcp_exigir_admin().
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Helper interno: situação de cada conversa com mensagens desde p_desde
-- (não exposto via API)
-- -----------------------------------------------------------------------------
create or replace function public.mcp__conversas_desde(p_empresa uuid, p_desde timestamptz)
returns table (
  conversation_id uuid,
  primeira_em timestamptz,
  ultima_em timestamptz,
  ultima_direcao text,
  ultima_loja_em timestamptz,
  primeira_cliente_pendente_em timestamptz,
  msgs_cliente bigint,
  msgs_loja bigint
)
language sql
stable
security definer
set search_path = public
as $$
  with m as (
    select m.conversation_id, m.direction, m."timestamp" as ts, m.id,
           max(m."timestamp") filter (where m.direction = 'inbound')
             over (partition by m.conversation_id) as ultima_loja
    from public.chat_messages m
    where m.empresa_id = p_empresa
      and m."timestamp" >= p_desde
  )
  select conversation_id,
         min(ts),
         max(ts),
         (array_agg(direction order by ts desc, id desc))[1],
         max(ultima_loja),
         min(ts) filter (where direction = 'outbound'
                           and ts > coalesce(ultima_loja, '-infinity'::timestamptz)),
         count(*) filter (where direction = 'outbound'),
         count(*) filter (where direction = 'inbound')
  from m
  group by conversation_id
$$;

revoke all on function public.mcp__conversas_desde(uuid, timestamptz) from public, anon, authenticated;

-- -----------------------------------------------------------------------------
-- chat_visao_geral
-- -----------------------------------------------------------------------------
create or replace function public.mcp_chat_visao_geral(
  p_inicio date,
  p_fim date,
  p_instancia uuid default null
) returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_empresa uuid := public.mcp_exigir_admin();
  v_periodo tstzrange := public.mcp_periodo(p_inicio, p_fim);
begin
  return (
    with msgs as (
      select m.conversation_id, m.direction, m.message_type
      from public.chat_messages m
      where m.empresa_id = v_empresa
        and m."timestamp" <@ v_periodo
        and (p_instancia is null or m.instance_id = p_instancia)
    ),
    -- Conversas criadas no período: todo o histórico delas está a partir de p_inicio
    novas as (
      select s.*
      from public.mcp__conversas_desde(v_empresa, lower(v_periodo)) s
      join public.chat_conversations c on c.id = s.conversation_id and c.empresa_id = v_empresa
      where c.created_at <@ v_periodo
        and (p_instancia is null or c.instance_id = p_instancia)
    ),
    situacao as (
      select case
               when msgs_loja = 0 then 'nao_respondido'
               when msgs_cliente = 0 then 'sem_resposta_cliente'
               when ultima_em >= now() - interval '24 hours' then 'em_conversa'
               when ultima_direcao = 'outbound' then 'aguardando_loja'
               else 'cliente_parou'
             end as categoria
      from novas
    )
    select jsonb_build_object(
      'periodo', jsonb_build_object('inicio', p_inicio, 'fim', p_fim),
      'conversas_com_mensagem_no_periodo', (select count(distinct conversation_id) from msgs),
      'conversas_novas', (select count(*) from novas),
      'mensagens', (
        select jsonb_build_object(
          'do_cliente', count(*) filter (where direction = 'outbound' and message_type <> 'call'),
          'da_loja', count(*) filter (where direction = 'inbound' and message_type <> 'call'),
          'audios', count(*) filter (where message_type = 'audio'),
          'percentual_audio', round(100.0 * count(*) filter (where message_type = 'audio')
                                    / nullif(count(*) filter (where message_type <> 'call'), 0), 1),
          'imagens', count(*) filter (where message_type = 'image'),
          'ligacoes', count(*) filter (where message_type = 'call')
        ) from msgs
      ),
      'situacao_atual_das_conversas_novas', (
        select coalesce(jsonb_object_agg(categoria, n), '{}'::jsonb)
        from (select categoria, count(*) n from situacao group by categoria) x
      ),
      'legenda_situacao', jsonb_build_object(
        'nao_respondido', 'cliente escreveu e a loja nunca respondeu',
        'sem_resposta_cliente', 'loja escreveu e o cliente nunca respondeu',
        'em_conversa', 'houve mensagem nas últimas 24h',
        'aguardando_loja', 'última mensagem é do cliente, parada há mais de 24h',
        'cliente_parou', 'última mensagem é da loja, parada há mais de 24h'
      )
    )
  );
end;
$$;

-- -----------------------------------------------------------------------------
-- tempo_resposta (todas as esperas do cliente respondidas pela loja em até 7 dias)
-- -----------------------------------------------------------------------------
create or replace function public.mcp_tempo_resposta(
  p_inicio date,
  p_fim date,
  p_agrupar text default 'total',
  p_excluir_ia boolean default false,
  p_instancia uuid default null
) returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_empresa uuid := public.mcp_exigir_admin();
  v_periodo tstzrange := public.mcp_periodo(p_inicio, p_fim);
begin
  if p_agrupar not in ('total', 'vendedor', 'instancia', 'hora', 'dia_semana') then
    raise exception 'mcp: agrupar deve ser total, vendedor, instancia, hora ou dia_semana'
      using errcode = '22023';
  end if;

  return jsonb_build_object(
    'agrupado_por', p_agrupar,
    'excluiu_instancias_com_ia', p_excluir_ia,
    'grupos', coalesce((
      with w as (
        select w.minutes, w.conversation_id, w.instance_id,
               coalesce(c.assigned_user_id, l.responsible_uuid) as responsavel,
               w.waited_from at time zone 'America/Sao_Paulo' as local_ts
        from public._chat_response_waits(v_empresa, p_inicio, p_fim,
               case when p_instancia is null then null else array[p_instancia] end,
               null, null, null) w
        join public.chat_conversations c on c.id = w.conversation_id and c.empresa_id = v_empresa
        left join public.leads l on l.id = c.lead_id
        left join public.whatsapp_instances i on i.id = w.instance_id
        where not p_excluir_ia or not coalesce(i."IA", false)
      ),
      g as (
        select
          case p_agrupar
            when 'total' then 'total'
            when 'vendedor' then coalesce(p.full_name, 'Sem responsável')
            when 'instancia' then coalesce(nullif(i.display_name, ''), i.name, 'Desconhecida')
            when 'hora' then lpad(extract(hour from w.local_ts)::int::text, 2, '0') || 'h'
            when 'dia_semana' then (array['domingo','segunda','terça','quarta','quinta','sexta','sábado'])
                                   [extract(dow from w.local_ts)::int + 1]
          end as grupo,
          case p_agrupar
            when 'hora' then extract(hour from w.local_ts)::int
            when 'dia_semana' then extract(dow from w.local_ts)::int
            else 0
          end as ordem,
          w.minutes, w.conversation_id
        from w
        left join public.profiles p on p.uuid = w.responsavel
        left join public.whatsapp_instances i on i.id = w.instance_id
      )
      select jsonb_agg(jsonb_build_object(
        'grupo', grupo,
        'esperas', n,
        'conversas', conversas,
        'mediana_min', mediana,
        'p90_min', p90,
        'media_min', media,
        'ate_5_min_pct', round(100.0 * ate5 / n, 1),
        'de_5_a_30_min_pct', round(100.0 * ate30 / n, 1),
        'de_30_min_a_2h_pct', round(100.0 * ate120 / n, 1),
        'acima_2h_pct', round(100.0 * acima / n, 1)
      ) order by case when p_agrupar in ('hora', 'dia_semana') then ordem end, n desc)
      from (
        select grupo, min(ordem) as ordem, count(*) as n,
               count(distinct conversation_id) as conversas,
               round(percentile_cont(0.5) within group (order by minutes)::numeric, 1) as mediana,
               round(percentile_cont(0.9) within group (order by minutes)::numeric, 1) as p90,
               round(avg(minutes), 1) as media,
               count(*) filter (where minutes <= 5) as ate5,
               count(*) filter (where minutes > 5 and minutes <= 30) as ate30,
               count(*) filter (where minutes > 30 and minutes <= 120) as ate120,
               count(*) filter (where minutes > 120) as acima
        from g group by grupo
      ) x
    ), '[]'::jsonb)
  );
end;
$$;

-- -----------------------------------------------------------------------------
-- conversas_sem_resposta (cliente esperando AGORA)
-- -----------------------------------------------------------------------------
create or replace function public.mcp_conversas_sem_resposta(
  p_minutos integer default 30,
  p_max_dias integer default 7,
  p_vendedor uuid default null,
  p_instancia uuid default null,
  p_limite integer default 50
) returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_empresa uuid := public.mcp_exigir_admin();
  v_limite integer := least(greatest(coalesce(p_limite, 50), 1), 200);
begin
  if coalesce(p_minutos, 0) < 1 or coalesce(p_max_dias, 0) < 1 or p_max_dias > 60 then
    raise exception 'mcp: minutos >= 1 e max_dias entre 1 e 60' using errcode = '22023';
  end if;

  return (
    with esperando as (
      select s.*, c.lead_id, c.instance_id, c.fone,
             coalesce(c.assigned_user_id, l.responsible_uuid) as responsavel
      from public.mcp__conversas_desde(v_empresa, now() - make_interval(days => p_max_dias)) s
      join public.chat_conversations c on c.id = s.conversation_id and c.empresa_id = v_empresa
      left join public.leads l on l.id = c.lead_id
      where s.ultima_direcao = 'outbound'
        and s.primeira_cliente_pendente_em < now() - make_interval(mins => p_minutos)
        and (p_instancia is null or c.instance_id = p_instancia)
        and (p_vendedor is null or coalesce(c.assigned_user_id, l.responsible_uuid) = p_vendedor)
    )
    select jsonb_build_object(
      'total', (select count(*) from esperando),
      'nunca_respondidas_na_janela', (select count(*) from esperando where ultima_loja_em is null),
      'por_responsavel', coalesce((
        select jsonb_agg(jsonb_build_object('responsavel', nome, 'conversas', n) order by n desc)
        from (select coalesce(p.full_name, 'Sem responsável') nome, count(*) n
              from esperando e left join public.profiles p on p.uuid = e.responsavel
              group by 1) r
      ), '[]'::jsonb),
      'conversas', coalesce((
        select jsonb_agg(jsonb_build_object(
          'conversa_id', e.conversation_id,
          'lead_id', e.lead_id,
          'lead', l.name,
          'telefone', coalesce(l.phone, e.fone),
          'responsavel', coalesce(p.full_name, 'Sem responsável'),
          'instancia', coalesce(nullif(i.display_name, ''), i.name),
          'aguardando_desde', e.primeira_cliente_pendente_em,
          'minutos_esperando', floor(extract(epoch from now() - e.primeira_cliente_pendente_em) / 60)::int,
          'loja_ja_respondeu_antes', e.ultima_loja_em is not null
        ) order by e.primeira_cliente_pendente_em)
        from (select * from esperando order by primeira_cliente_pendente_em limit v_limite) e
        left join public.leads l on l.id = e.lead_id
        left join public.profiles p on p.uuid = e.responsavel
        left join public.whatsapp_instances i on i.id = e.instance_id
      ), '[]'::jsonb)
    )
  );
end;
$$;

-- -----------------------------------------------------------------------------
-- followup_ausente (loja falou por último, cliente sumiu, lead em aberto)
-- -----------------------------------------------------------------------------
create or replace function public.mcp_followup_ausente(
  p_dias integer default 2,
  p_max_dias integer default 30,
  p_vendedor uuid default null,
  p_limite integer default 50
) returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_empresa uuid := public.mcp_exigir_admin();
  v_limite integer := least(greatest(coalesce(p_limite, 50), 1), 200);
begin
  if coalesce(p_dias, 0) < 1 or coalesce(p_max_dias, 0) <= p_dias or p_max_dias > 90 then
    raise exception 'mcp: dias >= 1 e max_dias maior que dias (até 90)' using errcode = '22023';
  end if;

  return (
    with paradas as (
      select s.*, c.lead_id,
             coalesce(c.assigned_user_id, l.responsible_uuid) as responsavel,
             l.name as lead_nome, l.phone, l.stage_id
      from public.mcp__conversas_desde(v_empresa, now() - make_interval(days => p_max_dias)) s
      join public.chat_conversations c on c.id = s.conversation_id and c.empresa_id = v_empresa
      join public.leads l on l.id = c.lead_id and l.empresa_id = v_empresa
      where s.ultima_direcao = 'inbound'
        and s.ultima_em < now() - make_interval(days => p_dias)
        and l.sold_at is null and l.lost_at is null
        and (p_vendedor is null or coalesce(c.assigned_user_id, l.responsible_uuid) = p_vendedor)
    )
    select jsonb_build_object(
      'total', (select count(*) from paradas),
      'cliente_nao_escreveu_na_janela', (select count(*) from paradas where msgs_cliente = 0),
      'por_responsavel', coalesce((
        select jsonb_agg(jsonb_build_object('responsavel', nome, 'conversas', n) order by n desc)
        from (select coalesce(p.full_name, 'Sem responsável') nome, count(*) n
              from paradas x left join public.profiles p on p.uuid = x.responsavel
              group by 1) r
      ), '[]'::jsonb),
      'conversas', coalesce((
        select jsonb_agg(jsonb_build_object(
          'conversa_id', x.conversation_id,
          'lead_id', x.lead_id,
          'lead', x.lead_nome,
          'telefone', x.phone,
          'etapa', s.name,
          'responsavel', coalesce(p.full_name, 'Sem responsável'),
          'ultima_mensagem_da_loja_em', x.ultima_em,
          'dias_sem_retorno', floor(extract(epoch from now() - x.ultima_em) / 86400)::int,
          'cliente_escreveu_na_janela', x.msgs_cliente > 0
        ) order by x.ultima_em desc)
        from (select * from paradas order by ultima_em desc limit v_limite) x
        left join public.stages s on s.id = x.stage_id
        left join public.profiles p on p.uuid = x.responsavel
      ), '[]'::jsonb)
    )
  );
end;
$$;

-- -----------------------------------------------------------------------------
-- ligacoes (cliente ligou e a loja perdeu/recusou; retorno em até N horas)
-- -----------------------------------------------------------------------------
create or replace function public.mcp_ligacoes(
  p_inicio date,
  p_fim date,
  p_instancia uuid default null,
  p_horas_retorno integer default 2,
  p_limite integer default 50
) returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_empresa uuid := public.mcp_exigir_admin();
  v_periodo tstzrange := public.mcp_periodo(p_inicio, p_fim);
  v_limite integer := least(greatest(coalesce(p_limite, 50), 1), 200);
begin
  if coalesce(p_horas_retorno, 0) < 1 or p_horas_retorno > 72 then
    raise exception 'mcp: horas_retorno entre 1 e 72' using errcode = '22023';
  end if;

  return (
    with chamadas as (
      select m.id, m.conversation_id, m.instance_id, m."timestamp" as quando, m.direction,
             coalesce(m.metadata->>'resultado', 'desconhecido') as resultado
      from public.chat_messages m
      where m.empresa_id = v_empresa
        and m.message_type = 'call'
        and m."timestamp" <@ v_periodo
        and (p_instancia is null or m.instance_id = p_instancia)
    ),
    perdidas as (
      select ch.*,
             (select min(r."timestamp") from public.chat_messages r
              where r.conversation_id = ch.conversation_id
                and r.direction = 'inbound'
                and r."timestamp" > ch.quando) as primeiro_retorno
      from chamadas ch
      where ch.direction = 'outbound' and ch.resultado in ('perdida', 'recusada')
    ),
    sem_retorno as (
      select * from perdidas
      where primeiro_retorno is null
         or primeiro_retorno > quando + make_interval(hours => p_horas_retorno)
    )
    select jsonb_build_object(
      'do_cliente', (
        select coalesce(jsonb_object_agg(resultado, n), '{}'::jsonb)
        from (select resultado, count(*) n from chamadas where direction = 'outbound' group by 1) x
      ),
      'da_loja', (
        select coalesce(jsonb_object_agg(resultado, n), '{}'::jsonb)
        from (select resultado, count(*) n from chamadas where direction = 'inbound' group by 1) x
      ),
      'perdidas_ou_recusadas_pela_loja', (select count(*) from perdidas),
      'sem_retorno_no_prazo', (select count(*) from sem_retorno),
      'lista_sem_retorno', coalesce((
        select jsonb_agg(jsonb_build_object(
          'conversa_id', x.conversation_id,
          'lead', l.name,
          'telefone', coalesce(l.phone, c.fone),
          'responsavel', coalesce(p.full_name, 'Sem responsável'),
          'instancia', coalesce(nullif(i.display_name, ''), i.name),
          'ligou_em', x.quando,
          'resultado', x.resultado,
          'retorno_da_loja_em', x.primeiro_retorno
        ) order by x.quando desc)
        from (select * from sem_retorno order by quando desc limit v_limite) x
        join public.chat_conversations c on c.id = x.conversation_id
        left join public.leads l on l.id = c.lead_id
        left join public.profiles p on p.uuid = coalesce(c.assigned_user_id, l.responsible_uuid)
        left join public.whatsapp_instances i on i.id = x.instance_id
      ), '[]'::jsonb)
    )
  );
end;
$$;

-- -----------------------------------------------------------------------------
-- mapa_demanda (dia da semana x hora: mensagens do cliente e tempo de resposta)
-- -----------------------------------------------------------------------------
create or replace function public.mcp_mapa_demanda(
  p_inicio date,
  p_fim date,
  p_instancia uuid default null
) returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_empresa uuid := public.mcp_exigir_admin();
  v_periodo tstzrange := public.mcp_periodo(p_inicio, p_fim);
begin
  return coalesce((
    with msgs as (
      select extract(dow from m."timestamp" at time zone 'America/Sao_Paulo')::int as dow,
             extract(hour from m."timestamp" at time zone 'America/Sao_Paulo')::int as hora
      from public.chat_messages m
      where m.empresa_id = v_empresa
        and m.direction = 'outbound'
        and m."timestamp" <@ v_periodo
        and (p_instancia is null or m.instance_id = p_instancia)
    ),
    waits as (
      select extract(dow from w.waited_from at time zone 'America/Sao_Paulo')::int as dow,
             extract(hour from w.waited_from at time zone 'America/Sao_Paulo')::int as hora,
             w.minutes
      from public._chat_response_waits(v_empresa, p_inicio, p_fim,
             case when p_instancia is null then null else array[p_instancia] end,
             null, null, null) w
    ),
    celulas as (
      select dow, hora, count(*) as mensagens from msgs group by 1, 2
    ),
    resp as (
      select dow, hora, count(*) as esperas,
             round(percentile_cont(0.5) within group (order by minutes)::numeric, 1) as mediana
      from waits group by 1, 2
    )
    select jsonb_agg(jsonb_build_object(
      'dia_semana', (array['domingo','segunda','terça','quarta','quinta','sexta','sábado'])[coalesce(c.dow, r.dow) + 1],
      'hora', coalesce(c.hora, r.hora),
      'mensagens_do_cliente', coalesce(c.mensagens, 0),
      'esperas_respondidas', coalesce(r.esperas, 0),
      'mediana_resposta_min', r.mediana
    ) order by coalesce(c.dow, r.dow), coalesce(c.hora, r.hora))
    from celulas c
    full join resp r on r.dow = c.dow and r.hora = c.hora
  ), '[]'::jsonb);
end;
$$;

-- -----------------------------------------------------------------------------
-- conversas_orfas (com mensagem no período, sem responsável e/ou sem lead)
-- -----------------------------------------------------------------------------
create or replace function public.mcp_conversas_orfas(
  p_inicio date,
  p_fim date,
  p_limite integer default 50
) returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_empresa uuid := public.mcp_exigir_admin();
  v_periodo tstzrange := public.mcp_periodo(p_inicio, p_fim);
  v_limite integer := least(greatest(coalesce(p_limite, 50), 1), 200);
begin
  return (
    with ativas as (
      select m.conversation_id,
             max(m."timestamp") as ultima_em,
             count(*) filter (where m.direction = 'outbound') as msgs_cliente,
             count(*) filter (where m.direction = 'inbound') as msgs_loja
      from public.chat_messages m
      where m.empresa_id = v_empresa
        and m."timestamp" <@ v_periodo
      group by m.conversation_id
    ),
    orfas as (
      select a.*, c.instance_id, c.fone, c."Nome_Whatsapp" as contato,
             coalesce(c.assigned_user_id, l.responsible_uuid) is null as sem_responsavel,
             c.lead_id is null as sem_lead
      from ativas a
      join public.chat_conversations c on c.id = a.conversation_id and c.empresa_id = v_empresa
      left join public.leads l on l.id = c.lead_id
      where c.lead_id is null or coalesce(c.assigned_user_id, l.responsible_uuid) is null
    )
    select jsonb_build_object(
      'conversas_com_mensagem_no_periodo', (select count(*) from ativas),
      'sem_responsavel', (select count(*) from orfas where sem_responsavel),
      'sem_lead', (select count(*) from orfas where sem_lead),
      'sem_lead_e_cliente_escreveu', (select count(*) from orfas where sem_lead and msgs_cliente > 0),
      'por_instancia', coalesce((
        select jsonb_agg(jsonb_build_object('instancia', nome, 'conversas', n) order by n desc)
        from (select coalesce(nullif(i.display_name, ''), i.name, 'Desconhecida') nome, count(*) n
              from orfas o left join public.whatsapp_instances i on i.id = o.instance_id
              group by 1) x
      ), '[]'::jsonb),
      'conversas', coalesce((
        select jsonb_agg(jsonb_build_object(
          'conversa_id', o.conversation_id,
          'contato', o.contato,
          'telefone', o.fone,
          'instancia', coalesce(nullif(i.display_name, ''), i.name),
          'sem_responsavel', o.sem_responsavel,
          'sem_lead', o.sem_lead,
          'mensagens_do_cliente_no_periodo', o.msgs_cliente,
          'mensagens_da_loja_no_periodo', o.msgs_loja,
          'ultima_mensagem_em', o.ultima_em
        ) order by o.ultima_em desc)
        from (select * from orfas where msgs_cliente > 0 order by ultima_em desc limit v_limite) o
        left join public.whatsapp_instances i on i.id = o.instance_id
      ), '[]'::jsonb)
    )
  );
end;
$$;

-- -----------------------------------------------------------------------------
-- chat_x_conversao (primeira resposta da loja x venda do lead)
-- -----------------------------------------------------------------------------
create or replace function public.mcp_chat_x_conversao(
  p_inicio date,
  p_fim date
) returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_empresa uuid := public.mcp_exigir_admin();
  v_periodo tstzrange := public.mcp_periodo(p_inicio, p_fim);
begin
  return (
    with leads_periodo as (
      select l.id, l.status = 'venda_confirmada' and l.sold_at is not null as vendido
      from public.leads l
      where l.empresa_id = v_empresa
        and l.created_at <@ v_periodo
    ),
    -- Uma varredura das mensagens desde o início do período (índice empresa+timestamp)
    m as (
      select c.lead_id, m.direction, m."timestamp" as ts,
             min(m."timestamp") filter (where m.direction = 'outbound')
               over (partition by c.lead_id) as cliente_em
      from public.chat_messages m
      join public.chat_conversations c on c.id = m.conversation_id and c.empresa_id = v_empresa
      join leads_periodo lp on lp.id = c.lead_id
      where m.empresa_id = v_empresa
        and m."timestamp" >= lower(v_periodo)
    ),
    tempos as (
      select lead_id,
             extract(epoch from (min(ts) filter (where direction = 'inbound' and ts > cliente_em)
                                 - min(cliente_em))) / 60.0 as minutos
      from m
      where cliente_em is not null
      group by lead_id
    ),
    faixas as (
      select case when t.minutos is null then '5) sem resposta'
                  when t.minutos <= 5 then '1) até 5 min'
                  when t.minutos <= 30 then '2) 5 a 30 min'
                  when t.minutos <= 120 then '3) 30 min a 2h'
                  else '4) mais de 2h' end as faixa,
             lp.vendido
      from tempos t
      join leads_periodo lp on lp.id = t.lead_id
    )
    select jsonb_build_object(
      'observacao', 'leads criados no período que escreveram no WhatsApp; a venda conta até hoje',
      'faixas', coalesce((
        select jsonb_agg(jsonb_build_object(
          'primeira_resposta', substr(faixa, 4),
          'leads', n,
          'vendas', v,
          'taxa_conversao_pct', round(100.0 * v / n, 2)
        ) order by faixa)
        from (select faixa, count(*) n, count(*) filter (where vendido) v from faixas group by faixa) x
      ), '[]'::jsonb)
    )
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
    'public.mcp_chat_visao_geral(date, date, uuid)',
    'public.mcp_tempo_resposta(date, date, text, boolean, uuid)',
    'public.mcp_conversas_sem_resposta(integer, integer, uuid, uuid, integer)',
    'public.mcp_followup_ausente(integer, integer, uuid, integer)',
    'public.mcp_ligacoes(date, date, uuid, integer, integer)',
    'public.mcp_mapa_demanda(date, date, uuid)',
    'public.mcp_conversas_orfas(date, date, integer)',
    'public.mcp_chat_x_conversao(date, date)'
  ] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end;
$$;
