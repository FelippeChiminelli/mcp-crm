-- =============================================================================
-- MCP (expansão): conversão entre etapas, distribuição de leads e leads sem contato.
--
-- SECURITY DEFINER: usa chat_messages e o helper privado _leads_sem_contato (o mesmo
-- da tela "Leads sem contato" e do relatório do n8n). A empresa vem SEMPRE de
-- mcp_exigir_admin().
--
-- Direção invertida: outbound = cliente, inbound = loja.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- conversao_etapas: coorte de leads criados no período e por quais etapas passou.
-- Entradas em etapa = lead_pipeline_history (created, stage_changed, both_changed,
-- reactivated) mais a etapa atual (leads antigos podem não ter histórico).
-- -----------------------------------------------------------------------------
create or replace function public.mcp_conversao_etapas(
  p_inicio date,
  p_fim date,
  p_pipeline uuid default null
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
    with coorte as (
      select l.id, l.pipeline_id, l.stage_id, l.created_at, l.current_stage_since,
             l.status = 'venda_confirmada' and l.sold_at is not null as vendido,
             l.status = 'perdido' and l.lost_at is not null as perdido
      from public.leads l
      where l.empresa_id = v_empresa
        and l.created_at <@ v_periodo
        and (p_pipeline is null or l.pipeline_id = p_pipeline)
    ),
    historico as (
      select h.lead_id, h.stage_id, h.changed_at as entrou_em,
             lead(h.changed_at) over (partition by h.lead_id order by h.changed_at, h.id) as saiu_em
      from public.lead_pipeline_history h
      join coorte c on c.id = h.lead_id
      where h.empresa_id = v_empresa
        and h.change_type in ('created', 'stage_changed', 'both_changed', 'reactivated')
        and h.stage_id is not null
    ),
    passagens as (
      select lead_id, stage_id from historico
      union
      select id, stage_id from coorte where stage_id is not null
    ),
    etapas as (
      select s.id, s.name, s.position, s.pipeline_id, pl.name as pipeline
      from public.stages s
      join public.pipelines pl on pl.id = s.pipeline_id and pl.empresa_id = v_empresa
      where s.empresa_id = v_empresa
        and (p_pipeline is null or pl.id = p_pipeline)
        and pl.id in (select pipeline_id from coorte)
    ),
    alcance as materialized (
      -- etapa mais avançada que cada lead atingiu em cada pipeline
      select p.lead_id, e.pipeline_id, max(e.position) as posicao_max
      from passagens p join etapas e on e.id = p.stage_id
      group by p.lead_id, e.pipeline_id
    ),
    n_passaram as (
      select stage_id, count(*) as n from passagens group by stage_id
    ),
    n_alcance as (
      select e.id, count(*) as n
      from etapas e
      join alcance a on a.pipeline_id = e.pipeline_id and a.posicao_max >= e.position
      group by e.id
    ),
    n_situacao as (
      select stage_id,
             count(*) filter (where not vendido and not perdido) as agora,
             count(*) filter (where perdido) as perdidos,
             count(*) filter (where vendido) as vendidos
      from coorte group by stage_id
    ),
    n_tempo as (
      select stage_id,
             round((percentile_cont(0.5) within group (
               order by extract(epoch from saiu_em - entrou_em) / 86400))::numeric, 1) as mediana
      from historico where saiu_em is not null group by stage_id
    ),
    por_etapa as (
      select e.*,
             coalesce(np.n, 0) as passaram,
             coalesce(na.n, 0) as chegaram_ate_aqui_ou_alem,
             coalesce(ns.agora, 0) as estao_agora,
             coalesce(ns.perdidos, 0) as perdidos_nesta_etapa,
             coalesce(ns.vendidos, 0) as vendidos_nesta_etapa,
             nt.mediana as mediana_dias_ate_sair
      from etapas e
      left join n_passaram np on np.stage_id = e.id
      left join n_alcance na on na.id = e.id
      left join n_situacao ns on ns.stage_id = e.id
      left join n_tempo nt on nt.stage_id = e.id
    )
    select jsonb_build_object(
      'periodo', jsonb_build_object('inicio', p_inicio, 'fim', p_fim),
      'leads_na_coorte', (select count(*) from coorte),
      'vendidos', (select count(*) from coorte where vendido),
      'perdidos', (select count(*) from coorte where perdido),
      'observacao', 'coorte = leads criados no período, acompanhados até hoje; '
                    || '"chegaram_ate_aqui_ou_alem" conta quem atingiu esta etapa ou uma posterior '
                    || '(funil que não regride); "perdidos_nesta_etapa" usa a etapa em que o lead '
                    || 'estava quando foi perdido',
      'etapas', coalesce((
        select jsonb_agg(jsonb_build_object(
          'pipeline', x.pipeline,
          'pipeline_id', x.pipeline_id,
          'etapa', x.name,
          'etapa_id', x.id,
          'posicao', x.position,
          'passaram', x.passaram,
          'chegaram_ate_aqui_ou_alem', x.chegaram_ate_aqui_ou_alem,
          'pct_da_etapa_anterior', x.pct_anterior,
          'estao_agora', x.estao_agora,
          'perdidos_nesta_etapa', x.perdidos_nesta_etapa,
          'vendidos_nesta_etapa', x.vendidos_nesta_etapa,
          'mediana_dias_ate_sair', x.mediana_dias_ate_sair
        ) order by x.pipeline, x.position)
        from (
          select pe.*,
                 round(100.0 * pe.chegaram_ate_aqui_ou_alem / nullif(lag(pe.chegaram_ate_aqui_ou_alem)
                   over (partition by pe.pipeline_id order by pe.position), 0), 1) as pct_anterior
          from por_etapa pe
        ) x
      ), '[]'::jsonb)
    )
  );
