import asyncio
from collections.abc import Callable
from datetime import date
from typing import Annotated, Any, Literal
from uuid import UUID

from fastmcp import FastMCP
from fastmcp.exceptions import ToolError
from pydantic import Field

from app.core.consulta import consultar
from app.tools.contexto import LEITURA
from app.utils import comparacao, periodo

Inicio = Annotated[
    date | None,
    Field(description="Data inicial (AAAA-MM-DD), inclusiva. Padrão: 30 dias antes do fim."),
]
Fim = Annotated[
    date | None,
    Field(description="Data final (AAAA-MM-DD), inclusiva. Padrão: hoje. Período máximo de 93 dias."),
]
PipelineId = Annotated[
    UUID | None, Field(description="Filtra por um pipeline (id de `info_loja`).")
]
VendedorId = Annotated[
    UUID | None, Field(description="Filtra por um vendedor (id de `info_loja`).")
]
Limite = Annotated[int, Field(ge=1, le=200, description="Máximo de itens na lista.")]
Comparar = Annotated[
    bool,
    Field(description="Inclui a variação em relação ao período anterior de mesmo tamanho."),
]

TAGS = {"comercial"}

METRICAS_FUNIL = (
    "novos_leads", "vendas", "valor_vendido", "ticket_medio", "perdas",
    "taxa_conversao_pct", "vendas_com_valor_abaixo_de_1000",
)


def _periodo(inicio: date | None, fim: date | None) -> dict:
    ini, fim_ = periodo.resolver(inicio, fim)
    return {"p_inicio": ini.isoformat(), "p_fim": fim_.isoformat()}


def _metricas_funil(resultado: dict) -> dict:
    return {chave: resultado.get(chave) for chave in METRICAS_FUNIL}


def _totais_vendas(resultado: dict) -> dict:
    series = resultado.get("series") or []
    return {
        "vendas": sum(s.get("vendas") or 0 for s in series),
        "valor": sum(s.get("valor") or 0 for s in series),
        "vendas_com_valor_abaixo_de_1000": resultado.get("vendas_com_valor_abaixo_de_1000"),
    }


async def _consultar_comparando(
    funcao: str,
    params: dict[str, Any],
    inicio: date | None,
    fim: date | None,
    metricas: Callable[[dict], dict],
) -> dict:
    """Consulta o período e o anterior em paralelo e anexa as variações das métricas."""
    ini, fim_ = periodo.resolver(inicio, fim)
    ini_ant, fim_ant = comparacao.periodo_anterior(ini, fim_)
    atual, anterior = await asyncio.gather(
        consultar(funcao, {**params, "p_inicio": ini.isoformat(), "p_fim": fim_.isoformat()}),
        consultar(funcao, {**params, "p_inicio": ini_ant.isoformat(), "p_fim": fim_ant.isoformat()}),
    )
    atual["comparacao_periodo_anterior"] = {
        "periodo": {"inicio": ini_ant.isoformat(), "fim": fim_ant.isoformat()},
        "metricas": comparacao.variacoes(metricas(atual), metricas(anterior)),
    }
    return atual


