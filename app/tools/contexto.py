from fastmcp import FastMCP

from app.core.consulta import consultar

LEITURA = {"readOnlyHint": True, "destructiveHint": False, "openWorldHint": False}


def registrar(mcp: FastMCP) -> None:
    @mcp.tool(annotations=LEITURA, tags={"contexto"})
    async def info_loja() -> dict:
        """Retorna o contexto da loja no Aucta CRM: nome, pipelines e suas etapas
        (com ids), equipe (vendedores e admins, com ids), instâncias de WhatsApp
        (e se têm IA de atendimento ativa) e permissões do assistente.

        Chame esta ferramenta primeiro em uma conversa nova: os ids retornados são
        usados como filtro nas outras ferramentas, e os nomes ajudam a interpretar
        os relatórios. Mensagens enviadas por instâncias com `ia_ativa = true`
        podem ter sido respondidas por um robô, não por um vendedor.
        """
        return await consultar("mcp_info_loja")
