"""Funil: conversão entre etapas, distribuição de leads e leads sem contato."""

from typing import Annotated

from fastmcp import FastMCP
from pydantic import Field

from app.core.consulta import consultar
from app.tools.comercial import Fim, Inicio, Limite, PipelineId, VendedorId, _periodo
from app.tools.contexto import LEITURA

TAGS = {"comercial"}


def registrar(mcp: FastMCP) -> None:
    @mcp.tool(annotations=LEITURA, tags=TAGS)
    async def conversao_etapas(
        inicio: Inicio = None, fim: Fim = None, pipeline_id: PipelineId = None
    ) -> dict:
        """Onde o funil vaza: acompanha os leads CRIADOS no período até hoje e mostra,
        para cada etapa de cada pipeline, quantos chegaram até ela ou além, o % em
        relação à etapa anterior, quantos estão nela agora, quantos foram perdidos
        ou vendidos estando nela e a mediana de dias até sair dela.

        Use `pct_da_etapa_anterior` para achar o maior gargalo e `perdidos_nesta_etapa`
        para ver em que ponto os leads são perdidos. Períodos recentes ainda têm
        leads em andamento; para conclusões sobre o funil completo, prefira períodos
        que terminaram há algumas semanas."""
        return await consultar(
            "mcp_conversao_etapas", {**_periodo(inicio, fim), "p_pipeline": pipeline_id}
        )

    @mcp.tool(annotations=LEITURA, tags=TAGS)
    async def distribuicao_leads(
        inicio: Inicio = None, fim: Fim = None, pipeline_id: PipelineId = None
    ) -> dict:
        """Como os leads foram distribuídos entre os vendedores (rodízio ou manual) no
        período: atribuições, % de cada vendedor, origens recebidas, vendas desses
        leads e o tempo entre receber o lead e a primeira mensagem da loja no WhatsApp
        (mediana e faixas). Mostra também quantos leads foram redistribuídos.

        Mensagens automáticas contam como contato ("ate_1_min" alto costuma ser
        automação). Se `pct_atribuicoes_com_contato_registrado` for baixo para a loja
        toda, o atendimento acontece fora do WhatsApp conectado ao CRM: não conclua
        que os vendedores não atendem. Períodos longos podem ser lentos: prefira até 60 dias."""
        return await consultar(
            "mcp_distribuicao_leads", {**_periodo(inicio, fim), "p_pipeline": pipeline_id}
        )

    @mcp.tool(annotations=LEITURA, tags=TAGS)
    async def leads_sem_contato(
        dias: Annotated[
            int, Field(ge=1, le=365, description="Sem mensagem (de ninguém) há mais de N dias.")
        ] = 3,
        max_dias: Annotated[
            int | None, Field(ge=2, le=730, description="Ignora leads parados há mais de N dias.")
        ] = None,
        vendedor_id: VendedorId = None,
        somente_sem_responsavel: Annotated[
            bool, Field(description="Só leads sem vendedor responsável.")
        ] = False,
        limite: Limite = 50,
        offset: Annotated[int, Field(ge=0, description="Paginação: itens a pular.")] = 0,
    ) -> dict:
        """Leads em aberto sem nenhuma mensagem de WhatsApp (nem da loja, nem do
        cliente) há mais de N dias, incluindo os que nunca foram contatados. Mesma
        regra da tela "Leads sem contato" do CRM. Mostra total, quebra por
        responsável e lista (mais antigos primeiro). Telefones vêm mascarados.

        Diferente de `followup_ausente` (a loja falou por último) e de
        `leads_parados` (tempo na etapa do funil)."""
        return await consultar(
            "mcp_leads_sem_contato",
            {
                "p_dias": dias,
                "p_max_dias": max_dias,
                "p_vendedor": vendedor_id,
                "p_sem_responsavel": somente_sem_responsavel,
                "p_limite": limite,
                "p_offset": offset,
            },
        )
