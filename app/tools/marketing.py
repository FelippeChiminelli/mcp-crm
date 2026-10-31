"""Marketing: anúncios do Meta, campanhas de WhatsApp e demanda x estoque."""

from typing import Annotated, Literal

from fastmcp import FastMCP
from pydantic import Field

from app.core.consulta import consultar
from app.tools.comercial import Fim, Inicio, _periodo
from app.tools.contexto import LEITURA

TAGS = {"marketing"}


def registrar(mcp: FastMCP) -> None:
    @mcp.tool(annotations=LEITURA, tags=TAGS)
    async def desempenho_anuncios(
        inicio: Inicio = None,
        fim: Fim = None,
        agrupar_por: Literal["anuncio", "campanha", "conjunto"] = "anuncio",
        limite: Annotated[int, Field(ge=1, le=100, description="Máximo de grupos.")] = 30,
    ) -> dict:
        """Desempenho dos anúncios do Meta (Facebook/Instagram) que levaram o cliente
        ao WhatsApp: por anúncio, campanha ou conjunto, quantos leads chegaram no
        período e quantos já viraram venda ou perda (conversão até hoje, então
        períodos recentes têm conversão menor). Cada lead conta uma vez, no primeiro
        anúncio do período. Compare `leads_por_anuncio` com `leads_totais_no_periodo`
        para ver o peso do tráfego pago.

        O Meta nem sempre envia nome de campanha e conjunto: se
        `pct_com_nome_de_campanha` for baixo, agrupe por "anuncio". Investimento
        por origem está em `leads_por_origem`."""
        return await consultar(
            "mcp_desempenho_anuncios",
            {**_periodo(inicio, fim), "p_agrupar": agrupar_por, "p_limite": limite},
        )

    @mcp.tool(annotations=LEITURA, tags=TAGS)
    async def resultado_campanhas(
        inicio: Inicio = None,
        fim: Fim = None,
        horas_resposta: Annotated[
            int, Field(ge=1, le=168, description="Janela para considerar que o cliente respondeu.")
        ] = 72,
    ) -> dict:
        """Resultado das campanhas de disparo em massa no WhatsApp iniciadas no
        período: destinatários, leads que receberam, falhas de envio, quantos
        clientes responderam dentro da janela e quantos desses leads foram vendidos
        depois do envio. Campanhas em andamento ou pausadas ainda não enviaram para
        todos os destinatários.

        "vendas_depois" não prova que a campanha causou a venda; use como indício.
        Falha alta costuma indicar números inválidos ou instância desconectada."""
        return await consultar(
            "mcp_resultado_campanhas",
            {**_periodo(inicio, fim), "p_horas_resposta": horas_resposta},
        )

    @mcp.tool(annotations=LEITURA, tags=TAGS)
    async def demanda_x_estoque(
        inicio: Inicio = None,
        fim: Fim = None,
        limite: Annotated[int, Field(ge=1, le=100, description="Máximo de modelos por lista.")] = 30,
    ) -> dict:
        """Cruza os modelos de carro que os clientes procuraram com o estoque:
        modelos mais procurados (e quantos há disponíveis), procurados que a loja
        não tem disponível e disponíveis que ninguém procurou no período.

        Sinais de interesse: o título do anúncio do Meta que o cliente clicou (reflete
        o que a loja anunciou) e o carro informado à IA de qualificação (pedido
        espontâneo). O modelo é reconhecido pelo nome (ex.: "prisma", "t-cross").
        Se `sinais_com_modelo_identificado` for pequeno perto de `sinais_de_interesse`,
        os anúncios são institucionais e não há dado suficiente: diga isso em vez de
        concluir sobre a demanda."""
        return await consultar(
            "mcp_demanda_estoque", {**_periodo(inicio, fim), "p_limite": limite}
        )
