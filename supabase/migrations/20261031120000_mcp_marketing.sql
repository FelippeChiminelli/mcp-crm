-- =============================================================================
-- MCP (expansão): anúncios do Meta, campanhas de WhatsApp e demanda x estoque.
--
-- SECURITY DEFINER pelo mesmo motivo da fase 3: as consultas cruzam chat_messages
-- e o dicionário de modelos usa o estoque de todas as lojas (só o nome do modelo
-- sai dessa leitura). A empresa vem SEMPRE de mcp_exigir_admin().
--
-- Direção invertida: outbound = cliente, inbound = loja.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- desempenho_anuncios: leads que chegaram por anúncio do Meta (click-to-WhatsApp)
-- Cada lead conta uma vez, no primeiro anúncio dentro do período.
-- Só ~8% das linhas têm nome de campanha/conjunto (o Meta nem sempre envia).
-- -----------------------------------------------------------------------------
create or replace function public.mcp_desempenho_anuncios(
  p_inicio date,
  p_fim date,
  p_agrupar text default 'anuncio',
  p_limite integer default 30
) returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_empresa uuid := public.mcp_exigir_admin();
  v_periodo tstzrange := public.mcp_periodo(p_inicio, p_fim);
  v_limite integer := least(greatest(coalesce(p_limite, 30), 1), 100);
begin
  if p_agrupar not in ('anuncio', 'campanha', 'conjunto') then
    raise exception 'mcp: agrupar deve ser anuncio, campanha ou conjunto' using errcode = '22023';
  end if;

  return (
    with toques as (
      select distinct on (a.lead_id)
             a.lead_id, a.source_id,
             coalesce(nullif(trim(a.name_ads), ''), nullif(trim(a.title_ads), '')) as anuncio,
             nullif(trim(a.name_campaign), '') as campanha,
             nullif(trim(a.name_conjunto_anuncio), '') as conjunto
      from public.meta_ads a
      where a.empresa_id = v_empresa
        and a.created_at <@ v_periodo
        and a.lead_id is not null
      order by a.lead_id, a.created_at
    ),
    base as (
      select t.*,
             case p_agrupar
               when 'anuncio' then coalesce(t.source_id, 'sem id')
               when 'campanha' then coalesce(t.campanha, 'Não identificada')
               else coalesce(t.conjunto, 'Não identificado')
             end as chave,
             l.status = 'venda_confirmada' and l.sold_at is not null as vendido,
             l.status = 'perdido' and l.lost_at is not null as perdido,
             coalesce(l.sold_value, l.value, 0) as valor
      from toques t
      join public.leads l on l.id = t.lead_id and l.empresa_id = v_empresa
    ),
    grupos as (
      select chave,
             max(anuncio) as anuncio,
             max(campanha) as campanha,
             count(*) as leads,
             count(*) filter (where vendido) as vendas,
             coalesce(sum(valor) filter (where vendido), 0) as valor_vendido,
             count(*) filter (where perdido) as perdas
      from base
      group by chave
    )
    select jsonb_build_object(
      'periodo', jsonb_build_object('inicio', p_inicio, 'fim', p_fim),
      'agrupado_por', p_agrupar,
      'leads_por_anuncio', (select count(*) from base),
      'leads_totais_no_periodo', (
        select count(*) from public.leads l
        where l.empresa_id = v_empresa and l.created_at <@ v_periodo
      ),
      'pct_com_nome_de_campanha', (
        select round(100.0 * count(*) filter (where campanha is not null) / nullif(count(*), 0), 1)
        from base
      ),
      'observacao', 'vendas e perdas contam até hoje (períodos recentes têm conversão menor); '
                    || '"anuncio" usa o nome do anúncio ou, sem ele, o título exibido no WhatsApp',
      'grupos', coalesce((
        select jsonb_agg(jsonb_build_object(
          'grupo', case when p_agrupar = 'anuncio' then coalesce(g.anuncio, 'Sem título') else g.chave end,
          'anuncio_id', case when p_agrupar = 'anuncio' then g.chave end,
          'campanha', case when p_agrupar = 'anuncio' then g.campanha end,
          'leads', g.leads,
          'vendas', g.vendas,
          'valor_vendido', g.valor_vendido,
          'perdas', g.perdas,
          'em_aberto', g.leads - g.vendas - g.perdas,
          'taxa_conversao_pct', round(100.0 * g.vendas / g.leads, 2)
        ) order by g.leads desc, g.vendas desc)
        from (select * from grupos order by leads desc, vendas desc limit v_limite) g
      ), '[]'::jsonb)
    )
  );
end;
$$;