end;
$$;

-- -----------------------------------------------------------------------------
-- distribuicao_leads: atribuições (rodízio/manual) e tempo até o primeiro contato.
-- Primeiro contato = primeira mensagem da loja (inbound) em conversa do lead depois
-- da atribuição, até 7 dias ou até a próxima atribuição do mesmo lead.
-- -----------------------------------------------------------------------------
create or replace function public.mcp_distribuicao_leads(
  p_inicio date,
  p_fim date,
  p_pipeline uuid default null
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
    with atribuicoes as (
      select a.lead_id, a.vendedor_id, a.created_at,
             coalesce(nullif(trim(a.origem), ''), 'Não informado') as origem,
             lead(a.created_at) over (partition by a.lead_id order by a.created_at) as proxima
      from public.lead_assignment_log a
      where a.empresa_id = v_empresa
        and a.created_at <@ v_periodo
        and (p_pipeline is null or a.pipeline_id = p_pipeline)
    ),
    com_contato as (
      select a.*,
             extract(epoch from (
               select min(m."timestamp")
               from public.chat_conversations c
               join public.chat_messages m on m.conversation_id = c.id
               where c.lead_id = a.lead_id
                 and c.empresa_id = v_empresa
                 and m.direction = 'inbound'
                 and m."timestamp" >= a.created_at
                 and m."timestamp" < least(a.created_at + interval '7 days', coalesce(a.proxima, 'infinity'))
             ) - a.created_at) / 60 as minutos
      from atribuicoes a
    ),
    por_vendedor as (
      select x.vendedor_id,
             count(*) as atribuicoes,
             count(distinct x.lead_id) as leads,
             count(distinct x.lead_id) filter (
               where l.status = 'venda_confirmada' and l.sold_at is not null
                 and l.responsible_uuid = x.vendedor_id
             ) as vendas_destes_leads,
             round((percentile_cont(0.5) within group (order by x.minutos))::numeric, 1)
               as mediana_min_primeiro_contato,
             count(*) filter (where x.minutos <= 1) as ate_1_min,
             count(*) filter (where x.minutos > 1 and x.minutos <= 5) as de_1_a_5_min,
             count(*) filter (where x.minutos > 5 and x.minutos <= 30) as de_5_a_30_min,
             count(*) filter (where x.minutos > 30 and x.minutos <= 120) as de_30_min_a_2h,
             count(*) filter (where x.minutos > 120) as acima_de_2h,
             count(*) filter (where x.minutos is null) as sem_contato,
             (select jsonb_object_agg(o.origem, o.n) from (
                select y.origem, count(*) n from com_contato y
                where y.vendedor_id is not distinct from x.vendedor_id
                group by y.origem order by 2 desc limit 8
              ) o) as por_origem
      from com_contato x
      left join public.leads l on l.id = x.lead_id
      group by x.vendedor_id
    )
    select jsonb_build_object(
      'periodo', jsonb_build_object('inicio', p_inicio, 'fim', p_fim),
      'atribuicoes', (select count(*) from atribuicoes),
      'leads', (select count(distinct lead_id) from atribuicoes),
      'leads_redistribuidos', (
        select count(*) from (select lead_id from atribuicoes group by 1 having count(*) > 1) r
      ),
      -- Em algumas lojas o vendedor atende fora do WhatsApp conectado ao CRM
      'pct_atribuicoes_com_contato_registrado', (
        select round(100.0 * count(*) filter (where minutos is not null) / nullif(count(*), 0), 1)
        from com_contato
      ),
      'observacao', 'primeiro contato = primeira mensagem da loja após a atribuição; mensagens '
                    || 'automáticas (saudação, IA) contam, por isso "ate_1_min" alto costuma ser automação. '
                    || 'Se pct_atribuicoes_com_contato_registrado for baixo para a loja toda, o atendimento '
                    || 'provavelmente acontece fora do WhatsApp conectado ao CRM: não conclua que os '
                    || 'vendedores não atendem. "vendas_destes_leads" só conta se o vendedor ainda é o responsável',
      'vendedores', coalesce((
        select jsonb_agg(jsonb_build_object(
          'vendedor', coalesce(p.full_name, 'Sem vendedor'),
          'vendedor_id', v.vendedor_id,
          'participa_rodizio', coalesce(p.participa_rotacao, false),
          'atribuicoes', v.atribuicoes,
          'leads', v.leads,
          'pct_das_atribuicoes', round(100.0 * v.atribuicoes / nullif(v.total_atribuicoes, 0), 1),
          'vendas_destes_leads', v.vendas_destes_leads,
          'mediana_min_primeiro_contato', v.mediana_min_primeiro_contato,
          'faixas_primeiro_contato', jsonb_build_object(
            'ate_1_min', v.ate_1_min, '1_a_5_min', v.de_1_a_5_min, '5_a_30_min', v.de_5_a_30_min,
            '30_min_a_2h', v.de_30_min_a_2h, 'acima_de_2h', v.acima_de_2h,
            'sem_contato_em_7_dias', v.sem_contato
          ),
          'por_origem', coalesce(v.por_origem, '{}'::jsonb)
        ) order by v.atribuicoes desc)
        from (select pv.*, sum(pv.atribuicoes) over () as total_atribuicoes from por_vendedor pv) v
        left join public.profiles p on p.uuid = v.vendedor_id
      ), '[]'::jsonb)
    )
  );
