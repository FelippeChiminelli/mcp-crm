from typing import Annotated, Literal
from uuid import UUID

from fastmcp import FastMCP
from pydantic import Field

from app.core.consulta import consultar
from app.tools.comercial import Fim, Inicio, Limite, VendedorId, _periodo
from app.tools.contexto import LEITURA

InstanciaId = Annotated[
    UUID | None, Field(description="Filtra por instância de WhatsApp (id de `info_loja`).")
]

TAGS = {"atendimento"}

# Lembrete repetido nas ferramentas de tempo: a IA precisa considerar o expediente
OBS_HORARIO = (
    "Os tempos são corridos (não descontam noite nem fim de semana): antes de apontar "
    "falha, considere o horário de funcionamento da loja (pergunte ao usuário ou "
    "deduza por `mapa_demanda`). Mensagens da loja incluem respostas de vendedores, "
    "saudação automática, IA da instância e campanhas."
)


def com_obs_horario(fn):
    """Acrescenta OBS_HORARIO à docstring (aplicar antes de @mcp.tool)."""
    fn.__doc__ = f"{fn.__doc__.rstrip()}\n\n{OBS_HORARIO}"
    return fn


def registrar(mcp: FastMCP) -> None:
    @mcp.tool(annotations=LEITURA, tags=TAGS)
    async def chat_visao_geral(
        inicio: Inicio = None, fim: Fim = None, instancia_id: InstanciaId = None
    ) -> dict:
        """Panorama do atendimento no WhatsApp no período: conversas com mensagem,
        conversas novas, mensagens do cliente e da loja, percentual de áudio
        (áudios não são transcritos), imagens e ligações, e a situação ATUAL das
        conversas novas (nunca respondidas pela loja, aguardando a loja, cliente
        parou de responder etc.; veja `legenda_situacao`)."""
        return await consultar(
            "mcp_chat_visao_geral", {**_periodo(inicio, fim), "p_instancia": instancia_id}
        )

    @mcp.tool(annotations=LEITURA, tags=TAGS)
    @com_obs_horario
    async def tempo_resposta(
        inicio: Inicio = None,
        fim: Fim = None,
        agrupar_por: Literal["total", "vendedor", "instancia", "hora", "dia_semana"] = "total",
        excluir_instancias_com_ia: Annotated[
            bool,
            Field(description="Ignora instâncias com IA de atendimento (respostas de robô)."),
        ] = False,
        instancia_id: InstanciaId = None,
    ) -> dict:
        """Tempo que a loja leva para responder o cliente no WhatsApp. Cada "espera"
        começa quando o cliente manda mensagem depois de uma mensagem da loja (ou
        abre a conversa) e termina na próxima mensagem da loja, até 7 dias. Traz
        mediana, p90, média e faixas (até 5 min, 5–30 min, 30 min–2h, acima de 2h),
        agrupando por vendedor, instância, hora ou dia da semana em que a espera
        começou. Esperas ainda sem resposta não entram: use `conversas_sem_resposta`.

        Prefira a mediana e as faixas à média (poucas esperas longas distorcem a média).
        """
        return await consultar(
            "mcp_tempo_resposta",
            {
                **_periodo(inicio, fim),
                "p_agrupar": agrupar_por,
                "p_excluir_ia": excluir_instancias_com_ia,
                "p_instancia": instancia_id,
            },
        )

    @mcp.tool(annotations=LEITURA, tags=TAGS)
    @com_obs_horario
    async def conversas_sem_resposta(
        minutos: Annotated[int, Field(ge=1, le=10080, description="Cliente esperando há mais de N minutos.")] = 30,
        max_dias: Annotated[
            int, Field(ge=1, le=60, description="Ignora conversas paradas há mais de N dias (abandonadas).")
        ] = 7,
        vendedor_id: VendedorId = None,
        instancia_id: InstanciaId = None,
        limite: Limite = 50,
    ) -> dict:
        """Clientes esperando resposta AGORA: a última mensagem da conversa é do
        cliente e a loja não respondeu há mais de N minutos. Mostra o total, a
        quebra por responsável e a lista (mais antigas primeiro), indicando se a
        loja já tinha respondido antes nessa conversa. Responsável = vendedor da
        conversa ou, se vazio, o responsável do lead."""
        return await consultar(
            "mcp_conversas_sem_resposta",
            {
                "p_minutos": minutos,
                "p_max_dias": max_dias,
                "p_vendedor": vendedor_id,
                "p_instancia": instancia_id,
                "p_limite": limite,
            },
        )

    @mcp.tool(annotations=LEITURA, tags=TAGS)
    async def followup_ausente(
        dias: Annotated[int, Field(ge=1, le=60, description="Loja sem retomar o contato há mais de N dias.")] = 2,
        max_dias: Annotated[int, Field(ge=2, le=90, description="Janela máxima analisada, em dias.")] = 30,
        vendedor_id: VendedorId = None,
        limite: Limite = 50,
    ) -> dict:
        """Conversas com lead EM ABERTO em que a loja mandou a última mensagem há
        mais de N dias e ninguém retomou o contato (falta de follow-up). Mostra
        total, quebra por responsável e lista com a etapa do lead.
        `cliente_escreveu_na_janela = false` indica contato iniciado pela loja
        (prospecção) sem nenhuma resposta do cliente."""
        return await consultar(
            "mcp_followup_ausente",
            {"p_dias": dias, "p_max_dias": max_dias, "p_vendedor": vendedor_id, "p_limite": limite},
        )

    @mcp.tool(annotations=LEITURA, tags=TAGS)
    async def ligacoes(
        inicio: Inicio = None,
        fim: Fim = None,
        instancia_id: InstanciaId = None,
        horas_retorno: Annotated[
            int, Field(ge=1, le=72, description="Prazo para considerar que a loja retornou.")
        ] = 2,
        limite: Limite = 50,
    ) -> dict:
        """Ligações de WhatsApp no período, separando as feitas PELO CLIENTE e PELA
        LOJA, por resultado (atendida, perdida, recusada, não atendida...). Destaca
        as ligações do cliente que a loja perdeu ou recusou e quantas ficaram sem
        retorno da loja (mensagem ou ligação) dentro do prazo, com a lista."""
        return await consultar(
            "mcp_ligacoes",
            {
                **_periodo(inicio, fim),
                "p_instancia": instancia_id,
                "p_horas_retorno": horas_retorno,
                "p_limite": limite,
            },
        )

    @mcp.tool(annotations=LEITURA, tags=TAGS)
    async def mapa_demanda(
        inicio: Inicio = None, fim: Fim = None, instancia_id: InstanciaId = None
    ) -> list:
        """Mapa de calor da demanda: para cada dia da semana e hora (horário de
        Brasília), quantas mensagens os clientes enviaram e a mediana do tempo de
        resposta da loja. Use para identificar horários de pico, horários
        descobertos e o expediente real da loja."""
        return await consultar(
            "mcp_mapa_demanda", {**_periodo(inicio, fim), "p_instancia": instancia_id}
        )

    @mcp.tool(annotations=LEITURA, tags=TAGS)
    async def conversas_orfas(inicio: Inicio = None, fim: Fim = None, limite: Limite = 50) -> dict:
        """Conversas com mensagem no período que não têm responsável (nem na conversa
        nem no lead) e/ou não estão vinculadas a um lead no CRM. Conversas sem lead
        podem ser fornecedores, funcionários ou pós-venda; as com o cliente
        escrevendo e sem lead indicam oportunidades fora do funil. Mostra quebra por
        instância e lista das mais recentes em que o cliente escreveu."""
        return await consultar(
            "mcp_conversas_orfas", {**_periodo(inicio, fim), "p_limite": limite}
        )

    @mcp.tool(annotations=LEITURA, tags=TAGS)
    async def chat_x_conversao(inicio: Inicio = None, fim: Fim = None) -> dict:
        """Relação entre a velocidade da PRIMEIRA resposta da loja no WhatsApp e a
        venda: para os leads criados no período que escreveram, mostra leads,
        vendas e conversão por faixa de primeira resposta (até 5 min, 5–30 min,
        30 min–2h, mais de 2h, sem resposta). A venda conta até hoje, então
        períodos recentes têm conversão menor. Faixas com poucos leads não são
        conclusivas. Períodos longos podem ser lentos: prefira até 60 dias."""
        return await consultar("mcp_chat_x_conversao", _periodo(inicio, fim))