-- -----------------------------------------------------------------------------
-- resultado_campanhas: envios, falhas, respostas do cliente e vendas depois do envio
-- -----------------------------------------------------------------------------
create or replace function public.mcp_resultado_campanhas(
  p_inicio date,
  p_fim date,
  p_horas_resposta integer default 72
) returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_empresa uuid := public.mcp_exigir_admin();
  v_periodo tstzrange := public.mcp_periodo(p_inicio, p_fim);
  v_janela interval := make_interval(hours => least(greatest(coalesce(p_horas_resposta, 72), 1), 168));
begin
  return (
    with campanhas as (
      select c.*
      from public.whatsapp_campaigns c
      where c.empresa_id = v_empresa
        and coalesce(c.started_at, c.scheduled_at, c.created_at) <@ v_periodo
    ),
    -- Os contadores messages_sent/messages_failed da campanha reiniciam por lote;
    -- os logs por destinatário são a fonte confiável
    eventos as (
      select g.campaign_id, g.lead_id,
             min(g.created_at) filter (where g.event_type = 'recipient_sent') as enviado_em
      from public.whatsapp_campaign_logs g
      join campanhas c on c.id = g.campaign_id
      where g.empresa_id = v_empresa
        and g.event_type in ('recipient_sent', 'recipient_failed')
        and g.lead_id is not null
      group by g.campaign_id, g.lead_id
    ),
    envios as (
      select campaign_id, lead_id, enviado_em from eventos where enviado_em is not null
    ),
    falhas as (
      select campaign_id, count(*) as n from eventos where enviado_em is null group by campaign_id
    ),
    resultado as (
      select e.campaign_id,
             exists (
               select 1
               from public.chat_conversations cv
               join public.chat_messages m on m.conversation_id = cv.id
               where cv.lead_id = e.lead_id
                 and cv.empresa_id = v_empresa
                 and m.direction = 'outbound'
                 and m."timestamp" > e.enviado_em
                 and m."timestamp" <= e.enviado_em + v_janela
             ) as respondeu,
             l.status = 'venda_confirmada' and l.sold_at > e.enviado_em as vendeu_depois,
             coalesce(l.sold_value, l.value, 0) as valor
      from envios e
      left join public.leads l on l.id = e.lead_id
    ),
    por_campanha as (
      select campaign_id,
             count(*) as leads_enviados,
             count(*) filter (where respondeu) as responderam,
             count(*) filter (where vendeu_depois) as vendas_depois,
             coalesce(sum(valor) filter (where vendeu_depois), 0) as valor_vendas_depois
      from resultado
      group by campaign_id
    )
    select jsonb_build_object(
      'periodo', jsonb_build_object('inicio', p_inicio, 'fim', p_fim),
      'janela_resposta_horas', extract(epoch from v_janela) / 3600,
      'observacao', 'vendas_depois = leads da campanha vendidos após o envio (não prova que a '
                    || 'campanha causou a venda); responderam = cliente escreveu dentro da janela',
      'campanhas', coalesce((
        select jsonb_agg(jsonb_build_object(
          'campanha_id', c.id,
          'nome', c.name,
          'status', c.status,
          'instancia', coalesce(nullif(i.display_name, ''), i.name),
          'responsavel', p.full_name,
          'inicio', coalesce(c.started_at, c.scheduled_at, c.created_at),
          'concluida_em', c.completed_at,
          'destinatarios', c.total_recipients,
          'leads_enviados', coalesce(r.leads_enviados, 0),
          'leads_com_falha', coalesce(f.n, 0),
          'pct_falha', round(100.0 * coalesce(f.n, 0)
                             / nullif(coalesce(r.leads_enviados, 0) + coalesce(f.n, 0), 0), 1),
          'responderam', coalesce(r.responderam, 0),
          'taxa_resposta_pct', round(100.0 * r.responderam / nullif(r.leads_enviados, 0), 1),
          'vendas_depois', coalesce(r.vendas_depois, 0),
          'valor_vendas_depois', coalesce(r.valor_vendas_depois, 0)
        ) order by coalesce(c.started_at, c.scheduled_at, c.created_at) desc)
        from campanhas c
        left join por_campanha r on r.campaign_id = c.id
        left join falhas f on f.campaign_id = c.id
        left join public.whatsapp_instances i on i.id = c.instance_id
        left join public.profiles p on p.uuid = coalesce(c.responsible_uuid, c.created_by)
      ), '[]'::jsonb)
    )
  );
end;
$$;

-- -----------------------------------------------------------------------------
-- demanda_estoque: modelos que os clientes procuram x estoque da loja
-- Sinais: título do anúncio do Meta que o cliente clicou e o carro de interesse
-- registrado pela IA de qualificação. O modelo é a primeira palavra de
-- vehicles.modelo_veiculo (ex.: "PRISMA", "T-CROSS"), usando o estoque de todas
-- as lojas como dicionário, sem as marcas.
-- -----------------------------------------------------------------------------
create or replace function public.mcp_demanda_estoque(
  p_inicio date,
  p_fim date,
  p_limite integer default 30
) returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_empresa uuid := public.mcp_exigir_admin();
  v_periodo tstzrange := public.mcp_periodo(p_inicio, p_fim);
  v_limite integer := least(greatest(coalesce(p_limite, 30), 1), 100);