def registrar(mcp: FastMCP) -> None:
    @mcp.tool(annotations=LEITURA, tags=TAGS)
    async def resumo_funil(
        inicio: Inicio = None,
        fim: Fim = None,
        pipeline_id: PipelineId = None,
        comparar_com_anterior: Comparar = False,
    ) -> dict:
        """Visão geral do funil de vendas no período: leads novos, vendas, valor
        vendido, ticket médio, perdas e taxa de conversão, mais um retrato ATUAL
        dos leads em aberto por etapa (quantidade, dias médios na etapa e quantos
        estão parados há mais de 7 dias).

        A conversão é "vendas fechadas no período / leads criados no período"
        (coortes diferentes). Se `vendas_com_valor_abaixo_de_1000` for alto, parte
        das vendas foi registrada com valor simbólico e o valor/ticket estão subestimados.
        Com `comparar_com_anterior`, traz a variação de cada métrica em relação ao
        período anterior de mesmo tamanho (use em vez de chamar duas vezes).
        """
        params = {"p_pipeline": pipeline_id}
        if comparar_com_anterior:
            return await _consultar_comparando(
                "mcp_resumo_funil", params, inicio, fim, _metricas_funil
            )
        return await consultar("mcp_resumo_funil", {**_periodo(inicio, fim), **params})

    @mcp.tool(annotations=LEITURA, tags=TAGS)
    async def leads_por_origem(
        inicio: Inicio = None, fim: Fim = None, pipeline_id: PipelineId = None
    ) -> list:
        """Desempenho por origem do lead (WhatsApp, tráfego pago, portais etc.):
        leads, vendas, valor vendido, perdas, conversão e, quando a loja cadastrou
        investimento por origem no CRM, investimento proporcional ao período,
        custo por lead e custo por venda. `investimento` nulo = não cadastrado.
        """
        return await consultar(
            "mcp_leads_por_origem", {**_periodo(inicio, fim), "p_pipeline": pipeline_id}
        )

    @mcp.tool(annotations=LEITURA, tags=TAGS)
    async def desempenho_vendedores(
        inicio: Inicio = None, fim: Fim = None, pipeline_id: PipelineId = None
    ) -> list:
        """Ranking de vendedores no período: leads recebidos, vendas, valor vendido,
        conversão, perdas e, no momento atual, leads em aberto, leads parados há mais
        de 7 dias e tarefas atrasadas. Inclui a linha "Sem responsável".

        Compare vendedores com volumes parecidos; conversão com poucos leads é instável.
        """
        return await consultar(
            "mcp_desempenho_vendedores", {**_periodo(inicio, fim), "p_pipeline": pipeline_id}
        )

    @mcp.tool(annotations=LEITURA, tags=TAGS)
    async def motivos_perda(
        inicio: Inicio = None,
        fim: Fim = None,
        pipeline_id: PipelineId = None,
        vendedor_id: VendedorId = None,
    ) -> list:
        """Motivos de perda no período, com quantidade, percentual e até 3 exemplos
        das observações escritas pelos vendedores."""
        return await consultar(
            "mcp_motivos_perda",
            {**_periodo(inicio, fim), "p_pipeline": pipeline_id, "p_vendedor": vendedor_id},
        )

    @mcp.tool(annotations=LEITURA, tags=TAGS)
    async def leads_parados(
        dias: Annotated[int, Field(ge=1, le=365, description="Parado há mais de N dias na etapa.")] = 7,
        pipeline_id: PipelineId = None,
        etapa_id: Annotated[UUID | None, Field(description="Filtra por etapa (id de `info_loja`).")] = None,
        vendedor_id: VendedorId = None,
        limite: Limite = 50,
        offset: Annotated[int, Field(ge=0, description="Paginação: itens a pular.")] = 0,
    ) -> dict:
        """Leads em aberto que estão há mais de N dias na mesma etapa do funil,
        do mais antigo para o mais recente, com responsável, etapa, origem e último
        contato. `total` traz a contagem completa; use `offset` para paginar.
        Telefones vêm mascarados."""
        return await consultar(
            "mcp_leads_parados",
            {
                "p_dias": dias,
                "p_pipeline": pipeline_id,
                "p_etapa": etapa_id,
                "p_vendedor": vendedor_id,
                "p_limite": limite,
                "p_offset": offset,
            },
        )

    @mcp.tool(annotations=LEITURA, tags=TAGS)
    async def buscar_lead(
        termo: Annotated[str, Field(min_length=3, description="Parte do nome ou do telefone.")],
    ) -> list:
        """Procura leads por nome ou telefone (até 10, mais recentes primeiro).
        Use `detalhar_lead` com o `lead_id` para ver a ficha completa."""
        return await consultar("mcp_buscar_lead", {"p_termo": termo})

    @mcp.tool(annotations=LEITURA, tags=TAGS)
    async def detalhar_lead(
        lead_id: Annotated[UUID, Field(description="Id do lead (de `buscar_lead` ou outras listas).")],
    ) -> dict:
        """Ficha completa de um lead: dados, etapa atual, responsável, venda/perda,
        histórico de etapas (20 últimas mudanças), interações registradas, tarefas e
        resumo das conversas de WhatsApp (sem o conteúdo das mensagens)."""
        resultado = await consultar("mcp_detalhar_lead", {"p_lead_id": lead_id})
        if resultado is None:
            raise ToolError("Lead não encontrado nesta loja.")
        return resultado

    @mcp.tool(annotations=LEITURA, tags=TAGS)
    async def tarefas(
        inicio: Inicio = None,
        fim: Fim = None,
        vendedor_id: VendedorId = None,
        situacao: Literal["atrasadas", "pendentes", "concluidas"] = "atrasadas",
        limite: Limite = 50,
    ) -> dict:
        """Tarefas da equipe: resumo (atrasadas e pendentes agora; criadas e
        concluídas no período), quebra por responsável e lista conforme a
        `situacao`. O período só afeta "criadas" e "concluídas"."""
        return await consultar(
            "mcp_tarefas",
            {
                **_periodo(inicio, fim),
                "p_vendedor": vendedor_id,
                "p_situacao": situacao,
                "p_limite": limite,
            },
        )

    @mcp.tool(annotations=LEITURA, tags=TAGS)
    async def estoque_veiculos(
        status: Literal["disponivel", "vendido", "indisponivel", "todos"] = "disponivel",
        marca: Annotated[str | None, Field(description="Filtra por marca (ex.: Fiat).")] = None,
        dias_minimo: Annotated[
            int | None, Field(ge=1, description="Só veículos cadastrados há mais de N dias.")
        ] = None,
        limite: Limite = 50,
    ) -> dict:
        """Resumo do estoque de veículos (quantidade por status, preços mínimo,
        mediano e máximo, distribuição por marca) e lista dos veículos.

        Se `data_de_entrada_confiavel` for falso, a loja usa integração de estoque
        que recria os veículos a cada sincronização: os "dias em estoque" NÃO
        representam o tempo real do carro na loja e não devem ser usados para concluir giro.
        """
        return await consultar(
            "mcp_estoque_veiculos",
            {
                "p_status": None if status == "todos" else status,
                "p_marca": marca,
                "p_dias_min": dias_minimo,
                "p_limite": limite,
            },
        )

    @mcp.tool(annotations=LEITURA, tags=TAGS)
    async def vendas_periodo(
        inicio: Inicio = None,
        fim: Fim = None,
        agrupar_por: Literal["dia", "semana", "mes", "vendedor", "origem", "pipeline"] = "semana",
        pipeline_id: PipelineId = None,
        comparar_com_anterior: Comparar = False,
    ) -> dict:
        """Série de vendas (quantidade e valor) no período agrupada por dia, semana,
        mês, vendedor, origem ou pipeline, mais os produtos/serviços mais vendidos
        quando a loja registra produtos nas vendas. Semanas começam na segunda-feira.
        Veja `vendas_com_valor_abaixo_de_1000` antes de concluir sobre faturamento.
        Com `comparar_com_anterior`, traz a variação dos totais (vendas e valor) em
        relação ao período anterior de mesmo tamanho."""
        params = {"p_agrupar": agrupar_por, "p_pipeline": pipeline_id}
        if comparar_com_anterior:
            return await _consultar_comparando(
                "mcp_vendas_periodo", params, inicio, fim, _totais_vendas
            )
        return await consultar("mcp_vendas_periodo", {**_periodo(inicio, fim), **params})