end;
$$;

-- -----------------------------------------------------------------------------
-- leads_sem_contato: leads em aberto sem mensagem de WhatsApp (em qualquer direção)
-- há mais de N dias. Mesma regra da tela do CRM (_leads_sem_contato).
-- -----------------------------------------------------------------------------
create or replace function public.mcp_leads_sem_contato(
  p_dias integer default 3,
  p_max_dias integer default null,
  p_vendedor uuid default null,
  p_sem_responsavel boolean default false,
  p_limite integer default 50,
  p_offset integer default 0
) returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_empresa uuid := public.mcp_exigir_admin();
  v_limite integer := least(greatest(coalesce(p_limite, 50), 1), 200);
  v_offset integer := greatest(coalesce(p_offset, 0), 0);
begin
  if p_dias is null or p_dias < 1 then
    raise exception 'mcp: dias deve ser maior ou igual a 1' using errcode = '22023';
  end if;
  if p_max_dias is not null and p_max_dias <= p_dias then
    raise exception 'mcp: max_dias deve ser maior que dias' using errcode = '22023';
  end if;

  return (
    with s as materialized (
      select *
      from public._leads_sem_contato(
        v_empresa,
        now() - make_interval(days => p_dias),
        case when p_max_dias is not null then now() - make_interval(days => p_max_dias) end,
        p_vendedor,
        coalesce(p_sem_responsavel, false)
      )
    )
    select jsonb_build_object(
      'total', (select count(*) from s),
      'nunca_contatados', (select count(*) from s where ultimo_contato is null),
      'limite', v_limite,
      'offset', v_offset,
      'por_responsavel', coalesce((
        select jsonb_agg(jsonb_build_object('responsavel', nome, 'leads', n) order by n desc)
        from (
          select coalesce(p.full_name, 'Sem responsável') as nome, count(*) as n
          from s left join public.profiles p on p.uuid = s.responsavel_id
          group by 1
        ) r
      ), '[]'::jsonb),
      'leads', coalesce((
        select jsonb_agg(jsonb_build_object(
          'lead_id', x.lead_id,
          'nome', coalesce(nullif(trim(x.nome), ''), 'Sem nome'),
          'telefone', x.telefone,
          'responsavel', coalesce(p.full_name, 'Sem responsável'),
          'pipeline', pl.name,
          'etapa', st.name,
          'ultimo_contato', x.ultimo_contato,
          'nunca_contatado', x.ultimo_contato is null,
          'dias_parado', floor(extract(epoch from now() - x.referencia) / 86400)::int
        ) order by x.referencia, x.lead_id)
        from (select * from s order by referencia, lead_id limit v_limite offset v_offset) x
        left join public.profiles p on p.uuid = x.responsavel_id
        left join public.pipelines pl on pl.id = x.pipeline_id
        left join public.stages st on st.id = x.stage_id
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
    'public.mcp_conversao_etapas(date, date, uuid)',
    'public.mcp_distribuicao_leads(date, date, uuid)',
    'public.mcp_leads_sem_contato(integer, integer, uuid, boolean, integer, integer)'
  ] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end;
$$;