begin
  return (
    with marcas as (
      select distinct lower(split_part(trim(v.marca_veiculo), ' ', 1)) as marca
      from public.vehicles v where v.marca_veiculo is not null
    ),
    dicionario as (
      select distinct lower(split_part(trim(v.modelo_veiculo), ' ', 1)) as modelo
      from public.vehicles v where v.modelo_veiculo is not null
    ),
    modelos as (
      select modelo from dicionario
      where length(modelo) >= 2
        and modelo !~ '^[0-9.,]+$'
        and modelo not in (select marca from marcas)
    ),
    sinais as (
      select 'anuncio' as fonte, a.lead_id::text as quem, a.title_ads as texto
      from public.meta_ads a
      where a.empresa_id = v_empresa and a.created_at <@ v_periodo and a.title_ads is not null
      union all
      select 'qualificacao_ia', q.phone, q.carro_interesse
      from public.lead_qualificacao q
      where q.empresa_id = v_empresa and q.created_at <@ v_periodo and q.carro_interesse is not null
    ),
    tokens as (
      select distinct s.fonte, s.quem, t.tok
      from sinais s
      cross join lateral regexp_split_to_table(lower(s.texto), '[^[:alnum:]-]+') as t(tok)
    ),
    procura as (
      select m.modelo,
             count(distinct (t.fonte, t.quem)) as interessados,
             count(distinct t.quem) filter (where t.fonte = 'anuncio') as via_anuncio,
             count(distinct t.quem) filter (where t.fonte = 'qualificacao_ia') as via_qualificacao_ia
      from tokens t
      join modelos m on m.modelo = t.tok
      group by m.modelo
    ),
    estoque as (
      select lower(split_part(trim(v.modelo_veiculo), ' ', 1)) as modelo,
             count(*) filter (where v.status_veiculo = 'disponivel') as disponiveis,
             min(coalesce(nullif(v.promotion_price, 0), v.price_veiculo))
               filter (where v.status_veiculo = 'disponivel') as preco_min,
             max(coalesce(nullif(v.promotion_price, 0), v.price_veiculo))
               filter (where v.status_veiculo = 'disponivel') as preco_max
      from public.vehicles v
      where v.empresa_id = v_empresa and v.modelo_veiculo is not null
      group by 1
    )
    select jsonb_build_object(
      'periodo', jsonb_build_object('inicio', p_inicio, 'fim', p_fim),
      'sinais_de_interesse', (select count(distinct (fonte, quem)) from sinais),
      'sinais_com_modelo_identificado', (
        select count(distinct (t.fonte, t.quem)) from tokens t join modelos m on m.modelo = t.tok
      ),
      'observacao', 'anúncios refletem o que a loja anunciou (o cliente clicou); a qualificação '
                    || 'da IA é o pedido espontâneo. Modelo = primeira palavra do modelo no estoque',
      'mais_procurados', coalesce((
        select jsonb_agg(jsonb_build_object(
          'modelo', p.modelo,
          'interessados', p.interessados,
          'via_anuncio', p.via_anuncio,
          'via_qualificacao_ia', p.via_qualificacao_ia,
          'disponiveis_no_estoque', coalesce(e.disponiveis, 0),
          'preco_min', e.preco_min,
          'preco_max', e.preco_max
        ) order by p.interessados desc)
        from (select * from procura order by interessados desc limit v_limite) p
        left join estoque e on e.modelo = p.modelo
      ), '[]'::jsonb),
      'procurados_sem_estoque', coalesce((
        select jsonb_agg(jsonb_build_object('modelo', p.modelo, 'interessados', p.interessados)
                         order by p.interessados desc)
        from (
          select p.* from procura p
          left join estoque e on e.modelo = p.modelo
          where coalesce(e.disponiveis, 0) = 0
          order by p.interessados desc limit v_limite
        ) p
      ), '[]'::jsonb),
      'disponiveis_sem_procura', coalesce((
        select jsonb_agg(jsonb_build_object(
          'modelo', e.modelo,
          'disponiveis', e.disponiveis,
          'preco_min', e.preco_min,
          'preco_max', e.preco_max
        ) order by e.disponiveis desc, e.modelo)
        from (
          select e.* from estoque e
          where e.disponiveis > 0
            and not exists (select 1 from procura p where p.modelo = e.modelo)
          order by e.disponiveis desc limit v_limite
        ) e
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
    'public.mcp_desempenho_anuncios(date, date, text, integer)',
    'public.mcp_resultado_campanhas(date, date, integer)',
    'public.mcp_demanda_estoque(date, date, integer)'
  ] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end;
$$;
